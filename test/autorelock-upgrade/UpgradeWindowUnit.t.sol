// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {RevertingVoteDelegation} from "../mocks/RevertingVoteDelegation.sol";
import {MockHemiVoteDelegation} from "../mocks/MockHemiVoteDelegation.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @dev A module whose `legacyDatingActive()` returns a chosen raw payload.
contract DatingProbeModule is MockHemiVoteDelegation {
    bytes internal payload;

    function setPayload(bytes memory p) external {
        payload = p;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory p = payload;
        assembly ("memory-safe") {
            return(add(p, 32), mload(p))
        }
    }
}

/**
 * Unit tests (no fork) for the upgrade-hour window:
 *   U1 `_imm` truth table through the booking stamp and `legacyDatingActive`;
 *   U2 sentinels (constructor, initialize on ERC1967Proxy / OZ5 TUP, no clobber);
 *   U3 the lazy close happens only in `_delegate`;
 *   U4 the arm on each proxy type;
 *   U5 the window probe: fail-open on broken/older modules, refusal on a
 *      deferring one, garbage returndata, and gas sweeps that never yield an
 *      armed position (below the removal gas floor, and across it).
 */
contract UpgradeWindowUnitTest is AutoRelockTestBase {
    uint256 constant HOUR = 3600;

    function _nb(uint256 t) internal pure returns (uint256) {
        return (t / HOUR) * HOUR + HOUR;
    }

    function _setW(address vvd_, uint256 w) internal {
        vm.store(vvd_, bytes32(uint256(101)), bytes32(w));
    }

    function _expected(uint256 w, uint256 t) internal pure returns (uint256) {
        uint256 b = _nb(t);
        return (w == 0 || b <= w) ? b : t + 1;
    }

    // ---- U1 ----------------------------------------------------------------

    function test_U1_immTruthTable() public {
        (uint256 id, , ) = createLock(victim, 1000 ether, 4 * 365 days);
        uint256 base = _nb(block.timestamp) + 10 * HOUR; // an hour start
        uint256[3] memory ts = [base + 1799, base + HOUR - 1, base + HOUR];
        for (uint256 i; i < ts.length; ++i) {
            uint256 t = ts[i];
            uint256 nb = _nb(t);
            uint256[9] memory ws = [
                uint256(0), 1, nb, nb + HOUR, (t / HOUR) * HOUR, t + 100 < nb ? t + 100 : nb - 1, nb + 100,
                uint256(type(uint64).max), t
            ];
            for (uint256 j; j < ws.length; ++j) {
                uint256 snap = vm.snapshotState();
                vm.warp(t);
                _setW(address(delegation), ws[j]);
                uint256 exp = _expected(ws[j], t);
                assertEq(delegation.legacyDatingActive(), exp != t + 1, "U1: legacyDatingActive");
                address to = address(uint160(0xD0D0 + j));
                vm.prank(victim);
                delegation.delegate(id, to);
                assertEq(uint256(delegation.delegationBookedAt(id)), exp, string.concat("U1: stamp t#", vm.toString(i), " w#", vm.toString(j)));
                if (ws[j] == 0) assertEq(uint256(delegation.legacyDatingUntil()), nb, "U1: lazy close value");
                else assertEq(uint256(delegation.legacyDatingUntil()), ws[j], "U1: W moved");
                vm.revertToState(snap);
            }
        }
    }

    /// Fuzzed equivalence of the fast path with the pure boundary form.
    function testFuzz_U1_fastPathEquivalence(uint64 w, uint32 dt) public {
        (uint256 id, , ) = createLock(victim, 1000 ether, 4 * 365 days);
        uint256 t = block.timestamp + bound(uint256(dt), 0, 3 * 365 days); // the lock is live throughout
        vm.warp(t);
        _setW(address(delegation), w);
        vm.prank(victim);
        delegation.delegate(id, address(0xD0D0));
        assertEq(uint256(delegation.delegationBookedAt(id)), _expected(w, t), "U1f: stamp");
    }

    // ---- U2 ----------------------------------------------------------------

    function test_U2_windowWordSentinels() public {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        assertEq(uint256(impl.legacyDatingUntil()), 1, "U2: constructor sentinel");
        assertEq(uint256(delegation.legacyDatingUntil()), 1, "U2: base harness VVD");
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        assertEq(uint256(VeHemiVoteDelegation(address(p)).legacyDatingUntil()), 1, "U2: initialize on ERC1967Proxy");
        TransparentUpgradeableProxy tp = new TransparentUpgradeableProxy(address(impl), address(this), abi.encodeWithSignature("initialize()"));
        assertEq(uint256(VeHemiVoteDelegation(address(tp)).legacyDatingUntil()), 1, "U2: initialize on OZ5 TUP");
        // TUP created with EMPTY data, then armed by upgradeAndCall, then initialize(): no clobber.
        TransparentUpgradeableProxy tp2 = new TransparentUpgradeableProxy(address(impl), address(this), "");
        assertEq(uint256(VeHemiVoteDelegation(address(tp2)).legacyDatingUntil()), 0, "U2: empty-data TUP starts at 0");
        ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(tp2), ERC1967Utils.ADMIN_SLOT)))));
        VeHemiVoteDelegation impl2 = new VeHemiVoteDelegation(address(veHemi));
        pa.upgradeAndCall(ITransparentUpgradeableProxy(address(tp2)), address(impl2), abi.encodeWithSignature("armLegacyDatingWindow()"));
        uint256 b = _nb(block.timestamp);
        assertEq(uint256(VeHemiVoteDelegation(address(tp2)).legacyDatingUntil()), b, "U2: armed");
        VeHemiVoteDelegation(address(tp2)).initialize();
        assertEq(uint256(VeHemiVoteDelegation(address(tp2)).legacyDatingUntil()), b, "U2: initialize clobbered the arm");
    }

    // ---- U3 ----------------------------------------------------------------

    function test_U3_lazyCloseOnlyInDelegate() public {
        (uint256 id, , ) = createLock(victim, 1000 ether, 4 * 365 days);
        (uint256 idShort, , ) = createLock(stranger, 1000 ether, 2 * SIX_DAYS + 100);
        address d = address(0xD0D1);
        vm.prank(victim);
        delegation.delegate(id, d);
        vm.prank(stranger);
        delegation.delegate(idShort, d); // expires before the warp: the amortiser has work
        vm.warp(block.timestamp + 7 * SIX_DAYS);
        _setW(address(delegation), 0);
        vm.record();
        delegation.writeNewCheckpointForExpiredDelegations(d); // SUCCESS path, W == 0
        delegation.refreshVotingPower(d);
        address[] memory a = new address[](1);
        a[0] = d;
        delegation.refreshVotingPowerBatch(a);
        try delegation.calculateExpiredDelegations(d) {} catch {}
        (, bytes32[] memory writes) = vm.accesses(address(delegation));
        for (uint256 i; i < writes.length; ++i) assertTrue(writes[i] != bytes32(uint256(101)), "U3: non-_delegate path wrote slot 101");
        assertEq(uint256(delegation.legacyDatingUntil()), 0, "U3: W moved");
        vm.prank(victim);
        delegation.delegate(id, address(0xD0D2));
        assertEq(uint256(delegation.legacyDatingUntil()), _nb(block.timestamp), "U3: _delegate did not close");
    }

    // ---- U4 ----------------------------------------------------------------

    function test_U4_armOnProxyTypes() public {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        impl.armLegacyDatingWindow();
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        VeHemiVoteDelegation(address(p)).armLegacyDatingWindow();
        TransparentUpgradeableProxy tp = new TransparentUpgradeableProxy(address(impl), address(this), abi.encodeWithSignature("initialize()"));
        ProxyAdmin pa = ProxyAdmin(address(uint160(uint256(vm.load(address(tp), ERC1967Utils.ADMIN_SLOT)))));
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        VeHemiVoteDelegation(address(tp)).armLegacyDatingWindow();
        vm.warp(_nb(block.timestamp) + 1799);
        pa.upgradeAndCall(ITransparentUpgradeableProxy(address(tp)), address(impl), abi.encodeWithSignature("armLegacyDatingWindow()"));
        assertEq(uint256(VeHemiVoteDelegation(address(tp)).legacyDatingUntil()), _nb(block.timestamp), "U4: arm through OZ5 ProxyAdmin");
        assertTrue(VeHemiVoteDelegation(address(tp)).legacyDatingActive(), "U4: window not active");
    }

    // ---- U5 (window probe) -------------------------------------------------

    function _armable() internal returns (uint256 id) {
        (id, , ) = createLock(victim, 1000 ether, 4 * 365 days);
    }

    function test_U5_windowProbe_failOpen_brokenAndOlderModules() public {
        uint256 id = _armable();
        uint256 snap = vm.snapshotState();
        veHemi.updateVoteDelegation(new RevertingVoteDelegation());
        enable(victim, id);
        assertTrue(veHemi.autoRelockRemaining(id) != 0, "U5: Reverting module blocked arming");
        vm.revertToState(snap);
        veHemi.updateVoteDelegation(new MockHemiVoteDelegation());
        enable(victim, id);
        assertTrue(veHemi.autoRelockRemaining(id) != 0, "U5: Mock module (no probe) blocked arming");
    }

    function test_U5_windowProbe_payloads() public {
        uint256 id = _armable();
        DatingProbeModule m = new DatingProbeModule();
        veHemi.updateVoteDelegation(m);
        bytes[5] memory ps = [abi.encode(uint256(1)), abi.encode(uint256(2)), bytes(hex"01"), abi.encode(uint256(0)), bytes("")];
        bool[5] memory refused = [true, true, false, false, false];
        for (uint256 i; i < ps.length; ++i) {
            uint256 snap = vm.snapshotState();
            m.setPayload(ps[i]);
            vm.prank(victim);
            if (refused[i]) vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
            veHemi.enableAutoRelock(id);
            vm.revertToState(snap);
        }
        // createLockWithAutoRelock is refused too
        m.setPayload(abi.encode(uint256(1)));
        hemi.mint(victim, 100 ether);
        vm.prank(victim);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        veHemi.createLockWithAutoRelock(100 ether, 3 * SIX_DAYS, true, false);
    }

    function test_U5_windowProbe_realVVD_inWindow_refused_atLastSecond_allowed() public {
        uint256 id = _armable();
        uint256 h = _nb(block.timestamp) + HOUR;
        vm.warp(h + 1799);
        _setW(address(delegation), h + HOUR);
        vm.prank(victim);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        veHemi.enableAutoRelock(id);
        vm.warp(h + HOUR - 1);
        enable(victim, id);
        assertTrue(veHemi.autoRelockRemaining(id) != 0, "U5: B-1 refused");
    }

    /// Gas sweep: inside the window, no gas limit yields an armed position.
    /// Every limit here is below the removal gas floor (8,176,984 gas left at
    /// the arming re-delegation), so the floor alone would refuse them; the
    /// band test below covers the limits where the floor is met.
    function test_U5_windowProbe_gasSweepNeverArms() public {
        uint256 id = _armable();
        uint256 h = _nb(block.timestamp) + HOUR;
        vm.warp(h + 1799);
        _setW(address(delegation), h + HOUR);
        for (uint256 g = 30_000; g <= 600_000; g += 2_500) {
            vm.prank(victim);
            (bool ok, ) = address(veHemi).call{gas: g}(abi.encodeCall(veHemi.enableAutoRelock, (id)));
            assertFalse(ok, "U5: an in-window enable succeeded");
            assertEq(veHemi.autoRelockRemaining(id), 0, "U5: armed by gas choice");
        }
    }

    /// Gas band across the removal gas floor: inside the window every limit
    /// from 8.0M to 9.5M reverts `VoteDelegationTransitionInProgress` (the
    /// probe gets its whole allowance, so the window check refuses before the
    /// floor is reached) and never arms. The control -- the same position an
    /// hour later, outside the window -- reverts `DelegationCallStarved` at the
    /// low end of the band and commits from its first limit that meets the
    /// floor, so the band really reaches it.
    function test_U5_windowProbe_gasBandAcrossTheFloorNeverArms() public {
        uint256 id = _armable(); // delegated to its owner, so the floor applies
        uint256 h = _nb(block.timestamp) + HOUR;
        vm.warp(h + 1799);
        _setW(address(delegation), h + HOUR);
        assertTrue(delegation.legacyDatingActive(), "U5: probe: window not active");
        uint256 start = vm.snapshotState();
        bytes memory refusal = abi.encodeWithSelector(VeHemi.VoteDelegationTransitionInProgress.selector);
        for (uint256 g = 8_000_000; g <= 9_500_000; g += 10_000) {
            vm.prank(victim);
            (bool ok, bytes memory ret) = address(veHemi).call{gas: g}(abi.encodeCall(veHemi.enableAutoRelock, (id)));
            assertFalse(ok, "U5: an in-window enable succeeded in the floor band");
            assertEq(veHemi.autoRelockRemaining(id), 0, "U5: armed by gas choice in the floor band");
            assertEq(ret, refusal, "U5: in-window refusal is not VoteDelegationTransitionInProgress");
        }

        // Control: the window has closed (W = h + HOUR); the same sweep.
        vm.revertToState(start);
        vm.warp(h + HOUR + 1799);
        assertFalse(delegation.legacyDatingActive(), "U5: probe: control still in the window");
        uint256 starved;
        uint256 firstCommit;
        for (uint256 g = 8_000_000; g <= 9_500_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(victim);
            (bool ok, bytes memory ret) = address(veHemi).call{gas: g}(abi.encodeCall(veHemi.enableAutoRelock, (id)));
            if (ok) {
                if (firstCommit == 0) firstCommit = g;
                assertTrue(veHemi.autoRelockRemaining(id) != 0, "U5: control committed unarmed");
            } else {
                assertEq(firstCommit, 0, "U5: control gas response not monotone");
                assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "U5: control refused for a reason other than the floor");
                ++starved;
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("control: first committing gas limit", firstCommit);
        emit log_named_uint("control: limits refused by the floor", starved);
        assertGt(starved, 0, "U5: vacuous -- the band starts above the floor");
        assertGt(firstCommit, 0, "U5: vacuous -- the band never meets the floor");
    }
}

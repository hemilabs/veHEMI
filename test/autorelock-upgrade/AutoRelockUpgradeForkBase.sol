// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../../src/VeHemi.sol";
import "../../src/VeHemiVoteDelegation.sol";
import "../../src/interfaces/IVeHemi.sol";
import "../../src/interfaces/IVeHemiVoteDelegation.sol";

interface IForkProxyAdmin {
    function upgrade(address proxy, address implementation) external;
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
}

interface IForkERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/**
 * Shared fork harness for the upgrade-hour window (`legacyDatingUntil`).
 * Throughout this directory B is the hour boundary that closes the window,
 * W is the stored window end (VVD slot 101, `legacyDatingUntil`), and A is
 * the delegatee of the picked position (`_pickDelegated`).
 *
 * Fork-only: skips without HEMI_RPC_URL. Forks at AUTORELOCK_TEST_FORK_BLOCK
 * (digits only; default 5,524,738) and logs the block it forked. Skips unless
 * the VVD proxy still points at the deployed implementation. setUp also asserts
 * the three on-chain premises the upgrade-hour window rests on, as deploy/08's
 * pre-flight 5b checks them: slot 101 is 0 or an hour boundary at or before the
 * next boundary (a window word left by an earlier window-arming forward, then a
 * rollback; the window-arming leg overwrites it), EIP-1967 admin == ProxyAdmin,
 * and Initializable `_initialized == 1`. Over a non-zero window word the
 * plain-leg bodies (`_upgradeBothPlain`) skip: they pin the fallback from
 * W == 0, and over a past boundary a plain leg dates writes immediately instead
 * (deploy/08 never queues a plain VVD leg).
 */
abstract contract AutoRelockUpgradeForkBase is Test {
    address constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address constant VVD_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;
    address constant PROXY_ADMIN = 0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F;
    address constant SAFE = 0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6;
    address constant HEMI_TOKEN = 0x99e3dE3817F6081B2568208337ef83295b7f591D;
    address constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    /// The live VVD implementation (deployments/hemi/VeHemiVoteDelegation_Implementation.json
    /// before the upgrade).
    address constant LIVE_VVD_IMPL = 0xAcAA0d96121C035fC21345551317d66921394128;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    uint256 constant HOUR = 3600;
    uint256 constant SIX_DAYS = 525_960;

    VeHemiVoteDelegation vvd;
    IVeHemi veHemi;
    address liveVeHemiImpl;
    bool forkReady;
    /// @dev VVD slot 101 (`legacyDatingUntil`) at the fork block: 0, or the
    ///      window word of an earlier window-arming forward that was rolled
    ///      back.
    uint256 priorWindowWord;
    // Implementations deployed once per test (so a re-upgrade reuses them).
    address newVeHemiImpl;
    address newVvdImpl;

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("HEMI_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        // Digits only: an empty or unset variable selects the default fork block,
        // anything else must parse (a comma-formatted block reverts here). The
        // block is logged so a rehearsal can check it ran at the signing block.
        string memory forkBlockEnv = vm.envOr("AUTORELOCK_TEST_FORK_BLOCK", string(""));
        vm.createSelectFork("hemi", bytes(forkBlockEnv).length == 0 ? 5_524_738 : vm.parseUint(forkBlockEnv));
        emit log_named_uint("fork block", block.number);
        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }
        if (address(uint160(uint256(vm.load(VVD_PROXY, IMPL_SLOT)))) != LIVE_VVD_IMPL) {
            vm.skip(true); // already upgraded at this block: the premise is gone
            return;
        }
        priorWindowWord = uint256(vm.load(VVD_PROXY, bytes32(uint256(101))));
        assertTrue(
            priorWindowWord == 0 || (priorWindowWord % HOUR == 0 && priorWindowWord <= _nextHourBoundary(block.timestamp)),
            "premise: VVD slot 101 is neither 0 nor a window word left by an earlier window-arming forward"
        );
        assertEq(address(uint160(uint256(vm.load(VVD_PROXY, ADMIN_SLOT)))), PROXY_ADMIN, "premise: VVD admin");
        assertEq(uint256(vm.load(VVD_PROXY, INITIALIZABLE_SLOT)), 1, "premise: VVD _initialized != 1");
        vvd = VeHemiVoteDelegation(VVD_PROXY);
        veHemi = IVeHemi(VEHEMI_PROXY);
        liveVeHemiImpl = address(uint160(uint256(vm.load(VEHEMI_PROXY, IMPL_SLOT))));
        forkReady = true;
    }

    function _nextHourBoundary(uint256 t) internal pure returns (uint256) {
        return (t / HOUR) * HOUR + HOUR;
    }

    function _deployImplementationsOnce() internal {
        if (newVvdImpl == address(0)) {
            newVeHemiImpl = address(new VeHemi(HEMI_TOKEN));
            newVvdImpl = address(new VeHemiVoteDelegation(VEHEMI_PROXY));
        }
    }

    function _armWindowCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(VeHemiVoteDelegation.armLegacyDatingWindow, ());
    }

    /// @dev THE deploy/08 batch shape: VeHemi FIRST (plain upgrade),
    ///      VVD SECOND via upgradeAndCall(armLegacyDatingWindow()).
    function _upgradeBothAndArmWindow() internal {
        _deployImplementationsOnce();
        vm.startPrank(SAFE);
        IForkProxyAdmin(PROXY_ADMIN).upgrade(VEHEMI_PROXY, newVeHemiImpl);
        IForkProxyAdmin(PROXY_ADMIN).upgradeAndCall(VVD_PROXY, newVvdImpl, _armWindowCalldata());
        vm.stopPrank();
        assertEq(uint256(vvd.legacyDatingUntil()), _nextHourBoundary(block.timestamp), "window arm: window end != next hour boundary");
    }

    /// @dev Two plain upgrades (no window arm): the fail-safe fallback. Skips
    ///      over a non-zero window word (see the contract header).
    function _upgradeBothPlain() internal {
        if (priorWindowWord != 0) {
            vm.skip(true); // these bodies pin the fallback from W == 0
            return;
        }
        _deployImplementationsOnce();
        vm.startPrank(SAFE);
        IForkProxyAdmin(PROXY_ADMIN).upgrade(VEHEMI_PROXY, newVeHemiImpl);
        IForkProxyAdmin(PROXY_ADMIN).upgrade(VVD_PROXY, newVvdImpl);
        vm.stopPrank();
    }

    function _upgradeVeHemiOnly() internal {
        _deployImplementationsOnce();
        vm.prank(SAFE);
        IForkProxyAdmin(PROXY_ADMIN).upgrade(VEHEMI_PROXY, newVeHemiImpl);
    }

    function _warpAndRollTo(uint256 t) internal {
        vm.warp(t);
        vm.roll(block.number + 1);
    }

    /// @dev A block after `boundary_` (never backwards in time).
    function _toAfterBoundary(uint256 boundary_) internal {
        uint256 t = boundary_ + 10;
        if (t <= block.timestamp) t = block.timestamp + 12;
        _warpAndRollTo(t);
    }

    /// @dev The next 12 s Hemi block, unless that would cross into the next
    ///      hour from B-1, in which case stay in the same block.
    function _nextBlockOrSame(uint256 boundary_) internal {
        if (block.timestamp + 1 != boundary_) _warpAndRollTo(block.timestamp + 12);
    }

    /// @dev The first delegated position in the scan range with id >= `from_`,
    ///      at least 30 days from its end, weighing at least `minWeight_`.
    function _pickDelegatedFrom(uint256 from_, uint256 minWeight_)
        internal
        view
        returns (uint256 id, address owner, address delegatee)
    {
        uint256 lo = vm.envOr("AUTORELOCK_FORK_SCAN_LO", uint256(29400));
        uint256 hi = vm.envOr("AUTORELOCK_FORK_SCAN_HI", uint256(29720));
        if (from_ > lo) lo = from_;
        for (uint256 i = lo; i < hi; ++i) {
            (address d,,,,) = vvd.delegations(i);
            if (d == address(0)) continue;
            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(i);
            if (uint256(lb.end) < block.timestamp + 30 days) continue;
            if (veHemi.balanceOfNFT(i) < minWeight_) continue;
            return (i, veHemi.ownerOf(i), d);
        }
        revert("no delegated position in the scan range at least 30 days from its end and weighing at least minWeight_");
    }

    function _pickDelegated() internal view returns (uint256, address, address) {
        return _pickDelegatedFrom(0, 1e18);
    }

    /// The seven execution offsets (seconds after the hour's start). All are
    /// == 11 mod 12 (Hemi block times); 3599 is B-1, the last second of the hour.
    /// 3575 is the latest offset whose follow-up write (12 s later) still
    /// discriminates (it lands at B-13, not B-1).
    function _offsets() internal pure returns (uint256[7] memory o) {
        o = [uint256(11), 23, 599, 1799, 3011, 3575, 3599];
    }

    // ---------------- raw-state observation (layout of VeHemiDelegationStorageV1) ----------------

    function _checkpointArraySlot(address d) internal pure returns (bytes32) {
        return keccak256(abi.encode(d, uint256(1)));
    }

    /// @dev Raw words of delegateCheckpoints[d] (length + every element, 2 words each).
    function _rawArray(address d) internal view returns (bytes32[] memory words) {
        bytes32 arraySlot = _checkpointArraySlot(d);
        uint256 len = uint256(vm.load(VVD_PROXY, arraySlot));
        words = new bytes32[](1 + 2 * len);
        words[0] = bytes32(len);
        uint256 data = uint256(keccak256(abi.encode(arraySlot)));
        for (uint256 i; i < 2 * len; ++i) words[1 + i] = vm.load(VVD_PROXY, bytes32(data + i));
    }

    function _rawRecord(uint256 id) internal view returns (bytes32 recordWord0, bytes32 recordWord1) {
        uint256 recordSlot = uint256(keccak256(abi.encode(id, uint256(0))));
        recordWord0 = vm.load(VVD_PROXY, bytes32(recordSlot));
        recordWord1 = vm.load(VVD_PROXY, bytes32(recordSlot + 1));
    }

    function _rawBucket(address d, uint256 k) internal view returns (bytes32) {
        return vm.load(VVD_PROXY, keccak256(abi.encode(k, keccak256(abi.encode(d, uint256(2))))));
    }

    /// @dev One digest over the raw state of `delegatees` x (`keys` buckets) and the
    ///      records of `ids`, plus per-item words for diagnostics.
    function _observe(address[] memory delegatees, uint256[] memory ids, uint256[] memory keys)
        internal
        view
        returns (bytes32[] memory items)
    {
        items = new bytes32[](delegatees.length * (1 + keys.length) + ids.length);
        uint256 n;
        for (uint256 i; i < delegatees.length; ++i) {
            items[n++] = keccak256(abi.encode(_rawArray(delegatees[i])));
            for (uint256 j; j < keys.length; ++j) items[n++] = _rawBucket(delegatees[i], keys[j]);
        }
        for (uint256 i; i < ids.length; ++i) {
            (bytes32 recordWord0, bytes32 recordWord1) = _rawRecord(ids[i]);
            items[n++] = keccak256(abi.encode(recordWord0, recordWord1));
        }
    }

    function _assertSameObservation(bytes32[] memory x, bytes32[] memory y, string memory what) internal {
        assertEq(x.length, y.length, string.concat(what, ": observation length"));
        for (uint256 i; i < x.length; ++i) {
            if (x[i] != y[i]) emit log_named_uint(string.concat(what, ": raw-state mismatch at item"), i);
        }
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)), string.concat(what, ": raw state differs between the two worlds"));
    }

    /// @dev DelegateVotesChanged(delegatee, prev, new) emitted by the VVD proxy, in order.
    function _delegateVotesChangedDigests(Vm.Log[] memory logs) internal pure returns (bytes32[] memory out) {
        bytes32 topic0 = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == VVD_PROXY && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
        out = new bytes32[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == VVD_PROXY && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                out[n++] = keccak256(abi.encode(logs[i].topics[1], logs[i].data));
            }
        }
    }

    function _countTopic(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }
}

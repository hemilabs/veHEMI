// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// S12 — THE GUARD SPEC. Behavioural coverage of VeHemi's `nonReentrant`
/// guard, asserted by the guard's own selector (`ReentrancyGuardReentrantCall`):
///
///   G1-G3  `safeTransferFrom` takes the guard itself and holds it across
///          `onERC721Received`: a re-entering hook is refused (G1), an
///          ordinary receiver is unaffected (G2), and a hook that does not
///          swallow the refusal reverts the whole transfer (G3);
///   G4     a delegation module that re-enters a guarded VeHemi entry point
///          from inside `_delegate` is refused.

contract BenignReceiver is IERC721Receiver {
    uint256 public seen;
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        seen++;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// Re-enters and SWALLOWS the revert, so the outer call still returns.
contract SwallowingReentrant is IERC721Receiver {
    VeHemi ve;
    uint8 public mode;
    bool public armed;
    bool public innerOk;
    bytes4 public innerErr;
    address public sink;
    constructor(VeHemi v) { ve = v; }
    function arm(uint8 m, address s) external { mode = m; sink = s; armed = true; innerOk = false; innerErr = bytes4(0); }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (armed) {
            armed = false;
            bytes memory cd;
            if (mode == 1) cd = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), sink, id);
            else if (mode == 2) cd = abi.encodeWithSignature("withdraw(uint256)", id);
            else cd = abi.encodeWithSignature("createLock(uint256,uint256)", uint256(10 ether), uint256(365 days));
            (bool s, bytes memory r) = address(ve).call(cd);
            innerOk = s;
            if (!s && r.length >= 4) innerErr = bytes4(r);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// Re-enters and does NOT swallow — the revert propagates.
contract PropagatingReentrant is IERC721Receiver {
    VeHemi ve;
    constructor(VeHemi v) { ve = v; }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        ve.transferFrom(address(this), address(0xBEEF), id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// A module that satisfies every decode contract VeHemi enforces and re-enters
/// from inside `VeHemi._delegate`.
contract GuardProbeModule {
    VeHemi public ve;
    bool public armed;
    address public tgt;
    bytes public cd;
    bool public ok;
    bytes4 public err;
    function setVeHemi(VeHemi v) external { ve = v; }
    function arm(address t, bytes calldata c) external { tgt = t; cd = c; armed = true; ok = false; err = bytes4(0); }
    function delegation(uint256) external pure returns (IVeHemiVoteDelegation.Delegation memory d) { return d; }
    function autoDelegate(address) external pure returns (address) { return address(0); }
    function delegate(uint256, address) external {
        if (!armed) return;
        armed = false;
        (bool s, bytes memory r) = tgt.call(cd);
        ok = s;
        if (!s && r.length >= 4) err = bytes4(r);
    }
}

contract S12GuardSpec is LockedCurveTestBase {
    bytes4 immutable GUARD = ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector;

    function _lock(address who, uint256 amt, uint256 dur) internal returns (uint256 id) {
        hemi.mint(who, amt);
        vm.startPrank(who);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLock(amt, dur);
        vm.stopPrank();
    }

    // -- G1: a receiver hook cannot re-enter transferFrom, withdraw or createLock
    function test_S12_G1_receiverHookReentryRevertsWithTheGuard() public {
        SwallowingReentrant rc = new SwallowingReentrant(veHemi);
        hemi.mint(address(rc), 1_000 ether);
        vm.prank(address(rc)); hemi.approve(address(veHemi), type(uint256).max);

        uint256 refusedByGuard;
        for (uint8 m = 1; m <= 3; ++m) {
            uint256 snap = vm.snapshotState();
            vm.warp(1_700_000_000);
            uint256 id = _lock(bob, 100 ether, m == 2 ? 370 days : 2 * 365 days);
            vm.warp(block.timestamp + (m == 2 ? 400 days : 2 hours));
            rc.arm(m, address(0xBEEF));
            vm.prank(bob);
            veHemi.safeTransferFrom(bob, address(rc), id);
            bool innerOk = rc.innerOk();
            bytes4 e = rc.innerErr();
            emit log_named_string(
                string.concat("S12/G1 hook re-entry mode ", vm.toString(uint256(m))),
                innerOk ? "ADMITTED" : string.concat("refused ", vm.toString(bytes32(e)))
            );
            if (!innerOk && e == GUARD) refusedByGuard++;
            vm.revertToState(snap);
        }
        emit log_named_uint("S12/G1 modes refused by the GUARD", refusedByGuard);
        assertEq(refusedByGuard, 3, "G1: onERC721Received re-entry is NOT refused by the reentrancy guard");
    }

    // -- G2: the ordinary path is unaffected ---------------------------------
    function test_S12_G2_ordinarySafeTransferIsUnaffected() public {
        vm.warp(1_700_000_000);
        uint256 id = _lock(bob, 100 ether, 2 * 365 days);
        vm.warp(block.timestamp + 2 hours);
        BenignReceiver b = new BenignReceiver();
        vm.prank(bob);
        veHemi.safeTransferFrom(bob, address(b), id);
        assertEq(b.seen(), 1, "G2: the receiver hook did not fire");
        assertEq(veHemi.ownerOf(id), address(b), "G2: the token did not arrive");
    }

    // -- G3: a hook that does not swallow reverts the WHOLE transfer ---------
    function test_S12_G3_aNonSwallowingHookRevertsTheWholeTransfer() public {
        vm.warp(1_700_000_000);
        uint256 id = _lock(bob, 100 ether, 2 * 365 days);
        vm.warp(block.timestamp + 2 hours);
        PropagatingReentrant p = new PropagatingReentrant(veHemi);
        vm.prank(bob);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        veHemi.safeTransferFrom(bob, address(p), id);
    }

    // -- G4: the module path IS guarded --------------------------------------
    function test_S12_G4_moduleReentryIntoAGuardedEntryPointReverts() public {
        GuardProbeModule mod = new GuardProbeModule();
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy px = new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, admin));
        VeHemi ve2 = VeHemi(address(px));
        mod.setVeHemi(ve2);
        ve2.updateVoteDelegation(IVeHemiVoteDelegation(address(mod)));

        string[5] memory names = ["checkpoint()", "withdraw(1)", "createLock", "transferFrom", "retireStaleAutoRelock(1)"];
        uint256 refused;
        for (uint256 i; i < 5; ++i) {
            uint256 snap = vm.snapshotState();
            bytes memory cd;
            if (i == 0) cd = abi.encodeWithSignature("checkpoint()");
            else if (i == 1) cd = abi.encodeWithSignature("withdraw(uint256)", uint256(1));
            else if (i == 2) cd = abi.encodeWithSignature("createLock(uint256,uint256)", uint256(10 ether), uint256(365 days));
            else if (i == 3) cd = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(mod), address(0xBEEF), uint256(1));
            else cd = abi.encodeWithSignature("retireStaleAutoRelock(uint256)", uint256(1));
            mod.arm(address(ve2), cd);
            hemi.mint(alice, 100 ether);
            vm.startPrank(alice);
            hemi.approve(address(ve2), type(uint256).max);
            ve2.createLock(100 ether, 365 days);
            vm.stopPrank();
            emit log_named_string(
                string.concat("S12/G4 ", names[i]),
                mod.ok() ? "ADMITTED" : string.concat("refused ", vm.toString(bytes32(mod.err())))
            );
            if (!mod.ok() && mod.err() == GUARD) refused++;
            vm.revertToState(snap);
        }
        emit log_named_uint("S12/G4 refused by the GUARD", refused);
        assertEq(refused, 5, "G4: a guarded VeHemi entry point admitted a re-entrant module");
    }
}

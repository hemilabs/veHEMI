// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// Behavioural coverage of VeHemi's `nonReentrant` guard, asserted by the
/// guard's own selector (`ReentrancyGuardReentrantCall`):
///
///   G1-G3  `safeTransferFrom` takes the guard itself and holds it across
///          `onERC721Received`: a re-entering hook is refused (G1), an
///          ordinary receiver is unaffected (G2), and a hook that does not
///          swallow the refusal reverts the whole transfer (G3);
///   G4     a delegation module that re-enters a guarded VeHemi entry point
///          from inside `_delegate` is refused.

contract BenignReceiver is IERC721Receiver {
    uint256 public hookCalls;
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        hookCalls++;
        return IERC721Receiver.onERC721Received.selector;
    }
}

// The guarded entry point a `SwallowingReentrantReceiver` re-enters.
enum ReentryTarget { TransferFrom, Withdraw, CreateLock }

/// Re-enters and SWALLOWS the revert, so the outer call still returns.
contract SwallowingReentrantReceiver is IERC721Receiver {
    VeHemi ve;
    ReentryTarget public reentryTarget;
    bool public reentryPending;
    bool public innerOk;
    bytes4 public innerErr;
    address public sink;
    constructor(VeHemi ve_) { ve = ve_; }
    function setReentry(ReentryTarget reentryTarget_, address sink_) external {
        reentryTarget = reentryTarget_; sink = sink_; reentryPending = true; innerOk = false; innerErr = bytes4(0);
    }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (reentryPending) {
            reentryPending = false;
            bytes memory callData;
            if (reentryTarget == ReentryTarget.TransferFrom) {
                callData = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), sink, id);
            } else if (reentryTarget == ReentryTarget.Withdraw) {
                callData = abi.encodeWithSignature("withdraw(uint256)", id);
            } else {
                callData = abi.encodeWithSignature("createLock(uint256,uint256)", uint256(10 ether), uint256(365 days));
            }
            (bool ok, bytes memory ret) = address(ve).call(callData);
            innerOk = ok;
            if (!ok && ret.length >= 4) innerErr = bytes4(ret);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// Re-enters and does NOT swallow — the revert propagates.
contract PropagatingReentrantReceiver is IERC721Receiver {
    VeHemi ve;
    constructor(VeHemi ve_) { ve = ve_; }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        ve.transferFrom(address(this), address(0xBEEF), id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// A module that satisfies every decode contract VeHemi enforces and re-enters
/// from inside `VeHemi._delegate`.
contract ReentrantDelegationModule {
    VeHemi public ve;
    bool public reentryPending;
    address public target;
    bytes public callData;
    bool public innerOk;
    bytes4 public innerErr;
    function setVeHemi(VeHemi ve_) external { ve = ve_; }
    function setReentry(address target_, bytes calldata callData_) external {
        target = target_; callData = callData_; reentryPending = true; innerOk = false; innerErr = bytes4(0);
    }
    function delegation(uint256) external pure returns (IVeHemiVoteDelegation.Delegation memory d) { return d; }
    function autoDelegate(address) external pure returns (address) { return address(0); }
    function delegate(uint256, address) external {
        if (!reentryPending) return;
        reentryPending = false;
        (bool ok, bytes memory ret) = target.call(callData);
        innerOk = ok;
        if (!ok && ret.length >= 4) innerErr = bytes4(ret);
    }
}

contract NonReentrantGuardTest is LockedCurveTestBase {
    bytes4 immutable GUARD_SELECTOR = ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector;

    function _lock(address who, uint256 amt, uint256 dur) internal returns (uint256 id) {
        hemi.mint(who, amt);
        vm.startPrank(who);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLock(amt, dur);
        vm.stopPrank();
    }

    // -- G1: a receiver hook cannot re-enter transferFrom, withdraw or createLock
    function test_G1_receiverHookReentryRevertsWithTheGuard() public {
        SwallowingReentrantReceiver receiver = new SwallowingReentrantReceiver(veHemi);
        hemi.mint(address(receiver), 1_000 ether);
        vm.prank(address(receiver)); hemi.approve(address(veHemi), type(uint256).max);

        string[3] memory targets = ["transferFrom", "withdraw", "createLock"];
        uint256 refusedByGuard;
        for (uint8 i; i < 3; ++i) {
            ReentryTarget reentryTarget = ReentryTarget(i);
            uint256 snap = vm.snapshotState();
            vm.warp(1_700_000_000);
            uint256 id = _lock(bob, 100 ether, reentryTarget == ReentryTarget.Withdraw ? 370 days : 2 * 365 days);
            vm.warp(block.timestamp + (reentryTarget == ReentryTarget.Withdraw ? 400 days : 2 hours));
            receiver.setReentry(reentryTarget, address(0xBEEF));
            vm.prank(bob);
            veHemi.safeTransferFrom(bob, address(receiver), id);
            bool innerOk = receiver.innerOk();
            bytes4 innerErr = receiver.innerErr();
            emit log_named_string(
                string.concat("G1 hook re-entry into ", targets[i]),
                innerOk ? "ADMITTED" : string.concat("refused ", vm.toString(bytes32(innerErr)))
            );
            if (!innerOk && innerErr == GUARD_SELECTOR) refusedByGuard++;
            vm.revertToState(snap);
        }
        emit log_named_uint("G1 targets refused by the GUARD", refusedByGuard);
        assertEq(refusedByGuard, 3, "G1: onERC721Received re-entry is NOT refused by the reentrancy guard");
    }

    // -- G2: the ordinary path is unaffected ---------------------------------
    function test_G2_ordinarySafeTransferIsUnaffected() public {
        vm.warp(1_700_000_000);
        uint256 id = _lock(bob, 100 ether, 2 * 365 days);
        vm.warp(block.timestamp + 2 hours);
        BenignReceiver benign = new BenignReceiver();
        vm.prank(bob);
        veHemi.safeTransferFrom(bob, address(benign), id);
        assertEq(benign.hookCalls(), 1, "G2: the receiver hook did not fire");
        assertEq(veHemi.ownerOf(id), address(benign), "G2: the token did not arrive");
    }

    // -- G3: a hook that does not swallow reverts the WHOLE transfer ---------
    function test_G3_aNonSwallowingHookRevertsTheWholeTransfer() public {
        vm.warp(1_700_000_000);
        uint256 id = _lock(bob, 100 ether, 2 * 365 days);
        vm.warp(block.timestamp + 2 hours);
        PropagatingReentrantReceiver propagating = new PropagatingReentrantReceiver(veHemi);
        vm.prank(bob);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        veHemi.safeTransferFrom(bob, address(propagating), id);
    }

    // -- G4: the module path IS guarded --------------------------------------
    function test_G4_moduleReentryIntoAGuardedEntryPointReverts() public {
        ReentrantDelegationModule module = new ReentrantDelegationModule();
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, admin));
        VeHemi isolatedVeHemi = VeHemi(address(proxy));
        module.setVeHemi(isolatedVeHemi);
        isolatedVeHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(module)));

        string[5] memory names = ["checkpoint()", "withdraw(1)", "createLock", "transferFrom", "retireStaleAutoRelock(1)"];
        uint256 refused;
        for (uint256 i; i < 5; ++i) {
            uint256 snap = vm.snapshotState();
            bytes memory callData;
            if (i == 0) callData = abi.encodeWithSignature("checkpoint()");
            else if (i == 1) callData = abi.encodeWithSignature("withdraw(uint256)", uint256(1));
            else if (i == 2) callData = abi.encodeWithSignature("createLock(uint256,uint256)", uint256(10 ether), uint256(365 days));
            else if (i == 3) callData = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(module), address(0xBEEF), uint256(1));
            else callData = abi.encodeWithSignature("retireStaleAutoRelock(uint256)", uint256(1));
            module.setReentry(address(isolatedVeHemi), callData);
            hemi.mint(alice, 100 ether);
            vm.startPrank(alice);
            hemi.approve(address(isolatedVeHemi), type(uint256).max);
            isolatedVeHemi.createLock(100 ether, 365 days);
            vm.stopPrank();
            emit log_named_string(
                string.concat("G4 ", names[i]),
                module.innerOk() ? "ADMITTED" : string.concat("refused ", vm.toString(bytes32(module.innerErr())))
            );
            if (!module.innerOk() && module.innerErr() == GUARD_SELECTOR) refused++;
            vm.revertToState(snap);
        }
        emit log_named_uint("G4 refused by the GUARD", refused);
        assertEq(refused, 5, "G4: a guarded VeHemi entry point admitted a re-entrant module");
    }
}

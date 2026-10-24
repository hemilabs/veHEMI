// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";

/**
 * @title CheckpointLayoutSwallowTest
 * @notice A `CheckpointLayoutViolated` revert inside `VeHemi._delegate`'s try/catch is
 *         swallowed by design -- FAIL-CLOSED: the corrupt array is not written through,
 *         the delegatee's represented weight does not move, and the NFT operation still
 *         completes -- and the swallow is ATTRIBUTABLE: next to the reason-less
 *         `DelegationUpdateFailed`, VeHemi emits `DelegationUpdateFailedReason` with the
 *         selector of the eaten revert. Principal stays recoverable.
 *         The corrupt array is written with `vm.store` (layout clause (2) broken: a
 *         second future element).
 */
contract CheckpointLayoutSwallowTest is LockedCurveTestBase {
    uint256 internal constant CP_SLOT = 1;

    error CheckpointLayoutViolated();
    event DelegationUpdateFailed(uint256 indexed delegator);
    event DelegationUpdateFailedReason(uint256 indexed delegator, bytes4 reason);

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }
    /// `increaseAmount` is owner-only (`NotOwner` for anyone else), so the
    /// top-up that reaches the guard is the POSITION OWNER's.
    function _topUp(address owner_, uint256 id, uint256 amt) internal {
        hemi.mint(owner_, amt);
        vm.prank(owner_); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(owner_); veHemi.increaseAmount(id, amt);
    }
    function _cps(address d) internal view returns (VeHemiVoteDelegation.DelegateCheckpoint[] memory) {
        return delegation.getDelegationCheckpoints(d);
    }
    function _nb(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }
    function _arrSlot(address d) internal pure returns (uint256) { return uint256(keccak256(abi.encode(d, CP_SLOT))); }
    function _dataSlot(address d) internal pure returns (uint256) { return uint256(keccak256(abi.encode(bytes32(_arrSlot(d))))); }
    function _len(address d) internal view returns (uint256) { return uint256(vm.load(address(delegation), bytes32(_arrSlot(d)))); }
    function _setLen(address d, uint256 n) internal { vm.store(address(delegation), bytes32(_arrSlot(d)), bytes32(n)); }
    function _setTs(address d, uint256 i, uint256 ts) internal {
        bytes32 s = bytes32(_dataSlot(d) + 2 * i + 1);
        uint256 w = uint256(vm.load(address(delegation), s));
        w = (w & ((uint256(1) << 192) - 1)) | (ts << 192);
        vm.store(address(delegation), s, bytes32(w));
    }
    function _copyEl(address d, uint256 from, uint256 to) internal {
        for (uint256 k; k < 2; ++k) {
            vm.store(address(delegation), bytes32(_dataSlot(d) + 2 * to + k),
                vm.load(address(delegation), bytes32(_dataSlot(d) + 2 * from + k)));
        }
    }
    /// A layout-compliant `[live, pending]` base, then a second future element
    /// (clause (2) of the layout invariant on `_applyToCheckpoints` broken).
    function _armSecondFutureElement() internal returns (uint256 idA) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nb(block.timestamp) + 120);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(block.timestamp + 600);
        uint256 n = _len(bob);
        uint256 B = _nb(block.timestamp);
        _copyEl(bob, n - 1, n);
        _setLen(bob, n + 1);
        _setTs(bob, n, B);
        _setTs(bob, _len(bob) - 2, B - 1);   // clause (2) broken: a SECOND future element
    }

    // ======================================================= ATTRIBUTION
    /// *** THE VIOLATION IS ATTRIBUTABLE ON CHAIN. ***
    /// The swallow happens -- `transferFrom` returns normally -- but the
    /// transaction carries the selector of the revert that was eaten, so
    /// `CheckpointLayoutViolated` is distinguishable from the other causes
    /// that share this catch.
    function test_layoutViolationIsAttributable() public {
        uint256 idA = _armSecondFutureElement();

        vm.expectEmit(true, false, false, true, address(veHemi));
        emit DelegationUpdateFailedReason(idA, CheckpointLayoutViolated.selector);
        vm.prank(alice); veHemi.transferFrom(alice, charlie, idA);

        assertEq(veHemi.ownerOf(idA), charlie, "premise: the NFT still moved - this is still a swallow");
    }

    /// The reason-less `DelegationUpdateFailed` is emitted as well, so indexers
    /// that watch it see the failure. VeHemi emits it immediately before
    /// `DelegationUpdateFailedReason`; this body pins that event, not the order.
    function test_swallowedLayoutViolation_alsoEmitsDelegationUpdateFailed() public {
        uint256 idA = _armSecondFutureElement();
        vm.expectEmit(true, false, false, false, address(veHemi));
        emit DelegationUpdateFailed(idA);
        vm.prank(alice); veHemi.transferFrom(alice, charlie, idA);
    }

    // ======================================================= FAIL-CLOSED
    /// *** THE CORRUPTED DELEGATEE IS FROZEN: THE FAIL-CLOSED DESIGN. ***
    /// A write that would go through the corrupt array is refused, so the
    /// escrow grows while the represented weight stays where it was (and the
    /// refusal is announced, per the bodies above).
    function test_corruptedDelegateeFailsClosed() public {
        uint256 idA = _armSecondFutureElement();
        uint256 votesBefore = delegation.getVotes(bob);
        uint256 escrowBefore = veHemi.balanceOfNFT(idA);
        _topUp(alice, idA, 400 ether);
        uint256 escrowAfter = veHemi.balanceOfNFT(idA);

        assertGt(escrowAfter, escrowBefore, "premise: the ESCROW really grew");
        assertEq(delegation.getVotes(bob), votesBefore,
            "FAIL-CLOSED: represented weight must not move through a corrupt array");
        emit log_named_uint("escrow grew by   ", escrowAfter - escrowBefore);
        emit log_named_uint("represented delta", 0);
    }

    /// NO TRAPPED PRINCIPAL: re-reverting the eaten error would trap the
    /// principal behind a corrupt delegatee array; the swallow must not.
    function test_swallowedLayoutViolation_principalIsNotTrapped() public {
        uint256 idA = _armSecondFutureElement();
        uint256 before_ = hemi.balanceOf(alice);
        vm.warp(veHemi.getLockedBalance(idA).end + 1);
        vm.prank(alice); veHemi.withdraw(idA);
        assertGt(hemi.balanceOf(alice), before_, "principal must be recoverable with no owner action");
    }

    /// Control: on an UNCORRUPTED array `DelegationUpdateFailedReason` must
    /// NOT fire, so the bodies above are not merely observing
    /// "transferFrom always emits".
    function test_control_noEventOnCleanArray() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(block.timestamp + 600);

        vm.recordLogs();
        vm.prank(alice); veHemi.transferFrom(alice, charlie, idA);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("DelegationUpdateFailedReason(uint256,bytes4)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != topic, "control: no failure event on a clean array");
        }
        assertGt(logs.length, 0, "control premise: the transfer really did emit something");
    }
}

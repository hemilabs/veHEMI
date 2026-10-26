// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// A ZERO-WEIGHT (bias == 0) MOVE THROUGH `_applyToCheckpoints`'
// TWO-LEG (pending + live) PATH.
//
// A stranded flat term whose restored end has passed takes the expired-lock
// tolerance in `VeHemiVoteDelegation::_getNormalizedLockedInfo`
// (`tolerateExpired_`), so the holder's `delegate()` books a bias == 0 addition
// at the new delegatee. That addition reaches every branch of
// `_applyToCheckpoints`, including the one guarded by
// `CheckpointLayoutViolated()` -- a HARD revert for a direct `vvd.delegate()`
// caller.
//
// The test drives the bias == 0 move onto a delegatee that carries a PENDING
// element (created honestly, by the permissionless amortiser), against an
// identical control delegatee that receives no move. The move must succeed,
// leave the checkpoint array layout-valid (L1 strictly ascending; L2 at most
// one element dated after `block.timestamp + 1`, and it is the last), leave
// the weight equal to the control's, and not change whether a later honest
// retirement works. The stranded term is set up first and the delegatees'
// positions after it, so they are still live at the move (non-zero weight)
// and at the later retirement (which must succeed on the control).
// ============================================================================

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

contract ZeroBiasMoveOntoPendingTest is AutoRelockTestBase {
    address internal movedOntoDelegatee = address(0xE93C71);
    address internal controlDelegatee = address(0xE93C72);

    function _revertSelectorString(bytes memory r_) internal pure returns (string memory) {
        if (r_.length < 4) return "0x(empty)";
        bytes4 selector; assembly { selector := mload(add(r_, 0x20)) }
        return vm.toString(selector);
    }

    function _strandExpiredFlatTerm(address owner_, uint256 amount_) internal returns (uint256 id) {
        IVeHemiVoteDelegation realDelegation = IVeHemiVoteDelegation(address(delegation));
        (id, , ) = createLock(owner_, amount_, 4 * 365 days);
        enable(owner_, id);
        delegateTo(owner_, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        veHemi.updateVoteDelegation(
            IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation)))
        );
        disable(owner_, id);
        veHemi.updateVoteDelegation(realDelegation);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1 hours);
    }

    /// @dev Checkpoint-layout check. L1 strictly ascending; L2 at most one element
    ///      dated after `block.timestamp + 1`, and it must be the LAST.
    function _checkLayout(address who_, string memory tag_) internal returns (uint256 violations) {
        uint256 n = delegation.getDelegationCheckpointsLength(who_);
        if (n == 0) { emit log_string(string.concat(tag_, " array EMPTY")); return 0; }
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory checkpoints =
            delegation.getDelegationCheckpointsPage(who_, 0, n);
        uint256 futureElements;
        for (uint256 i; i < n; ++i) {
            if (i > 0 && !(checkpoints[i].timestamp > checkpoints[i - 1].timestamp)) {
                violations++;
                emit log_string(string.concat(tag_, " L1 VIOLATED at index ", vm.toString(i)));
            }
            if (uint256(checkpoints[i].timestamp) > block.timestamp + 1) {
                futureElements++;
                if (i != n - 1) {
                    violations++;
                    emit log_string(string.concat(tag_, " L2 VIOLATED: future element is not last, index ", vm.toString(i)));
                }
            }
        }
        if (futureElements > 1) {
            violations++;
            emit log_string(string.concat(tag_, " L2 VIOLATED: ", vm.toString(futureElements), " future elements"));
        }
        emit log_string(
            string.concat(tag_, " len=", vm.toString(n), " future=", vm.toString(futureElements),
                          " violations=", vm.toString(violations))
        );
        return violations;
    }

    // =====================================================================
    // The bias == 0 move onto a delegatee that carries a PENDING element.
    // Control: an identical delegatee with a pending element that receives
    // NO move.
    // =====================================================================
    uint256 internal expiringA; uint256 internal expiringB; uint256 internal liveA; uint256 internal liveB;

    function _amortise(address who_) internal returns (bool ok) {
        vm.prank(stranger);
        (ok, ) = address(delegation).call(
            abi.encodeWithSignature("writeNewCheckpointForExpiredDelegations(address)", who_)
        );
    }

    function _hasPending(address who_) internal view returns (bool) {
        uint256 n = delegation.getDelegationCheckpointsLength(who_);
        if (n == 0) return false;
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory checkpoints =
            delegation.getDelegationCheckpointsPage(who_, n - 1, 1);
        return uint256(checkpoints[0].timestamp) > block.timestamp + 1;
    }

    function _setUpTwoPendingDelegatees() internal {
        (expiringA, , ) = createLock(alice, 200 ether, 2 * 365 days);
        (expiringB, , ) = createLock(bob,   200 ether, 2 * 365 days);
        delegateTo(alice, expiringA, movedOntoDelegatee);
        delegateTo(bob,   expiringB, controlDelegatee);
        (liveA, , ) = createLock(charlie, 300 ether, 4 * 365 days);
        (liveB, , ) = createLock(victim,  300 ether, 4 * 365 days);
        delegateTo(charlie, liveA, movedOntoDelegatee);
        delegateTo(victim,  liveB, controlDelegatee);
        vm.warp(uint256(veHemi.getLockedBalance(expiringA).end) + 3 * SIX_DAYS);
    }

    function test_biasZeroMoveOntoAPendingDelegatee() public {
        uint256 id = _strandExpiredFlatTerm(attacker, 1_000 ether);
        _setUpTwoPendingDelegatees();

        // The amortiser materialises expiringA/expiringB's expiry as an element
        // dated at the next hour boundary: the PENDING element the move must
        // meet.
        assertTrue(_amortise(movedOntoDelegatee), "premise: the amortiser reverted on movedOntoDelegatee");
        assertTrue(_amortise(controlDelegatee), "premise: the amortiser reverted on controlDelegatee");
        assertTrue(
            _hasPending(movedOntoDelegatee), "NON-VACUOUS: movedOntoDelegatee carries no PENDING element at the move"
        );
        assertTrue(_hasPending(controlDelegatee), "NON-VACUOUS: controlDelegatee carries no PENDING element");

        assertEq(delegation.getVotes(movedOntoDelegatee), delegation.getVotes(controlDelegatee),
                 "premise: movedOntoDelegatee and controlDelegatee differ before the move");
        assertGt(delegation.getVotes(movedOntoDelegatee), 0, "VACUOUS: no weight on the delegatees");

        // The move takes the tolerated-expiry branch (bias == 0): the record it
        // retires is flat and the lock has passed its end.
        IVeHemiVoteDelegation.Delegation memory previousRecord = delegation.delegation(id);
        assertEq(previousRecord.slope, 0, "NON-VACUOUS: the record is not flat (slope != 0)");
        assertGt(previousRecord.bias, 0, "NON-VACUOUS: the record is not flat (bias == 0)");
        assertLe(uint256(veHemi.getLockedBalance(id).end), block.timestamp,
                 "NON-VACUOUS: the lock has not passed its end");

        vm.prank(attacker);
        (bool moveOk, bytes memory moveRevertData) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, movedOntoDelegatee)
        );
        emit log_string(
            string.concat(
                "the bias==0 move onto a PENDING delegatee: ",
                moveOk ? "SUCCEEDED" : string.concat("revert selector=", _revertSelectorString(moveRevertData))
            )
        );
        assertTrue(moveOk, "the bias==0 move onto a PENDING delegatee reverted");
        assertEq(delegation.delegation(id).delegatee, movedOntoDelegatee, "the move was not recorded");

        emit log_named_uint("getVotes(movedOntoDelegatee) after", delegation.getVotes(movedOntoDelegatee));
        emit log_named_uint("getVotes(controlDelegatee)        ", delegation.getVotes(controlDelegatee));
        uint256 violations =
            _checkLayout(movedOntoDelegatee, "movedOntoDelegatee") + _checkLayout(controlDelegatee, "controlDelegatee");
        emit log_string(string.concat("layout-violations: ", vm.toString(violations)));
        assertEq(violations, 0, "the bias==0 move left an array that violates the checkpoint layout");
        assertEq(delegation.getVotes(movedOntoDelegatee), delegation.getVotes(controlDelegatee),
                 "the bias==0 move onto a PENDING delegatee changed its weight");

        _lateRetirement();
    }

    function _lateRetirement() internal {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(charlie);
        (bool movedSideRetireOk, bytes memory movedSideRevertData) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", liveA, delegateeB)
        );
        vm.prank(victim);
        (bool controlSideRetireOk, ) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", liveB, delegateeB)
        );
        emit log_string(
            string.concat(
                "later retirement from movedOntoDelegatee: ",
                movedSideRetireOk ? "SUCCEEDED" : string.concat("revert ", _revertSelectorString(movedSideRevertData)),
                " | from controlDelegatee: ",
                controlSideRetireOk ? "SUCCEEDED" : "revert"
            )
        );
        assertTrue(controlSideRetireOk, "NON-VACUOUS: the control's later honest retirement did not succeed");
        assertEq(
            movedSideRetireOk, controlSideRetireOk, "the bias==0 move changed whether a LATER honest retirement works"
        );
        assertEq(delegation.getVotes(movedOntoDelegatee), delegation.getVotes(controlDelegatee),
                 "divergence after the later retirement");
    }
}

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
// retirement works. The stranded term is armed first and the delegatees'
// positions after it, so they are still live at the move (non-zero weight)
// and at the later retirement (which must succeed on the control).
// ============================================================================

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

contract ZeroBiasMoveOntoPendingTest is AutoRelockTestBase {
    address internal Z1 = address(0xF15301);
    address internal Z2 = address(0xF15302);

    function _sel(bytes memory r_) internal pure returns (string memory) {
        if (r_.length < 4) return "0x(empty)";
        bytes4 s4; assembly { s4 := mload(add(r_, 0x20)) }
        return vm.toString(s4);
    }

    function _armFlatExpired(address owner_, uint256 amount_) internal returns (uint256 id) {
        IVeHemiVoteDelegation good = IVeHemiVoteDelegation(address(delegation));
        (id, , ) = createLock(owner_, amount_, 4 * 365 days);
        enable(owner_, id);
        delegateTo(owner_, id, dele);
        vm.warp(block.timestamp + 7200);
        veHemi.updateVoteDelegation(
            IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation)))
        );
        disable(owner_, id);
        veHemi.updateVoteDelegation(good);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1 hours);
    }

    /// @dev Checkpoint-layout check. L1 strictly ascending; L2 at most one element
    ///      dated after `block.timestamp + 1`, and it must be the LAST.
    function _checkLayout(address who_, string memory tag_) internal returns (uint256 viol) {
        uint256 n = delegation.getDelegationCheckpointsLength(who_);
        if (n == 0) { emit log_string(string.concat(tag_, " array EMPTY")); return 0; }
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory w =
            delegation.getDelegationCheckpointsPage(who_, 0, n);
        uint256 futures;
        for (uint256 i; i < n; ++i) {
            if (i > 0 && !(w[i].timestamp > w[i - 1].timestamp)) {
                viol++;
                emit log_string(string.concat(tag_, " L1 VIOLATED at index ", vm.toString(i)));
            }
            if (uint256(w[i].timestamp) > block.timestamp + 1) {
                futures++;
                if (i != n - 1) {
                    viol++;
                    emit log_string(string.concat(tag_, " L2 VIOLATED: future element is not last, index ", vm.toString(i)));
                }
            }
        }
        if (futures > 1) { viol++; emit log_string(string.concat(tag_, " L2 VIOLATED: ", vm.toString(futures), " future elements")); }
        emit log_string(
            string.concat(tag_, " len=", vm.toString(n), " future=", vm.toString(futures),
                          " violations=", vm.toString(viol))
        );
        return viol;
    }

    // =====================================================================
    // The bias == 0 move onto a delegatee that carries a PENDING element.
    // Control: an identical delegatee with a pending element that receives
    // NO move.
    // =====================================================================
    uint256 internal a1; uint256 internal a2; uint256 internal b1; uint256 internal b2;

    function _amortise(address who_) internal returns (bool ok) {
        vm.prank(stranger);
        (ok, ) = address(delegation).call(
            abi.encodeWithSignature("writeNewCheckpointForExpiredDelegations(address)", who_)
        );
    }

    function _hasPending(address who_) internal view returns (bool) {
        uint256 n = delegation.getDelegationCheckpointsLength(who_);
        if (n == 0) return false;
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory w =
            delegation.getDelegationCheckpointsPage(who_, n - 1, 1);
        return uint256(w[0].timestamp) > block.timestamp + 1;
    }

    function _setupZ() internal {
        (a1, , ) = createLock(alice, 200 ether, 2 * 365 days);
        (a2, , ) = createLock(bob,   200 ether, 2 * 365 days);
        delegateTo(alice, a1, Z1);
        delegateTo(bob,   a2, Z2);
        (b1, , ) = createLock(charlie, 300 ether, 4 * 365 days);
        (b2, , ) = createLock(victim,  300 ether, 4 * 365 days);
        delegateTo(charlie, b1, Z1);
        delegateTo(victim,  b2, Z2);
        vm.warp(uint256(veHemi.getLockedBalance(a1).end) + 3 * SIX_DAYS);
    }

    function test_biasZeroMoveOntoAPendingDelegatee() public {
        uint256 id = _armFlatExpired(attacker, 1_000 ether);
        _setupZ();

        // The amortiser materialises a1/a2's expiry as an element dated at the
        // next hour boundary: the PENDING element the move must meet.
        assertTrue(_amortise(Z1), "setup: the amortiser reverted on Z1");
        assertTrue(_amortise(Z2), "setup: the amortiser reverted on Z2");
        assertTrue(_hasPending(Z1), "NON-VACUOUS: Z1 carries no PENDING element at the move");
        assertTrue(_hasPending(Z2), "NON-VACUOUS: the control Z2 carries no PENDING element");

        assertEq(delegation.getVotes(Z1), delegation.getVotes(Z2),
                 "HARNESS BROKEN: Z1 and Z2 differ before the move");
        assertGt(delegation.getVotes(Z1), 0, "VACUOUS: no weight on the delegatees");

        // The move takes the tolerated-expiry branch (bias == 0): the record it
        // retires is flat and the lock has passed its end.
        IVeHemiVoteDelegation.Delegation memory prev = delegation.delegation(id);
        assertEq(prev.slope, 0, "NON-VACUOUS: the record is not flat (slope != 0)");
        assertGt(prev.bias, 0, "NON-VACUOUS: the record is not flat (bias == 0)");
        assertLe(uint256(veHemi.getLockedBalance(id).end), block.timestamp,
                 "NON-VACUOUS: the lock has not passed its end");

        vm.prank(attacker);
        (bool okM, bytes memory rM) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, Z1)
        );
        emit log_string(
            string.concat("the bias==0 move onto a PENDING delegatee: ",
                          okM ? "SUCCEEDED" : string.concat("revert sel=", _sel(rM)))
        );
        assertTrue(okM, "the bias==0 move onto a PENDING delegatee reverted");
        assertEq(delegation.delegation(id).delegatee, Z1, "the move was not recorded");

        emit log_named_uint("getVotes(Z1) after", delegation.getVotes(Z1));
        emit log_named_uint("getVotes(Z2) ctrl ", delegation.getVotes(Z2));
        uint256 viol = _checkLayout(Z1, "Z1") + _checkLayout(Z2, "Z2");
        emit log_string(string.concat("layout-violations: ", vm.toString(viol)));
        assertEq(viol, 0, "the bias==0 move left an array that violates the checkpoint layout");
        assertEq(delegation.getVotes(Z1), delegation.getVotes(Z2),
                 "the bias==0 move onto a PENDING delegatee changed its weight");

        _lateRetirement();
    }

    function _lateRetirement() internal {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(charlie);
        (bool okL, bytes memory rL) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", b1, dele2)
        );
        vm.prank(victim);
        (bool okL2, ) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", b2, dele2)
        );
        emit log_string(
            string.concat("later retirement from Z1: ",
                          okL ? "SUCCEEDED" : string.concat("revert ", _sel(rL)),
                          " | from Z2: ", okL2 ? "SUCCEEDED" : "revert")
        );
        assertTrue(okL2, "NON-VACUOUS: the control's later honest retirement did not succeed");
        assertEq(okL, okL2, "the bias==0 move changed whether a LATER honest retirement works");
        assertEq(delegation.getVotes(Z1), delegation.getVotes(Z2),
                 "divergence after the later retirement");
    }
}

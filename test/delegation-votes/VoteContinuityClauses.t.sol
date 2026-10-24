// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import {VoteContinuityLaw} from "./VoteContinuityLaw.sol";

/// THE CONTINUITY CLAUSES (C1, C2, C3) of `VoteContinuityLaw`.
///
/// Each body reads only the public surface (`getVotes`, `getPastVotes`,
/// `delegations(id)`, `balanceOfNFTAt`) and asks a historical question about
/// a window that has already elapsed:
///   C1  a window in which nobody wrote has no shortfall;
///   C2  an owner's write to her own position never reaches a co-delegator
///       of the same delegatee (also with two writes in one interval, C2b);
///   C3  at the next hour boundary after a write the delegatee's sealed
///       votes cover the full weight, touched position included.
/// L0 first checks the law's own boundary against the contract: hour-aligned,
/// and a delegation is live from `t+1` and still live at the boundary.
/// The caller-conditional half (only the owner may write) is clause C4, on
/// the access surface, in `VoteContinuityGate.t.sol`.
contract VoteContinuityClausesTest is LockedCurveTestBase {
    function _mk(address owner_, uint256 amount_, uint256 duration_) internal returns (uint256 id) {
        hemi.mint(owner_, amount_);
        vm.prank(owner_); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(owner_); id = veHemi.createLock(amount_, duration_);
    }

    function _ids(uint256 id_) internal pure returns (uint256[] memory ids_) {
        ids_ = new uint256[](1); ids_[0] = id_;
    }
    function _ids(uint256 firstId_, uint256 secondId_) internal pure returns (uint256[] memory ids_) {
        ids_ = new uint256[](2); ids_[0] = firstId_; ids_[1] = secondId_;
    }

    // ------------------------------------------------------------------ L0
    /// The law restates `CHECKPOINT_INTERVAL` because the contract keeps it
    /// `private constant`. Pin it from the PUBLIC surface: the boundary is
    /// hour-aligned, and a delegation is live from `t+1` and still there at
    /// and after the boundary.
    function test_lawBoundaryMatchesTheContract() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 t = block.timestamp;
        vm.prank(alice); delegation.delegate(id, bob);

        uint256 nextHourBoundary = VoteContinuityLaw.nextBoundary(t);
        assertGt(nextHourBoundary, t, "L0: the boundary is not in the future");
        assertEq(nextHourBoundary % 1 hours, 0, "L0: the law's grid is not hour-aligned");
        // Both `_delegate` legs land at `block.timestamp + 1`, so the booking
        // is live from the next second rather than from the boundary, and
        // the weight is STILL there at the boundary (a skipped re-book would
        // fail this half).
        vm.warp(t + 1);
        assertGt(delegation.getVotes(bob), 0, "L0: the booking did NOT take effect at t+1");
        vm.warp(nextHourBoundary - 1);
        assertGt(delegation.getVotes(bob), 0, "L0: the weight vanished before the boundary");
        vm.warp(nextHourBoundary);
        assertGt(delegation.getVotes(bob), 0, "L0: the booking did NOT survive the boundary");
    }

    // ------------------------------------------------------------------ C1
    /// A window in which NOBODY wrote: the delegatee's sealed ledger covers
    /// both positions' weight at every instant.
    function test_C1_quietWindowIsContinuous() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 12 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(VoteContinuityLaw.nextBoundary(block.timestamp) + 60); // both bookings landed

        uint256 from_ = block.timestamp;
        VoteContinuityLaw.Term[] memory witnessed = VoteContinuityLaw.readTerms(delegation, _ids(idA, idC));
        assertEq(witnessed.length, 2, "C1 COVERAGE: the witnessed set is not the set this body describes");

        uint256 to_ = from_ + 600;
        vm.warp(to_ + 7 days);                                 // the window has ELAPSED
        VoteContinuityLaw.assertQuietWindowContinuous(veHemi, delegation, witnessed, bob, from_, to_);
    }

    // ------------------------------------------------------------------ C2
    /// The owner tops up her OWN position. Charlie is a co-delegator of the
    /// same delegatee and nobody touched his position, so his full weight must
    /// stay in the delegatee's sealed ledger at every instant to the boundary.
    function test_C2_ownerTopUpDoesNotReachTheCoDelegator() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 12 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(VoteContinuityLaw.nextBoundary(block.timestamp) + 60);

        // Witness ONLY the untouched co-delegator. `idA` is the touched
        // position and is deliberately absent from the floor.
        VoteContinuityLaw.Term[] memory untouched = VoteContinuityLaw.readTerms(delegation, _ids(idC));

        hemi.mint(alice, 10 ether);
        vm.prank(alice); veHemi.increaseAmount(idA, 10 ether);   // the owner's own write
        uint256 writeAt = block.timestamp;
        uint256 nextHourBoundary = VoteContinuityLaw.nextBoundary(writeAt);

        vm.warp(nextHourBoundary + 7 days);
        VoteContinuityLaw.assertConfinedToTouchedPosition(
            veHemi, delegation, untouched, bob, writeAt + 1, nextHourBoundary - 1
        );
    }

    // ------------------------------------------------------------------ C3
    /// At the boundary fixed the moment the write landed, the delegatee holds
    /// the full weight, to the wei, in SEALED votes — touched position
    /// included. Fails if the re-book is skipped or lands low.
    function test_C3_delegateeIsHealedInFullAtTheBoundary() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 12 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(VoteContinuityLaw.nextBoundary(block.timestamp) + 60);

        hemi.mint(alice, 10 ether);
        vm.prank(alice); veHemi.increaseAmount(idA, 10 ether);
        uint256 writeAt = block.timestamp;

        vm.warp(VoteContinuityLaw.nextBoundary(writeAt) + 30 days);
        VoteContinuityLaw.assertHealedInFullAtBoundary(veHemi, delegation, _ids(idA, idC), bob, writeAt);
    }

    // --------------------------------------------------------------- C2b
    /// C2 with TWO writes inside one interval: the second write retires a
    /// record booked earlier in the same hour. Subtracting it from the wrong
    /// checkpoint would come out of the CO-DELEGATOR's aggregate.
    function test_C2b_twoWritesInOneIntervalStillSpareTheCoDelegator() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 12 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(VoteContinuityLaw.nextBoundary(block.timestamp) + 120);

        VoteContinuityLaw.Term[] memory untouched = VoteContinuityLaw.readTerms(delegation, _ids(idC));

        hemi.mint(alice, 20 ether);
        vm.prank(alice); veHemi.increaseAmount(idA, 10 ether);   // write 1
        uint256 firstWriteAt = block.timestamp;
        vm.warp(firstWriteAt + 60);
        vm.prank(alice); veHemi.increaseAmount(idA, 10 ether);   // write 2, SAME interval
        uint256 nextHourBoundary = VoteContinuityLaw.nextBoundary(block.timestamp);

        vm.warp(nextHourBoundary + 7 days);
        VoteContinuityLaw.assertConfinedToTouchedPosition(
            veHemi, delegation, untouched, bob, firstWriteAt + 1, nextHourBoundary - 1
        );
    }
}

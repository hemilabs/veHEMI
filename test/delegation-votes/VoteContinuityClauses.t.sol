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
///       history covers the full weight, touched position included.
/// The caller-conditional half (only the owner may write) is clause C4, on
/// the access surface, in `VoteContinuityGate.t.sol`.
contract VoteContinuityClausesTest is LockedCurveTestBase {
    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1); o[0] = a;
    }
    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2); o[0] = a; o[1] = b;
    }

    // ------------------------------------------------------------------ L0
    /// The law restates `CHECKPOINT_INTERVAL` because the contract keeps it
    /// `private constant`. Pin it from the PUBLIC surface: the boundary is
    /// hour-aligned, and a delegation is live from `t+1` and still there at
    /// and after the boundary.
    function test_L0_boundaryIsWhereTheContractSaysItIs() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 t = block.timestamp;
        vm.prank(alice); delegation.delegate(id, bob);

        uint256 bnd = VoteContinuityLaw.nextBoundary(t);
        assertGt(bnd, t, "L0: the boundary is not in the future");
        assertEq(bnd % 1 hours, 0, "L0: the law's grid is not hour-aligned");
        // Both `_delegate` legs land at `block.timestamp + 1`, so the booking
        // is live from the next second rather than from the boundary, and
        // the weight is STILL there at the boundary (a skipped re-book would
        // fail this half).
        vm.warp(t + 1);
        assertGt(delegation.getVotes(bob), 0, "L0: the booking did NOT take effect at t+1");
        vm.warp(bnd - 1);
        assertGt(delegation.getVotes(bob), 0, "L0: the weight vanished before the boundary");
        vm.warp(bnd);
        assertGt(delegation.getVotes(bob), 0, "L0: the booking did NOT survive the boundary");
    }

    // ------------------------------------------------------------------ C1
    /// A window in which NOBODY wrote: the delegatee's sealed history covers
    /// both positions' weight at every instant.
    function test_C1_quietWindowIsContinuous() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 12 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(VoteContinuityLaw.nextBoundary(block.timestamp) + 60); // both bookings landed

        uint256 from_ = block.timestamp;
        VoteContinuityLaw.Term[] memory ws = VoteContinuityLaw.readTerms(delegation, _ids(idA, idC));
        assertEq(ws.length, 2, "C1 COVERAGE: the witnessed set is not the set this body describes");

        uint256 to_ = from_ + 600;
        vm.warp(to_ + 7 days);                                 // the window has ELAPSED
        VoteContinuityLaw.assertQuietWindowContinuous(veHemi, delegation, ws, bob, from_, to_);
    }

    // ------------------------------------------------------------------ C2
    /// The owner tops up her OWN position. Charlie is a co-delegator of the
    /// same delegatee and nobody touched his position, so his full weight must
    /// stay in the delegatee's sealed history at every instant to the boundary.
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
        uint256 T = block.timestamp;
        uint256 bnd = VoteContinuityLaw.nextBoundary(T);

        vm.warp(bnd + 7 days);
        VoteContinuityLaw.assertConfinedToTouchedPosition(veHemi, delegation, untouched, bob, T + 1, bnd - 1);
    }

    // ------------------------------------------------------------------ C3
    /// At the boundary fixed the moment the write landed, the delegatee holds
    /// the full weight, to the wei, in SEALED history — touched position
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
        uint256 T = block.timestamp;

        vm.warp(VoteContinuityLaw.nextBoundary(T) + 30 days);
        VoteContinuityLaw.assertHealedInFullAtBoundary(veHemi, delegation, _ids(idA, idC), bob, T);
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
        uint256 T = block.timestamp;
        vm.warp(T + 60);
        vm.prank(alice); veHemi.increaseAmount(idA, 10 ether);   // write 2, SAME interval
        uint256 bnd = VoteContinuityLaw.nextBoundary(block.timestamp);

        vm.warp(bnd + 7 days);
        VoteContinuityLaw.assertConfinedToTouchedPosition(veHemi, delegation, untouched, bob, T + 1, bnd - 1);
    }
}

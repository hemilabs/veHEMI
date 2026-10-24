// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {VoteHoleLaw} from "./autorelock-ledger/VoteHoleLaw.sol";

/**
 * @title VoteHoleTest
 * @notice Directed bodies for `VoteHoleLaw`: a delegation is booked at
 *         `block.timestamp + 1` (`delegationBookedAt`), and a weight-changing
 *         write by the position owner (top-up, enable, disable) never leaves a
 *         delegatee with fewer votes than the sum of its matured records, and
 *         never takes weight from a co-delegator. The invariant side of the
 *         same law is `AutoRelockLedgerChecks.checkVoteHole*`; both call
 *         `VoteHoleLaw.scan`. `VoteHoleLaw` is a state predicate at
 *         `block.timestamp` on `delegationBookedAt`, whereas
 *         `VoteContinuityLaw` (test/delegation-votes/) reads only the public
 *         vote surface over windows that have already elapsed and measures a
 *         shortfall against records the caller witnessed.
 */
contract VoteHoleTest is LockedCurveTestBase {
    function _ids(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1); o[0] = a;
    }
    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2); o[0] = a; o[1] = b;
    }
    function _delegatees(address a) internal pure returns (address[] memory o) {
        o = new address[](1); o[0] = a;
    }
    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }
    function _ownerTopUp(address o, uint256 id, uint256 amt) internal {
        hemi.mint(o, amt);
        vm.prank(o); veHemi.increaseAmount(id, amt);
    }
    function _law(uint256[] memory ids, address d) internal view returns (VoteHoleLaw.Report memory) {
        return VoteHoleLaw.scan(delegation, ids, _delegatees(d), block.timestamp);
    }
    function _assertLaw(uint256[] memory ids, address d, string memory where) internal view {
        VoteHoleLaw.Report memory r = _law(ids, d);
        assertEq(r.lateMaturities, 0, string.concat(where, ": CLAUSE A late maturity"));
        assertEq(r.orphanBookingStamps, 0, string.concat(where, ": CLAUSE A2 orphan booking stamp"));
        assertEq(r.shortfalls, 0, string.concat(where, ": CLAUSE B shortfall"));
    }

    // -- THE BOOKING STAMP -------------------------------------------------
    /// The booking stamp is the next second, `block.timestamp + 1`. Clause B of
    /// `VoteHoleLaw` counts a record as matured from that booking stamp, so
    /// this pin is what makes the law check the weight from the second it is
    /// live. The law's hour grid is also checked for shape, since clause A
    /// uses it.
    function test_bookingStampIsNextSecond() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        assertEq(
            uint256(delegation.delegationBookedAt(id)),
            block.timestamp + 1,
            "the booking stamp is block.timestamp + 1"
        );
        uint256 nextHourBoundary = VoteHoleLaw.nextBoundary(block.timestamp);
        assertEq(nextHourBoundary % VoteHoleLaw.CHECKPOINT_INTERVAL, 0, "the law's grid is not hour-aligned");
        assertGt(nextHourBoundary, block.timestamp, "the law's next boundary is not in the future");
        assertLe(uint256(delegation.delegationBookedAt(id)), nextHourBoundary, "clause A");
    }

    // -- A FLAT (AUTO-RELOCK) POSITION'S TOP-UP -----------------------------
    function test_flatPositionTopUp_noUnderCount() public {
        uint256 bucketIndex = (block.timestamp / SIX_DAYS) + 2;
        vm.warp(bucketIndex * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp((bucketIndex + 1) * SIX_DAYS);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        vm.warp(VoteHoleLaw.nextBoundary(block.timestamp) + 300);
        uint256[] memory ids = _ids(id);
        _assertLaw(ids, bob, "flat pre-write");

        _ownerTopUp(alice, id, 10 ether);
        uint256 boundary = VoteHoleLaw.nextBoundary(block.timestamp);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "flat after the top-up");
        vm.warp(boundary);
        _assertLaw(ids, bob, "flat at the boundary");
        (, uint48 end, uint96 bias, , uint64 slope) = delegation.delegations(id);
        assertEq(
            delegation.getVotes(bob),
            VoteHoleLaw.contributionAt(slope, bias, end, block.timestamp),
            "the delegatee does not carry exactly the flat position"
        );
    }

    // -- THE OWNER'S ENABLE AND DISABLE -------------------------------------
    function test_enableAndDisable_noUnderCount() public {
        uint256 bucketIndex = (block.timestamp / SIX_DAYS) + 2;
        vm.warp(bucketIndex * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 9 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(VoteHoleLaw.nextBoundary(block.timestamp) + 900);
        uint256[] memory ids = _ids(id);

        vm.prank(alice); veHemi.enableAutoRelock(id);
        uint256 boundary = VoteHoleLaw.nextBoundary(block.timestamp);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "after enable");
        vm.warp(boundary);
        _assertLaw(ids, bob, "enable, at the boundary");

        vm.warp(block.timestamp + 3 hours + 77);
        vm.prank(alice); veHemi.disableAutoRelock(id);
        uint256 boundary2 = VoteHoleLaw.nextBoundary(block.timestamp);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "after disable");
        vm.warp(boundary2);
        _assertLaw(ids, bob, "disable, at the boundary");
    }

    // -- A CO-DELEGATOR BOOKING IN THE SAME BLOCK AS A TOP-UP ---------------
    /// A has matured on bob; C delegates to bob and, in the same block, A's
    /// owner tops A up. Both writes land on bob's checkpoint array in one
    /// block. Afterwards bob must carry exactly A + C, to the wei.
    function test_coDelegatorBookingSurvivesASameBlockTopUp() public {
        uint256 bucketIndex = (block.timestamp / SIX_DAYS) + 2;
        vm.warp(bucketIndex * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(VoteHoleLaw.nextBoundary(block.timestamp) + 120);      // A matured
        vm.prank(charlie); delegation.delegate(idC, bob);              // C books
        uint256 boundary = VoteHoleLaw.nextBoundary(block.timestamp);

        _ownerTopUp(alice, idA, 10 ether);                             // same block
        uint256[] memory ids = _ids(idA, idC);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "same-block writes, next second");

        vm.warp(boundary + 30);
        (, uint48 endA, uint96 biasA, , uint64 slopeA) = delegation.delegations(idA);
        (, uint48 endC, uint96 biasC, , uint64 slopeC) = delegation.delegations(idC);
        uint256 expected = VoteHoleLaw.contributionAt(slopeA, biasA, endA, block.timestamp)
            + VoteHoleLaw.contributionAt(slopeC, biasC, endC, block.timestamp);
        _assertLaw(ids, bob, "same-block writes, past the boundary");
        assertEq(delegation.getVotes(bob), expected, "a booking was lost across the same-block writes");
    }
}

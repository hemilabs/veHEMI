// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {I04VoteHoleLaw} from "./arl/I04VoteHoleLaw.sol";

/**
 * @title I04VoteHoleTest
 * @notice Directed bodies for `I04VoteHoleLaw`: a delegation is booked at
 *         `block.timestamp + 1` (`delegationBookedAt`), and a weight-changing
 *         write by the position owner (top-up, enable, disable) never leaves a
 *         delegatee with fewer votes than the sum of its matured records, and
 *         never takes weight from a co-delegator. The invariant side of the
 *         same law is `ARLChecks.checkVoteHole*`; both call
 *         `I04VoteHoleLaw.scan`.
 */
contract I04VoteHoleTest is LockedCurveTestBase {
    function _ids(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1); o[0] = a;
    }
    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2); o[0] = a; o[1] = b;
    }
    function _dg(address a) internal pure returns (address[] memory o) {
        o = new address[](1); o[0] = a;
    }
    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }
    function _topUp(address o, uint256 id, uint256 amt) internal {
        hemi.mint(o, amt);
        vm.prank(o); veHemi.increaseAmount(id, amt);
    }
    function _law(uint256[] memory ids, address d) internal view returns (I04VoteHoleLaw.Report memory) {
        return I04VoteHoleLaw.scan(delegation, ids, _dg(d), block.timestamp);
    }
    function _assertLaw(uint256[] memory ids, address d, string memory where) internal view {
        I04VoteHoleLaw.Report memory r = _law(ids, d);
        assertEq(r.lateMaturity, 0, string.concat(where, ": CLAUSE A late maturity"));
        assertEq(r.orphanStamp, 0, string.concat(where, ": CLAUSE A2 orphan stamp"));
        assertEq(r.shortfalls, 0, string.concat(where, ": CLAUSE B shortfall"));
    }

    // -- THE BOOKING STAMP -------------------------------------------------
    /// The booking stamp is the next second, `block.timestamp + 1`. Clause B of
    /// `I04VoteHoleLaw` counts a record as matured from that stamp, so this pin
    /// is what makes the law check the weight from the second it is live. The
    /// law's hour grid is also checked for shape, since clause A uses it.
    function test_I04_V1_bookingStampIsNextSecond() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        assertEq(
            uint256(delegation.delegationBookedAt(id)),
            block.timestamp + 1,
            "the booking stamp is block.timestamp + 1"
        );
        uint256 nb = I04VoteHoleLaw.nextBoundary(block.timestamp);
        assertEq(nb % I04VoteHoleLaw.CHECKPOINT_INTERVAL, 0, "the law's grid is not hour-aligned");
        assertGt(nb, block.timestamp, "the law's next boundary is not in the future");
        assertLe(uint256(delegation.delegationBookedAt(id)), nb, "clause A");
    }

    // -- A FLAT (AUTO-RELOCK) POSITION'S TOP-UP -----------------------------
    function test_I04_V3_flatPositionTopUp_noUnderCount() public {
        uint256 b0 = (block.timestamp / SIX_DAYS) + 2;
        vm.warp(b0 * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp((b0 + 1) * SIX_DAYS);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        vm.warp(I04VoteHoleLaw.nextBoundary(block.timestamp) + 300);
        uint256[] memory ids = _ids(id);
        _assertLaw(ids, bob, "flat pre-write");

        _topUp(alice, id, 10 ether);
        uint256 boundary = I04VoteHoleLaw.nextBoundary(block.timestamp);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "flat after the top-up");
        vm.warp(boundary);
        _assertLaw(ids, bob, "flat at the boundary");
        (, uint48 e, uint96 bi, , uint64 sl) = delegation.delegations(id);
        assertEq(
            delegation.getVotes(bob),
            I04VoteHoleLaw.contributionAt(sl, bi, e, block.timestamp),
            "the delegatee does not carry exactly the flat position"
        );
    }

    // -- THE OWNER'S ENABLE AND DISABLE -------------------------------------
    function test_I04_V4_enableAndDisable_noUnderCount() public {
        uint256 b0 = (block.timestamp / SIX_DAYS) + 2;
        vm.warp(b0 * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 9 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(I04VoteHoleLaw.nextBoundary(block.timestamp) + 900);
        uint256[] memory ids = _ids(id);

        vm.prank(alice); veHemi.enableAutoRelock(id);
        uint256 boundary = I04VoteHoleLaw.nextBoundary(block.timestamp);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "after enable");
        vm.warp(boundary);
        _assertLaw(ids, bob, "enable, at the boundary");

        vm.warp(block.timestamp + 3 hours + 77);
        vm.prank(alice); veHemi.disableAutoRelock(id);
        uint256 boundary2 = I04VoteHoleLaw.nextBoundary(block.timestamp);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "after disable");
        vm.warp(boundary2);
        _assertLaw(ids, bob, "disable, at the boundary");
    }

    // -- A CO-DELEGATOR BOOKING IN THE SAME BLOCK AS A TOP-UP ---------------
    /// A has matured on bob; C delegates to bob and, in the same block, A's
    /// owner tops A up. Both writes land on bob's checkpoint array in one
    /// block. Afterwards bob must carry exactly A + C, to the wei.
    function test_I04_V7_coDelegatorBookingSurvivesASameBlockTopUp() public {
        uint256 b0 = (block.timestamp / SIX_DAYS) + 2;
        vm.warp(b0 * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(I04VoteHoleLaw.nextBoundary(block.timestamp) + 120);   // A matured
        vm.prank(charlie); delegation.delegate(idC, bob);              // C books
        uint256 boundary = I04VoteHoleLaw.nextBoundary(block.timestamp);

        _topUp(alice, idA, 10 ether);                                  // same block
        uint256[] memory ids = _ids(idA, idC);
        vm.warp(block.timestamp + 1);
        _assertLaw(ids, bob, "same-block writes, next second");

        vm.warp(boundary + 30);
        (, uint48 eA, uint96 bA, , uint64 sA) = delegation.delegations(idA);
        (, uint48 eC, uint96 bC, , uint64 sC) = delegation.delegations(idC);
        uint256 expected = I04VoteHoleLaw.contributionAt(sA, bA, eA, block.timestamp)
            + I04VoteHoleLaw.contributionAt(sC, bC, eC, block.timestamp);
        _assertLaw(ids, bob, "same-block writes, past the boundary");
        assertEq(delegation.getVotes(bob), expected, "a booking was lost across the same-block writes");
    }
}

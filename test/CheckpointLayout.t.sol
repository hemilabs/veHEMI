// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";

/**
 * @title CheckpointLayoutTest
 * @notice The checkpoint-array layout invariant documented on
 *         `VeHemiVoteDelegation._applyToCheckpoints` (`CP-LAYOUT` in the
 *         messages below; the contract's `CheckpointLayoutViolated` checks only
 *         part of it, on the tail), asserted clause by clause directly on
 *         `getDelegationCheckpoints`: L1 strictly sorted; L2 at most one
 *         future element, dated at the next hour boundary and last, and no
 *         growth from further writes in the same second; L3 the element
 *         `_liveIndex` names is not future-dated; L4 append-only at or below
 *         `now`. Also: a co-delegator's booking survives a same-block top-up
 *         with every array clause holding. Plus three public read-surface
 *         bodies: a same-block pair never shaves a co-delegator (S), a
 *         delegatee move leaves no second in which nobody carries the weight
 *         (M), and a 1-wei top-up opens no zero-vote second (R).
 */
contract CheckpointLayoutTest is LockedCurveTestBase {

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }
    /// A top-up by the position's owner (`increaseAmount` is owner-only),
    /// which runs `_depositFor` -> `_reDelegate`. The owner is read from the
    /// chain so every body tops up as whoever owns the position.
    function _ownerTopUp(uint256 id, uint256 amt) internal {
        address owner_ = veHemi.ownerOf(id);
        hemi.mint(owner_, amt);
        vm.prank(owner_); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(owner_); veHemi.increaseAmount(id, amt);
    }
    function _checkpoints(address d) internal view returns (VeHemiVoteDelegation.DelegateCheckpoint[] memory) {
        return delegation.getDelegationCheckpoints(d);
    }
    function _nextHourBoundary(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    /// The array clauses of CP-LAYOUT (L1-L3), evaluated on the array as it stands.
    function _assertLayout(address d, string memory where) internal view {
        VeHemiVoteDelegation.DelegateCheckpoint[] memory a = _checkpoints(d);
        uint256 future;
        for (uint256 i; i < a.length; ++i) {
            if (i > 0) {
                // L1  SORTED, STRICTLY.
                assertLt(
                    uint256(a[i - 1].timestamp), uint256(a[i].timestamp),
                    string.concat(where, ": CP-LAYOUT L1 - checkpoints not strictly sorted")
                );
            }
            if (uint256(a[i].timestamp) > block.timestamp + 1) {
                unchecked { ++future; }
                // L2  a future element is dated EXACTLY at the current boundary ...
                assertEq(
                    uint256(a[i].timestamp), _nextHourBoundary(block.timestamp),
                    string.concat(where, ": CP-LAYOUT L2 - a pending element is not at the boundary")
                );
                // ... and is the LAST element.
                assertEq(
                    i, a.length - 1,
                    string.concat(where, ": CP-LAYOUT L2 - the pending element is not last")
                );
            }
        }
        // L2  AT MOST ONE.
        assertLe(future, 1, string.concat(where, ": CP-LAYOUT L2 - more than one future element"));
        // L3  a LIVE element exists whenever the array is non-empty and is not
        //     pending-only, and it is the one `_liveIndex` arithmetic names.
        if (a.length > 0 && !(a.length == 1 && future == 1)) {
            uint256 liveIndex = future == 1 ? a.length - 2 : a.length - 1;
            assertLe(
                uint256(a[liveIndex].timestamp), block.timestamp + 1,
                string.concat(where, ": CP-LAYOUT L3 - the element at _liveIndex is future-dated")
            );
        }
    }

    // =================================================================== L1/L2/L3
    /// A matured delegator, a co-delegator booking in a later hour, a top-up
    /// on the first position in that same block, then two more top-ups in
    /// later blocks of the same hour. Every clause holds at every step.
    function test_L1toL3_layoutHoldsThroughABookingAndTopUps() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        _assertLayout(bob, "after A books");

        vm.warp(_nextHourBoundary(block.timestamp) + 120);  // A matured
        vm.prank(charlie); delegation.delegate(idC, bob);   // C books
        _assertLayout(bob, "after C books");

        _ownerTopUp(idA, 10 ether);                         // same block
        _assertLayout(bob, "after the same-block top-up");

        vm.warp(block.timestamp + 60);  _ownerTopUp(idA, 1 ether);
        _assertLayout(bob, "after write 2");
        vm.warp(block.timestamp + 60);  _ownerTopUp(idA, 1 ether);
        _assertLayout(bob, "after write 3");

        vm.warp(_nextHourBoundary(block.timestamp));
        _assertLayout(bob, "at the boundary");
    }

    // ====================================================================== L2
    /// A THIRD ELEMENT IN THE SAME SECOND IS IMPOSSIBLE. The first write of a
    /// block leaves an element dated exactly `block.timestamp + 1`, so every
    /// later write in that same block takes the in-place overwrite branch. Only
    /// the first write of a block can grow the array, however many writes land.
    function test_L2_laterWritesInTheSameSecondDoNotGrowTheArray() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nextHourBoundary(block.timestamp) + 300);

        uint256 n0 = _checkpoints(bob).length;
        _ownerTopUp(idA, 1 ether);
        uint256 n1 = _checkpoints(bob).length;  // the FIRST write of this second
        _ownerTopUp(idA, 1 ether);
        _ownerTopUp(idA, 1 ether);
        _ownerTopUp(idA, 1 ether);
        uint256 n2 = _checkpoints(bob).length;  // three MORE, same second
        emit log_named_uint("L2 elements before any write   ", n0);
        emit log_named_uint("L2 elements after write 1      ", n1);
        emit log_named_uint("L2 elements after writes 2,3,4 ", n2);
        // Whatever the first write of a second costs, every later write in
        // that same second must cost nothing: each finds an element already
        // dated at the instant it wants to write and overwrites it in place.
        assertEq(n2, n1, "CP-LAYOUT L2: a later write in the SAME second grew the array");
        _assertLayout(bob, "L2 same-second");
    }

    // ====================================================================== L4
    /// APPEND-ONLY AT OR BELOW `now`. 64 already-elapsed seconds of the current
    /// hour PLUS `now` itself, read before a write and re-read after it in the
    /// SAME block. Nothing a caller could already have read may move.
    function test_L4_appendOnlyBelowNow() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nextHourBoundary(block.timestamp) + 1800);

        uint256[] memory before_ = new uint256[](65);
        for (uint256 i; i < 65; ++i) before_[i] = delegation.getPastVotes(bob, block.timestamp - i);
        _ownerTopUp(idA, 7 ether);
        for (uint256 i; i < 65; ++i) {
            assertEq(
                delegation.getPastVotes(bob, block.timestamp - i), before_[i],
                "CP-LAYOUT L4: a readable instant was RESTATED by a write"
            );
        }
        _assertLayout(bob, "L4");
    }

    // ============================================== CO-DELEGATOR BOOKING
    /// A co-delegator's booking made in the same block as a top-up on the same
    /// delegatee must survive: past the boundary the delegatee must read BOTH
    /// positions.
    /// `test_coDelegatorBookingSurvivesASameBlockTopUp` in VoteHole.t.sol
    /// asserts the same property against a recomputed per-record sum; this
    /// body asserts it against the layout.
    function test_coDelegatorBookingSurvivesSameBlockTopUp_layoutHolds() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nextHourBoundary(block.timestamp) + 120);

        uint256 aAlone = delegation.getVotes(bob);
        assertGt(aAlone, 0, "premise: A is live");
        vm.prank(charlie); delegation.delegate(idC, bob);     // C books
        _ownerTopUp(idA, 5 ether);                            // same block

        uint256 boundary = _nextHourBoundary(block.timestamp);
        vm.warp(boundary + 30);
        _assertLayout(bob, "co-delegator booking, past the boundary");
        uint256 both = delegation.getVotes(bob);
        emit log_named_uint("A alone (before C booked)", aAlone);
        emit log_named_uint("A + C past the boundary  ", both);
        assertGt(both, aAlone, "CP-LAYOUT: the co-delegator's booking was LOST across the same-block top-up");
    }

    // ============================================== SAME-BLOCK PAIR
    /// TWO WRITES ON THE SAME POSITION IN THE SAME BLOCK. The second write
    /// finds a record this block stamped `block.timestamp + 1`; if it
    /// subtracted from an element that does not carry the record, the
    /// difference would come out of the CO-DELEGATOR. Measured against a
    /// `vm.snapshotState` counterfactual -- the same tree, the same block, the
    /// writes simply not made -- so nothing is recomputed and no epsilon is
    /// chosen.
    function test_S_sameBlockPairNeverShavesTheCoDelegator() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 20 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 20 * SIX_DAYS);
        vm.prank(alice);   delegation.delegate(idA, bob);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(_nextHourBoundary(block.timestamp) + 900);   // both matured

        uint256 snap = vm.snapshotState();
        // COUNTERFACTUAL: nobody touches anything.
        vm.warp(block.timestamp + 1);
        uint256 doNothing = delegation.getVotes(bob);
        vm.revertToState(snap);

        // TWO writes, ONE block, on idA only.
        _ownerTopUp(idA, 3 ether);
        _ownerTopUp(idA, 3 ether);
        vm.warp(block.timestamp + 1);
        uint256 afterPair = delegation.getVotes(bob);

        emit log_named_uint("S do-nothing counterfactual ", doNothing);
        emit log_named_uint("S after two same-block writes", afterPair);
        // `increaseAmount` only ADDS weight, so the pair can never leave bob
        // poorer than doing nothing.
        assertGe(afterPair, doNothing, "S: a same-block pair made the delegatee POORER than doing nothing");
        // and the other direction: no phantom.
        assertLe(afterPair, veHemi.totalVeHemiSupply(), "S: votes exceed the escrow after a same-block pair");
        _assertLayout(bob, "S");
    }

    // ============================================== THE MOVE
    /// A DELEGATEE MOVE (`VVD.delegate(id, NEW)`; transfers and the adapter's
    /// `delegateAllFor` reach the same retire-then-book path) must leave no
    /// second in which the position's escrowed weight is carried by NOBODY:
    /// the old delegatee is retired and the new one booked at the same
    /// instant, `t+1`. Worst case: the move at an hour boundary.
    ///
    /// Read surface: `getVotes` and `getPastVotes` on the TWO delegatees. No
    /// struct field, no recomputation, no epsilon.
    function test_M_delegateeMoveLeavesNoSecondWithoutVotes() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 20 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours);   // phase 0: worst case
        uint256 before_ = delegation.getVotes(bob);
        assertGt(before_, 0, "premise: bob carries the weight");

        vm.prank(alice); delegation.delegate(id, charlie);          // THE MOVE
        uint256 t = block.timestamp;
        uint256 boundary = _nextHourBoundary(t);

        uint256 unionZeroVoteSeconds;
        for (uint256 s = t + 1; s < boundary; ++s) {
            vm.warp(s);
            if (delegation.getVotes(bob) + delegation.getVotes(charlie) == 0) {
                unchecked { ++unionZeroVoteSeconds; }
            }
            _assertLayout(bob, "M bob");
            _assertLayout(charlie, "M charlie");
        }
        emit log_named_uint("M window width (s)       ", boundary - (t + 1));
        emit log_named_uint("M UNION zero-vote seconds", unionZeroVoteSeconds);
        emit log_named_uint("M weight before the move ", before_);
        assertEq(unionZeroVoteSeconds, 0, "M: a delegatee MOVE leaves the escrowed weight represented by NOBODY");

        // and the union gap is sealed into history, not merely live state.
        vm.warp(boundary + 365 days);
        assertGt(
            delegation.getPastVotes(bob, t + 1) + delegation.getPastVotes(charlie, t + 1),
            0,
            "M: the union gap is SEALED into getPastVotes"
        );
    }

    // ============================================= NO ZERO-VOTE SECOND
    /// On the public read surface only: after a weight-changing write (here a
    /// 1-wei top-up at an hour boundary, the worst case), the delegatee's
    /// votes are NEVER zero at any second of the rest of the hour, and
    /// `getPastVotes` agrees a year later.
    function test_R_noZeroVoteSecondAnywhereInTheHour() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours);   // phase 0: worst case

        _ownerTopUp(idA, 1);                                         // ONE WEI
        uint256 t = block.timestamp;
        uint256 boundary = _nextHourBoundary(t);
        uint256 zeroVoteSeconds;
        for (uint256 s = t + 1; s < boundary; ++s) {
            vm.warp(s);
            if (delegation.getVotes(bob) == 0) { unchecked { ++zeroVoteSeconds; } }
        }
        emit log_named_uint("R window width (s)  ", boundary - (t + 1));
        emit log_named_uint("R zero-vote seconds ", zeroVoteSeconds);
        assertEq(zeroVoteSeconds, 0, "R: a 1-wei top-up opened a zero-vote second in the hour");

        // and it is not merely live-state: the history agrees a year later.
        vm.warp(boundary + 365 days);
        assertGt(delegation.getPastVotes(bob, t + 1), 0, "R: the zero is sealed into getPastVotes");
    }
}

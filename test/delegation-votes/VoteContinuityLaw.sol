// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Vm.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";

/**
 * @title Vote-continuity clauses for delegated weight.
 *
 * @dev Four clauses. C1-C3 read only the public vote surface (`getVotes`,
 *      `getPastVotes`, `delegations(id)`, `VeHemi.balanceOfNFTAt`), which
 *      carries no caller, so the caller-conditional property ("only the
 *      position's owner may write to it") is clause C4, on the access surface:
 *
 *        C1 QUIET CONTINUITY  — a window in which NOBODY wrote to the witnessed
 *                               positions has no shortfall in the delegatee's
 *                               sealed ledger.
 *        C2 CONFINEMENT       — a write to ONE position never reaches an
 *                               UNTOUCHED co-delegator of the same delegatee:
 *                               its full weight survives, to the wei.
 *        C3 HEALED IN FULL    — at the next hour boundary after the write, the
 *                               delegatee's SEALED votes cover the FULL floor,
 *                               touched position included.
 *        C4 ACCESS PAIRING    — from ONE snapshot, three runs: the delegatee's
 *                               sealed ledger with NO call made (the
 *                               counterfactual), the same ledger after the
 *                               OWNER's call, which must succeed AND differ from
 *                               the counterfactual, and only then the identical
 *                               call by a NON-OWNER, which must REVERT. The owner
 *                               run is the stranger run's non-vacuity witness: a
 *                               lone "the stranger reverts" assertion also passes
 *                               if the call never reached the ledger.
 *
 * @dev SEALED: the `getPastVotes(d, t)` answer for an instant `t` that has
 *      already passed; layout clause L4 (test/CheckpointLayout.t.sol) forbids
 *      any later write from changing it. "Sealed votes" (a "sealed reading")
 *      is one such reading, the "sealed ledger" a sampled series of them.
 *
 * @dev `VoteHoleLaw` (test/autorelock-ledger/VoteHoleLaw.sol) bounds the same
 *      harm from the inside: it is a state predicate at `block.timestamp` on
 *      `delegationBookedAt` and the delegation records, and its "hole" is one
 *      position's missing contribution while its booking is pending, whereas
 *      this law reads only the public vote surface, over elapsed windows, and
 *      measures a shortfall against records the caller witnessed.
 *
 * @dev Construction rules:
 *      * NO COUNTERS. Every number computed is an argument to an assertion.
 *      * NON-DEGENERATE DIRECTION. Every clause is an equality or a LOWER bound
 *        whose reference is proved non-zero first; nothing here is satisfied
 *        by `votes = 0`.
 *      * FAIL ON VACUITY. Every clause asserts its own coverage (a non-empty
 *        witnessed set, a non-zero floor) BEFORE its property.
 *      * PUBLIC SURFACE ONLY. No `delegationBookedAt`, no checkpoint array.
 *      * HISTORICAL, ENFORCED. `_requireHistorical` reverts if a clause is
 *        called at or before the end of the window it is asked about, so the
 *        law cannot decay into a live-state predicate.
 *      * NO EXCLUSION PATH. No `continue`, skip, tolerance or sampling step in
 *        C1-C3: where a precondition fails, the law FAILS. The one branch per
 *        loop exists because Solidity evaluates the message argument eagerly
 *        and an unconditional call runs the EVM out of memory over a
 *        3,600-second window; control flow inside it can only fail.
 */
library VoteContinuityLaw {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `VeHemiVoteDelegation.CHECKPOINT_INTERVAL` is `private constant`,
    ///      so it is restated here and pinned from the PUBLIC surface by
    ///      `test_lawBoundaryMatchesTheContract` in
    ///      `VoteContinuityClauses.t.sol`.
    uint256 internal constant CHECKPOINT_INTERVAL = 1 hours;
    uint256 internal constant EPOCH_OFFSET = 0;

    /// @notice One position's delegation record as the caller witnessed it.
    ///         The caller must take these BEFORE the window; a record is a
    ///         reference only if it predates what it is used to judge.
    struct Term {
        uint256 id;
        address delegatee;
        uint256 bias;
        uint256 slope;
        uint256 end;
    }

    function nextBoundary(uint256 t_) internal pure returns (uint256) {
        return (((t_ - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL)
            + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
    }

    /// @notice Read a position's CURRENT delegation record off the public
    ///         getter.
    function readTerm(VeHemiVoteDelegation delegation_, uint256 id_) internal view returns (Term memory term) {
        (address delegatee, uint48 end, uint96 bias, , uint64 slope) = delegation_.delegations(id_);
        term.id = id_;
        term.delegatee = delegatee;
        term.bias = uint256(bias);
        term.slope = uint256(slope);
        term.end = uint256(end);
    }

    function readTerms(VeHemiVoteDelegation delegation_, uint256[] memory ids_)
        internal view returns (Term[] memory out)
    {
        out = new Term[](ids_.length);
        for (uint256 i; i < ids_.length; ++i) out[i] = readTerm(delegation_, ids_[i]);
    }

    /// @dev The per-record contribution `_getDelegateVotesAt` aggregates
    ///      (`bias - slope * t`, or `bias` for a flat term).
    function contributionAt(uint256 slope_, uint256 bias_, uint256 end_, uint256 t_)
        internal pure returns (uint256)
    {
        if (slope_ == 0) return bias_;   // FLAT (or an inert empty record)
        if (end_ <= t_) return 0;        // swept by the SIX_DAYS expiration walk
        uint256 decay = slope_ * t_;
        return bias_ > decay ? bias_ - decay : 0;
    }

    /// @dev The summed weight, at `t_`, of every supplied term still pointing
    ///      at `delegatee_`.
    function _floorAt(Term[] memory terms_, address delegatee_, uint256 t_)
        private pure returns (uint256 sum)
    {
        for (uint256 i; i < terms_.length; ++i) {
            if (terms_[i].delegatee != delegatee_) continue;   // not a member of the set at all
            sum += contributionAt(terms_[i].slope, terms_[i].bias, terms_[i].end, t_);
        }
    }

    // ==================================================================== C1
    /**
     * @notice CLAUSE 1 — QUIET CONTINUITY. Over a window in which the supplied
     *         delegator set was demonstrably NOT written to, the delegatee's
     *         SEALED ledger covers that set's full weight at every instant.
     *
     * @dev Red on any shortfall a write did not cause: a shortfall opened by
     *      the passage of time, or on a position nobody touched.
     *
     * @dev QUIETNESS IS VERIFIED, NOT ASSUMED, AND A NON-QUIET WINDOW FAILS.
     *      The law re-reads each record now and requires it identical to the
     *      witnessed one. If a record moved, this body cannot answer the
     *      question it was asked, so it goes RED rather than skipping.
     *
     * @param witnessed_ records witnessed BEFORE `from_`. Taken with `readTerms`.
     */
    function assertQuietWindowContinuous(
        VeHemi ve_,
        VeHemiVoteDelegation delegation_,
        Term[] memory witnessed_,
        address delegatee_,
        uint256 from_,
        uint256 to_
    ) internal view {
        _requireHistorical(to_);
        _requireQuiet(delegation_, witnessed_);

        // COVERAGE, ASSERTED: a floor of zero would make every later assertion
        // trivially satisfiable, which is the degenerate shape this whole file
        // exists to avoid. Checked at BOTH ends so a term expiring mid-window
        // cannot hollow the law out silently.
        uint256 floorAtFrom = _floorAt(witnessed_, delegatee_, from_);
        uint256 floorAtTo = _floorAt(witnessed_, delegatee_, to_);
        vm.assertGt(floorAtFrom, 0, _vacuous("C1", delegatee_, from_));
        vm.assertGt(floorAtTo, 0, _vacuous("C1", delegatee_, to_));

        for (uint256 t = from_; t <= to_; ++t) {
            uint256 floor_ = _floorAt(witnessed_, delegatee_, t);
            uint256 votes = delegation_.getPastVotes(delegatee_, t);
            if (votes < floor_) {
                vm.assertGe(votes, floor_, _shortfall(ve_, witnessed_, delegatee_, t, floor_, votes, "QUIET"));
            }
        }
    }

    // ==================================================================== C2
    /**
     * @notice CLAUSE 2 — CONFINEMENT. Over a window containing a write to ONE
     *         position, every UNTOUCHED position delegating to the same
     *         delegatee keeps its full weight in the SEALED ledger, at every
     *         instant, to the wei.
     *
     * @dev Alice's write to her own position may change Alice's weight inside
     *      Bob's total; it must never reach CHARLIE's weight inside the same
     *      total. The shape that would break it is a second write in the same
     *      hour subtracting from the wrong aggregate.
     *
     * @dev `untouched_` is checked for quietness the same way as C1 — a
     *      position the caller claims is untouched and which in fact moved is a
     *      FAILURE of this body, not a skip.
     */
    function assertConfinedToTouchedPosition(
        VeHemi ve_,
        VeHemiVoteDelegation delegation_,
        Term[] memory untouched_,
        address delegatee_,
        uint256 from_,
        uint256 to_
    ) internal view {
        _requireHistorical(to_);
        _requireQuiet(delegation_, untouched_);

        uint256 floorAtFrom = _floorAt(untouched_, delegatee_, from_);
        uint256 floorAtTo = _floorAt(untouched_, delegatee_, to_);
        vm.assertGt(floorAtFrom, 0, _vacuous("C2", delegatee_, from_));
        vm.assertGt(floorAtTo, 0, _vacuous("C2", delegatee_, to_));

        for (uint256 t = from_; t <= to_; ++t) {
            uint256 floor_ = _floorAt(untouched_, delegatee_, t);
            uint256 votes = delegation_.getPastVotes(delegatee_, t);
            if (votes < floor_) {
                vm.assertGe(votes, floor_, _shortfall(ve_, untouched_, delegatee_, t, floor_, votes, "CONFINEMENT"));
            }
        }
    }

    // ==================================================================== C3
    /**
     * @notice CLAUSE 3 — HEALED IN FULL, AT THE BOUNDARY, IN SEALED VOTES.
     *         At the next hour boundary after `writeAt_`, the delegatee's
     *         sealed votes cover the full floor of the supplied set INCLUDING
     *         the position that was written.
     *
     * @dev Any effect of a write on the delegatee is bounded IN TIME by the
     *      boundary fixed the moment the write lands. It goes RED if the
     *      re-book is SKIPPED (a silent freeze, which satisfies every "votes
     *      may not fall" law), if the booking lands LOW, or if a shortfall runs
     *      past its own boundary.
     *
     * @dev The floor is read from the terms AS THEY ARE NOW, because the write
     *      has already landed and the post-write record is the correct
     *      reference for an instant after the boundary. Non-degeneracy is
     *      asserted first, so `0 >= 0` cannot satisfy it.
     */
    function assertHealedInFullAtBoundary(
        VeHemi ve_,
        VeHemiVoteDelegation delegation_,
        uint256[] memory ids_,
        address delegatee_,
        uint256 writeAt_
    ) internal view {
        uint256 nextHourBoundary = nextBoundary(writeAt_);
        _requireHistorical(nextHourBoundary);

        Term[] memory currentTerms = readTerms(delegation_, ids_);
        uint256 floor_ = _floorAt(currentTerms, delegatee_, nextHourBoundary);
        vm.assertGt(floor_, 0, _vacuous("C3", delegatee_, nextHourBoundary));

        uint256 votes = delegation_.getPastVotes(delegatee_, nextHourBoundary);
        if (votes < floor_) {
            vm.assertGe(
                votes, floor_, _notHealed(ve_, currentTerms, delegatee_, nextHourBoundary, writeAt_, floor_, votes)
            );
        }
    }

    // ==================================================================== C4
    /**
     * @notice CLAUSE 4 — ACCESS PAIRING. The caller-conditional property,
     *         asserted on the surface where the caller is actually the subject.
     *
     *         RUN N: NOBODY calls anything. The delegatee's SEALED ledger is
     *                swept and kept. This is the counterfactual.
     *         RUN O: from the SAME state, `owner_` makes the call; it MUST
     *                succeed, AND the same sweep MUST DIFFER from run N's.
     *         RUN S: from the SAME state again, `stranger_` makes the
     *                IDENTICAL call, and it MUST REVERT.
     *
     * @dev THE WITNESS IS "THE OWNER'S CALL MUTATES THE DELEGATEE'S LEDGER",
     *      measured as a DIFFERENTIAL against a no-call counterfactual
     *      replayed from the same snapshot:
     *
     *          #{ t in W : getPastVotes(delegatee, t) after the owner's call
     *                   != getPastVotes(delegatee, t) with no call at all }  > 0
     *
     *      and the law is RED if that count is zero, before run S is reached.
     *
     * @dev WHY A DIFFERENTIAL AND NOT A COMPARISON AGAINST THE FLOOR.
     *      `_floorAt` sums only the CALLER-SUPPLIED records, so a delegatee with
     *      any co-delegator the caller did not name reads ABOVE its floor at
     *      every instant WITH NO CALL MADE AT ALL, and a "moved away from the
     *      floor" witness would fire on nothing. Both runs of the differential
     *      carry the same co-delegators and the same decay, so the ONLY thing
     *      that can separate them is the call.
     *
     * @dev NON-VACUITY. A call that changes nothing about the delegatee's
     *      ledger produces two identical sweeps, so a stranger's revert is
     *      never credited on its own. `increaseAmount(id, 1)` is such a call: a
     *      1-wei top-up leaves `delegations(id)`'s bias, slope and end
     *      unchanged, and this clause is RED on it.
     *
     * @dev The harm the gate prevents is an UNCONSENTED THIRD-PARTY MUTATION: a
     *      party with no authority over the position writes to another holder's
     *      position and moves a third account's governance weight.
     *
     * @dev PARAMETRIC OVER THE ENTRY POINT: the signature takes
     *      `(target_, call_)`, so each additional gated entry point is one more
     *      call through this same body.
     */
    function assertOnlyOwnerCanMutate(
        VeHemiVoteDelegation delegation_,
        address target_,
        bytes memory call_,
        address stranger_,
        address owner_,
        address delegatee_,
        uint256[] memory ids_,
        string memory label_
    ) internal {
        // COVERAGE, ASSERTED FIRST. The delegatee must actually hold
        // escrow-backed weight from the witnessed set, or this body has no
        // subject and every later assertion is trivially satisfiable.
        vm.assertGt(
            _floorAt(readTerms(delegation_, ids_), delegatee_, block.timestamp), 0,
            _vacuous(string.concat("C4/", label_), delegatee_, block.timestamp)
        );

        uint256 snap = vm.snapshotState();

        // ---- RUN N. THE COUNTERFACTUAL. Nobody calls anything; the ledger is
        //      swept exactly as run O will sweep it. EVM memory survives
        //      `revertToState` (only storage, balances and nonces roll back),
        //      so this vector is still here when run O's is taken.
        uint256[] memory noCallLedger = _sealedLedger(delegation_, delegatee_);
        vm.revertToState(snap);

        // ---- RUN O COMES BEFORE RUN S, AND THE ORDER IS LOAD-BEARING.
        // Doing run O first makes the gate assertion UNREACHABLE unless this
        // entry point demonstrably moves the ledger; a body that
        // cannot evaluate its own subject is RED, not green.
        uint256[] memory ownerCallLedger =
            _sealedLedgerAfterOwnerCall(delegation_, target_, call_, owner_, delegatee_, label_);
        vm.revertToState(snap);

        vm.assertGt(
            _movedInstants(noCallLedger, ownerCallLedger), 0,
            string.concat(
                "C4 [", label_, "] NOT APPLICABLE / VACUOUS. The OWNER made this exact call"
                " and ", vm.toString(delegatee_), "'s sealed ledger is IDENTICAL to the"
                " no-call counterfactual replayed from the same snapshot, at every instant"
                " sampled. The call does not mutate the delegatee's ledger, so"
                " there is nothing here for a gate to close and asserting the stranger's revert"
                " from here would prove NOTHING - it is the failure mode where a"
                " permission check turns a body green without touching any defect. This is"
                " deliberately RED and not a pass. Either point this C4 check at calldata that"
                " does mutate the ledger, or delete it on purpose and say so."
            )
        );

        // ---- RUN S. Only now, with the mutation proved, is the
        //      stranger's refusal a statement about anything.
        _assertStrangerCallReverts(target_, call_, stranger_, delegatee_, label_);

        vm.revertToState(snap);
    }

    /// @dev RUN O, split out because the paired body runs out of EVM stack
    ///      otherwise. The owner's call MUST succeed; the sweep it returns is
    ///      half of the non-vacuity differential.
    function _sealedLedgerAfterOwnerCall(
        VeHemiVoteDelegation delegation_,
        address target_,
        bytes memory call_,
        address owner_,
        address delegatee_,
        string memory label_
    ) private returns (uint256[] memory) {
        vm.prank(owner_);
        (bool ownerCallOk, ) = target_.call(call_);
        vm.assertEq(
            ownerCallOk, true,
            string.concat(
                "C4 [", label_, "] OWNER LOCKED OUT. The gate refused the position's own"
                " owner. The gate is for STRANGERS, not owners."
            )
        );
        return _sealedLedger(delegation_, delegatee_);
    }

    /// @dev RUN S, split out for the same reason. Reached ONLY after run O has
    ///      proved that the refused call mutates the ledger.
    function _assertStrangerCallReverts(
        address target_,
        bytes memory call_,
        address stranger_,
        address delegatee_,
        string memory label_
    ) private {
        vm.prank(stranger_);
        (bool strangerCallOk, ) = target_.call(call_);
        vm.assertEq(
            strangerCallOk, false,
            string.concat(
                "C4 [", label_, "] GATE OPEN. ", vm.toString(stranger_),
                " does not own the position and was allowed to write to it. The owner run of"
                " this same body has already demonstrated, against a no-call counterfactual"
                " replayed from the same snapshot, that this exact call MUTATES ",
                vm.toString(delegatee_),
                "'s SEALED ledger - so this is not a bare permission check. A party with"
                " no authority over the position can move a third account's governance weight,"
                " irreversibly and without the consent of either. Only the owner may make this call."
            )
        );
    }

    /// @dev C4's non-vacuity witness, half one: the delegatee's SEALED ledger
    ///      over the instants a call made at `block.timestamp` can reach.
    ///      Split out only because the paired body runs out of EVM stack
    ///      otherwise. The warp is undone by the caller's snapshot restore, so
    ///      the clock is left where it was found.
    ///
    ///      THE WINDOW. `[callAt+1 .. min(nextBoundary(callAt)-1, callAt+600)]`,
    ///      plus THREE post-boundary instants — the boundary itself, one hour
    ///      later and one day later. The contiguous part costs at most 600
    ///      `getPastVotes` reads and is a LOWER bound on the evidence, which is
    ///      the safe direction for a vacuity guard. The three tail samples exist
    ///      so that a call whose ONLY effect lands at or after the boundary (a
    ///      deferred re-booking) is still witnessed rather than mistaken for a
    ///      no-op.
    function _sealedLedger(VeHemiVoteDelegation delegation_, address delegatee_)
        private returns (uint256[] memory out)
    {
        uint256 callAt = block.timestamp;
        uint256 nextHourBoundary = nextBoundary(callAt);
        uint256 lastContiguousSample = nextHourBoundary - 1;
        if (lastContiguousSample > callAt + 600) lastContiguousSample = callAt + 600;

        uint256 n = lastContiguousSample - callAt;
        out = new uint256[](n + 3);
        vm.warp(nextHourBoundary + 86401);   // `getPastVotes` refuses the future
        for (uint256 t = callAt + 1; t <= lastContiguousSample; ++t) {
            out[t - callAt - 1] = delegation_.getPastVotes(delegatee_, t);
        }
        out[n]     = delegation_.getPastVotes(delegatee_, nextHourBoundary);
        out[n + 1] = delegation_.getPastVotes(delegatee_, nextHourBoundary + 3600);
        out[n + 2] = delegation_.getPastVotes(delegatee_, nextHourBoundary + 86400);
    }

    /// @dev C4's non-vacuity witness, half two: how many sampled instants the
    ///      call moved. Zero means the call did not mutate the delegatee's
    ///      ledger AT ALL, which is the vacuity condition. Length equality is
    ///      asserted rather than assumed — two sweeps of different lengths
    ///      would mean the window moved under the law, and a law that cannot
    ///      answer must fail rather than guess.
    function _movedInstants(uint256[] memory noCallLedger_, uint256[] memory ownerCallLedger_)
        private returns (uint256 moved)
    {
        vm.assertEq(
            noCallLedger_.length, ownerCallLedger_.length, "C4 INTERNAL: the two sweeps have different lengths."
        );
        vm.assertGt(noCallLedger_.length, 0, "C4 INTERNAL: the sweep window is EMPTY - this body proved nothing.");
        for (uint256 i; i < noCallLedger_.length; ++i) {
            if (noCallLedger_[i] != ownerCallLedger_[i]) { unchecked { ++moved; } }
        }
    }

    // ================================================================= GUARDS
    /// @dev The law is historical: refuse to evaluate a window that has not
    ///      fully elapsed.
    function _requireHistorical(uint256 to_) private view {
        if (block.timestamp <= to_) {
            revert(string.concat(
                "MISUSE: this is a HISTORICAL law and was called at or before the end of the"
                " window it was asked about (now=", vm.toString(block.timestamp),
                ", window ends ", vm.toString(to_),
                "). A live predicate can always be told that what it sees is transient."
            ));
        }
    }

    /// @dev A record that MOVED is not a reference. A law that cannot answer
    ///      goes RED; it does not decline to look.
    function _requireQuiet(VeHemiVoteDelegation delegation_, Term[] memory witnessed_) private view {
        vm.assertGt(witnessed_.length, 0, "VACUOUS: the witnessed set is EMPTY - this body proved nothing.");
        for (uint256 i; i < witnessed_.length; ++i) {
            Term memory current = readTerm(delegation_, witnessed_[i].id);
            bool same = current.delegatee == witnessed_[i].delegatee
                && current.bias == witnessed_[i].bias
                && current.slope == witnessed_[i].slope
                && current.end == witnessed_[i].end;
            if (!same) {
                vm.assertTrue(same, string.concat(
                    "WINDOW NOT QUIET: position #", vm.toString(witnessed_[i].id),
                    "'s delegation record MOVED between the witness and now, so it is not a"
                    " reference for this window and this body proved nothing. Re-witness, or pass"
                    " it as the TOUCHED position to clause 2 instead. (This is deliberately a"
                    " FAILURE and not a skip: the branch that skips is the branch that suppresses.)"
                ));
            }
        }
    }

    // =============================================================== MESSAGES
    // Split out solely to keep ~400-byte strings off the EVM stack and out of
    // every iteration of a 3,600-second walk (measured: MemoryOOG at 1.07 G gas
    // when the concat is unconditional).
    function _vacuous(string memory clause_, address delegatee_, uint256 t_)
        private pure returns (string memory)
    {
        return string.concat(
            clause_, " VACUOUS: the floor for delegatee ", vm.toString(delegatee_),
            " at t=", vm.toString(t_),
            " is ZERO, so the clause would be satisfied by any reading whatsoever, including"
            " zero votes at every instant. A body that evaluated nothing FAILS here; it does not pass."
        );
    }

    function _shortfall(
        VeHemi ve_,
        Term[] memory witnessed_,
        address delegatee_,
        uint256 t_,
        uint256 floor_,
        uint256 votes_,
        string memory kind_
    ) private view returns (string memory) {
        return string.concat(
            string.concat(
                "DELEGATED VOTING POWER VANISHED (", kind_, "). Delegatee ", vm.toString(delegatee_),
                " should hold at least ", vm.toString(floor_),
                " wei of historical voting power at timestamp ", vm.toString(t_),
                ", but getPastVotes answers ", vm.toString(votes_), " wei - short by ",
                vm.toString(floor_ - votes_), " wei."
            ),
            string.concat(
                " Every position in that floor was still delegated to it and the escrow still"
                " held them: position #", vm.toString(witnessed_[0].id), " alone carried ",
                vm.toString(ve_.balanceOfNFTAt(witnessed_[0].id, t_)),
                " wei of escrow weight at that instant."
            ),
            " The instant has ALREADY ELAPSED, so any governance proposal snapshotted at it"
            " counts the missing weight as nonexistent and no vote taken in it can be re-cast."
        );
    }

    function _notHealed(
        VeHemi ve_,
        Term[] memory terms_,
        address delegatee_,
        uint256 nextHourBoundary_,
        uint256 writeAt_,
        uint256 floor_,
        uint256 votes_
    ) private view returns (string memory) {
        return string.concat(
            string.concat(
                "NOT HEALED AT THE BOUNDARY. A write landed at timestamp ", vm.toString(writeAt_),
                ". By the next hour boundary at ", vm.toString(nextHourBoundary_),
                " its effect must have landed in full. At that boundary delegatee ", vm.toString(delegatee_),
                " should hold ", vm.toString(floor_), " wei."
            ),
            string.concat(
                " getPastVotes answers ", vm.toString(votes_), " wei, short by ",
                vm.toString(floor_ - votes_),
                " wei, with ", vm.toString(ve_.balanceOfNFTAt(terms_[0].id, nextHourBoundary_)),
                " wei of escrow still backing position #", vm.toString(terms_[0].id), "."
            ),
            " Either the re-booking was skipped, or it landed low, or the shortfall outlived its"
            " own boundary."
        );
    }
}

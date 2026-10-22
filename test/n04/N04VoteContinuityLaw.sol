// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Vm.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";

/**
 * @title N04VoteContinuityLaw — vote-continuity clauses for delegated weight.
 *
 * @dev Four clauses. C1-C3 read only the public vote surface (`getVotes`,
 *      `getPastVotes`, `delegations(id)`, `VeHemi.balanceOfNFTAt`), which
 *      carries no caller, so the caller-conditional property ("only the
 *      position's owner may write to it") is clause C4, on the access surface:
 *
 *        C1 QUIET CONTINUITY  — a window in which NOBODY wrote to the witnessed
 *                               positions has no shortfall in the delegatee's
 *                               sealed history.
 *        C2 CONFINEMENT       — a write to ONE position never reaches an
 *                               UNTOUCHED co-delegator of the same delegatee:
 *                               its full weight survives, to the wei.
 *        C3 HEALED IN FULL    — at the first checkpoint boundary at or after a
 *                               write, the delegatee's SEALED history covers the
 *                               FULL floor, touched position included.
 *        C4 ACCESS PAIRING    — from ONE snapshot, three arms: the delegatee's
 *                               sealed ledger with NO call made (the
 *                               counterfactual), the same ledger after the
 *                               OWNER's call, which must succeed AND differ from
 *                               the counterfactual, and only then the identical
 *                               call by a NON-OWNER, which must REVERT. The owner
 *                               arm is the stranger arm's non-vacuity witness: a
 *                               lone "the stranger reverts" assertion also passes
 *                               if the call never reached the ledger.
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
library N04VoteContinuityLaw {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `VeHemiVoteDelegation.CHECKPOINT_INTERVAL` is `private constant`,
    ///      so it is restated here and pinned from the PUBLIC surface by
    ///      `N04LawTest.test_N04_L0_boundaryIsWhereTheContractSaysItIs`.
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
    function readTerm(VeHemiVoteDelegation d_, uint256 id_) internal view returns (Term memory w) {
        (address rd, uint48 end, uint96 bias, , uint64 slope) = d_.delegations(id_);
        w.id = id_;
        w.delegatee = rd;
        w.bias = uint256(bias);
        w.slope = uint256(slope);
        w.end = uint256(end);
    }

    function readTerms(VeHemiVoteDelegation d_, uint256[] memory ids_)
        internal view returns (Term[] memory out)
    {
        out = new Term[](ids_.length);
        for (uint256 i; i < ids_.length; ++i) out[i] = readTerm(d_, ids_[i]);
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
    function _floorAt(Term[] memory ws_, address delegatee_, uint256 t_)
        private pure returns (uint256 sum)
    {
        for (uint256 i; i < ws_.length; ++i) {
            if (ws_[i].delegatee != delegatee_) continue;   // not a member of the set at all
            sum += contributionAt(ws_[i].slope, ws_[i].bias, ws_[i].end, t_);
        }
    }

    // ==================================================================== C1
    /**
     * @notice CLAUSE 1 — QUIET CONTINUITY. Over a window in which the supplied
     *         delegator set was demonstrably NOT written to, the delegatee's
     *         SEALED history covers that set's full weight at every instant.
     *
     * @dev Red on any shortfall a write did not cause: a hole opened by the
     *      passage of time, or on a position nobody touched.
     *
     * @dev QUIETNESS IS VERIFIED, NOT ASSUMED, AND A NON-QUIET WINDOW FAILS.
     *      The law re-reads each record now and requires it identical to the
     *      witnessed one. If a record moved, this body cannot answer the
     *      question it was asked, so it goes RED rather than skipping.
     *
     * @param ws_ records witnessed BEFORE `from_`. Taken with `readTerms`.
     */
    function assertQuietWindowContinuous(
        VeHemi ve_,
        VeHemiVoteDelegation d_,
        Term[] memory ws_,
        address delegatee_,
        uint256 from_,
        uint256 to_
    ) internal view {
        _requireHistorical(to_);
        _requireQuiet(d_, ws_);

        // COVERAGE, ASSERTED: a floor of zero would make every later assertion
        // trivially satisfiable, which is the degenerate shape this whole file
        // exists to avoid. Checked at BOTH ends so a term expiring mid-window
        // cannot hollow the law out silently.
        uint256 f0 = _floorAt(ws_, delegatee_, from_);
        uint256 f1 = _floorAt(ws_, delegatee_, to_);
        vm.assertGt(f0, 0, _vacuous("C1", delegatee_, from_));
        vm.assertGt(f1, 0, _vacuous("C1", delegatee_, to_));

        for (uint256 t = from_; t <= to_; ++t) {
            uint256 floor_ = _floorAt(ws_, delegatee_, t);
            uint256 votes = d_.getPastVotes(delegatee_, t);
            if (votes < floor_) {
                vm.assertGe(votes, floor_, _shortfall(ve_, ws_, delegatee_, t, floor_, votes, "QUIET"));
            }
        }
    }

    // ==================================================================== C2
    /**
     * @notice CLAUSE 2 — CONFINEMENT. Over a window containing a write to ONE
     *         position, every UNTOUCHED position delegating to the same
     *         delegatee keeps its full weight in SEALED history, at every
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
        VeHemiVoteDelegation d_,
        Term[] memory untouched_,
        address delegatee_,
        uint256 from_,
        uint256 to_
    ) internal view {
        _requireHistorical(to_);
        _requireQuiet(d_, untouched_);

        uint256 f0 = _floorAt(untouched_, delegatee_, from_);
        uint256 f1 = _floorAt(untouched_, delegatee_, to_);
        vm.assertGt(f0, 0, _vacuous("C2", delegatee_, from_));
        vm.assertGt(f1, 0, _vacuous("C2", delegatee_, to_));

        for (uint256 t = from_; t <= to_; ++t) {
            uint256 floor_ = _floorAt(untouched_, delegatee_, t);
            uint256 votes = d_.getPastVotes(delegatee_, t);
            if (votes < floor_) {
                vm.assertGe(votes, floor_, _shortfall(ve_, untouched_, delegatee_, t, floor_, votes, "CONFINEMENT"));
            }
        }
    }

    // ==================================================================== C3
    /**
     * @notice CLAUSE 3 — HEALED IN FULL, AT THE BOUNDARY, IN SEALED HISTORY.
     *         At the first checkpoint boundary at or after `writeAt_`, the
     *         delegatee's historical votes cover the full floor of the supplied
     *         set INCLUDING the position that was written.
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
        VeHemiVoteDelegation d_,
        uint256[] memory ids_,
        address delegatee_,
        uint256 writeAt_
    ) internal view {
        uint256 bnd = nextBoundary(writeAt_);
        _requireHistorical(bnd);

        Term[] memory now_ = readTerms(d_, ids_);
        uint256 floor_ = _floorAt(now_, delegatee_, bnd);
        vm.assertGt(floor_, 0, _vacuous("C3", delegatee_, bnd));

        uint256 votes = d_.getPastVotes(delegatee_, bnd);
        if (votes < floor_) {
            vm.assertGe(votes, floor_, _notHealed(ve_, now_, delegatee_, bnd, writeAt_, floor_, votes));
        }
    }

    // ==================================================================== C4
    /**
     * @notice CLAUSE 4 — ACCESS PAIRING. The caller-conditional property,
     *         asserted on the surface where the caller is actually the subject.
     *
     *         ARM N: NOBODY calls anything. The delegatee's SEALED ledger is
     *                swept and kept. This is the counterfactual.
     *         ARM O: from the SAME state, `owner_` makes the call; it MUST
     *                succeed, AND the same sweep MUST DIFFER from arm N's.
     *         ARM S: from the SAME state again, `stranger_` makes the
     *                IDENTICAL call, and it MUST REVERT.
     *
     * @dev THE WITNESS IS "THE OWNER'S CALL MUTATES THE DELEGATEE'S LEDGER",
     *      measured as a DIFFERENTIAL against a no-call counterfactual
     *      replayed from the same snapshot:
     *
     *          #{ t in W : getPastVotes(delegatee, t) after the owner's call
     *                   != getPastVotes(delegatee, t) with no call at all }  > 0
     *
     *      and the law is RED if that count is zero, before arm S is reached.
     *
     * @dev WHY A DIFFERENTIAL AND NOT A COMPARISON AGAINST THE FLOOR.
     *      `_floorAt` sums only the CALLER-SUPPLIED records, so a delegatee with
     *      any co-delegator the caller did not name reads ABOVE its floor at
     *      every instant WITH NO CALL MADE AT ALL, and a "moved away from the
     *      floor" witness would fire on nothing. Both arms of the differential
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
        VeHemiVoteDelegation d_,
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
            _floorAt(readTerms(d_, ids_), delegatee_, block.timestamp), 0,
            _vacuous(string.concat("C4/", label_), delegatee_, block.timestamp)
        );

        uint256 snap = vm.snapshotState();

        // ---- ARM N. THE COUNTERFACTUAL. Nobody calls anything; the ledger is
        //      swept exactly as arm O will sweep it. EVM memory survives
        //      `revertToState` (only storage, balances and nonces roll back),
        //      so this vector is still here when arm O's is taken.
        uint256[] memory ctl = _sealedLedger(d_, delegatee_);
        vm.revertToState(snap);

        // ---- ARM O RUNS BEFORE ARM S, AND THE ORDER IS LOAD-BEARING.
        // Running arm O first makes the gate assertion UNREACHABLE unless this
        // entry point demonstrably moves the ledger on THIS tree; a body that
        // cannot evaluate its own subject is RED, not green.
        uint256[] memory own = _armOwner(d_, target_, call_, owner_, delegatee_, label_);
        vm.revertToState(snap);

        vm.assertGt(
            _movedInstants(ctl, own), 0,
            string.concat(
                "N04 C4 [", label_, "] NOT APPLICABLE / VACUOUS. The OWNER made this exact call"
                " and ", vm.toString(delegatee_), "'s sealed ledger is IDENTICAL to the"
                " no-call counterfactual replayed from the same snapshot, at every instant"
                " sampled. The call does not mutate the delegatee's ledger on this tree, so"
                " there is nothing here for a gate to close and asserting the stranger's revert"
                " from here would prove NOTHING - it is the `C5` failure mode, where a"
                " permission check turns a body green without touching any defect. This is"
                " deliberately RED and not a pass. Either point this probe at calldata that"
                " does mutate the ledger, or delete it on purpose and say so."
            )
        );

        // ---- ARM S. Only now, with the mutation proved on this tree, is the
        //      stranger's refusal a statement about anything.
        _armStranger(target_, call_, stranger_, delegatee_, label_);

        vm.revertToState(snap);
    }

    /// @dev ARM O, split out because the paired body runs out of EVM stack
    ///      otherwise. The owner's call MUST succeed; the sweep it returns is
    ///      half of the non-vacuity differential.
    function _armOwner(
        VeHemiVoteDelegation d_,
        address target_,
        bytes memory call_,
        address owner_,
        address delegatee_,
        string memory label_
    ) private returns (uint256[] memory) {
        vm.prank(owner_);
        (bool okO, ) = target_.call(call_);
        vm.assertEq(
            okO, true,
            string.concat(
                "N04 C4 [", label_, "] OWNER LOCKED OUT. The gate refused the position's own"
                " owner. The gate is for STRANGERS, not owners."
            )
        );
        return _sealedLedger(d_, delegatee_);
    }

    /// @dev ARM S, split out for the same reason. Reached ONLY after arm O has
    ///      proved, on this tree, that the refused call mutates the ledger.
    function _armStranger(
        address target_,
        bytes memory call_,
        address stranger_,
        address delegatee_,
        string memory label_
    ) private {
        vm.prank(stranger_);
        (bool okS, ) = target_.call(call_);
        vm.assertEq(
            okS, false,
            string.concat(
                "N04 C4 [", label_, "] GATE OPEN. ", vm.toString(stranger_),
                " does not own the position and was allowed to write to it. The owner arm of"
                " this same body has already demonstrated, against a no-call counterfactual"
                " replayed from the same snapshot, that this exact call MUTATES ",
                vm.toString(delegatee_),
                "'s SEALED voting record - so this is not a bare permission check. A party with"
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
    ///      THE WINDOW. `[T+1 .. min(nextBoundary(T)-1, T+600)]`, plus THREE
    ///      post-boundary instants — the boundary itself, one hour later and
    ///      one day later. The contiguous part costs at most 600 `getPastVotes`
    ///      reads and is a LOWER bound on the evidence, which is the safe
    ///      direction for a vacuity guard. The three tail samples exist so that
    ///      a call whose ONLY effect lands at or after the boundary (a deferred
    ///      re-booking) is still witnessed rather than mistaken for a no-op.
    function _sealedLedger(VeHemiVoteDelegation d_, address delegatee_)
        private returns (uint256[] memory out)
    {
        uint256 T = block.timestamp;
        uint256 bnd = nextBoundary(T);
        uint256 end = bnd - 1;
        if (end > T + 600) end = T + 600;

        uint256 n = end - T;
        out = new uint256[](n + 3);
        vm.warp(bnd + 86401);   // `getPastVotes` refuses the future
        for (uint256 t = T + 1; t <= end; ++t) out[t - T - 1] = d_.getPastVotes(delegatee_, t);
        out[n]     = d_.getPastVotes(delegatee_, bnd);
        out[n + 1] = d_.getPastVotes(delegatee_, bnd + 3600);
        out[n + 2] = d_.getPastVotes(delegatee_, bnd + 86400);
    }

    /// @dev C4's non-vacuity witness, half two: how many sampled instants the
    ///      call moved. Zero means the call did not mutate the delegatee's
    ///      ledger AT ALL, which is the vacuity condition. Length equality is
    ///      asserted rather than assumed — two sweeps of different lengths
    ///      would mean the window moved under the law, and a law that cannot
    ///      answer must fail rather than guess.
    function _movedInstants(uint256[] memory a_, uint256[] memory b_)
        private returns (uint256 moved)
    {
        vm.assertEq(a_.length, b_.length, "N04 C4 INTERNAL: the two sweeps have different lengths.");
        vm.assertGt(a_.length, 0, "N04 C4 INTERNAL: the sweep window is EMPTY - this body proved nothing.");
        for (uint256 i; i < a_.length; ++i) {
            if (a_[i] != b_[i]) { unchecked { ++moved; } }
        }
    }

    // ================================================================= GUARDS
    /// @dev The law is historical: refuse to evaluate a window that has not
    ///      fully elapsed.
    function _requireHistorical(uint256 to_) private view {
        if (block.timestamp <= to_) {
            revert(string.concat(
                "N04 MISUSE: this is a HISTORICAL law and was called at or before the end of the"
                " window it was asked about (now=", vm.toString(block.timestamp),
                ", window ends ", vm.toString(to_),
                "). A live predicate can always be told that what it sees is transient."
            ));
        }
    }

    /// @dev A record that MOVED is not a reference. A law that cannot answer
    ///      goes RED; it does not decline to look.
    function _requireQuiet(VeHemiVoteDelegation d_, Term[] memory ws_) private view {
        vm.assertGt(ws_.length, 0, "N04 VACUOUS: the witnessed set is EMPTY - this body proved nothing.");
        for (uint256 i; i < ws_.length; ++i) {
            Term memory n = readTerm(d_, ws_[i].id);
            bool same = n.delegatee == ws_[i].delegatee
                && n.bias == ws_[i].bias
                && n.slope == ws_[i].slope
                && n.end == ws_[i].end;
            if (!same) {
                vm.assertTrue(same, string.concat(
                    "N04 WINDOW NOT QUIET: position #", vm.toString(ws_[i].id),
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
            "N04 ", clause_, " VACUOUS: the floor for delegatee ", vm.toString(delegatee_),
            " at t=", vm.toString(t_),
            " is ZERO, so the clause would be satisfied by any reading whatsoever, including a"
            " total blackout. A body that evaluated nothing FAILS here; it does not pass."
        );
    }

    function _shortfall(
        VeHemi ve_,
        Term[] memory ws_,
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
                " held them: position #", vm.toString(ws_[0].id), " alone carried ",
                vm.toString(ve_.balanceOfNFTAt(ws_[0].id, t_)),
                " wei of escrow weight at that instant."
            ),
            " The instant has ALREADY ELAPSED, so any governance proposal snapshotted at it"
            " counts the missing weight as nonexistent and no vote taken in it can be re-cast."
        );
    }

    function _notHealed(
        VeHemi ve_,
        Term[] memory ws_,
        address delegatee_,
        uint256 bnd_,
        uint256 writeAt_,
        uint256 floor_,
        uint256 votes_
    ) private view returns (string memory) {
        return string.concat(
            string.concat(
                "NOT HEALED AT THE BOUNDARY. A write landed at timestamp ", vm.toString(writeAt_),
                ". By the checkpoint boundary at ", vm.toString(bnd_),
                " its effect must have landed in full. At that boundary delegatee ", vm.toString(delegatee_),
                " should hold ", vm.toString(floor_), " wei."
            ),
            string.concat(
                " getPastVotes answers ", vm.toString(votes_), " wei, short by ",
                vm.toString(floor_ - votes_),
                " wei, with ", vm.toString(ve_.balanceOfNFTAt(ws_[0].id, bnd_)),
                " wei of escrow still backing position #", vm.toString(ws_[0].id), "."
            ),
            " Either the re-booking was skipped, or it landed low, or the shortfall outlived its"
            " own boundary."
        );
    }
}

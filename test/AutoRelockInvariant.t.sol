// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {InvariantHandler} from "./InvariantHandler.sol";

/// @title AutoRelockInvariantTest
/// @notice Auto-relock invariants, plus the governance-denominator law, over the
///         same handler as `InvariantTest` (test/Invariant.t.sol). The handler's
///         auto-relock actions keep a per-token `FlatGhost` whose anchors (the
///         instant and end of the last enable or flat extension, the disable
///         instant, the R the handler computed) are written by the handler at
///         the time of each action.
///         `afterInvariant` floors the committed enables, disables and flat
///         extensions across the campaigns' runs.
///
///         Notation: R = `autoRelockRemaining(id)`;
///         grid(t) = floor(t / SIX_DAYS) * SIX_DAYS, the start of t's six-day bucket.
contract AutoRelockInvariantTest is Test {
    /// @dev Constants of VeHemi, restated (`MAX_TIME` is private there;
    ///      `SIX_DAYS` is also `veHemi.SIX_DAYS()`).
    uint256 internal constant MAX_TIME = 4 * 365.25 days;
    uint256 internal constant SIX_DAYS = 365.25 days / (12 * 5);

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carl = makeAddr("carl");
    address dan = makeAddr("dan");
    address earl = makeAddr("earl");

    InvariantHandler handler;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;

    /// @dev Runs after which the suite fails if some auto-relock action has
    ///      still never committed (see `afterInvariant`): the smallest PR
    ///      budget of one campaign in this contract.
    uint256 internal constant COVERAGE_WARMUP_RUNS = 32;
    string internal constant COVERAGE_PREFIX = "AUTO_RELOCK_INVARIANT_COVERAGE_";

    function setUp() public {
        handler = new InvariantHandler(admin, [alice, bob, carl, dan, earl]);
        veHemi = handler.veHemi();
        delegation = handler.delegation();

        targetContract(address(handler));

        for (uint256 i = 0; i < 5; i++) {
            targetSender(handler.users(i));
        }

        vm.setEnv(string.concat(COVERAGE_PREFIX, "runs"), "0");
        (string[] memory names,) = _coverage();
        for (uint256 i; i < names.length; ++i) vm.setEnv(string.concat(COVERAGE_PREFIX, names[i]), "0");
    }

    /// @dev Every invariant below is vacuous on a build without the
    ///      auto-relock ABI (the handler's auto-relock actions are no-ops).
    function invariant_autoRelockAbiIsPresent() public view {
        assertTrue(
            handler.autoRelockSupported(),
            "this build exposes no auto-relock ABI - every auto-relock invariant is vacuous"
        );
    }

    /// @dev The enable step is exactly `slope * (off - SIX_DAYS/2)` (signed),
    ///      `off = now - grid(now)`: the decaying weight `slope * (R - off)`
    ///      becomes the flat level `slope * (R - SIX_DAYS/2)`. An enable that
    ///      mints even one bucket of weight (e.g. stores `R + SIX_DAYS`) is
    ///      self-consistent across every curve, so only a comparison with the
    ///      weight just before the enable sees it.
    function invariant_autoRelockEnableStepIsTheBucketMeanClosedForm() public view {
        assertEq(
            handler.autoRelockEnableStepViolations(),
            0,
            "the enable step is not slope * ((now - grid(now)) - SIX_DAYS/2) to the wei"
        );
    }

    /// @dev R equals the value the handler computed at enable (or at the last
    ///      flat extension), `floor((end - grid(t)) / SIX_DAYS) * SIX_DAYS`,
    ///      for every position the handler believes is flat. Nothing between
    ///      the owner's enable and disable (top-ups included) may change it.
    function invariant_autoRelockRemainingMatchesAuthored() public {
        uint256 n = handler.everEnabledIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.everEnabledIds(i);
            InvariantHandler.FlatGhost memory g = handler.flatGhost(id);
            if (!g.enabled) continue;
            if (handler._ownerOf(id) == address(0)) continue;
            assertEq(
                uint256(handler.readAutoRelockRemaining(id)),
                uint256(g.remainingAuthored),
                "autoRelockRemaining != the R the handler computed at the last enable or flat extension"
            );
        }
    }

    /// @dev A flat position's weight is exactly constant: wei-equal to the
    ///      weight just after the enable, re-based only by a top-up or a flat
    ///      extension (the actions that legitimately change it).
    function invariant_autoRelockIsFlat() public {
        uint256 n = handler.everEnabledIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.everEnabledIds(i);
            InvariantHandler.FlatGhost memory g = handler.flatGhost(id);
            if (!g.enabled) continue;
            if (handler._ownerOf(id) == address(0)) continue;
            assertEq(
                veHemi.balanceOfNFT(id),
                g.flatWeight,
                "an auto-relocked position's weight moved - the curve is not flat"
            );
        }
    }

    /// @dev No live position has `lock.end > now + MAX_TIME`. `lock.end` is the
    ///      only withdraw gate, so a far-future sentinel end (or a disable rule
    ///      that hands back more than it froze, cycle after cycle) would make
    ///      the principal unreachable or the position immortal.
    function invariant_noLockEndBeyondNowPlusMaxTime() public {
        uint256 nextId = veHemi.nextTokenId();
        uint256 ceiling = block.timestamp + MAX_TIME;
        for (uint256 id = 1; id < nextId; ++id) {
            if (handler._ownerOf(id) == address(0)) continue;
            assertLe(
                uint256(veHemi.getLockedBalance(id).end),
                ceiling,
                "lock.end beyond now + MAX_TIME - sentinel end / immortal position"
            );
        }
    }

    /// @dev Disable restores the anchor end carried forward by the whole
    ///      buckets served flat, and never more. The anchor is the handler's
    ///      last enable or flat extension (`extendFlatPosition`) of the
    ///      position: `t_e` is its instant (`enabledAt`) and `E` its end
    ///      (`endBeforeEnable`: the end just before the enable, or the end the
    ///      extension bought). With `D` the disable instant,
    ///          X = grid(D) + (E - grid(t_e))
    ///      and the restored end must satisfy `X - SIX_DAYS < end <= X`. The
    ///      upper bound is anti-ratchet (a cycle never hands back more time than
    ///      it froze); the lower bound caps the loss below one bucket. `X` is
    ///      built from the handler's anchors only, not from the contract's R.
    function invariant_autoRelockDisableIsAntiRatchet() public view {
        uint256 n = handler.everEnabledIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.everEnabledIds(i);
            InvariantHandler.FlatGhost memory g = handler.flatGhost(id);
            if (!g.ownerDisabled) continue;
            uint256 x = (uint256(g.disabledAt) / SIX_DAYS) * SIX_DAYS
                + (uint256(g.endBeforeEnable) - (uint256(g.enabledAt) / SIX_DAYS) * SIX_DAYS);
            assertLe(
                uint256(g.endAfterDisable),
                x,
                "disable restored MORE than the frozen term - ratchet / immortal position"
            );
            assertGt(
                uint256(g.endAfterDisable) + SIX_DAYS,
                x,
                "disable destroyed a whole SIX_DAYS bucket or more of the frozen term"
            );
        }
    }

    // =====================================================================
    // Governance denominator.
    //
    // For every past instant t and every set of distinct delegatees D:
    //     sum_{d in D} getPastVotes(d, t) <= getPastTotalSupply(t)
    //
    // One-sided by design: undelegated weight is part of total supply
    // (`getPastTotalSupply`'s NatSpec), so equality holds only when everything
    // is delegated. Aragon's MajorityVotingBase computes
    // `totalVotingPower(snapshot) - yes - abstain` in checked arithmetic, so
    // one wei over this bound makes `canExecute()` revert for that proposal.
    // =====================================================================

    /// @dev Lock-final-hour records sampled per check: the newest three the
    ///      handler's ring still holds (`_newestLockFinalHourRecordIndices`).
    uint256 private constant LOCK_FINAL_HOUR_SAMPLES = 3;

    /// @dev Checked at `now`, `now - 1`, and at instants relative to recorded
    ///      lock-final-hour operations (`InvariantHandler.lockFinalHourOp`):
    ///      around the operation instant and around the subject lock's own
    ///      end. About twenty times the per-call cost of the other bodies (up
    ///      to 23 instants x 7 history reads), hence the smaller PR budget.
    /// forge-config: ci.invariant.runs = 32
    function invariant_pastVotesNeverExceedPastTotalSupply() public view {
        _checkPastVotesBound(block.timestamp);
        if (block.timestamp > 1) _checkPastVotesBound(block.timestamp - 1);

        uint256 n = handler.lockFinalHourRecordCount();
        uint256 lim = n < LOCK_FINAL_HOUR_SAMPLES ? n : LOCK_FINAL_HOUR_SAMPLES;
        uint256[] memory newest = _newestLockFinalHourRecordIndices(n, lim);
        for (uint256 i; i < lim; ++i) {
            (uint64 calledAt, uint64 endBefore) = handler.lockFinalHourRecord(newest[i]);
            if (calledAt > 1) _checkPastVotesBound(uint256(calledAt) - 1);
            _checkPastVotesBound(calledAt);
            _checkPastVotesBound(uint256(calledAt) + 1);
            if (endBefore > calledAt) {
                _checkPastVotesBound((uint256(calledAt) + uint256(endBefore)) / 2);
                _checkPastVotesBound(uint256(endBefore) - 1);
            }
            _checkPastVotesBound(endBefore);
            _checkPastVotesBound(uint256(endBefore) + 1);
        }
    }

    /// @dev Indices of the `k_` records with the largest `calledAt` among the
    ///      ring's `n_`. Until the ring is full the handler appends, so these
    ///      are its last slots; once it is full each record overwrites the
    ///      oldest slot (the handler's write counter mod 8), so the ring holds
    ///      the last eight records and the newest can sit in any slot. Every
    ///      record warps to an instant after the previous one, so `calledAt`
    ///      grows strictly from record to record and the largest are the newest.
    function _newestLockFinalHourRecordIndices(uint256 n_, uint256 k_) internal view returns (uint256[] memory idx) {
        uint64[] memory callInstants = new uint64[](n_);
        for (uint256 i; i < n_; ++i) (callInstants[i], ) = handler.lockFinalHourRecord(i);
        idx = new uint256[](k_);
        for (uint256 j; j < k_; ++j) {
            uint256 best;
            for (uint256 i = 1; i < n_; ++i) {
                if (callInstants[i] > callInstants[best]) best = i;
            }
            idx[j] = best;
            callInstants[best] = 0; // taken (every recorded calledAt is > 0)
        }
    }

    /// @dev Instants in the future are not past instants and are skipped.
    function _checkPastVotesBound(uint256 t) private view {
        if (t == 0 || t > block.timestamp) return;
        uint256 supply = delegation.getPastTotalSupply(t);
        uint256 votes;
        for (uint256 i; i < 5; ++i) {
            votes += delegation.getPastVotes(handler.users(i), t);
        }
        // address(0) is distinct from every user, so it belongs in the sum.
        votes += delegation.getPastVotes(address(0), t);
        require(
            votes <= supply,
            "sum getPastVotes(d,t) > getPastTotalSupply(t) - Aragon's noVotesWorstCase underflows"
        );
    }

    // =====================================================================
    // Coverage floor.
    // =====================================================================

    function _coverage() internal view returns (string[] memory names, uint256[] memory counts) {
        names = new string[](3);
        counts = new uint256[](3);
        names[0] = "enableSuccesses";  counts[0] = handler.autoRelockEnableSuccesses();
        names[1] = "disableSuccesses"; counts[1] = handler.autoRelockDisableSuccesses();
        names[2] = "extendSuccesses";  counts[2] = handler.autoRelockExtendSuccesses();
    }

    /// @notice Coverage floor, as in
    ///         `AutoRelockLedgerInvariantTest.afterInvariant`. Foundry resets
    ///         all EVM state (the handler's counters included) at every
    ///         run boundary and calls `afterInvariant` once per run, so the
    ///         counts are summed across runs in process environment variables,
    ///         which the reset does not touch, and the suite fails once
    ///         `COVERAGE_WARMUP_RUNS` runs have passed with some auto-relock
    ///         action never committed. This contract has one campaign per
    ///         invariant, possibly on parallel threads, and they all add to the
    ///         same sums, so the floor is over every run of every campaign here
    ///         (nothing outside this contract writes these variables).
    function afterInvariant() public {
        string memory runsKey = string.concat(COVERAGE_PREFIX, "runs");
        uint256 runs = vm.envOr(runsKey, uint256(0)) + 1;
        vm.setEnv(runsKey, vm.toString(runs));
        (string[] memory names, uint256[] memory counts) = _coverage();
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(COVERAGE_PREFIX, names[i]);
            uint256 total = vm.envOr(key, uint256(0)) + counts[i];
            vm.setEnv(key, vm.toString(total));
            if (runs >= COVERAGE_WARMUP_RUNS && total == 0) {
                revert(string.concat(
                    "COVERAGE: ", names[i], " never committed in ", vm.toString(runs),
                    " runs - the auto-relock invariants that depend on it are vacuous"
                ));
            }
        }
    }
}

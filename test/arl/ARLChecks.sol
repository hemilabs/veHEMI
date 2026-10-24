// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Vm.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";
import {ARLHandler} from "./ARLHandler.sol";
import {VoteHoleLaw} from "./VoteHoleLaw.sol";

/**
 * @title ARLChecks
 * @notice The auto-relock invariant laws, one external function per law, called
 *         by `ARLInvariantTest.invariant_arl_core` after every handler call and
 *         by the deterministic tests in test/arl/MaintainedEnd.t.sol.
 *
 * @dev Each check reverts on failure (`vm.assert*`). "Authored" values come
 *      from `ARLHandler`'s ledger, which is written from the arguments the
 *      handler chose and its own clock, never read back from the contract.
 */
contract ARLChecks {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ARLHandler public immutable handler;
    VeHemi public immutable veHemi;
    VeHemiVoteDelegation public immutable delegation;

    constructor(ARLHandler h) {
        handler = h;
        veHemi = h.veHemi();
        delegation = h.delegation();
    }

    function _rem(uint256 i) internal view returns (uint64 r) { (,,,,,, r) = handler.shadows(i); }
    function _alive(uint256 i) internal view returns (bool a) { (, a,,,,,) = handler.shadows(i); }
    function _id(uint256 i) internal view returns (uint256 t) { (t,,,,,,) = handler.shadows(i); }
    function _forf(uint256 i) internal view returns (bool f) { (,,,,, f,) = handler.shadows(i); }

    // ===================== weight and supply vs the ledger =====================

    /// @notice Every live position's `balanceOfNFT` equals the ledger's weight:
    ///         `slope * (R - SIX_DAYS/2)` when flat, `slope * (end - now)` when
    ///         decaying. Per position, so corruptions that cancel in a sum are
    ///         still caught.
    function checkPerPositionWeightMatchesAuthored() external view {
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            if (!_alive(i)) continue;
            vm.assertEq(veHemi.balanceOfNFT(_id(i)), handler.authoredWeight(i),
                "balanceOfNFT != AUTHORED weight for this position");
        }
    }

    function checkSupplyEqualsAuthoredSum() external view {
        uint256 sum;
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) if (_alive(i)) sum += handler.authoredWeight(i);
        vm.assertEq(sum, veHemi.totalVeHemiSupply(), "totalVeHemiSupply != AUTHORED sum");
    }

    /// @notice The global point's flat aggregate (`Point.amount`) equals the
    ///         ledger's sum of flat weights.
    function checkFlatAggregateEqualsAuthoredSum() external view {
        uint256 expected;
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            if (!_alive(i) || _rem(i) == 0) continue;
            expected += handler.authoredWeight(i);
        }
        vm.assertEq(
            uint256(veHemi.getGlobalPoint(veHemi.epoch()).amount), expected,
            "flat aggregate != AUTHORED sum"
        );
    }

    /// @notice The per-position primitives equal the ledger: amount, end,
    ///         transferableAfter, forfeitable, R, and the refresh stamp (set
    ///         while flat, cleared once the position leaves flat).
    function checkPrimitivesMatchAuthoredLedger() external view {
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            (uint256 id, bool alive, int128 amount, uint64 end, uint64 ta, bool forf, uint64 rem) =
                handler.shadows(i);
            if (!alive) continue;
            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(id);
            vm.assertEq(int256(lb.amount), int256(amount), "locked.amount != authored");
            vm.assertEq(uint256(lb.end), uint256(end), "locked.end != authored");
            vm.assertEq(veHemi.transferableAfter(id), uint256(ta), "transferableAfter != authored");
            vm.assertEq(veHemi.forfeitable(id), forf, "forfeitable != authored");
            vm.assertEq(uint256(veHemi.autoRelockRemaining(id)), uint256(rem), "autoRelockRemaining != authored");
            if (rem != 0) {
                vm.assertGt(uint256(veHemi.autoRelockRefreshedAt(id)), 0, "refresh stamp unset on a flat position");
                vm.assertLe(uint256(veHemi.autoRelockRefreshedAt(id)), block.timestamp, "refresh stamp in the future");
            } else {
                vm.assertEq(uint256(veHemi.autoRelockRefreshedAt(id)), 0, "refresh stamp survived retirement");
            }
        }
    }

    /// @notice Every flat position's `autoRelockRemaining` is a whole number
    ///         of SIX_DAYS buckets.
    function checkRemainingIsWholeBuckets() external view {
        uint256 S = handler.SIX_DAYS();
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            if (!_alive(i) || _rem(i) == 0) continue;
            vm.assertEq(uint256(veHemi.autoRelockRemaining(_id(i))) % S, 0,
                "autoRelockRemaining is not a whole number of SIX_DAYS buckets");
        }
    }

    /// @notice `effectiveLockEnd` of a flat position is `grid(now) + R`, with
    ///         R from the ledger, at every instant (no touch needed).
    function checkMaintainedEndIsPureFunction() external view {
        uint256 S = handler.SIX_DAYS();
        uint256 g = (block.timestamp / S) * S;
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            if (!_alive(i) || _rem(i) == 0) continue;
            vm.assertEq(veHemi.effectiveLockEnd(_id(i)), g + uint256(_rem(i)),
                "effectiveLockEnd != grid(now) + AUTHORED R");
        }
    }

    // ===================== the weight steps, in closed form =====================

    /// @notice The enable step is exactly `slope * (off - SIX_DAYS/2)`
    ///         (signed), `off = now - grid(now)`, and under one bucket of the
    ///         position's own slope.
    function checkEnableStepIsExact() external view {
        vm.assertEq(handler.enableStepOverBucket(), 0,
            "ENABLE STEP (either sign) >= ONE FULL BUCKET of the position's own slope");
        vm.assertEq(
            handler.enableStepNotExact(), 0,
            string.concat(
                "ENABLE STEP != slope * ((now - grid(now)) - SIX_DAYS/2). worst error = ",
                vm.toString(handler.maxEnableStepErrWei()), " wei"
            )
        );
    }

    /// @notice The disable step is exactly `slope * (SIX_DAYS/2 - off)`
    ///         (signed): the half bucket the enable gave up, handed back.
    function checkDisableStepIsExact() external view {
        vm.assertEq(handler.disableStepOverBucket(), 0,
            "DISABLE STEP >= ONE FULL BUCKET of the position's own slope");
        vm.assertEq(
            handler.disableStepNotExact(), 0,
            string.concat(
                "DISABLE STEP != slope * (SIX_DAYS/2 - (now - grid(now))). worst error = ",
                vm.toString(handler.maxDisableStepErrWei()), " wei"
            )
        );
    }

    /// @notice A keeper's `retireStaleAutoRelock` moves the weight by the same
    ///         closed form as an owner disable.
    function checkRetireStepIsExact() external view {
        vm.assertEq(
            handler.staleRetireStepNotExact(), 0,
            string.concat(
                "a KEEPER retire moved the weight by something other than the disable step; worst err = ",
                vm.toString(handler.maxStaleRetireStepErrWei()), " wei"
            )
        );
    }

    /// @notice `increaseUnlockTime` on a flat position raises the weight by
    ///         exactly `slope * (newR - R)`.
    function checkExtendWhileFlatIsExact() external view {
        vm.assertEq(
            handler.extendWeightViolations(), 0,
            "EXTEND-WHILE-FLAT: increaseUnlockTime did not deliver newR exactly"
        );
    }

    // ===================== refusals =====================

    /// @notice A flat position is never withdrawable, at any timestamp
    ///         (including past its stored `lock.end`), and the refusal is
    ///         `LockNotExpired`. Fed by two independent probe actions.
    function checkFlatIsNeverWithdrawable() external view {
        vm.assertEq(
            handler.flatWithdrawSuccesses(), 0,
            string.concat(
                "a FLAT position was withdrawn. max weight that left = ",
                vm.toString(handler.flatWithdrawWeightLeaked()), " wei"
            )
        );
        vm.assertEq(handler.flatWithdrawAccepted(), 0, "withdraw() ACCEPTED on a flat position");
        vm.assertEq(
            handler.flatWithdrawWrongError(), 0,
            "a flat withdraw was refused with the WRONG error (not LockNotExpired)"
        );
    }

    /// @notice Calls the contract must refuse were refused, every time.
    function checkGuardProbesAllRefused() external view {
        vm.assertEq(handler.doubleEnableAccepted(), 0, "PROBE: a second enableAutoRelock was ACCEPTED");
        vm.assertEq(handler.shortREnableAccepted(), 0, "PROBE: enableAutoRelock ACCEPTED with R < 2 * SIX_DAYS");
        vm.assertEq(handler.disableNotEnabledAccepted(), 0, "PROBE: disableAutoRelock ACCEPTED on a non-flat position");
        vm.assertEq(handler.extendShorterAccepted(), 0, "PROBE: increaseUnlockTime ACCEPTED a SHORTER term while flat");
    }

    function checkKeeperProbesAllRefused() external view {
        vm.assertEq(handler.refreshStrangerAccepted(), 0,
            "PROBE: refreshAutoRelock ACCEPTED from a NON-OWNER (NotOwner)");
        vm.assertEq(handler.refreshNotEnabledAccepted(), 0,
            "PROBE: refreshAutoRelock ACCEPTED on a NON-FLAT position (AutoRelockNotEnabled)");
        vm.assertEq(handler.staleRetireEarlyAccepted(), 0,
            "PROBE: retireStaleAutoRelock ACCEPTED BEFORE autoRelockStaleAt (AutoRelockNotStale)");
        vm.assertEq(handler.extendTooLongAccepted(), 0,
            "PROBE: increaseUnlockTime ACCEPTED unlockTime > now + MAX_TIME while flat (LockDurationTooLong)");
    }

    /// @notice `refreshAutoRelock` (and `enableAutoRelock`, which also stamps)
    ///         sets `autoRelockStaleAt` to `stamp + STALE_FLAT_BUCKETS * SIX_DAYS`,
    ///         with the stamp taken from the ledger.
    function checkHeartbeatMovesStaleClock() external view {
        vm.assertEq(handler.heartbeatClockViolations(), 0,
            "refreshAutoRelock did NOT move autoRelockStaleAt to now + STALE_FLAT_BUCKETS * SIX_DAYS");
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            (uint256 id, bool alive,,,,, uint64 rem) = handler.shadows(i);
            if (!alive || rem == 0) continue;
            uint64 stamped = handler.refreshedAtAuthored(id);
            if (stamped == 0) continue;
            vm.assertEq(
                veHemi.autoRelockStaleAt(id),
                uint256(stamped) + handler.STALE_FLAT_BUCKETS_LOCAL() * handler.SIX_DAYS(),
                "autoRelockStaleAt != AUTHORED refresh stamp + STALE_FLAT_BUCKETS * SIX_DAYS"
            );
        }
    }

    /// @notice The forfeit window is `transferableAfter`, not the (possibly
    ///         frozen) `lock.end`: refused once `now >= ta`, accepted inside
    ///         the window on a flat position.
    function checkForfeitWindowIsTA() external view {
        vm.assertEq(handler.forfeitOutOfWindowAccepted(), 0,
            "forfeit ACCEPTED outside the transferableAfter window");
        vm.assertEq(handler.forfeitInWindowFlatRefused(), 0,
            "forfeit REFUSED inside the window on a FLAT position");
    }

    // ===================== votes and delegation =====================

    /// @notice At the next hour boundary, the sum of `getVotes` over the users
    ///         is at most `totalVeHemiSupply()` and at most the ledger's total.
    /// @dev Evaluated at the next hour boundary, past every pending checkpoint
    ///      leg (a delegation write is dated `block.timestamp + 1`, its deferred
    ///      leg the next boundary).
    function checkVotesNeverExceedSupply() external {
        uint256 saved = block.timestamp;
        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours);
        uint256 votes;
        for (uint256 i; i < 5; ++i) votes += delegation.getVotes(handler.users(i));
        uint256 supply = veHemi.totalVeHemiSupply();
        uint256 authored;
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) if (_alive(i)) authored += handler.authoredWeight(i);
        vm.warp(saved);
        vm.assertLe(votes, supply, "sum(getVotes) EXCEEDS totalVeHemiSupply - vote inflation");
        vm.assertLe(votes, authored, "sum(getVotes) EXCEEDS the AUTHORED total weight - vote inflation");
    }

    /// @notice At the next hour boundary, the sum of `getVotes` over the users
    ///         equals the sum of their positions' `balanceOfNFT` (every
    ///         position is delegated to one of the users).
    function checkVotingPowerEquality() external {
        uint256 saved = block.timestamp;
        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours);
        uint256 sumOfBalances;
        uint256 sumOfVotes;
        for (uint256 i; i < 5; ++i) {
            address user = handler.users(i);
            sumOfVotes += delegation.getVotes(user);
            uint256 nfts = veHemi.balanceOf(user);
            for (uint256 j; j < nfts; ++j) {
                sumOfBalances += veHemi.balanceOfNFT(veHemi.tokenOfOwnerByIndex(user, j));
            }
        }
        vm.warp(saved);
        vm.assertEq(sumOfBalances, sumOfVotes, "sum of balances != sum of votes");
    }

    /// @notice The governance denominator: for t in {now, now - 1, the last
    ///         hour boundary}, the users' `getPastVotes(t)` sum to at most
    ///         `getPastTotalSupply(t)`. Aragon subtracts the votes from the
    ///         total in checked arithmetic.
    function checkPastVotesNeverExceedPastTotalSupply() external view {
        _pastVotesBound(block.timestamp, "now");
        if (block.timestamp > 1) _pastVotesBound(block.timestamp - 1, "now - 1");
        uint256 h = (block.timestamp / 1 hours) * 1 hours;
        if (h != 0) _pastVotesBound(h, "last hour boundary");
    }

    function _pastVotesBound(uint256 t, string memory at) internal view {
        uint256 votes;
        for (uint256 i; i < 5; ++i) votes += delegation.getPastVotes(handler.users(i), t);
        votes += delegation.getPastVotes(address(0), t);
        vm.assertLe(votes, delegation.getPastTotalSupply(t),
            string.concat("sum(getPastVotes) EXCEEDS getPastTotalSupply at ", at));
    }

    /// @notice No weight-changing call swallowed a delegation revert
    ///         (`DelegationUpdateFailed` is never emitted under the honest
    ///         module).
    function checkDelegationRefreshNeverSilentlyFails() external view {
        vm.assertEq(handler.delegationUpdateFailedCount(), 0,
            "a delegation refresh reverted and was swallowed (DelegationUpdateFailed)");
    }

    /// @notice For every live flat position the delegation record's cached
    ///         amount equals the ledger's principal, so a refresh that was
    ///         silently skipped (no revert, no event) is caught.
    function checkFlatPositionsStayDelegated() external view {
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) {
            (uint256 id, bool alive, int128 amount,,,, uint64 rem) = handler.shadows(i);
            if (!alive || rem == 0 || amount <= 0) continue;
            uint256 cached = uint256(delegation.delegation(id).amount);
            vm.assertEq(cached, uint256(uint128(amount)),
                "flat position's cached delegation is STALE - the refresh was silently skipped");
        }
    }

    function checkTransferAlwaysDisarms() external view {
        vm.assertEq(handler.transferDisarmMissed(), 0,
            "a transfer to another account left the position ARMED");
    }

    /// @notice After a transfer the record is a decaying record at the
    ///         recipient's delegate; after `delegate` it is at the chosen
    ///         delegatee.
    function checkRecordsRouteToTheChosenDelegate() external view {
        vm.assertEq(handler.transferMisrouted(), 0,
            "after a transfer the record is not a decaying record at the recipient's delegate");
        vm.assertEq(handler.delegateMisrouted(), 0,
            "after delegate() the record is not at the chosen delegatee");
    }

    /// @notice The `VoteHoleLaw` bound on a re-delegation's booking
    ///         (`delegationBookedAt`, `block.timestamp + 1`): (A) no booking
    ///         matures past the next hourly boundary; (A2) a token without a
    ///         delegation record has no maturity stamp; (B) every delegatee's
    ///         votes are at least the sum of its matured records, so no write
    ///         takes weight from a co-delegator.
    function checkVoteHoleBounded() external view {
        uint256 n = handler.shadowsLength();
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = _id(i);
        address[] memory dg = new address[](5);
        for (uint256 i; i < 5; ++i) dg[i] = handler.users(i);
        VoteHoleLaw.Report memory r = VoteHoleLaw.scan(delegation, ids, dg, block.timestamp);
        vm.assertEq(
            r.lateMaturity, 0,
            string.concat(
                "VOTE HOLE (A): a delegation booking matures PAST the next hourly boundary, by ",
                vm.toString(r.maxLateBy), " s"
            )
        );
        vm.assertEq(r.orphanStamp, 0,
            "VOTE HOLE (A2): a maturity stamp survived the deletion of its delegation record");
        vm.assertEq(
            r.shortfalls, 0,
            string.concat(
                "VOTE HOLE (B): a delegatee's votes are BELOW the sum of its MATURED delegations by ",
                vm.toString(r.maxShortfallWei), " wei"
            )
        );
    }

    // ===================== subcurves and history =====================

    function checkNonTransferableEqualsAuthoredSum() external view {
        uint256 expected;
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) expected += handler.authoredSubWeight(i);
        vm.assertEq(expected, veHemi.nonTransferableTotalVeHemiSupply(), "non-transferable subcurve != AUTHORED sum");
    }

    function checkForfeitableEqualsAuthoredSum() external view {
        uint256 expected;
        uint256 n = handler.shadowsLength();
        for (uint256 i; i < n; ++i) if (_forf(i)) expected += handler.authoredSubWeight(i);
        vm.assertEq(expected, veHemi.forfeitableTotalVeHemiSupply(), "forfeitable subcurve != AUTHORED sum");
    }

    /// @notice `supplyBreakdown()` agrees with the dedicated views (no clamp
    ///         rewrites `locked_` or `forfeitable_`), and `transferable` is the
    ///         saturating complement.
    function checkBreakdownAgreesWithDedicated() external view {
        (uint256 bTot, uint256 bLk, uint256 bFo, uint256 bTr) = veHemi.supplyBreakdown();
        vm.assertEq(bTot, veHemi.totalVeHemiSupply(), "breakdown.total != totalVeHemiSupply()");
        vm.assertEq(bLk, veHemi.nonTransferableTotalVeHemiSupply(),
            "breakdown.locked_ != nonTransferableTotalVeHemiSupply()");
        vm.assertEq(bFo, veHemi.forfeitableTotalVeHemiSupply(),
            "breakdown.forfeitable_ != forfeitableTotalVeHemiSupply()");
        vm.assertLe(bFo, bLk, "breakdown forfeitable_ > locked_");
        vm.assertEq(bTr, bTot > bLk ? bTot - bLk : 0, "breakdown.transferable is not the saturating complement");
    }

    /// @notice A sampled `totalVeHemiSupplyAt(t)` never changes once `t` is in
    ///         the past (the Aragon quorum denominator), and equals the
    ///         ledger's total at `t`.
    function checkPastSupplyImmutability() external view {
        uint256 n = handler.pastSupplySamplesLength();
        for (uint256 i; i < n; ++i) {
            (uint256 ts, uint256 supply, uint256 authored, bool valid) = handler.pastSupplySamples(i);
            if (ts >= block.timestamp) continue;
            if (!valid) continue;
            vm.assertEq(veHemi.totalVeHemiSupplyAt(ts), supply,
                "totalVeHemiSupplyAt(past) MUTATED - Aragon quorum denominator");
            vm.assertEq(veHemi.totalVeHemiSupplyAt(ts), authored,
                "totalVeHemiSupplyAt(past) != the AUTHORED total at that instant");
        }
    }
}

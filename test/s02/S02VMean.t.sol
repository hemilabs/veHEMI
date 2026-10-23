// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/**
 * @title  The V-MEAN flat level.
 *
 * @notice A flat (auto-relocking) position's weight is `slope * (R - SIX_DAYS/2)`,
 *         `R = N * SIX_DAYS`, `N >= 2`, measured from `grid(enable)`. At any
 *         instant the position is still serving `R - off` seconds of lock-up
 *         (`disableAutoRelock` restores `grid(now) + R`), so the instantaneous
 *         entitlement `slope * (R - off)` is a sawtooth from `slope * R` at
 *         `off == 0` down to `slope * (R - SIX_DAYS)`. The shipped level is its
 *         midpoint. The rivals each body excludes:
 *
 *           V-UPPER  slope * R                    (the sup)
 *           V-MEAN   slope * (R - SIX_DAYS/2)     (the midpoint, shipped)
 *           V-LOWER  slope * (R - SIX_DAYS)       (the inf)
 *           N+1      slope * (R + SIX_DAYS/2)
 *           N-1      slope * (R - 3*SIX_DAYS/2)
 *
 *         V-UPPER minus V-MEAN is exactly `slope * SIX_DAYS/2` per flat
 *         position at every instant; the laws below observe it pointwise, in
 *         the global aggregate, in the time-integral and as a minimax claim.
 *
 * @dev    Every body counts its observations in memory, emits them and asserts
 *         a floor on them, and no discriminating assertion sits inside a
 *         conditional that a rival level would make false.
 */
contract S02VMean is LockedCurveTestBase {
    uint256 internal constant HALF_BUCKET = 262_980; // SIX_DAYS / 2

    function setUp() public virtual override {
        super.setUp();
        runSeedingFlow();
    }

    // ------------------------------------------------------------------ util

    function _mk(address who, uint256 amt, uint256 dur, bool transferable_, bool forf_)
        internal
        returns (uint256 id)
    {
        vm.startPrank(who);
        hemi.mint(who, amt);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLockFor(amt, dur, who, transferable_, forf_);
        vm.stopPrank();
    }

    function _grid() internal view returns (uint256) {
        return (block.timestamp / SIX_DAYS) * SIX_DAYS;
    }

    function _slope(uint256 amt) internal pure returns (uint256) {
        return amt / MAX_TIME;
    }

    function _enable(address who, uint256 id) internal {
        vm.prank(who);
        veHemi.enableAutoRelock(id);
    }

    /// @dev Park the clock on the NEXT SIX_DAYS grid point.
    function _warpToNextGrid() internal {
        vm.warp(_grid() + SIX_DAYS);
        vm.roll(block.number + 1);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // =====================================================================
    // L1 — THE MIDPOINT LAW.
    //
    //      The flat level is the exact MIDPOINT of the live sawtooth, and both
    //      endpoints of that sawtooth are read from a REAL position by the
    //      production reader.  No constant, no `SIX_DAYS/2`, no mirror of the
    //      source expression: `peak` and `trough` are `balanceOfNFT` of an
    //      identical, UNENABLED twin at the two ends of one bucket.
    //
    //          2 * flat  ==  peak + trough
    //
    //      V-UPPER  -> 2*peak != peak+trough      (short by slope*SIX_DAYS)
    //      V-LOWER  -> 2*trough != peak+trough    (long  by slope*SIX_DAYS)
    //      N+1 / N-1 off-by-one-bucket -> off the midpoint by slope*SIX_DAYS*2
    // =====================================================================
    function test_S02_L1_flat_level_is_the_live_midpoint_of_the_twin_sawtooth() public {
        uint256 obs;
        uint256 obsStrictlyInside;
        uint256 amt = 300 ether;
        uint256 s = _slope(amt);

        for (uint256 n = 2; n <= 9; ++n) {
            if (_l1OneHorizon(n, amt, s)) ++obsStrictlyInside;
            ++obs;
        }

        emit log_named_uint("L1 OBS midpoint equalities executed", obs);
        emit log_named_uint("L1 OBS level strictly inside [trough, peak]", obsStrictlyInside);
        assertEq(obs, 8, "L1 VACUITY: the law did not execute at 8 horizons");
        assertEq(obsStrictlyInside, 8, "L1 VACUITY: the level was never strictly inside the sawtooth");
    }


    /// @dev L1 at ONE horizon, extracted so the law's frame stays shallow.
    ///      Returns true iff the shipped level was strictly inside the live
    ///      sawtooth [trough, peak].
    function _l1OneHorizon(uint256 n, uint256 amt, uint256 s) internal returns (bool) {
        _warpToNextGrid();
        assertEq(block.timestamp % SIX_DAYS, 0, "L1 fixture: not on the grid");

        uint256 idA = _mk(alice, amt, n * SIX_DAYS, true, false);
        uint256 idB = _mk(bob, amt, n * SIX_DAYS, true, false);
        _enable(alice, idA);

        uint256 peak = veHemi.balanceOfNFT(idB);   // LIVE, off == 0
        uint256 flat = veHemi.balanceOfNFT(idA);

        vm.warp(block.timestamp + SIX_DAYS);
        vm.roll(block.number + 1);

        uint256 trough = veHemi.balanceOfNFT(idB); // LIVE, one bucket on
        assertEq(veHemi.balanceOfNFT(idA), flat, "L1: the auto-relock level moved inside a bucket");

        emit log_named_uint("L1 N", n);
        emit log_named_uint("   peak  (live twin, off=0)", peak);
        emit log_named_uint("   flat  (live, auto-relock)", flat);
        emit log_named_uint("   trough(live twin, off=S)", trough);

        // The twin really does saw -- otherwise the midpoint is a tautology.
        assertEq(peak - trough, s * SIX_DAYS, "L1: the twin ramp is not one bucket of slope");

        // *** THE LAW ***  UNCONDITIONAL.  No `if`.
        assertEq(2 * flat, peak + trough, "L1: flat level is NOT the midpoint of the live sawtooth");

        // and the named rivals, excluded by name so a reader sees the set.
        assertTrue(flat < peak, "L1: level is V-UPPER (the sup), not the midpoint");
        assertTrue(flat > trough, "L1: level is V-LOWER (the inf), not the midpoint");
        assertEq(peak - flat, s * HALF_BUCKET, "L1: V-MEAN/V-UPPER gap != slope * SIX_DAYS/2");
        assertEq(flat - trough, s * HALF_BUCKET, "L1: V-MEAN/V-LOWER gap != slope * SIX_DAYS/2");
        return flat < peak && flat > trough;
    }

    // =====================================================================
    // L2 — THE GLOBAL AGGREGATE.  Same claim, read through the SUPPLY views,
    //      over FIVE flat non-transferable positions of different sizes and
    //      different horizons.
    //
    //      `nonTransferableTotalVeHemiSupply()` is the frozen subcurve ramp
    //      `SUM slope_i * (ta_i - t)` (the subcurve ignores auto-relock),
    //      i.e. the live aggregate of the HONEST entitlement.  So:
    //
    //        crossing   lk(g + SIX_DAYS/2)  ==  total          exactly
    //        trapezoid  lk(g) + lk(g+SIX_DAYS)  ==  2 * total  exactly
    //        closed form, SIGNED and UNCONDITIONAL, at 16 phases:
    //          lk(t) - total  ==  SUM(slope_i) * (g + SIX_DAYS/2 - t)
    //
    //      Under V-UPPER `total` is `SUM slope_i * R_i`, the crossing moves to
    //      `off == 0`, the trapezoid is short by `SUM(slope_i) * SIX_DAYS`, and
    //      the signed closed form is wrong at every phase but one.
    // =====================================================================
    function test_S02_L2_aggregate_crossing_and_trapezoid() public {
        _warpToNextGrid();
        uint256 g = block.timestamp;
        uint256 sumSlope = _l2Spawn();
        uint256 total0 = veHemi.totalVeHemiSupply();
        uint256 lk0 = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(total0, 0, "L2 VACUITY: no flat supply was created");
        assertGt(sumSlope, 0, "L2 VACUITY: aggregate slope is zero");

        // --- the crossing, at exactly the half bucket -------------------
        {
            vm.warp(g + HALF_BUCKET);
            vm.roll(block.number + 1);
            uint256 lkH = veHemi.nonTransferableTotalVeHemiSupply();
            assertEq(veHemi.totalVeHemiSupply(), total0, "L2: the flat aggregate moved inside a bucket");
            emit log_named_uint("L2 lk(g+S/2)", lkH);
            emit log_named_uint("L2 total    ", total0);
            assertEq(lkH, total0, "L2: the subcurve does NOT cross the flat level at the half bucket");
        }

        // --- the trapezoid, over the whole bucket -----------------------
        {
            vm.warp(g + SIX_DAYS);
            vm.roll(block.number + 1);
            uint256 lkS = veHemi.nonTransferableTotalVeHemiSupply();
            assertEq(veHemi.totalVeHemiSupply(), total0, "L2: the flat aggregate moved across a bucket");
            emit log_named_uint("L2 lk(g)  ", lk0);
            emit log_named_uint("L2 lk(g+S)", lkS);
            assertEq(lk0 + lkS, 2 * total0, "L2: flat aggregate is not the trapezoid of the live subcurve");
            assertEq(lk0 - lkS, sumSlope * SIX_DAYS, "L2: the subcurve ramp is not one bucket of aggregate slope");
        }

        // --- the SIGNED closed form at 16 phases, no conditional --------
        uint256[4] memory obs; // 0 phases, 1 above, 2 below, 3 equal
        uint256 worstExcess;
        for (uint256 k; k < 16; ++k) {
            vm.warp(g + (k * SIX_DAYS) / 16);
            vm.roll(block.number + 1);
            (uint256 tot, uint256 lk) = _l2Phase(g, sumSlope, k);
            ++obs[0];
            if (lk > tot) { ++obs[1]; if (lk - tot > worstExcess) worstExcess = lk - tot; }
            else if (lk < tot) ++obs[2];
            else ++obs[3];
        }

        emit log_named_uint("L2 OBS phases", obs[0]);
        emit log_named_uint("L2 OBS locked_ > total (clamp would fire)", obs[1]);
        emit log_named_uint("L2 OBS locked_ < total (transferable > 0, nothing transferable)", obs[2]);
        emit log_named_uint("L2 OBS locked_ == total (the crossing)", obs[3]);
        emit log_named_uint("L2 worst excess", worstExcess);
        emit log_named_uint("L2 bound SUM(slope)*SIX_DAYS/2", sumSlope * HALF_BUCKET);
        assertEq(obs[0], 16, "L2 VACUITY: the closed form did not execute at 16 phases");
        assertGt(obs[1], 0, "L2 VACUITY: locked_ > total never observed -- the clamp never fires here");
        assertGt(obs[2], 0, "L2 VACUITY: locked_ < total never observed");
        assertEq(obs[3], 1, "L2 VACUITY: the crossing was not observed exactly once");
        assertEq(worstExcess, sumSlope * HALF_BUCKET, "L2: the half-bucket bound is not ATTAINED at off == 0");
    }

    /// @dev L2's fixture: five flat NON-TRANSFERABLE positions of different
    ///      sizes and different horizons, all enabled on the same grid point.
    ///      Returns SUM(slope_i).
    function _l2Spawn() internal returns (uint256 sumSlope) {
        uint256[5] memory amts = [uint256(300 ether), 1_000 ether, 47 ether, 12_345 ether, 100 ether];
        uint256[5] memory ns = [uint256(2), 3, 5, 8, 13];
        for (uint256 i; i < 5; ++i) {
            uint256 id = _mk(alice, amts[i], ns[i] * SIX_DAYS, false, false);
            _enable(alice, id);
            sumSlope += _slope(amts[i]);
        }
    }

    /// @dev L2's per-phase law, extracted so the loop frame stays shallow.
    ///      Returns `(total, locked_)` at the CURRENT block timestamp.
    function _l2Phase(uint256 g, uint256 sumSlope, uint256 k)
        internal
        returns (uint256 tot, uint256 lk)
    {
        tot = veHemi.totalVeHemiSupply();
        lk = veHemi.nonTransferableTotalVeHemiSupply();
        (, uint256 bLk, , uint256 bTr) = veHemi.supplyBreakdown();
        uint256 mid = g + HALF_BUCKET;
        uint256 t = block.timestamp;
        // The design's signed prediction, from the test's own clock:
        //     lk - total == sumSlope * (g + SIX_DAYS/2 - t)
        // rendered without signed arithmetic by adding the same offset to both
        // sides, so ONE assertion covers both signs and no branch can skip it.
        uint256 lhs = lk + sumSlope * (t < mid ? 0 : t - mid);
        uint256 rhs = tot + sumSlope * (t < mid ? mid - t : 0);
        emit log_named_uint("L2 phase", k);
        emit log_named_uint("   t-g", t - g);
        emit log_named_uint("   lk ", lk);
        emit log_named_uint("   tot", tot);
        // *** THE LAW ***  executes at EVERY phase, both signs.
        assertEq(lhs, rhs, "L2: signed deficit != SUM(slope)*(g + SIX_DAYS/2 - t)");
        assertEq(bLk, lk, "L2: supplyBreakdown.locked_ != nonTransferableTotalVeHemiSupply");
        assertEq(bTr, tot > lk ? tot - lk : 0, "L2: transferable is not the saturating complement");
    }

    // =====================================================================
    // L3 — INTEGRAL EQUIVALENCE AGAINST A LIVE MANUAL RE-LOCKER.
    //
    //      THE PROPERTY V-MEAN *IS*.  A flat position and a holder who extends
    //      by hand through `increaseUnlockTime` at every bucket boundary accrue
    //      IDENTICALLY over any whole number of buckets.  Both integrands are
    //      piecewise linear on a bucket, so the trapezoid from the two boundary
    //      samples is EXACT, and the comparison is made on DOUBLED integrals so
    //      no division enters.
    //
    //      V-UPPER over-credits the flat holder by `slope*SIX_DAYS/2` per
    //      second — a permanent emissions and governance transfer.
    //      V-LOWER under-credits by the same.
    // =====================================================================
    function test_S02_L3_flat_and_manual_relocker_accrue_identically() public {
        uint256 amt = 1_000 ether;
        uint256 n = 4;
        uint256 s = _slope(amt);

        _warpToNextGrid();
        uint256 idA = _mk(alice, amt, n * SIX_DAYS, true, false);
        // The twin is minted ONE BUCKET SHORT so that the very first
        // `increaseUnlockTime` is a genuine increase (the contract's `>` is
        // strict).  From the first extension on, both positions carry exactly
        // N whole buckets at every boundary.
        uint256 idB = _mk(bob, amt, (n - 1) * SIX_DAYS, true, false);
        _enable(alice, idA);

        uint256 buckets;
        uint256 extensions;
        uint256 twoIntA;
        uint256 twoIntB;
        uint256 sawteeth;

        for (uint256 k; k < 6; ++k) {
            (uint256 twoA, uint256 twoB, bool saw) = _l3OneBucket(idA, idB, n, s, k);
            twoIntA += twoA;
            twoIntB += twoB;
            if (saw) ++sawteeth;
            ++extensions;
            ++buckets;
        }

        emit log_named_uint("L3 OBS buckets integrated", buckets);
        emit log_named_uint("L3 OBS manual extensions", extensions);
        emit log_named_uint("L3 OBS twin sawteeth observed", sawteeth);
        emit log_named_uint("L3 2*integral FLAT  ", twoIntA);
        emit log_named_uint("L3 2*integral MANUAL", twoIntB);
        emit log_named_uint(
            "L3 |difference|",
            twoIntA > twoIntB ? twoIntA - twoIntB : twoIntB - twoIntA
        );
        assertEq(buckets, 6, "L3 VACUITY: no bucket was integrated");
        assertEq(sawteeth, 6, "L3 VACUITY: the manual twin never moved -- the comparison is degenerate");
        assertGt(twoIntA, 0, "L3 VACUITY: the flat integral is zero");

        // *** THE LAW ***
        assertEq(twoIntA, twoIntB, "L3: the flat holder does NOT accrue what a manual re-locker accrues");
    }


    /// @dev L3 over ONE bucket: re-lock the manual twin, then integrate both
    ///      positions across the bucket by the (exact) trapezoid rule.
    ///      Returns the DOUBLED integrals and whether the twin actually moved.
    function _l3OneBucket(uint256 idA, uint256 idB, uint256 n, uint256 s, uint256 k)
        internal
        returns (uint256 twoA, uint256 twoB, bool saw)
    {
        uint256 endBefore = uint256(veHemi.getLockedBalance(idB).end);
        vm.prank(bob);
        veHemi.increaseUnlockTime(idB, n * SIX_DAYS);
        assertEq(
            uint256(veHemi.getLockedBalance(idB).end) - endBefore,
            SIX_DAYS,
            "L3: the manual extension did not buy one bucket"
        );

        uint256 aStart = veHemi.balanceOfNFT(idA);
        uint256 bStart = veHemi.balanceOfNFT(idB);

        vm.warp(block.timestamp + SIX_DAYS);
        vm.roll(block.number + 1);

        uint256 bEnd = veHemi.balanceOfNFT(idB);
        assertEq(veHemi.balanceOfNFT(idA), aStart, "L3: the flat position is not flat");
        assertEq(bStart - bEnd, s * SIX_DAYS, "L3: the manual twin did not decay one bucket of slope");

        emit log_named_uint("L3 bucket", k);
        emit log_named_uint("   flat level ", aStart);
        emit log_named_uint("   twin start ", bStart);
        emit log_named_uint("   twin end   ", bEnd);

        // trapezoid, DOUBLED: A is constant on the bucket, B is linear.
        twoA = 2 * aStart * SIX_DAYS;
        twoB = (bStart + bEnd) * SIX_DAYS;
        saw = bStart != bEnd;
    }

    // =====================================================================
    // L4 — THE RELATIVE DEFICIT AND THE `_gp.amount / 3` CEILING.
    //
    //      `supplyBreakdown`'s NatSpec claims the excess is bounded by a third
    //      of the flat aggregate, and attributes the bound to the
    //      `R >= 2 * SIX_DAYS` floor.  The exact statement is
    //
    //          (peak - flat) * (2N - 1)  ==  flat          EXACTLY, and
    //          3 * (peak - flat)  <=  flat,  equality iff N == 2.
    //
    //      V-UPPER  -> peak - flat == 0, so `0 == flat` fails (flat > 0).
    //      V-LOWER  -> peak - flat == slope*SIX_DAYS, the identity fails.
    //      N+1      -> flat > peak, the subtraction underflows.
    // =====================================================================
    function test_S02_L4_relative_deficit_is_one_over_2N_minus_1_and_at_most_a_third() public {
        uint256 obs;
        uint256 obsThirdAttained;
        uint256 amt = 300 ether;

        for (uint256 n = 2; n <= 9; ++n) {
            _warpToNextGrid();
            uint256 idA = _mk(alice, amt, n * SIX_DAYS, true, false);
            uint256 idB = _mk(bob, amt, n * SIX_DAYS, true, false);
            _enable(alice, idA);

            uint256 peak = veHemi.balanceOfNFT(idB);
            uint256 flat = veHemi.balanceOfNFT(idA);
            assertGt(flat, 0, "L4 VACUITY: zero flat level");
            assertGe(peak, flat, "L4: the flat level EXCEEDS the sup of the honest sawtooth");
            uint256 d = peak - flat;
            uint256 bps = (d * 10_000) / flat;

            emit log_named_uint("L4 N", n);
            emit log_named_uint("   peak - flat", d);
            emit log_named_uint("   bps of flat", bps);

            // *** THE LAW ***
            assertEq(d * (2 * n - 1), flat, "L4: relative deficit is not exactly 1/(2N-1)");
            assertLe(3 * d, flat, "L4: the deficit exceeds a THIRD of the flat aggregate");
            if (3 * d == flat) { ++obsThirdAttained; assertEq(n, 2, "L4: the third is attained away from N == 2"); }
            if (n == 2) assertEq(bps, 3_333, "L4: N == 2 relative deficit is not 3,333 bps");
            ++obs;
        }

        emit log_named_uint("L4 OBS horizons", obs);
        emit log_named_uint("L4 OBS third ATTAINED", obsThirdAttained);
        assertEq(obs, 8, "L4 VACUITY: the identity did not execute at 8 horizons");
        assertEq(obsThirdAttained, 1, "L4 VACUITY: the NatSpec's bound was never attained");
    }

    // =====================================================================
    // L5 — THE OPTIMALITY LAW.  The one law here that is not a restatement of
    //      the source line: it asserts that the level the tree SHIPS is the
    //      unique MINIMAX choice over the bucket, by scoring it against four
    //      named rivals on LIVE samples of the honest entitlement.
    //
    //      For each candidate level L, maxErr(L) = max over the swept phases of
    //      |L - slope*(R - off)|.  The midpoint is the unique minimiser, so
    //      maxErr(shipped) < maxErr(rival) for all four.  Were the contract to
    //      ship a rival level instead, `cand[0]` would BE that rival and the
    //      strict `<` would fail on it.
    // =====================================================================
    function test_S02_L5_shipped_level_strictly_minimises_the_worst_case_error() public {
        _warpToNextGrid();
        uint256 g = block.timestamp;
        uint256 idA = _mk(alice, 300 ether, 5 * SIX_DAYS, true, false);
        _enable(alice, idA);
        uint256 s = _slope(300 ether);
        uint256 R = uint256(veHemi.autoRelockRemaining(idA));
        assertEq(R, 5 * SIX_DAYS, "L5 fixture: R is not N whole buckets");

        uint256[5] memory cand;
        cand[0] = veHemi.balanceOfNFT(idA);          // what THIS build ships
        cand[1] = s * R;                             // V-UPPER
        cand[2] = s * (R - SIX_DAYS);                // V-LOWER
        cand[3] = s * (R + HALF_BUCKET);             // one bucket high (N+1)
        cand[4] = s * (R - SIX_DAYS - HALF_BUCKET);  // one bucket low  (N-1)
        uint256[5] memory maxErr;

        uint256 obs = _l5Score(idA, g, R, s, cand, maxErr);

        emit log_named_uint("L5 OBS phases", obs);
        emit log_named_uint("L5 maxErr SHIPPED", maxErr[0]);
        emit log_named_uint("L5 maxErr V-UPPER", maxErr[1]);
        emit log_named_uint("L5 maxErr V-LOWER", maxErr[2]);
        emit log_named_uint("L5 maxErr N+1    ", maxErr[3]);
        emit log_named_uint("L5 maxErr N-1    ", maxErr[4]);
        emit log_named_uint("L5 slope*SIX_DAYS/2", s * HALF_BUCKET);
        assertEq(obs, 13, "L5 VACUITY: no phase was scored");
        assertGt(maxErr[1], 0, "L5 VACUITY: the rivals were never scored against anything");

        // *** THE LAW ***  the shipped level is the STRICT minimiser.
        assertLt(maxErr[0], maxErr[1], "L5: shipped level is no better than V-UPPER on worst-case error");
        assertLt(maxErr[0], maxErr[2], "L5: shipped level is no better than V-LOWER on worst-case error");
        assertLt(maxErr[0], maxErr[3], "L5: shipped level is no better than the N+1 bucket variant");
        assertLt(maxErr[0], maxErr[4], "L5: shipped level is no better than the N-1 bucket variant");
        // and the attained worst case is EXACTLY half a bucket of slope.
        assertEq(maxErr[0], s * HALF_BUCKET, "L5: the shipped worst-case error is not slope * SIX_DAYS/2");
    }

    /// @dev L5's phase sweep, extracted to keep the law's frame shallow.
    ///      Scores every candidate level against the LIVE honest entitlement at
    ///      13 phases spanning one whole bucket, and returns the phase count.
    function _l5Score(
        uint256 idA,
        uint256 g,
        uint256 R,
        uint256 s,
        uint256[5] memory cand,
        uint256[5] memory maxErr
    ) internal returns (uint256 obs) {
        uint256[13] memory offs =
            [uint256(0), 1, SIX_DAYS / 8, SIX_DAYS / 4, HALF_BUCKET - 1, HALF_BUCKET, HALF_BUCKET + 1,
             (5 * SIX_DAYS) / 8, (3 * SIX_DAYS) / 4, (7 * SIX_DAYS) / 8, SIX_DAYS - 2, SIX_DAYS - 1, SIX_DAYS];
        for (uint256 k; k < offs.length; ++k) {
            vm.warp(g + offs[k]);
            vm.roll(block.number + 1);
            // THE HONEST ENTITLEMENT, READ LIVE: the lock-up `disableAutoRelock`
            // would restore right now, priced at this position's own slope.
            uint256 lockup = veHemi.effectiveLockEnd(idA) - block.timestamp;
            assertEq(lockup, R - (offs[k] % SIX_DAYS), "L5: residual lock-up is not R - off");
            assertEq(veHemi.balanceOfNFT(idA), cand[0], "L5: the shipped level is not flat");
            uint256 honest = s * lockup;
            for (uint256 c; c < 5; ++c) {
                uint256 e = _absDiff(cand[c], honest);
                if (e > maxErr[c]) maxErr[c] = e;
            }
            ++obs;
        }
    }

    // =====================================================================
    // L6 — EXACTNESS.  `SIX_DAYS` is EVEN, so `SIX_DAYS/2` is an integer and
    //      the level loses nothing to rounding.  The source says so; this
    //      asserts it.  Also pins the four rival levels out by NAME so the
    //      excluded set is legible at the call site.
    // =====================================================================
    function test_S02_L6_half_bucket_is_exact_and_the_rivals_are_excluded() public {
        assertEq(SIX_DAYS % 2, 0, "L6: SIX_DAYS is ODD -- SIX_DAYS/2 truncates");
        assertEq(HALF_BUCKET * 2, SIX_DAYS, "L6: HALF_BUCKET is not SIX_DAYS/2");

        uint256 obs;
        uint256 amt = 777 ether;
        uint256 s = _slope(amt);
        for (uint256 n = 2; n <= 6; ++n) {
            _warpToNextGrid();
            uint256 id = _mk(alice, amt, n * SIX_DAYS, true, false);
            _enable(alice, id);
            uint256 R = uint256(veHemi.autoRelockRemaining(id));
            uint256 w = veHemi.balanceOfNFT(id);

            // no truncation anywhere in the level
            assertEq(2 * w + s * SIX_DAYS, 2 * s * R, "L6: the level lost something to rounding");
            // the four rivals, excluded by name
            assertTrue(w != s * R, "L6: the level IS V-UPPER");
            assertTrue(w != s * (R - SIX_DAYS), "L6: the level IS V-LOWER");
            assertTrue(w != s * (R + HALF_BUCKET), "L6: the level is one bucket HIGH (N+1)");
            assertTrue(w != s * (R - SIX_DAYS - HALF_BUCKET), "L6: the level is one bucket LOW (N-1)");
            assertEq(w, s * (R - HALF_BUCKET), "L6: the level is none of the five candidates");
            ++obs;
        }
        emit log_named_uint("L6 OBS horizons", obs);
        assertEq(obs, 5, "L6 VACUITY: nothing was excluded");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/**
 * @title  The flat level is the bucket midpoint (V-MEAN).
 *
 * @notice A flat (auto-relocking) position's weight is `slope * (R - SIX_DAYS/2)`,
 *         `R = N * SIX_DAYS`, `N >= 2`, measured from `grid(enable)`. At any
 *         instant the position is still serving `R - off` seconds of lock-up
 *         (`disableAutoRelock` restores `grid(now) + R`), so the instantaneous
 *         entitlement `slope * (R - off)` is a sawtooth from `slope * R` at
 *         `off == 0` down to `slope * (R - SIX_DAYS)`. The implemented level
 *         is its midpoint. The rivals each body excludes:
 *
 *           V-UPPER  slope * R                    (the sup)
 *           V-MEAN   slope * (R - SIX_DAYS/2)     (the midpoint, implemented)
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
contract FlatLevelMidpointTest is LockedCurveTestBase {
    uint256 internal constant HALF_BUCKET = 262_980; // SIX_DAYS / 2

    function setUp() public virtual override {
        super.setUp();
        runSeedingFlow();
    }

    // ------------------------------------------------------------------ util

    function _mk(address who, uint256 amt, uint256 dur, bool transferable_, bool forfeitable_)
        internal
        returns (uint256 id)
    {
        vm.startPrank(who);
        hemi.mint(who, amt);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLockFor(amt, dur, who, transferable_, forfeitable_);
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
    //      identical, UNENABLED control position at the two ends of one
    //      bucket.
    //
    //          2 * flat  ==  peak + trough
    //
    //      V-UPPER  -> 2*peak != peak+trough      (short by slope*SIX_DAYS)
    //      V-LOWER  -> 2*trough != peak+trough    (long  by slope*SIX_DAYS)
    //      N+1 / N-1 off-by-one-bucket -> off the midpoint by slope*SIX_DAYS*2
    // =====================================================================
    function test_L1_flat_level_is_the_live_midpoint_of_the_control_sawtooth() public {
        uint256 obs;
        uint256 obsStrictlyInside;
        uint256 amt = 300 ether;
        uint256 slope = _slope(amt);

        for (uint256 n = 2; n <= 9; ++n) {
            if (_assertMidpointAtOneHorizon(n, amt, slope)) ++obsStrictlyInside;
            ++obs;
        }

        emit log_named_uint("L1 observed: midpoint equalities executed", obs);
        emit log_named_uint("L1 observed: level strictly inside [trough, peak]", obsStrictlyInside);
        assertEq(obs, 8, "L1 VACUITY: the law did not execute at 8 horizons");
        assertEq(obsStrictlyInside, 8, "L1 VACUITY: the level was never strictly inside the sawtooth");
    }


    /// @dev L1 at ONE horizon, extracted so the law's frame stays shallow.
    ///      Returns true iff the implemented level was strictly inside the live
    ///      sawtooth [trough, peak].
    function _assertMidpointAtOneHorizon(uint256 n, uint256 amt, uint256 slope) internal returns (bool) {
        _warpToNextGrid();
        assertEq(block.timestamp % SIX_DAYS, 0, "L1 premise: not on the grid");

        uint256 flatId = _mk(alice, amt, n * SIX_DAYS, true, false);
        uint256 controlId = _mk(bob, amt, n * SIX_DAYS, true, false);
        _enable(alice, flatId);

        uint256 peak = veHemi.balanceOfNFT(controlId);   // LIVE, off == 0
        uint256 flat = veHemi.balanceOfNFT(flatId);

        vm.warp(block.timestamp + SIX_DAYS);
        vm.roll(block.number + 1);

        uint256 trough = veHemi.balanceOfNFT(controlId); // LIVE, one bucket on
        assertEq(veHemi.balanceOfNFT(flatId), flat, "L1: the auto-relock level moved inside a bucket");

        emit log_named_uint("L1 N", n);
        emit log_named_uint("   peak  (control, off=0)", peak);
        emit log_named_uint("   flat  (live, auto-relock)", flat);
        emit log_named_uint("   trough(control, off=SIX_DAYS)", trough);

        // The control position really does saw -- otherwise the midpoint is a
        // tautology.
        assertEq(peak - trough, slope * SIX_DAYS, "L1: the control position's ramp is not one bucket of slope");

        // *** THE LAW ***  UNCONDITIONAL.  No `if`.
        assertEq(2 * flat, peak + trough, "L1: flat level is NOT the midpoint of the live sawtooth");

        // and the named rivals, excluded by name so a reader sees the set.
        assertTrue(flat < peak, "L1: level is V-UPPER (the sup), not the midpoint");
        assertTrue(flat > trough, "L1: level is V-LOWER (the inf), not the midpoint");
        assertEq(peak - flat, slope * HALF_BUCKET, "L1: V-MEAN/V-UPPER gap != slope * SIX_DAYS/2");
        assertEq(flat - trough, slope * HALF_BUCKET, "L1: V-MEAN/V-LOWER gap != slope * SIX_DAYS/2");
        return flat < peak && flat > trough;
    }

    // =====================================================================
    // L2 — THE GLOBAL AGGREGATE.  Same claim, read through the SUPPLY views,
    //      over FIVE flat non-transferable positions of different sizes and
    //      different horizons.
    //
    //      `nonTransferableTotalVeHemiSupply()` is the plain subcurve ramp
    //      `SUM slope_i * (transferableAfter_i - t)` (the subcurve ignores
    //      auto-relock), i.e. the live aggregate of the HONEST entitlement.
    //      Writing lk(t) for that subcurve at t, and g for the bucket start:
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
    function test_L2_aggregate_crossing_and_trapezoid() public {
        _warpToNextGrid();
        uint256 g = block.timestamp;
        uint256 sumSlope = _spawnFlatPositions();
        uint256 total0 = veHemi.totalVeHemiSupply();
        uint256 lockedAtBucketStart = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(total0, 0, "L2 VACUITY: no flat supply was created");
        assertGt(sumSlope, 0, "L2 VACUITY: aggregate slope is zero");

        // --- the crossing, at exactly the half bucket -------------------
        {
            vm.warp(g + HALF_BUCKET);
            vm.roll(block.number + 1);
            uint256 lockedAtHalfBucket = veHemi.nonTransferableTotalVeHemiSupply();
            assertEq(veHemi.totalVeHemiSupply(), total0, "L2: the flat aggregate moved inside a bucket");
            emit log_named_uint("L2 locked subcurve at bucket start + SIX_DAYS/2", lockedAtHalfBucket);
            emit log_named_uint("L2 total supply", total0);
            assertEq(lockedAtHalfBucket, total0, "L2: the subcurve does NOT cross the flat level at the half bucket");
        }

        // --- the trapezoid, over the whole bucket -----------------------
        {
            vm.warp(g + SIX_DAYS);
            vm.roll(block.number + 1);
            uint256 lockedAtBucketEnd = veHemi.nonTransferableTotalVeHemiSupply();
            assertEq(veHemi.totalVeHemiSupply(), total0, "L2: the flat aggregate moved across a bucket");
            emit log_named_uint("L2 locked subcurve at bucket start", lockedAtBucketStart);
            emit log_named_uint("L2 locked subcurve at bucket start + SIX_DAYS", lockedAtBucketEnd);
            assertEq(
                lockedAtBucketStart + lockedAtBucketEnd, 2 * total0, "L2: flat aggregate is not the trapezoid of the live subcurve"
            );
            assertEq(
                lockedAtBucketStart - lockedAtBucketEnd,
                sumSlope * SIX_DAYS,
                "L2: the subcurve ramp is not one bucket of aggregate slope"
            );
        }

        // --- the SIGNED closed form at 16 phases, no conditional --------
        uint256[4] memory obs; // 0 phases, 1 above, 2 below, 3 equal
        uint256 worstExcess;
        for (uint256 k; k < 16; ++k) {
            vm.warp(g + (k * SIX_DAYS) / 16);
            vm.roll(block.number + 1);
            (uint256 totalSupply, uint256 lockedSubcurve) = _assertClosedFormAtPhase(g, sumSlope, k);
            ++obs[0];
            if (lockedSubcurve > totalSupply) {
                ++obs[1];
                if (lockedSubcurve - totalSupply > worstExcess) worstExcess = lockedSubcurve - totalSupply;
            } else if (lockedSubcurve < totalSupply) ++obs[2];
            else ++obs[3];
        }

        emit log_named_uint("L2 observed: phases", obs[0]);
        emit log_named_uint("L2 observed: locked_ > total (transferable saturates at 0)", obs[1]);
        emit log_named_uint("L2 observed: locked_ < total (transferable slice > 0 although no position is transferable)", obs[2]);
        emit log_named_uint("L2 observed: locked_ == total (the crossing)", obs[3]);
        emit log_named_uint("L2 worst excess", worstExcess);
        emit log_named_uint("L2 bound SUM(slope)*SIX_DAYS/2", sumSlope * HALF_BUCKET);
        assertEq(obs[0], 16, "L2 VACUITY: the closed form did not execute at 16 phases");
        assertGt(obs[1], 0, "L2 VACUITY: locked_ > total never observed -- the saturation is never exercised here");
        assertGt(obs[2], 0, "L2 VACUITY: locked_ < total never observed");
        assertEq(obs[3], 1, "L2 VACUITY: the crossing was not observed exactly once");
        assertEq(worstExcess, sumSlope * HALF_BUCKET, "L2: the half-bucket bound is not ATTAINED at off == 0");
    }

    /// @dev L2's fixture: five flat NON-TRANSFERABLE positions of different
    ///      sizes and different horizons, all enabled on the same grid point.
    ///      Returns SUM(slope_i).
    function _spawnFlatPositions() internal returns (uint256 sumSlope) {
        uint256[5] memory amts = [uint256(300 ether), 1_000 ether, 47 ether, 12_345 ether, 100 ether];
        uint256[5] memory ns = [uint256(2), 3, 5, 8, 13];
        for (uint256 i; i < 5; ++i) {
            uint256 id = _mk(alice, amts[i], ns[i] * SIX_DAYS, false, false);
            _enable(alice, id);
            sumSlope += _slope(amts[i]);
        }
    }

    /// @dev L2's per-phase law, extracted so the loop frame stays shallow.
    ///      Returns `(totalSupply, lockedSubcurve)` at the CURRENT block timestamp.
    function _assertClosedFormAtPhase(uint256 g, uint256 sumSlope, uint256 k)
        internal
        returns (uint256 totalSupply, uint256 lockedSubcurve)
    {
        totalSupply = veHemi.totalVeHemiSupply();
        lockedSubcurve = veHemi.nonTransferableTotalVeHemiSupply();
        (, uint256 locked_, , uint256 transferable) = veHemi.supplyBreakdown();
        uint256 mid = g + HALF_BUCKET;
        uint256 t = block.timestamp;
        // The design's signed prediction, from the test's own clock:
        //     lockedSubcurve - totalSupply == sumSlope * (g + SIX_DAYS/2 - t)
        // rendered without signed arithmetic by adding the same offset to both
        // sides, so ONE assertion covers both signs and no branch can skip it.
        uint256 lhs = lockedSubcurve + sumSlope * (t < mid ? 0 : t - mid);
        uint256 rhs = totalSupply + sumSlope * (t < mid ? mid - t : 0);
        emit log_named_uint("L2 phase", k);
        emit log_named_uint("   seconds into the bucket", t - g);
        emit log_named_uint("   locked subcurve", lockedSubcurve);
        emit log_named_uint("   total supply", totalSupply);
        // *** THE LAW ***  executes at EVERY phase, both signs.
        assertEq(lhs, rhs, "L2: signed deficit != SUM(slope)*(bucket start + SIX_DAYS/2 - now)");
        assertEq(locked_, lockedSubcurve, "L2: supplyBreakdown.locked_ != nonTransferableTotalVeHemiSupply");
        assertEq(
            transferable,
            totalSupply > lockedSubcurve ? totalSupply - lockedSubcurve : 0,
            "L2: transferable is not the saturating complement"
        );
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
    function test_L3_flat_and_manual_relocker_accrue_identically() public {
        uint256 amt = 1_000 ether;
        uint256 n = 4;
        uint256 slope = _slope(amt);

        _warpToNextGrid();
        uint256 flatId = _mk(alice, amt, n * SIX_DAYS, true, false);
        // The twin is minted ONE BUCKET SHORT so that the very first
        // `increaseUnlockTime` is a genuine increase (the contract's `>` is
        // strict).  From the first extension on, both positions carry exactly
        // N whole buckets at every boundary.
        uint256 twinId = _mk(bob, amt, (n - 1) * SIX_DAYS, true, false);
        _enable(alice, flatId);

        uint256 buckets;
        uint256 extensions;
        uint256 doubledFlatIntegral;
        uint256 doubledTwinIntegral;
        uint256 sawteeth;

        for (uint256 k; k < 6; ++k) {
            (uint256 doubledFlatBucketIntegral, uint256 doubledTwinBucketIntegral, bool saw) =
                _integrateOneBucket(flatId, twinId, n, slope, k);
            doubledFlatIntegral += doubledFlatBucketIntegral;
            doubledTwinIntegral += doubledTwinBucketIntegral;
            if (saw) ++sawteeth;
            ++extensions;
            ++buckets;
        }

        emit log_named_uint("L3 observed: buckets integrated", buckets);
        emit log_named_uint("L3 observed: manual extensions", extensions);
        emit log_named_uint("L3 observed: twin sawteeth", sawteeth);
        emit log_named_uint("L3 2*integral FLAT  ", doubledFlatIntegral);
        emit log_named_uint("L3 2*integral MANUAL", doubledTwinIntegral);
        emit log_named_uint(
            "L3 |difference|",
            doubledFlatIntegral > doubledTwinIntegral
                ? doubledFlatIntegral - doubledTwinIntegral
                : doubledTwinIntegral - doubledFlatIntegral
        );
        assertEq(buckets, 6, "L3 VACUITY: no bucket was integrated");
        assertEq(sawteeth, 6, "L3 VACUITY: the manual twin never moved -- the comparison is degenerate");
        assertGt(doubledFlatIntegral, 0, "L3 VACUITY: the flat integral is zero");

        // *** THE LAW ***
        assertEq(
            doubledFlatIntegral,
            doubledTwinIntegral,
            "L3: the flat holder does NOT accrue what a manual re-locker accrues"
        );
    }


    /// @dev L3 over ONE bucket: re-lock the manual twin, then integrate both
    ///      positions across the bucket by the (exact) trapezoid rule.
    ///      Returns the DOUBLED integrals and whether the twin actually moved.
    function _integrateOneBucket(uint256 flatId, uint256 twinId, uint256 n, uint256 slope, uint256 k)
        internal
        returns (uint256 doubledFlatBucketIntegral, uint256 doubledTwinBucketIntegral, bool saw)
    {
        uint256 endBefore = uint256(veHemi.getLockedBalance(twinId).end);
        vm.prank(bob);
        veHemi.increaseUnlockTime(twinId, n * SIX_DAYS);
        assertEq(
            uint256(veHemi.getLockedBalance(twinId).end) - endBefore,
            SIX_DAYS,
            "L3: the manual extension did not buy one bucket"
        );

        uint256 flatLevel = veHemi.balanceOfNFT(flatId);
        uint256 twinStart = veHemi.balanceOfNFT(twinId);

        vm.warp(block.timestamp + SIX_DAYS);
        vm.roll(block.number + 1);

        uint256 twinEnd = veHemi.balanceOfNFT(twinId);
        assertEq(veHemi.balanceOfNFT(flatId), flatLevel, "L3: the flat position is not flat");
        assertEq(twinStart - twinEnd, slope * SIX_DAYS, "L3: the manual twin did not decay one bucket of slope");

        emit log_named_uint("L3 bucket", k);
        emit log_named_uint("   flat level ", flatLevel);
        emit log_named_uint("   twin start ", twinStart);
        emit log_named_uint("   twin end   ", twinEnd);

        // trapezoid, DOUBLED: the flat position is constant on the bucket, the
        // twin is linear.
        doubledFlatBucketIntegral = 2 * flatLevel * SIX_DAYS;
        doubledTwinBucketIntegral = (twinStart + twinEnd) * SIX_DAYS;
        saw = twinStart != twinEnd;
    }

    // =====================================================================
    // L4 — THE RELATIVE DEFICIT AND THE GLOBAL `Point.amount / 3` CEILING.
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
    function test_L4_relative_deficit_is_one_over_2N_minus_1_and_at_most_a_third() public {
        uint256 obs;
        uint256 obsThirdAttained;
        uint256 amt = 300 ether;

        for (uint256 n = 2; n <= 9; ++n) {
            _warpToNextGrid();
            uint256 flatId = _mk(alice, amt, n * SIX_DAYS, true, false);
            uint256 controlId = _mk(bob, amt, n * SIX_DAYS, true, false);
            _enable(alice, flatId);

            uint256 peak = veHemi.balanceOfNFT(controlId);
            uint256 flat = veHemi.balanceOfNFT(flatId);
            assertGt(flat, 0, "L4 VACUITY: zero flat level");
            assertGe(peak, flat, "L4: the flat level EXCEEDS the sup of the honest sawtooth");
            uint256 deficit = peak - flat;
            uint256 bps = (deficit * 10_000) / flat;

            emit log_named_uint("L4 N", n);
            emit log_named_uint("   peak - flat", deficit);
            emit log_named_uint("   bps of flat", bps);

            // *** THE LAW ***
            assertEq(deficit * (2 * n - 1), flat, "L4: relative deficit is not exactly 1/(2N-1)");
            assertLe(3 * deficit, flat, "L4: the deficit exceeds a THIRD of the flat aggregate");
            if (3 * deficit == flat) {
                ++obsThirdAttained;
                assertEq(n, 2, "L4: the third is attained away from N == 2");
            }
            if (n == 2) assertEq(bps, 3_333, "L4: N == 2 relative deficit is not 3,333 bps");
            ++obs;
        }

        emit log_named_uint("L4 observed: horizons", obs);
        emit log_named_uint("L4 observed: third ATTAINED", obsThirdAttained);
        assertEq(obs, 8, "L4 VACUITY: the identity did not execute at 8 horizons");
        assertEq(obsThirdAttained, 1, "L4 VACUITY: the NatSpec's bound was never attained");
    }

    // =====================================================================
    // L5 — THE OPTIMALITY LAW.  The one law here that is not a restatement of
    //      the source line: it asserts that the level the contract IMPLEMENTS
    //      is the unique MINIMAX choice over the bucket, by scoring it against
    //      four named rivals on LIVE samples of the honest entitlement.
    //
    //      For each candidate level L, maxErr(L) = max over the swept phases of
    //      |L - slope*(R - off)|.  The midpoint is the unique minimiser, so
    //      maxErr(implemented) < maxErr(rival) for all four.  Were the contract
    //      to implement a rival level instead, `candidateLevels[0]` would BE
    //      that rival and the strict `<` would fail on it.
    // =====================================================================
    function test_L5_implemented_level_strictly_minimises_the_worst_case_error() public {
        _warpToNextGrid();
        uint256 g = block.timestamp;
        uint256 flatId = _mk(alice, 300 ether, 5 * SIX_DAYS, true, false);
        _enable(alice, flatId);
        uint256 slope = _slope(300 ether);
        uint256 R = uint256(veHemi.autoRelockRemaining(flatId));
        assertEq(R, 5 * SIX_DAYS, "L5 premise: R is not N whole buckets");

        uint256[5] memory candidateLevels;
        candidateLevels[0] = veHemi.balanceOfNFT(flatId);           // what THIS build implements
        candidateLevels[1] = slope * R;                             // V-UPPER
        candidateLevels[2] = slope * (R - SIX_DAYS);                // V-LOWER
        candidateLevels[3] = slope * (R + HALF_BUCKET);             // one bucket high (N+1)
        candidateLevels[4] = slope * (R - SIX_DAYS - HALF_BUCKET);  // one bucket low  (N-1)
        uint256[5] memory maxErr;

        uint256 obs = _scoreCandidateLevels(flatId, g, R, slope, candidateLevels, maxErr);

        emit log_named_uint("L5 observed: phases", obs);
        emit log_named_uint("L5 maxErr IMPLEMENTED", maxErr[0]);
        emit log_named_uint("L5 maxErr V-UPPER", maxErr[1]);
        emit log_named_uint("L5 maxErr V-LOWER", maxErr[2]);
        emit log_named_uint("L5 maxErr N+1    ", maxErr[3]);
        emit log_named_uint("L5 maxErr N-1    ", maxErr[4]);
        emit log_named_uint("L5 slope*SIX_DAYS/2", slope * HALF_BUCKET);
        assertEq(obs, 13, "L5 VACUITY: no phase was scored");
        assertGt(maxErr[1], 0, "L5 VACUITY: the rivals were never scored against anything");

        // *** THE LAW ***  the implemented level is the STRICT minimiser.
        assertLt(maxErr[0], maxErr[1], "L5: implemented level is no better than V-UPPER on worst-case error");
        assertLt(maxErr[0], maxErr[2], "L5: implemented level is no better than V-LOWER on worst-case error");
        assertLt(maxErr[0], maxErr[3], "L5: implemented level is no better than the N+1 bucket variant");
        assertLt(maxErr[0], maxErr[4], "L5: implemented level is no better than the N-1 bucket variant");
        // and the attained worst case is EXACTLY half a bucket of slope.
        assertEq(maxErr[0], slope * HALF_BUCKET, "L5: the implemented worst-case error is not slope * SIX_DAYS/2");
    }

    /// @dev L5's phase sweep, extracted to keep the law's frame shallow.
    ///      Scores every candidate level against the LIVE honest entitlement at
    ///      13 phases spanning one whole bucket, and returns the phase count.
    function _scoreCandidateLevels(
        uint256 flatId,
        uint256 g,
        uint256 R,
        uint256 slope,
        uint256[5] memory candidateLevels,
        uint256[5] memory maxErr
    ) internal returns (uint256 obs) {
        uint256[13] memory offsets =
            [uint256(0), 1, SIX_DAYS / 8, SIX_DAYS / 4, HALF_BUCKET - 1, HALF_BUCKET, HALF_BUCKET + 1,
             (5 * SIX_DAYS) / 8, (3 * SIX_DAYS) / 4, (7 * SIX_DAYS) / 8, SIX_DAYS - 2, SIX_DAYS - 1, SIX_DAYS];
        for (uint256 k; k < offsets.length; ++k) {
            vm.warp(g + offsets[k]);
            vm.roll(block.number + 1);
            // THE HONEST ENTITLEMENT, READ LIVE: the lock-up `disableAutoRelock`
            // would restore right now, priced at this position's own slope.
            uint256 lockup = veHemi.effectiveLockEnd(flatId) - block.timestamp;
            assertEq(lockup, R - (offsets[k] % SIX_DAYS), "L5: residual lock-up is not R - off");
            assertEq(veHemi.balanceOfNFT(flatId), candidateLevels[0], "L5: the implemented level is not flat");
            uint256 honest = slope * lockup;
            for (uint256 c; c < 5; ++c) {
                uint256 absError = _absDiff(candidateLevels[c], honest);
                if (absError > maxErr[c]) maxErr[c] = absError;
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
    function test_L6_half_bucket_is_exact_and_the_rivals_are_excluded() public {
        assertEq(SIX_DAYS % 2, 0, "L6: SIX_DAYS is ODD -- SIX_DAYS/2 truncates");
        assertEq(HALF_BUCKET * 2, SIX_DAYS, "L6: HALF_BUCKET is not SIX_DAYS/2");

        uint256 obs;
        uint256 amt = 777 ether;
        uint256 slope = _slope(amt);
        for (uint256 n = 2; n <= 6; ++n) {
            _warpToNextGrid();
            uint256 id = _mk(alice, amt, n * SIX_DAYS, true, false);
            _enable(alice, id);
            uint256 R = uint256(veHemi.autoRelockRemaining(id));
            uint256 flatWeight = veHemi.balanceOfNFT(id);

            // no truncation anywhere in the level
            assertEq(2 * flatWeight + slope * SIX_DAYS, 2 * slope * R, "L6: the level lost something to rounding");
            // the four rivals, excluded by name
            assertTrue(flatWeight != slope * R, "L6: the level IS V-UPPER");
            assertTrue(flatWeight != slope * (R - SIX_DAYS), "L6: the level IS V-LOWER");
            assertTrue(flatWeight != slope * (R + HALF_BUCKET), "L6: the level is one bucket HIGH (N+1)");
            assertTrue(flatWeight != slope * (R - SIX_DAYS - HALF_BUCKET), "L6: the level is one bucket LOW (N-1)");
            assertEq(flatWeight, slope * (R - HALF_BUCKET), "L6: the level is none of the five candidates");
            ++obs;
        }
        emit log_named_uint("L6 observed: horizons", obs);
        assertEq(obs, 5, "L6 VACUITY: nothing was excluded");
    }
}

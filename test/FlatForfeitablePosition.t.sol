// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// The flat (armed) forfeitable position.
// ----------------------------------------------------------------------------
// Auto-relock is invisible to the subcurves: a flat forfeitable position decays
// out of the locked and forfeitable subcurves on its manual ramp to
// `transferableAfter`, exactly like its manually-extended twin (I1, I6).
// `supplyBreakdown()` agrees with the dedicated views (I2, I3), forfeit still
// works on a flat position and retires its delegated weight (I4), and the
// forfeit window is `transferableAfter` whatever the flag says (I5, I5b).
// ============================================================================

import "./TwinOracle.sol";

contract FlatForfeitablePositionTest is TwinOracle {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB   = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant ADMIN = address(0xAD1);

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;
    uint256 internal constant NLONG = 40;

    function setUp() public {
        setUpTwinOracle();
        X.ve.updateForfeitAdmin(ADMIN);
        M.ve.updateForfeitAdmin(ADMIN);
    }

    function _driveCandidate(uint256) internal override {}

    function _mintForfeitable(Stack memory s, address owner, uint256 amount, uint256 n)
        internal returns (uint256 id)
    {
        s.hemi.mint(owner, amount);
        vm.startPrank(owner);
        s.hemi.approve(address(s.ve), type(uint256).max);
        id = s.ve.createLockFor(amount, n * SIX_DAYS, owner, false, true);
        vm.stopPrank();
    }

    function _mintLockedOnly(Stack memory s, address owner, uint256 amount, uint256 n)
        internal returns (uint256 id)
    {
        s.hemi.mint(owner, amount);
        vm.startPrank(owner);
        s.hemi.approve(address(s.ve), type(uint256).max);
        id = s.ve.createLockFor(amount, n * SIX_DAYS, owner, false, false);
        vm.stopPrank();
    }

    // ====================================================================== I1
    /// @notice A FLAT FORFEITABLE POSITION IS EXACT IN BOTH SUBCURVES.
    /// @dev By design, auto-relock is INVISIBLE to the
    ///      subcurves: a flat position decays out of them at
    ///      `min(lock.end, transferableAfter)` exactly as its manual twin does.
    ///      Both subcurves must therefore read
    ///      `slope * (transferableAfter - now)` to the wei, and -- because a
    ///      forfeitable position is a STRICT SUBSET of the locked subcurve --
    ///      they must read the SAME number when the forfeitable position is the
    ///      only non-transferable one.
    ///      Sampled 12 times, a third of a bucket (+7 s) apart, so the phase
    ///      walks through the bucket while the position ages about four buckets.
    function test_I1_flat_forfeitable_exact_in_both_subcurves() public {
        uint256 id = _mintForfeitable(X, ALICE, AMT, N);
        uint256 transferableAfter = X.ve.transferableAfter(id);
        uint256 slope = slopeOf(AMT);
        vm.warp(((block.timestamp / SIX_DAYS) + 1) * SIX_DAYS + 4321);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(id);

        for (uint256 k; k < 12; ++k) {
            vm.warp(block.timestamp + (SIX_DAYS / 3) + 7);
            if (block.timestamp >= transferableAfter) break;
            uint256 want = slope * (transferableAfter - block.timestamp);
            assertEq(X.ve.nonTransferableTotalVeHemiSupply(), want, "I1 locked subcurve not exact while flat");
            assertEq(X.ve.forfeitableTotalVeHemiSupply(), want, "I1 forfeitable subcurve not exact while flat");
            assertTrue(X.ve.isAutoRelockEnabled(id), "I1 position stopped being flat");

            // ALL FOUR supplyBreakdown SLICES. This position is the ONLY one
            // in the universe, so `total` is its own flat weight, both subcurve
            // slices are `want`, and `transferable` is the saturating
            // complement (zero for `off < SIX_DAYS/2` at the bucket-mean flat
            // level).
            (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = X.ve.supplyBreakdown();
            assertEq(total, X.ve.balanceOfNFT(id), "I1 slice 1: total != the position's own flat weight");
            assertEq(locked_, want, "I1 slice 2: breakdown.locked_ not exact");
            assertEq(forfeitable_, want, "I1 slice 3: breakdown.forfeitable_ not exact");
            assertEq(transferable, total > locked_ ? total - locked_ : 0,
                "I1 slice 4: transferable is not the saturating complement");
        }
    }

    // ====================================================================== I2
    /// @notice ALL FOUR supplyBreakdown SLICES AGREE WITH THE DEDICATED VIEWS.
    /// @dev At the bucket-mean level `locked_ > total` occurs routinely (the
    ///      flat member's half-bucket gap). A clamp on `locked_` or
    ///      `forfeitable_` inside `supplyBreakdown` would then make it disagree
    ///      with the dedicated views; this body builds exactly that population.
    function test_I2_breakdown_agrees_with_dedicated_views() public {
        // NLONG: the phase walk consumes one whole bucket per iteration, and
        // `enableAutoRelock` refuses `autoRelockRemaining < 2 * SIX_DAYS`, so
        // the fixture must outlive 12 buckets.
        // 4x so the flat member's half-bucket gap at the bucket-mean level
        // (slope*SIX_DAYS/2) EXCEEDS the transferable member's whole weight;
        // otherwise `total` stays above `locked_`.
        uint256 forfeitableId = _mintForfeitable(X, ALICE, 4 * AMT, NLONG);
        _mintLockedOnly(X, BOB, AMT / 2, NLONG + 3);
        X.hemi.mint(CAROL, AMT);
        vm.startPrank(CAROL);
        X.hemi.approve(address(X.ve), type(uint256).max);
        // A DELIBERATELY SMALL transferable member: it adds to `total` but not to
        // `locked_`, so a large one would keep `total` above `locked_`.
        X.ve.createLock(AMT / 50, (NLONG + 1) * SIX_DAYS);
        vm.stopPrank();

        uint256 lockedAboveTotal;
        for (uint256 k; k < 12; ++k) {
            uint256 target = ((block.timestamp / SIX_DAYS) + 1) * SIX_DAYS + (k * SIX_DAYS) / 12;
            vm.warp(target);
            vm.prank(ALICE);
            X.ve.enableAutoRelock(forfeitableId);

            (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = X.ve.supplyBreakdown();
            assertEq(total, X.ve.totalVeHemiSupply(), "I2 breakdown.total != totalVeHemiSupply()");
            assertEq(locked_, X.ve.nonTransferableTotalVeHemiSupply(), "I2 breakdown.locked_ CLAMPED");
            assertEq(forfeitable_, X.ve.forfeitableTotalVeHemiSupply(), "I2 breakdown.forfeitable_ CLAMPED");
            assertLe(forfeitable_, locked_, "I2 forfeitable_ > locked_");
            assertEq(transferable, total > locked_ ? total - locked_ : 0,
                "I2 transferable is not the saturating complement");
            if (locked_ > total) ++lockedAboveTotal;

            vm.prank(ALICE);
            X.ve.disableAutoRelock(forfeitableId);
        }
        assertGt(lockedAboveTotal, 0, "I2 NON-VACUOUS: `locked_ > total` never occurred, so a clamp would go unseen");
    }

    // ====================================================================== I3
    /// @notice `forfeitable <= locked` IS STRUCTURAL, NOT CLAMPED.
    /// @dev Built from a MIXED population (a flat and a decaying forfeitable
    ///      member, a flat locked-only member) and driven through the forfeit of
    ///      each forfeitable member and the disable of the locked-only one,
    ///      sampled 24 times a quarter-bucket apart. No member reaches its
    ///      `transferableAfter` inside the walk. The locked subcurve's per-event delta
    ///      and the forfeitable subcurve's per-event delta are the SAME
    ///      quantities (VeHemiCurveLib Phase C shares `_newSubcurveBias` /
    ///      `_oldSubcurveBias` and the forfeitable block is NESTED inside the
    ///      locked block), so the ordering cannot be broken by any interleaving,
    ///      and `supplyBreakdown` reports the dedicated values unclamped.
    function test_I3_forfeitable_at_most_locked_is_structural() public {
        uint256 aliceForfeitableId = _mintForfeitable(X, ALICE, AMT, N);
        uint256 bobForfeitableId = _mintForfeitable(X, BOB, AMT / 3, N + 2);
        uint256 carolLockedOnlyId = _mintLockedOnly(X, CAROL, AMT / 2, N + 4);

        vm.warp(block.timestamp + 1111);
        vm.prank(ALICE); X.ve.enableAutoRelock(aliceForfeitableId);
        vm.prank(CAROL); X.ve.enableAutoRelock(carolLockedOnlyId);

        for (uint256 k; k < 24; ++k) {
            vm.warp(block.timestamp + (SIX_DAYS / 4) + 13);
            uint256 dedicatedLocked = X.ve.nonTransferableTotalVeHemiSupply();
            uint256 dedicatedForfeitable = X.ve.forfeitableTotalVeHemiSupply();
            (, uint256 locked_, uint256 forfeitable_, ) = X.ve.supplyBreakdown();
            assertLe(dedicatedForfeitable, dedicatedLocked, "I3 forfeitable > locked (dedicated views)");
            assertEq(locked_, dedicatedLocked, "I3 breakdown.locked_ diverged");
            assertEq(forfeitable_, dedicatedForfeitable, "I3 breakdown.forfeitable_ diverged");
            if (k == 6) {   // 2 -> 1 while FLAT
                vm.prank(ADMIN);
                X.ve.forfeit(aliceForfeitableId);
                assertEq(X.hemi.balanceOf(ADMIN), AMT,
                    "I3 the forfeit of alice's forfeitable position did not pay out");
            }
            if (k == 9) {   // a decaying forfeitable leaves too
                vm.prank(ADMIN);
                X.ve.forfeit(bobForfeitableId);
                assertEq(X.hemi.balanceOf(ADMIN), AMT + AMT / 3,
                    "I3 the forfeit of bob's forfeitable position did not pay out");
            }
            if (k == 12) {  // disable the surviving flat member
                vm.prank(CAROL);
                X.ve.disableAutoRelock(carolLockedOnlyId);
                assertFalse(X.ve.isAutoRelockEnabled(carolLockedOnlyId),
                    "I3 carol's locked-only position is still flat after the disable");
            }
        }
    }

    // ====================================================================== I4
    /// @notice FORFEIT STILL WORKS ON A FLAT POSITION, AND RETIRES ITS
    ///         DELEGATED WEIGHT.
    /// @dev A flat position's weight rides in `DelegateCheckpoint.fixedBias`,
    ///      which books NO expiration bucket, so nothing but the forfeit's own
    ///      `_delegate(id, 0)` can ever retire it. The retirement is dated
    ///      `block.timestamp + 1`, so the delegatee's votes are zero at the
    ///      NEXT SECOND, not at the next hour.
    function test_I4_forfeit_while_flat_retires_the_flat_delegation() public {
        uint256 id = _mintForfeitable(X, ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + 3600 + 17);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(id);
        vm.warp(block.timestamp + 3600);

        uint256 votesBefore = X.del.getVotes(CAROL);
        assertGt(votesBefore, 0, "I4 flat position delegated no weight");
        assertEq(X.ve.forfeitableTotalVeHemiSupply(), slopeOf(AMT) * (X.ve.transferableAfter(id) - block.timestamp),
            "I4 forfeitable subcurve wrong before forfeit");

        vm.prank(ADMIN);
        X.ve.forfeit(id);

        assertEq(X.ve.totalVeHemiSupply(), 0, "I4 global flat aggregate survived the forfeit");
        assertEq(X.ve.nonTransferableTotalVeHemiSupply(), 0, "I4 locked subcurve survived the forfeit");
        assertEq(X.ve.forfeitableTotalVeHemiSupply(), 0, "I4 forfeitable subcurve survived the forfeit");
        assertEq(X.hemi.balanceOf(ADMIN), AMT, "I4 principal did not reach the forfeit admin");

        vm.warp(block.timestamp + 1);
        assertEq(X.del.getVotes(CAROL), 0, "I4 PHANTOM: delegatee kept the flat weight after forfeit");
    }

    // ====================================================================== I5
    /// @notice THE FORFEIT WINDOW IS `transferableAfter`, AND FLATNESS DOES NOT
    ///         MOVE IT.
    /// @dev Three legs:
    ///        (a) inside the window, on a flat position, forfeit is ACCEPTED --
    ///            `forfeit`'s OTHER time guard reads the stored `lock.end`, and
    ///            it is unreachable inside the window because
    ///            `transferableAfter <= lock.end` holds for life;
    ///        (b) AT `transferableAfter` and after, forfeit is REFUSED with
    ///            `ForfeitWindowExpired`, even though the position is still
    ///            flat, still alive and still carrying its full global weight;
    ///        (c) `transferableAfter <= lock.end` survives an enable/disable
    ///            cycle, which is the only operation that can move `lock.end`
    ///            BACKWARDS.
    function test_I5_forfeit_window_is_transferableAfter_while_flat() public {
        uint256 id = _mintForfeitable(X, ALICE, AMT, N);
        uint256 transferableAfter = X.ve.transferableAfter(id);
        vm.warp(block.timestamp + 999);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(id);

        // (c) the anti-ratchet cycle cannot push `lock.end` below `transferableAfter`
        assertGe(uint256(X.ve.getLockedBalance(id).end), transferableAfter, "I5 lock.end fell below transferableAfter at enable");
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        vm.prank(ALICE); X.ve.disableAutoRelock(id);
        assertGe(uint256(X.ve.getLockedBalance(id).end), transferableAfter, "I5 lock.end fell below transferableAfter at disable");
        vm.prank(ALICE); X.ve.enableAutoRelock(id);
        assertGe(uint256(X.ve.getLockedBalance(id).end), transferableAfter, "I5 lock.end fell below transferableAfter at re-enable");

        // (b) AT transferableAfter -- refused, while still flat and still weighty
        vm.warp(transferableAfter);
        assertTrue(X.ve.isAutoRelockEnabled(id), "I5 position stopped being flat at transferableAfter");
        assertGt(X.ve.totalVeHemiSupply(), 0, "I5 flat weight vanished at transferableAfter");
        assertEq(X.ve.nonTransferableTotalVeHemiSupply(), 0, "I5 still in the locked subcurve at transferableAfter");
        vm.prank(ADMIN);
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        X.ve.forfeit(id);

        // FAR past `transferableAfter`, the stored `lock.end` has itself fallen
        // into the past (a flat position's stored end does not move, by
        // design), and `forfeit`'s FIRST guard -- `locked[id].end < now` --
        // speaks before the window guard, so the revert is `LockExpired`, not
        // `ForfeitWindowExpired`.
        // Both are refusals; this pins the diagnostic so a reordering of the
        // two guards is visible.
        vm.warp(transferableAfter + 5 * SIX_DAYS);
        assertTrue(X.ve.isAutoRelockEnabled(id), "I5 stopped being flat far past transferableAfter");
        assertLt(uint256(X.ve.getLockedBalance(id).end), block.timestamp, "I5 stored end is not in the past");
        vm.prank(ADMIN);
        vm.expectRevert(VeHemi.LockExpired.selector);
        X.ve.forfeit(id);
    }

    /// @dev (a), on its own fixture so the revert legs above cannot mask it.
    function test_I5b_forfeit_accepted_at_the_last_second_of_the_window() public {
        uint256 id = _mintForfeitable(X, ALICE, AMT, N);
        uint256 transferableAfter = X.ve.transferableAfter(id);
        vm.warp(block.timestamp + 999);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(id);
        vm.warp(transferableAfter - 1);
        assertTrue(X.ve.isAutoRelockEnabled(id), "I5b not flat at transferableAfter - 1");
        assertGe(uint256(X.ve.getLockedBalance(id).end), transferableAfter, "I5b stored end below transferableAfter");
        vm.prank(ADMIN);
        X.ve.forfeit(id);                       // MUST NOT revert LockExpired
        assertEq(X.hemi.balanceOf(ADMIN), AMT, "I5b forfeit did not pay out");
    }

    // ====================================================================== I6
    /// @notice THE TWIN IS THE ORACLE: a FLAT forfeitable position's SUBCURVE
    ///         contribution equals its MANUALLY-EXTENDED twin's, to the wei.
    /// @dev `transferableAfter` is written once at mint and is NOT moved by
    ///      `increaseUnlockTime`, so the manual run's subcurve is also a plain
    ///      ramp to `transferableAfter` -- and the flat run must match it even
    ///      though the two GLOBAL weights differ.
    function test_I6_flat_subcurve_equals_the_manual_twin() public {
        uint256 manualId = _mintForfeitable(M, ALICE, AMT, N);  // MANUAL run
        uint256 flatId = _mintForfeitable(X, ALICE, AMT, N);    // FLAT run
        assertEq(M.ve.transferableAfter(manualId), X.ve.transferableAfter(flatId),
            "I6 the manual and flat runs disagree on transferableAfter");

        vm.warp(block.timestamp + 777);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(flatId);

        for (uint256 b; b < 8; ++b) {
            vm.warp(((block.timestamp / SIX_DAYS) + 1) * SIX_DAYS);
            // On the grid, `now + N * SIX_DAYS` is one bucket past the previous
            // end, so every extension is a strict increase and must succeed.
            vm.prank(ALICE);
            M.ve.increaseUnlockTime(manualId, N * SIX_DAYS);
            assertEq(uint256(M.ve.getLockedBalance(manualId).end), block.timestamp + N * SIX_DAYS,
                "I6 the manual twin was not extended");
            vm.warp(block.timestamp + 4242);
            assertEq(
                X.ve.nonTransferableTotalVeHemiSupply(),
                M.ve.nonTransferableTotalVeHemiSupply(),
                "I6 flat locked subcurve diverged from the manual twin"
            );
            assertEq(
                X.ve.forfeitableTotalVeHemiSupply(),
                M.ve.forfeitableTotalVeHemiSupply(),
                "I6 flat forfeitable subcurve diverged from the manual twin"
            );
        }
    }
}

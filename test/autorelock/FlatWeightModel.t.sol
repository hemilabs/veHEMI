// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice The flat (auto-relock) weight model: no droop, no sentinel end, the
///         restored slope is retired at the restored end, a decaying position
///         never reads as flat, the flat aggregate lives in the global
///         `Point.amount`, flat votes survive a past stored end and the
///         delegation module's MAX_LOCK_DURATION wipe, enable/disable are
///         owner-only, and a 1-wei top-up keeps R (`autoRelockRemaining`, the
///         frozen remaining term). Bodies that arm a position run the seeding
///         flow first, as on a live deployment.
contract FlatWeightModelTest is LockedCurveTestBase {
    // ---------------------------------------------------------------------
    // TRULY FLAT, NO DROOP. The whole point of the feature.
    // ---------------------------------------------------------------------
    function test_flatIsFlat_noDroop_position() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 w0 = veHemi.balanceOfNFT(id);
        assertGt(w0, 0, "flat weight must be non-zero");

        // 241 SIX_DAYS buckets -> ~4 years, well past the original lock.end.
        for (uint256 i = 0; i < 241; ++i) {
            vm.warp(block.timestamp + SIX_DAYS);
            assertEq(veHemi.balanceOfNFT(id), w0, "position weight drooped");
        }
        // lock.end is now firmly in the PAST and the position is still alive.
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "stored end should be past");
        assertEq(veHemi.balanceOfNFT(id), w0, "flat weight lost");
    }

    function test_flatIsFlat_noDroop_globalSupply() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 supplyAtEnable = veHemi.totalVeHemiSupply();
        assertGt(supplyAtEnable, 0);
        for (uint256 i = 0; i < 241; ++i) {
            vm.warp(block.timestamp + SIX_DAYS);
            assertEq(veHemi.totalVeHemiSupply(), supplyAtEnable, "global supply drooped");
        }
    }

    /// @dev The catch-up walk must not eat the flat term either: force a
    ///      200-bucket catch-up in ONE checkpoint() call.
    function test_flatSurvivesCatchupWalk() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 supplyAtEnable = veHemi.totalVeHemiSupply();

        vm.warp(block.timestamp + 200 * SIX_DAYS);
        veHemi.checkpoint();
        assertEq(veHemi.totalVeHemiSupply(), supplyAtEnable, "flat term lost across catch-up");
        assertEq(veHemi.balanceOfNFT(id), supplyAtEnable, "position weight lost across catch-up");
    }

    // ---------------------------------------------------------------------
    // NO SENTINEL. lock.end keeps its true value.
    // ---------------------------------------------------------------------
    function test_noSentinel_endIsUnchangedByEnable() public {
        runSeedingFlow();
        (uint256 id, , uint256 end) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        assertEq(veHemi.getLockedBalance(id).end, end, "enable moved lock.end");
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp + 5 * 365 days, "sentinel detected");
    }

    // ---------------------------------------------------------------------
    // The restored slope IS retired after disable.
    // ---------------------------------------------------------------------
    function test_disableRestoresDecayAndRetiresSlope() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        vm.warp(block.timestamp + 30 * SIX_DAYS);
        vm.prank(alice);
        veHemi.disableAutoRelock(id);

        uint64 newEnd = veHemi.getLockedBalance(id).end;
        assertGt(newEnd, block.timestamp, "restored end must be live");
        assertEq(uint256(newEnd) % SIX_DAYS, 0, "restored end must be on the SIX_DAYS grid");

        // Decay resumes.
        uint256 w1 = veHemi.balanceOfNFT(id);
        vm.warp(block.timestamp + SIX_DAYS);
        assertLt(veHemi.balanceOfNFT(id), w1, "decay did not resume");

        // After the restored end passes, global supply must be
        // EXACTLY zero. If the slope was never retired the global curve keeps
        // subtracting it forever and clamps at 0 -- but the DIFFERENCE shows
        // up as an under-count long before that, and as a permanently wrong
        // slopeChanges bucket. Assert the bucket directly.
        assertEq(veHemi.slopeChanges(newEnd), -int128(int256(100 ether / MAX_TIME)),
            "restored slope was NOT scheduled for retirement at the restored end");

        vm.warp(uint256(newEnd) + 1);
        veHemi.checkpoint();
        assertEq(veHemi.totalVeHemiSupply(), 0, "supply must be exactly 0 after the restored end");
    }

    /// @dev A disable EARLY ENOUGH that the floor-snapped restored end lands
    ///      on the SAME bucket as the stored `lock.end`. A `newEnd_ > oldEnd_`
    ///      scheduling guard would skip this case and never retire the
    ///      restored slope.
    ///
    ///      A SECOND, longer-lived position is mandatory here: with one
    ///      position the global bias clamp at 0 hides the leak completely.
    function test_disableWithinSameBucket_stillRetiresSlope() public {
        runSeedingFlow();
        (uint256 bobId, , ) = createLock(bob, 500 ether, 4 * 365 days);
        (uint256 id, , uint256 end) = createLock(alice, 100 ether, 2 * 365 days);

        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        // Less than one SIX_DAYS bucket, so grid(now) + R == end; the
        // premise below pins it.
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        veHemi.disableAutoRelock(id);

        uint64 newEnd = veHemi.getLockedBalance(id).end;
        assertEq(newEnd, end, "premise: restored end must collide with the stored end");

        int128 expected = -int128(int256(100 ether / MAX_TIME));
        assertEq(veHemi.slopeChanges(newEnd), expected,
            "restored slope NOT scheduled at the colliding endpoint");

        // And the consequence, end-to-end: once alice's lock retires, the
        // global supply must equal bob's position exactly. A never-retired
        // slope keeps subtracting bob's weight forever.
        vm.warp(uint256(newEnd) + 180 days);
        veHemi.checkpoint();
        assertEq(veHemi.totalVeHemiSupply(), veHemi.balanceOfNFT(bobId),
            "global supply != the only surviving position -- slope leak");
    }

    /// @dev Same collision, reached the other way: ENABLE must not leave a
    ///      leftover slope retirement behind either.
    function test_enableCancelsTheOutgoingRetirement() public {
        runSeedingFlow();
        (uint256 id, , uint256 end) = createLock(alice, 100 ether, 2 * 365 days);
        int128 before = veHemi.slopeChanges(end);
        assertEq(before, -int128(int256(100 ether / MAX_TIME)), "premise: the slope retirement is not scheduled at the end");
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        assertEq(veHemi.slopeChanges(end), int128(0),
            "enable left the scheduled slope retirement at the stored end");
    }

    /// @dev The single-position case above can be satisfied by the bias clamp.
    ///      This one cannot: a SECOND, longer-lived position means the global slope
    ///      is non-zero, so a never-retired slope destroys the other position's
    ///      weight measurably.
    function test_disableDoesNotDestroyOtherPositions() public {
        runSeedingFlow();
        (uint256 bobId, , ) = createLock(bob, 500 ether, 4 * 365 days);
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);

        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 30 * SIX_DAYS);
        vm.prank(alice);
        veHemi.disableAutoRelock(id);

        uint64 aliceEnd = veHemi.getLockedBalance(id).end;
        vm.warp(uint256(aliceEnd) + 180 days);
        veHemi.checkpoint();

        assertEq(veHemi.totalVeHemiSupply(), veHemi.balanceOfNFT(bobId),
            "global supply != the only surviving position -- slope leak");
    }

    // ---------------------------------------------------------------------
    // The flat discriminator (slope == 0 && bias > 0). A DECAYING
    // position must NEVER be mistaken for a flat one.
    // ---------------------------------------------------------------------
    function test_decayingPositionIsNeverFlat() public {
        // Minimum legal amount, maximum legal duration -- the smallest slope
        // the contract can produce.
        (uint256 id, , ) = createLock(alice, 10 ether, 4 * 365 days);
        for (uint256 i = 0; i < 200; ++i) {
            IVeHemi.UserPoint memory p = veHemi.getUserPoint(id, veHemi.userPointEpoch(id));
            // The discriminator is (slope == 0 && bias > 0). Assert it is
            // unreachable for a live decaying position at every epoch.
            assertFalse(p.point.slope == 0 && p.point.bias > 0, "decaying position looks FLAT");
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();
        }
    }

    // ---------------------------------------------------------------------
    // The flat aggregate is in Point.amount on GLOBAL points, a field
    // that is 0 on global points while no position is armed.
    // ---------------------------------------------------------------------
    function test_globalPointAmountCarriesTheFlatAggregate() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        assertEq(veHemi.getGlobalPoint(veHemi.epoch()).amount, 0,
            "Point.amount is non-zero while no position is armed");
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 flatWeight = veHemi.balanceOfNFT(id);
        assertEq(veHemi.getGlobalPoint(veHemi.epoch()).amount, flatWeight, "flat aggregate not in Point.amount");

        vm.warp(block.timestamp + 40 * SIX_DAYS);
        veHemi.checkpoint();
        assertEq(veHemi.getGlobalPoint(veHemi.epoch()).amount, flatWeight, "flat aggregate not carried");

        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        assertEq(veHemi.getGlobalPoint(veHemi.epoch()).amount, 0, "flat aggregate not removed");
    }

    // ---------------------------------------------------------------------
    // The withdraw path removes the flat aggregate.
    // ---------------------------------------------------------------------
    function test_disableThenWithdrawZeroesEverything() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 10 * SIX_DAYS);
        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        vm.prank(alice);
        veHemi.withdraw(id);
        assertEq(veHemi.totalVeHemiSupply(), 0, "supply not zero after withdraw");
        assertEq(veHemi.getGlobalPoint(veHemi.epoch()).amount, 0, "flat aggregate leaked past withdraw");
    }

    // ---------------------------------------------------------------------
    // The liveness checks. A flat position with a PAST stored end must still
    // be delegatable and must still carry voting power.
    // ---------------------------------------------------------------------
    function test_flatPositionWithPastStoredEndStillHasVotes() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 flatWeight = veHemi.balanceOfNFT(id);

        // Warp past the stored lock.end.
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "premise: stored end must be past");

        // The liveness checks in VeHemi._delegate and _getNormalizedLockedInfo.
        vm.prank(alice);
        delegation.delegate(id, bob);

        vm.warp(block.timestamp + 1 hours);
        assertEq(delegation.getVotes(bob), flatWeight, "flat votes lost");

        // ... and they must not decay.
        vm.warp(block.timestamp + 100 * SIX_DAYS);
        assertEq(delegation.getVotes(bob), flatWeight, "flat votes decayed");
    }

    /// @dev The MAX_LOCK_DURATION wipe branch of
    ///      `_calculateExpirations` zeroes normalizedBias/Slope/amount but
    ///      must NEVER touch `fixedBias`.
    function test_flatVotesSurviveMaxLockDurationWipe() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 flatWeight = veHemi.balanceOfNFT(id);
        vm.prank(alice);
        delegation.delegate(id, bob);

        // > MAX_LOCK_DURATION past the checkpoint -> the wipe branch fires.
        vm.warp(block.timestamp + 5 * 365 days);
        assertEq(delegation.getVotes(bob), flatWeight, "flat votes wiped by MAX_LOCK_DURATION branch");
    }

    // ---------------------------------------------------------------------
    // Authorization. enable/disable are strict _ownerOf.
    // ---------------------------------------------------------------------
    function test_onlyOwnerMayEnableOrDisable() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(bob);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.enableAutoRelock(id);

        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        vm.prank(bob);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.disableAutoRelock(id);
    }

    /// @dev A 1-wei top-up must not clear R: `_depositFor` rebuilds the
    ///      `LockedBalance`, and R lives in its own mapping, so it must be
    ///      untouched. (`increaseAmount` is owner-gated, so the owner sends it;
    ///      the deposit body is the same for any caller.)
    function test_oneWeiTopUpCannotClearR() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint64 r = veHemi.autoRelockRemaining(id);
        uint256 flatWeight = veHemi.balanceOfNFT(id);
        assertGt(r, 0);

        vm.startPrank(alice);
        hemi.mint(alice, 1);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(id, 1);
        vm.stopPrank();

        assertEq(veHemi.autoRelockRemaining(id), r, "a 1-wei top-up cleared R");
        assertGe(veHemi.balanceOfNFT(id), flatWeight, "a 1-wei top-up reduced the weight");
        vm.warp(block.timestamp + 100 * SIX_DAYS);
        assertGe(veHemi.balanceOfNFT(id), flatWeight, "position resumed decaying after the top-up");
    }
}

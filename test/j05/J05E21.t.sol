// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./J05Base.sol";

/// @title  J05E21 — the economic attacks on a flat position.
///
/// @notice An attacker who freezes a position flat must not hold more weight
///         than the lock-up it is still serving (beyond V-MEAN's half-bucket
///         slack), must not reach a one-second exit, must not move its end or
///         its forfeit window, must not out-last a manual twin by cycling, and
///         cannot keep an abandoned flat position in the denominator for ever.
///         R is derived from `lock.end` (whole buckets, `R >= 2 * SIX_DAYS`)
///         and the flat level is V-MEAN, `slope * (R - SIX_DAYS/2)`.
contract J05E21 is J05Base {
    // ------------------------------------------------------------------
    // A1 — THE ESCROW LAW. Under V-MEAN the excess of the flat weight over
    //      `slope * lockup` can never exceed HALF a bucket of slope.
    // ------------------------------------------------------------------
    function test_E21_A1_escrowLawExcessBoundedByHalfBucket() public {
        uint256 amt = 1_000 ether;
        (uint256 id, , ) = createLock(attacker, amt, 2 * 365 days);
        enable(attacker, id);
        uint256 s = slopeOf(amt);

        uint256[8] memory phases = [uint256(0), 1, SIX_DAYS / 4, HALF_BUCKET - 1, HALF_BUCKET, HALF_BUCKET + 1, (3 * SIX_DAYS) / 4, SIX_DAYS - 1];
        uint256 worst;
        for (uint256 i = 0; i < phases.length; ++i) {
            warpToPhase(phases[i]);
            uint256 w = veHemi.balanceOfNFT(id);
            uint256 lockup = residualLockup(id);
            // THE VOTE-ESCROW LAW, with V-MEAN's half-bucket slack.
            assertLe(w, s * lockup + s * HALF_BUCKET, "escrow-law excess exceeds HALF a bucket of slope");
            // and the position is never under-paid by more than half a bucket
            // either (the other half of V-MEAN's minimax).
            assertGe(w + s * HALF_BUCKET, s * lockup, "flat level below the twin by more than half a bucket");
            if (w > s * lockup && w - s * lockup > worst) worst = w - s * lockup;
        }
        // NON-VACUITY: the bound is actually approached, so `assertLe` above
        // is not passing on a degenerate zero excess.
        assertGt(worst, s * (HALF_BUCKET - 2), "bound never approached -- body is vacuous");
    }

    // ------------------------------------------------------------------
    // A2 — NO ONE-SECOND EXIT. A flash exit needs N = 1 (full weight held
    //      indefinitely, liquid on one second's notice). `R >= 2 * SIX_DAYS`
    //      makes N = 1 unreachable, so the minimum residual lock-up a flat
    //      position can ever be serving is a whole bucket plus one second.
    // ------------------------------------------------------------------
    function test_E21_A2_noOneSecondExit() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        enable(attacker, id);
        for (uint256 i = 0; i < 12; ++i) {
            warpToPhase(SIX_DAYS - 1); // the worst phase
            assertGe(residualLockup(id), SIX_DAYS + 1, "flat position one second from liquidity");
        }
        // and it survives the actual disable at that phase.
        disable(attacker, id);
        assertGe(veHemi.getLockedBalance(id).end, block.timestamp + SIX_DAYS + 1, "restored end one second away");
    }

    /// @dev The guard itself, directly: a position with exactly ONE bucket of
    ///      term left is REFUSED. This is the line that makes A2 true.
    function test_E21_A2b_enableRefusesTheOneBucketHorizon() public {
        (uint256 id, , uint256 end) = createLock(attacker, 1_000 ether, 2 * SIX_DAYS);
        // walk forward until exactly one bucket of term remains from grid(now)
        while (end - (block.timestamp / SIX_DAYS) * SIX_DAYS > SIX_DAYS) {
            vm.warp(block.timestamp + SIX_DAYS);
        }
        assertEq(end - (block.timestamp / SIX_DAYS) * SIX_DAYS, SIX_DAYS, "probe did not reach N=1");
        vm.prank(attacker);
        vm.expectRevert(VeHemi.AutoRelockDurationTooShort.selector);
        veHemi.enableAutoRelock(id);
    }

    // ------------------------------------------------------------------
    // A3 — ENABLE MOVES NO END. R is DERIVED from `lock.end`, so a
    //      truncating (or extending) enable is impossible at every phase.
    // ------------------------------------------------------------------
    function test_E21_A3_enableDoesNotMoveTheEffectiveEnd() public {
        uint256[6] memory phases = [uint256(0), 1, 3599, HALF_BUCKET, SIX_DAYS - 2, SIX_DAYS - 1];
        for (uint256 i = 0; i < phases.length; ++i) {
            warpToPhase(phases[i]);
            (uint256 id, , uint256 end) = createLock(attacker, 100 ether, 2 * 365 days);
            enable(attacker, id);
            assertEq(veHemi.effectiveLockEnd(id), end, "enable moved the effective end");
            assertEq(veHemi.getLockedBalance(id).end, end, "enable moved the stored end");
        }
    }

    // ------------------------------------------------------------------
    // A4 — THE FORFEIT ESCAPE IS CLOSED. A forfeitable grant that goes flat
    //      must stay clawable for the whole of its window and unclawable after
    //      it — the freeze must move neither edge.
    // ------------------------------------------------------------------
    function test_E21_A4_forfeitEscapeClosed() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 ta = veHemi.transferableAfter(id);
        enable(victim, id);
        assertEq(veHemi.effectiveLockEnd(id), ta, "freeze moved the forfeit edge");

        // 19 probes across the window: the admin can always claw back.
        uint256 t0 = block.timestamp;
        for (uint256 k = 1; k <= 19; ++k) {
            uint256 probe = t0 + ((ta - t0) * k) / 20;
            uint256 snap = vm.snapshotState();
            vm.warp(probe);
            veHemi.forfeit(id); // must not revert
            vm.revertToState(snap);
        }
        // and at `ta` itself the window is SHUT, not open.
        vm.warp(ta);
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        veHemi.forfeit(id);
    }

    // ------------------------------------------------------------------
    // A5 — NO RATCHET, against a MANUAL TWIN. Repeated enable/disable
    //      cycling must never buy a later `end` than the twin holds.
    // ------------------------------------------------------------------
    function test_E21_A5_cyclingNeverBeatsTheManualTwin() public {
        (uint256 a, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        (uint256 b, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        uint256 startEnd = veHemi.getLockedBalance(a).end;
        for (uint256 i = 0; i < 60; ++i) {
            enable(attacker, a);
            vm.warp(block.timestamp + 60);
            disable(attacker, a);
            assertLe(veHemi.getLockedBalance(a).end, startEnd, "END RATCHETED UP -- free lock duration minted");
            // the honest twin is not moved by the attacker's cycling
            assertEq(veHemi.getLockedBalance(b).end, startEnd, "twin moved");
        }
    }

    // ------------------------------------------------------------------
    // A6 — A FLAT POSITION DELEGATES LIKE A PLAIN ONE, with a plain-position
    //      control, on the STALE flat state (stored end far in the past) that
    //      is the only place the flag clause in `VeHemi._delegate` is
    //      load-bearing.
    // ------------------------------------------------------------------
    function test_E21_A6_staleFlatSellerHandsOverTheVotes() public {
        (uint256 flatId, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        (uint256 plainId, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        enable(attacker, flatId);
        delegateTo(attacker, flatId, dele);
        delegateTo(victim, plainId, dele2);
        vm.warp(block.timestamp + 3600);

        // drive the FLAT position's STORED end deep into the past; the flag
        // keeps it alive. The plain control is still live on its own date.
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        assertLt(veHemi.getLockedBalance(flatId).end, block.timestamp, "probe: stored end not stale");
        assertGt(delegation.getVotes(dele), 0, "probe: no flat votes to hand over");
        assertGt(delegation.getVotes(dele2), 0, "probe: no plain votes to hand over");

        vm.prank(attacker);
        veHemi.transferFrom(attacker, bob, flatId);
        vm.prank(victim);
        veHemi.transferFrom(victim, bob, plainId);

        // The sale retires the live contribution at `block.timestamp + 1`,
        // so the seller's votes are gone from the NEXT SECOND -- and the FLAT
        // seller must be treated exactly like the PLAIN one. The clause
        // `autoRelockRemaining[delegator_] != 0` in `VeHemi._delegate` is what
        // makes that true for a position whose stored end is in the past.
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(dele2), 0, "PLAIN control seller kept votes -- body is not measuring the flag");
        assertEq(delegation.getVotes(dele), 0, "stale FLAT seller kept the votes after the sale");
        vm.warp(block.timestamp + 3600);
        assertEq(delegation.getVotes(dele), 0, "stale FLAT seller still holds votes an hour later");
    }

    // ------------------------------------------------------------------
    // A7 — WITHDRAW CLEARS THE FLAT AGGREGATE: a served-out flat position
    //      must leave the quorum denominator completely.
    // ------------------------------------------------------------------
    function test_E21_A7_withdrawClearsTheFlatAggregate() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        (uint256 honest, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        enable(attacker, id);
        vm.warp(block.timestamp + 37 * SIX_DAYS);
        disable(attacker, id);
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(veHemi.balanceOfNFT(honest), veHemi.totalVeHemiSupply(), "flat aggregate stranded in the denominator");
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(veHemi.totalVeHemiSupply(), 0, "denominator never reaches zero");
    }

    // ------------------------------------------------------------------
    // A8 — A TOP-UP RE-MATERIALISES THE LAZY END.
    // ------------------------------------------------------------------
    function test_E21_A8_topUpRematerialisesTheEnd() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        enable(attacker, id);
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        uint256 eff = veHemi.effectiveLockEnd(id);
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "probe: stored end not stale");
        vm.prank(attacker);
        veHemi.increaseAmount(id, 10 ether);
        assertEq(veHemi.getLockedBalance(id).end, eff, "top-up left the stored end stale");
        assertEq(veHemi.effectiveLockEnd(id), eff, "top-up moved the effective end");
    }

    // ------------------------------------------------------------------
    // A9 — A TOUCH ON A STALE FLAT POSITION DOES NOT KILL ITS WEIGHT. The
    //      curve's flat branch must key on the FLAG, never on the stored
    //      (deliberately stale) end.
    // ------------------------------------------------------------------
    function test_E21_A9_touchOnStaleFlatDisarmsWithoutDestroyingWeight() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        enable(attacker, id);
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        uint256 w = veHemi.balanceOfNFT(id);
        assertGt(w, 0, "probe: no weight");
        vm.prank(attacker);
        veHemi.transferFrom(attacker, bob, id); // the TOUCH
        // The transfer DISARMS the stale flat position into a decaying lock.
        // The weight is NOT destroyed -- it is preserved up to
        // the disarm end-snap's sub-bucket phase step (at most half a SIX_DAYS
        // bucket of slope, either way) -- and the denominator still equals the
        // one live position.
        assertEq(veHemi.autoRelockRemaining(id), 0, "touch did not disarm");
        // The post-disarm step is deterministic: end=grid(now)+R moves the
        // weight from slope*(R - SIX_DAYS/2) to slope*(R - now % SIX_DAYS), a
        // step of at most slope*SIX_DAYS/2 either way (~0.42% of w for this
        // R). 0.5% is the tight bound; a 1% band would admit >2x the physical max.
        assertApproxEqRel(veHemi.balanceOfNFT(id), w, 0.005e18, "a touch on a stale flat position destroyed its weight");
        assertEq(veHemi.totalVeHemiSupply(), veHemi.balanceOfNFT(id), "denominator does not match the live weight");
    }

    // ------------------------------------------------------------------
    // A10 — THE ABANDONED FLAT POSITION *CAN* BE RETIRED. One transaction
    //      must not buy a denominator share that never decays: after
    //      STALE_FLAT_BUCKETS without a heartbeat anyone may retire it.
    // ------------------------------------------------------------------
    function test_E21_A10_abandonedFlatIsRetirable() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        uint256 staleAt = veHemi.autoRelockStaleAt(id);
        assertEq(staleAt, block.timestamp + veHemi.STALE_FLAT_BUCKETS() * SIX_DAYS, "stale clock wrong");

        // one second early it is NOT retirable -- the guard is real
        vm.warp(staleAt - 1);
        vm.prank(stranger);
        vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
        veHemi.retireStaleAutoRelock(id);

        // the owner's heartbeat defers it, and defers it EXACTLY
        vm.prank(attacker);
        veHemi.refreshAutoRelock(id);
        assertEq(veHemi.autoRelockStaleAt(id), block.timestamp + veHemi.STALE_FLAT_BUCKETS() * SIX_DAYS, "heartbeat did not defer the retire");

        // abandon it. a stranger retires it, and the denominator heals.
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "retire left the position flat");
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(veHemi.balanceOfNFT(id), 0, "abandoned flat weight still standing");
        assertEq(veHemi.totalVeHemiSupply(), 0, "abandoned flat position never left the denominator");
    }
}

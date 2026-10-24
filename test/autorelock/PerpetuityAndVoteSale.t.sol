// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";

/// @title  The perpetuity and sell-and-keep-the-vote attacks.
///
/// @notice A flat position must never weigh more than its principal or hold R
///         off the grid or above MAX_TIME; one transaction must not buy a
///         never-decaying share of the denominator (the heartbeat bounds it:
///         STALE_FLAT_BUCKETS of silence and anyone may retire it); a seller
///         loses the votes from the next second; a flat position does not
///         decay; a fresh delegation votes from the next block, not the same
///         one.
contract PerpetuityAndVoteSaleTest is AutoRelockTestBase {
    // ------------------------------------------------------------------
    // B1 — NO WEIGHT MINTING: `balanceOfNFT <= amount`
    //      is the value ceiling of the whole system.
    // ------------------------------------------------------------------
    function test_B1_weightNeverExceedsPrincipal() public {
        uint256[6] memory phases = [uint256(0), 1, 3599, HALF_BUCKET, SIX_DAYS - 2, SIX_DAYS - 1];
        uint256[4] memory durs = [uint256(2 * SIX_DAYS + 1), 60 days, 2 * 365 days, 4 * 365 days];
        for (uint256 p = 0; p < phases.length; ++p) {
            for (uint256 d = 0; d < durs.length; ++d) {
                warpToPhase(phases[p]);
                (uint256 id, , ) = createLock(attacker, 1_000 ether, durs[d]);
                enable(attacker, id);
                uint256 r = veHemi.autoRelockRemaining(id);
                assertEq(r % SIX_DAYS, 0, "R left the SIX_DAYS grid");
                assertLe(r, MAX_TIME, "R above MAX_TIME -- duration minted");
                assertLe(veHemi.balanceOfNFT(id), 1_000 ether, "WEIGHT MINTED above principal");
                // and an attempted max extension cannot lift it either
                vm.prank(attacker);
                try veHemi.increaseUnlockTime(id, MAX_TIME) {} catch {}
                assertLe(veHemi.autoRelockRemaining(id), MAX_TIME, "R above MAX_TIME after extension");
                assertLe(veHemi.balanceOfNFT(id), 1_000 ether, "WEIGHT MINTED after extension");
            }
        }
    }

    /// @dev 100 enable/disable cycles alternating the two hostile phases.
    function test_B1b_noWeightRatchetOverCycles() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(grid() + SIX_DAYS + (i % 2 == 0 ? SIX_DAYS - 1 : 3));
            enable(attacker, id);
            assertLe(veHemi.balanceOfNFT(id), 1_000 ether, "WEIGHT MINTED");
            assertLe(veHemi.autoRelockRemaining(id), MAX_TIME, "R above MAX_TIME");
            assertLt(veHemi.effectiveLockEnd(id) - block.timestamp, MAX_TIME, "effective term above MAX_TIME");
            disable(attacker, id);
            assertLe(veHemi.balanceOfNFT(id), 1_000 ether, "WEIGHT MINTED after disable");
        }
    }

    // ------------------------------------------------------------------
    // B3 — THE PERPETUITY IS BOUNDED: STALE_FLAT_BUCKETS of
    //      silence and any stranger ends it.
    // ------------------------------------------------------------------
    function test_B3_perpetuityIsBoundedByTheHeartbeat() public {
        (uint256 atk, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        (uint256 honest, , ) = createLock(victim, 9_000 ether, 4 * 365 days);
        enable(attacker, atk);

        // the honest book decays away; the squat does not.
        vm.warp(block.timestamp + 241 * SIX_DAYS);
        assertEq(veHemi.balanceOfNFT(honest), 0, "probe: honest arm did not decay");
        assertGt(veHemi.balanceOfNFT(atk), 0, "probe: squat already gone");
        assertEq(veHemi.totalVeHemiSupply(), veHemi.balanceOfNFT(atk), "probe: squatter is not the whole book");

        // ...but it has been retirable since 60 buckets after the last touch.
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(atk);
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(veHemi.balanceOfNFT(atk), 0, "PERPETUITY: the squat outlived the retire");
        assertEq(veHemi.totalVeHemiSupply(), 0, "PERPETUITY: the denominator never healed");
    }

    /// @dev The PRICE of the perpetuity, which is the whole point: upkeep is
    ///      not zero. A squatter must heartbeat at least once every
    ///      STALE_FLAT_BUCKETS buckets or lose the squat to any stranger.
    function test_B3b_upkeepCadenceIsExactlySixtyBuckets() public {
        (uint256 atk, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, atk);
        uint256 K = veHemi.STALE_FLAT_BUCKETS();
        for (uint256 round = 0; round < 4; ++round) {
            uint256 due = veHemi.autoRelockStaleAt(atk);
            assertEq(due, block.timestamp + K * SIX_DAYS, "cadence is not K buckets from the last touch");
            vm.warp(due - 1);
            vm.prank(stranger);
            vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
            veHemi.retireStaleAutoRelock(atk); // one second early: refused
            vm.prank(attacker);
            veHemi.refreshAutoRelock(atk); // pay the upkeep
        }
        // stop paying, and the squat dies.
        vm.warp(veHemi.autoRelockStaleAt(atk));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(atk);
        assertEq(veHemi.autoRelockRemaining(atk), 0, "unpaid squat survived");
    }

    // ------------------------------------------------------------------
    // B4 — SELL THE POSITION AND KEEP THE VOTE. A sale retires the
    //      seller's live contribution at `block.timestamp + 1`, so the
    //      rentable window is ONE SECOND, even when sold at the last second of
    //      an hour.
    // ------------------------------------------------------------------
    function test_B4_sellerLosesTheVotesAtTheNextSecond() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        delegateTo(attacker, id, dele);
        vm.warp(block.timestamp + 7200); // let the booking land

        assertGt(delegation.getVotes(dele), 0, "probe: nothing to rent");

        // sell at the last second of an hour
        vm.warp((block.timestamp / 3600) * 3600 + 3599);
        vm.prank(attacker);
        veHemi.transferFrom(attacker, bob, id);
        assertEq(veHemi.balanceOf(attacker), 0, "probe: seller still holds escrow");
        // The transfer disarmed the position (the vote-conservation asserts
        // below do not discriminate that).
        assertEq(veHemi.autoRelockRemaining(id), 0, "transfer did not disarm the position");

        // ONE second later the rent is over, and it never comes back.
        for (uint256 i = 1; i <= 3700; i += 149) {
            vm.warp(block.timestamp + (i == 1 ? 1 : 149));
            assertEq(delegation.getVotes(dele), 0, "SELLER KEPT THE VOTES after the sale");
        }
        // The buyer's side is credited, so the weight is not destroyed. The
        // buyer holds a DECAYING (disarmed) lock: its votes equal the live
        // weight.
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(bob), veHemi.balanceOfNFT(id), "buyer was not credited the weight");
    }

    // ------------------------------------------------------------------
    // B5 — THE FLAT DISCRIMINATOR: a flat position does not decay, and the
    //      aggregate agrees with the position.
    // ------------------------------------------------------------------
    function test_B5_flatDoesNotDecay() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        uint256 w0 = veHemi.balanceOfNFT(id);
        for (uint256 i = 0; i < 120; ++i) {
            vm.warp(block.timestamp + SIX_DAYS);
            assertEq(veHemi.balanceOfNFT(id), w0, "flat position DECAYED");
            assertEq(veHemi.totalVeHemiSupply(), w0, "flat aggregate decayed");
        }
    }

    // ------------------------------------------------------------------
    // B2 — `_newR > MAX_TIME` is UNREACHABLE from a flat position: repeated
    //      max extensions keep R <= MAX_TIME and the weight <= principal. This
    //      body pins the reachability argument, not the guard.
    // ------------------------------------------------------------------
    function test_B2_maxTimeIsUnreachableFromAFlatPosition() public {
        uint256[4] memory phases = [uint256(0), 1, SIX_DAYS - 1, HALF_BUCKET];
        for (uint256 p = 0; p < phases.length; ++p) {
            warpToPhase(phases[p]);
            (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
            enable(attacker, id);
            for (uint256 i = 0; i < 20; ++i) {
                vm.warp(block.timestamp + SIX_DAYS);
                vm.prank(attacker);
                try veHemi.increaseUnlockTime(id, MAX_TIME) {} catch {}
                assertLe(veHemi.autoRelockRemaining(id), MAX_TIME, "R EXCEEDED MAX_TIME");
                assertLe(veHemi.balanceOfNFT(id), 1_000 ether, "weight above principal");
            }
        }
    }

    // B6 — the other half of B4's attack. B4 pins that RETIREMENTS are
    // immediate; B6 pins that ADDITIONS are not free: a fresh delegation does
    // not vote in its own block (`getPastVotes` reverts `TimestampInFuture`
    // past `block.timestamp`, so same-block flash delegation is impossible),
    // and is live at full weight from the next second.
    function test_B6_additionsAreLiveFromTheNextBlock() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        // land inside an hourly epoch, not on its edge
        vm.warp((block.timestamp / 3600) * 3600 + 3600 + 7);
        uint256 boundary = ((block.timestamp / 3600) * 3600) + 3600;
        uint256 tDelegate = block.timestamp;
        delegateTo(attacker, id, dele);

        // (1) Not in the delegation's own block.
        assertEq(delegation.getVotes(dele), 0, "a fresh delegation voted IMMEDIATELY -- addition not deferred");

        // (2) Live from the next block, at full weight.
        vm.warp(tDelegate + 1);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id),
            "t+1: the addition must be live, and at full weight, in the NEXT block");

        // (3) And it is still exactly right at the boundary.
        vm.warp(boundary);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "addition did not land AT the boundary");
    }
}

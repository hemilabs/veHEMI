// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j17/J17Base.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

/// @title  Q29 — detectors for guards whose necessity is conditional.
///
/// @notice Three bodies pin D01's `force_` flag in `_endAutoRelock` (redundant on
///         this build, and only because `enableAutoRelock` refuses N == 1),
///         and one pins that a stranded flat term stays retirable after its
///         restored end has passed (D01's `tolerateExpired_` branch).
///
/// @dev    Every sweep carries a reachability counter and fails loudly when it
///         observed nothing; the single-shot bodies assert their own premises
///         instead. Counters are FUNCTION LOCALS, not storage:
///         `vm.revertToState` rolls back contract storage. Nothing here
///         snapshots at all; each cell uses a fresh position and only moves
///         time forward.
contract Q29Detectors is J17Base {
    // =====================================================================
    // D01 — THE `force_` FLAG IN `_endAutoRelock`. REDUNDANT ON THIS BUILD,
    // CONDITIONALLY.
    //
    // `VeHemi._endAutoRelock` calls `_reDelegate(tokenId_, true, strict_)` so the
    // ordinary `_delegate` near-expiry skip cannot skip the retirement of the
    // flat term. With the flag cleared that skip degenerates to
    // `nextHourBoundary < locked[id].end`, and on this build that is ALREADY
    // TRUE at the call site:
    //   1. `_endAutoRelock` restores `end = (floor(now/SIX_DAYS) + R/SIX_DAYS)
    //      * SIX_DAYS`;
    //   2. `enableAutoRelock` refuses `R < 2 * SIX_DAYS`
    //      (`AutoRelockDurationTooShort`), i.e. N == 1;
    //   3. R is MONOTONE NON-DECREASING afterwards (`increaseUnlockTime` is
    //      the only other writer, and only raises it);
    //   4. so R/SIX_DAYS >= 2 at every `_endAutoRelock`, and
    //        end - now  >=  2*SIX_DAYS - (now mod SIX_DAYS)  >  SIX_DAYS,
    //      while `nextHourBoundary - now <= 3,600 s`.
    // The equivalence is CONDITIONAL on step 2, so `force_` stays; these
    // bodies make the condition explicit.
    // =====================================================================

    /// @notice Leg 1 — the MARGIN, measured at the tightest admissible R and
    ///         at the worst phase inside the bucket. Reports the minimum
    ///         `end - nextHourBoundary` it saw.
    function test_Q29_D01_forceIsRedundantAtEveryAdmissibleDisableInstant() public {
        // phases inside the bucket, ending at the very last second — the
        // worst case for the floor-snap.
        uint256[8] memory phases = [
            uint256(0), 1, 3_599, 3_600, SIX_DAYS / 2,
            SIX_DAYS - 3_601, SIX_DAYS - 3_600, SIX_DAYS - 1
        ];

        uint256 cells;                    // LOCAL: survives nothing, rolls back never
        uint256 minSlackSeconds = type(uint256).max;
        uint256 tightestR = type(uint256).max;

        for (uint256 i; i < phases.length; ++i) {
            // Two durations: a long one (large R) and the TIGHTEST one
            // `enableAutoRelock` admits (R == 2 * SIX_DAYS).
            for (uint256 k; k < 2; ++k) {
                uint256 dur = k == 0 ? 4 * 365 days : 2 * SIX_DAYS;
                (uint256 id, , ) = createLock(victim, 1_000 ether, dur);
                delegateTo(victim, id, dele);
                enable(victim, id);
                uint256 r = veHemi.autoRelockRemaining(id);
                if (r < tightestR) tightestR = r;

                // move to `phases[i]` inside a LATER bucket
                vm.warp(grid() + SIX_DAYS + phases[i]);

                disable(victim, id);

                // The ordinary gate, recomputed EXACTLY as `VeHemi._delegate`
                // computes it.
                uint256 nextHour = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
                uint256 end = uint256(veHemi.getLockedBalance(id).end);

                assertLt(
                    nextHour,
                    end,
                    "Q29/D01: the restored end is INSIDE the next hourly checkpoint -- "
                    "`force_` in _endAutoRelock IS load-bearing after all"
                );
                if (end - nextHour < minSlackSeconds) minSlackSeconds = end - nextHour;
                ++cells;
            }
        }

        emit log_named_uint("Q29/D01 cells executed", cells);
        emit log_named_uint("Q29/D01 tightest R (seconds)", tightestR);
        emit log_named_uint("Q29/D01 MIN slack end-nextHour (s)", minSlackSeconds);
        // NON-VACUITY FLOOR.
        assertEq(cells, 16, "Q29/D01 VACUITY: the sweep did not execute 16 cells");
        assertEq(tightestR, 2 * SIX_DAYS, "Q29/D01: the tightest admissible R is not 2*SIX_DAYS");
        assertGt(minSlackSeconds, 1 hours, "Q29/D01: slack collapsed to within one hourly epoch");
    }

    /// @notice Leg 2 — THE COUPLING TRIPWIRE. `force_` is redundant ONLY
    ///         BECAUSE `enableAutoRelock` refuses N == 1. Pin that, by
    ///         selector, on exactly that position. The day the refusal is
    ///         weakened this body goes RED and says why.
    function test_Q29_D01_f16_1_isThePremiseThatMakesForceRedundant() public {
        // `_createLock` itself refuses `lockDuration_ < 2 * SIX_DAYS`, so an
        // N == 1 position cannot be MINTED — it is REACHED. Mint the shortest
        // admissible lock (N == 2) and let one bucket of time pass: `end` is
        // frozen, `grid(now)` advances, N falls to 1. This is the ONLY way the
        // state exists, and it is an ordinary one.
        (uint256 id, , ) = createLock(victim, 1_000 ether, 2 * SIX_DAYS);
        vm.warp(block.timestamp + SIX_DAYS);
        uint256 end = uint256(veHemi.getLockedBalance(id).end);
        uint256 n = (end - (block.timestamp / SIX_DAYS) * SIX_DAYS) / SIX_DAYS;
        emit log_named_uint("Q29/D01 leg2: N at enable", n);
        assertEq(n, 1, "Q29/D01 leg2 SETUP: the probe position is not N == 1");

        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call(
            abi.encodeWithSignature("enableAutoRelock(uint256)", id)
        );
        assertFalse(
            ok,
            "Q29/D01 leg2: enableAutoRelock NO LONGER REFUSES N == 1. `force_` in "
            "`_endAutoRelock` is LOAD-BEARING again -- restore a directed control "
            "for it before shipping."
        );
        assertEq(
            bytes4(ret),
            VeHemi.AutoRelockDurationTooShort.selector,
            "Q29/D01 leg2: N == 1 is refused, but not by AutoRelockDurationTooShort -- the premise moved"
        );
    }

    /// @notice Leg 3 — THE GENERAL LAW: after
    ///         `disableAutoRelock`, the delegation record for that token is
    ///         NOT FLAT. `(slope == 0 && bias > 0)` is the same discriminator
    ///         `VeHemi._requireFlatTermRetired` and
    ///         `VeHemiVoteDelegation._delegate` both use on their own OLD side.
    ///
    /// @dev    On this build it passes with or without `force_` (they are
    ///         equivalent, see above). It is the half that catches a dropped
    ///         `force_` the moment the N == 1 refusal stops holding: then cell
    ///         7 runs, and without `force_` the flat term survives.
    function test_Q29_D01_disableAlwaysRetiresTheFlatTerm() public {
        uint256 cells;
        uint256 flatSurvivors;
        // Sweep the tightest admissible position across the whole bucket,
        // INCLUDING the last second of the bucket.
        uint256[6] memory phases = [uint256(0), 1, 3_599, SIX_DAYS / 2, SIX_DAYS - 3_600, SIX_DAYS - 1];
        for (uint256 i; i < phases.length; ++i) {
            (uint256 id, , ) = createLock(victim, 1_000 ether, 2 * SIX_DAYS);
            delegateTo(victim, id, dele);
            enable(victim, id);
            // NON-VACUITY (a): the enable really did book a FLAT term.
            IVeHemiVoteDelegation.Delegation memory pre = delegation.delegation(id);
            assertTrue(pre.slope == 0 && pre.bias > 0, "Q29/D01 leg3 VACUITY: enable booked no flat term");

            vm.warp(grid() + SIX_DAYS + phases[i]);
            disable(victim, id);

            IVeHemiVoteDelegation.Delegation memory post = delegation.delegation(id);
            if (post.slope == 0 && post.bias > 0) ++flatSurvivors;
            ++cells;
        }
        // CELL 7 — the N == 1 cell. `_createLock` cannot mint it, so it is
        // REACHED: mint N == 2, let one bucket pass. On THIS build the enable
        // is refused and the cell is skipped (leg 2 pins that refusal). If the
        // refusal is weakened the enable succeeds, the cell RUNS, and it is the
        // cell that separates `force_` from no-`force_`.
        {
            (uint256 id7, , ) = createLock(victim, 1_000 ether, 2 * SIX_DAYS);
            delegateTo(victim, id7, dele);
            vm.warp(block.timestamp + SIX_DAYS);
            vm.prank(victim);
            (bool ok7, ) = address(veHemi).call(
                abi.encodeWithSignature("enableAutoRelock(uint256)", id7)
            );
            if (ok7) {
                emit log("Q29/D01 leg3: N == 1 IS ENABLEABLE ON THIS TREE -- cell 7 armed");
                IVeHemiVoteDelegation.Delegation memory p7 = delegation.delegation(id7);
                assertTrue(p7.slope == 0 && p7.bias > 0, "Q29/D01 leg3 cell7 VACUITY: no flat term booked");
                // the worst phase: the last second of the bucket
                vm.warp(grid() + SIX_DAYS - 1);
                disable(victim, id7);
                IVeHemiVoteDelegation.Delegation memory q7 = delegation.delegation(id7);
                if (q7.slope == 0 && q7.bias > 0) ++flatSurvivors;
                ++cells;
            }
        }

        emit log_named_uint("Q29/D01 leg3 cells executed", cells);
        emit log_named_uint("Q29/D01 leg3 flat terms still standing", flatSurvivors);
        assertGe(cells, 6, "Q29/D01 leg3 VACUITY: the sweep did not execute its 6 base cells");
        assertEq(
            flatSurvivors,
            0,
            "Q29/D01 leg3: disableAutoRelock left the FLAT term standing at the delegatee -- "
            "PHANTOM GOVERNANCE POWER (D01)"
        );
    }

    // =====================================================================
    // D01 `tolerateExpired_`. When the stored record is FLAT,
    // `autoRelockRemaining == 0` and `locked[id].end <= checkpoint`, moving the
    // record away must not revert `CanNotDelegateExpiredLocks`: if it did, a
    // stranded flat term could never be retired. This body builds exactly that
    // state with the SHORTEST admissible lock (so the restored end is reachable),
    // strands the term behind a lying module, repairs the module, lets the
    // restored end pass, and then tries the holder's cure.
    // =====================================================================
    function test_Q29_D01tol_strandedFlatTermIsStillRetirableAfterItsEndPasses() public {
        IVeHemiVoteDelegation good = IVeHemiVoteDelegation(address(delegation));

        // N == 2: the tightest admissible position, so the restored end is
        // ~12 days out rather than ~4 years and the expiry is REACHABLE.
        (uint256 id, , ) = createLock(victim, 1_000 ether, 2 * SIX_DAYS);
        delegateTo(victim, id, dele);
        enable(victim, id);
        vm.warp(block.timestamp + 7200);

        uint256 wFlat = delegation.getVotes(dele);
        assertGt(wFlat, 0, "Q29/D01-tol VACUITY: the enable booked no flat term");

        // STRAND IT: the module answers reads but does not perform the
        // retirement, so `delegations[id]` keeps its FLAT shape.
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        disable(victim, id);
        assertEq(delegation.getVotes(dele), wFlat,
            "Q29/D01-tol VACUITY: the term was not stranded -- the probe proves nothing");
        IVeHemiVoteDelegation.Delegation memory mid = delegation.delegation(id);
        assertTrue(mid.slope == 0 && mid.bias > 0,
            "Q29/D01-tol VACUITY: the stored record is not FLAT");

        veHemi.updateVoteDelegation(good);          // the module is repaired...

        // ...but `_endAutoRelock` already ran, so `autoRelockRemaining == 0`;
        // let the restored end fall into the past.
        uint256 end = uint256(veHemi.getLockedBalance(id).end);
        assertGt(end, block.timestamp, "Q29/D01-tol SETUP: the end is already past");
        vm.warp(end + 1 hours);

        // THE HOLDER'S CURE: the holder moves the stranded flat term away with
        // `delegate` (the permissionless one, `retireStrandedFlatTerm`, is not
        // exercised here).
        vm.prank(victim);
        (bool ok, ) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, dele2)
        );
        assertTrue(
            ok,
            "Q29/D01-tol: the holder CANNOT retire a stranded flat term once "
            "its restored end has passed -- CanNotDelegateExpiredLocks, "
            "PERMANENTLY. D01's `tolerateExpired_` is what prevents this."
        );

        IVeHemiVoteDelegation.Delegation memory post = delegation.delegation(id);
        assertFalse(
            post.slope == 0 && post.bias > 0,
            "Q29/D01-tol: the call committed but the record is STILL FLAT -- "
            "the term is stranded anyway"
        );
        emit log_named_uint("Q29/D01-tol votes at dele after the cure", delegation.getVotes(dele));
    }
}

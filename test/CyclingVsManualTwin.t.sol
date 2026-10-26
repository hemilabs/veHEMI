// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title CyclingVsManualTwinTest
/// @notice Repeated enable/disable cycling of auto-relock confers nothing over
///         a manual `increaseUnlockTime` twin, and a cycled position still dies.
///
/// @dev Three legs:
///      LEG A  Two positions, one clock, identical principal and schedule: A
///             cycles enable/disable, B calls `increaseUnlockTime`. Their ends
///             and weights must agree to the wei.
///      LEG B  No free term. A's total forward movement of `end` is strictly
///             less than `elapsed + SIX_DAYS`. Each episode moves `end` by
///             `grid(disable) - grid(enable)` and back-to-back episodes
///             telescope, so the total is `grid(last) - grid(first)`, which is
///             below `elapsed + SIX_DAYS` at every start phase. The stronger
///             `extensions <= elapsed` holds only when the start phase is not
///             later in its bucket than the finish phase, which is why the
///             same run is repeated from a sub-bucket start offset.
///      LEG C  Mortality. Stop cycling; the position decays to exactly zero
///             weight at its restored end and the flat aggregate leaves the
///             global curve.
contract CyclingVsManualTwinTest is LockedCurveTestBase {
    uint256 internal constant CYCLES = 206;
    uint256 internal constant STEP = 3 days;

    function _cycleAgainstTwin(uint256 startOffset_) internal {
        vm.warp(block.timestamp + startOffset_);
        runSeedingFlow();
        (uint256 idA, , uint256 end0A) = createLock(alice, 100 ether, 2 * 365 days);
        (uint256 idB, , uint256 end0B) = createLock(bob, 100 ether, 2 * 365 days);
        assertEq(end0A, end0B, "twins must start on the same end");

        uint256 t0 = block.timestamp;
        uint256 extensions;
        uint256 twinMoves;

        for (uint256 i = 0; i < CYCLES; ++i) {
            uint256 beforeEnd = veHemi.getLockedBalance(idA).end;

            vm.prank(alice);
            veHemi.enableAutoRelock(idA);
            vm.warp(block.timestamp + STEP);
            vm.prank(alice);
            veHemi.disableAutoRelock(idA);

            uint256 afterEnd = veHemi.getLockedBalance(idA).end;
            if (afterEnd > beforeEnd) extensions += afterEnd - beforeEnd;

            // The manual twin, on the same clock and the same schedule. A
            // request that is not a strict increase reverts
            // (`NewLockDurationNotGreater`); that is the twin declining to
            // move, not a failure. Any other revert fails the test.
            vm.prank(bob);
            try veHemi.increaseUnlockTime(idB, 2 * 365 days) {
                ++twinMoves;
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(VeHemi.NewLockDurationNotGreater.selector),
                    "the manual twin's increaseUnlockTime reverted for another reason");
            }
        }

        // The twin's end is `grid(now + 2 * 365 days)`, and a STEP is shorter
        // than a bucket, so it moves exactly once per bucket that grid enters.
        assertEq(
            twinMoves,
            ((block.timestamp + 2 * 365 days) / SIX_DAYS) - ((t0 + 2 * 365 days) / SIX_DAYS),
            "the manual twin did not move once per bucket"
        );

        uint256 endA = veHemi.getLockedBalance(idA).end;
        uint256 endB = veHemi.getLockedBalance(idB).end;

        // ---- LEG A: the twin comparison. ---------------------------------
        assertEq(endA, endB, "CYCLING BEATS MANUAL EXTENSION: ends diverge");
        assertEq(
            veHemi.balanceOfNFT(idA),
            veHemi.balanceOfNFT(idB),
            "CYCLING BEATS MANUAL EXTENSION: weights diverge"
        );

        // ---- LEG B: no free term. ----------------------------------------
        assertGt(extensions, 0, "premise: cycling moved the end forward");
        assertLt(
            extensions,
            (block.timestamp - t0) + SIX_DAYS,
            "FREE TERM: `end` moved forward by a bucket or more beyond the clock"
        );
        // And the lock is still a lock: it can never be pushed past the
        // contract's own ceiling.
        assertLe(endA, block.timestamp + MAX_TIME, "end past MAX_TIME");
    }

    /// LEG A + LEG B, starting on a SIX_DAYS boundary.
    function test_cyclingEqualsManualExtension() public {
        _cycleAgainstTwin(0);
    }

    /// LEG A + LEG B, starting 300,000 s into a bucket: a start phase at which
    /// `extensions <= elapsed` does NOT hold, so only the true bound passes.
    function test_cyclingEqualsManualExtension_subBucketStart() public {
        _cycleAgainstTwin(300_000);
    }

    /// LEG C -- a cycled position still decays to zero at its restored end.
    function test_cycledPositionStillDies() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);

        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(alice);
            veHemi.enableAutoRelock(id);
            vm.warp(block.timestamp + STEP);
            vm.prank(alice);
            veHemi.disableAutoRelock(id);
        }

        uint256 end = veHemi.getLockedBalance(id).end;
        assertGt(end, block.timestamp, "restored end must be in the future");

        // Walk to the end in bounded steps: `_checkpoint`'s catch-up is capped
        // at 300 buckets and `_walkCurve` at 255, so a single warp of four
        // years would silently truncate the curve walk rather than test it.
        while (block.timestamp < end) {
            uint256 next = block.timestamp + 200 * SIX_DAYS;
            vm.warp(next > end ? end : next);
            veHemi.checkpoint();
        }
        vm.warp(end + 1);
        veHemi.checkpoint();

        assertEq(veHemi.balanceOfNFT(id), 0, "position outlived its lock");
        assertEq(veHemi.totalVeHemiSupply(), 0, "flat aggregate outlived its lock");
    }
}

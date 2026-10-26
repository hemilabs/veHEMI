// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {AutoRelockLedgerHandler} from "./AutoRelockLedgerHandler.sol";
import {AutoRelockLedgerChecks} from "./AutoRelockLedgerChecks.sol";
import {VeHemi} from "src/VeHemi.sol";

/**
 * @title FlatPositionEndTest
 * @notice Deterministic sequences for two auto-relock laws a fuzz campaign
 *         reaches only by a rare draw: R stays a whole number of SIX_DAYS
 *         buckets across a flat extension, and a flat position's end is the
 *         pure function `grid(now) + R`, both in storage after an untimed
 *         touch (a top-up) and in `effectiveLockEnd` between touches. Each
 *         body also calls the invariant suite's own `AutoRelockLedgerChecks` laws.
 *         R = `autoRelockRemaining(id)`; grid(t) = floor(t / SIX_DAYS) * SIX_DAYS.
 */
contract FlatPositionEndTest is Test {
    AutoRelockLedgerHandler internal handler;
    AutoRelockLedgerChecks internal checks;
    VeHemi internal veHemi;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carl = makeAddr("carl");
    address internal dan = makeAddr("dan");
    address internal earl = makeAddr("earl");

    function setUp() public {
        handler = new AutoRelockLedgerHandler(admin, [alice, bob, carl, dan, earl]);
        checks = new AutoRelockLedgerChecks(handler);
        veHemi = handler.veHemi();
        handler.setActorIdx(0);
        handler.createLockedPosition(500 ether, 730 days);
        handler.setActorIdx(1);
        handler.createForfeitablePosition(300 ether, 500 days);
        handler.clearActor();
        handler.seedNow();
        handler.enableAutoRelockUnchecked(0);
    }

    function _grid(uint256 t) internal view returns (uint256) {
        return (t / handler.SIX_DAYS()) * handler.SIX_DAYS();
    }

    /// @notice R is a whole bucket count after the enable and after a flat
    ///         `increaseUnlockTime`, and the extension increases it.
    function test_remainingStaysWholeBucketsAcrossAnExtension() public {
        uint256 id = 1;
        uint256 r0 = veHemi.autoRelockRemaining(id);
        assertEq(r0 % handler.SIX_DAYS(), 0, "R is not a whole bucket count after enable");

        handler.increaseUnlockTimeFlat(0, type(uint256).max / 2);
        assertGt(handler.flatExtensions(), 0, "the flat extension did not execute");
        uint256 r1 = veHemi.autoRelockRemaining(id);
        assertEq(r1 % handler.SIX_DAYS(), 0, "increaseUnlockTime put a SUB-BUCKET remainder into R");
        assertGt(r1, r0, "the extension did not increase R");

        checks.checkRemainingIsWholeBuckets();
        checks.checkPrimitivesMatchAuthoredLedger();
        checks.checkExtendWhileFlatIsExact();
    }

    /// @notice A top-up on a flat position three buckets after the enable
    ///         re-materialises the stored end to `grid(now) + R`.
    function test_storedEndIsRematerialisedOnUntimedTouch() public {
        uint256 id = 1;
        uint64 endAtEnable = veHemi.getLockedBalance(id).end;
        uint256 r = veHemi.autoRelockRemaining(id);

        // Three buckets on, so the stored end and `grid(now) + R` differ.
        vm.warp(block.timestamp + 3 * handler.SIX_DAYS() + 12_345);

        uint256 expected = _grid(block.timestamp) + r;
        assertTrue(expected != endAtEnable, "test is vacuous: the end did not need to move");

        handler.increaseAmount(0, 50 ether);

        uint64 endAfter = veHemi.getLockedBalance(id).end;
        assertEq(uint256(endAfter), expected,
            "the stored end was NOT re-materialised on an untimed touch");

        checks.checkPrimitivesMatchAuthoredLedger();
        checks.checkEffectiveLockEndIsGridPlusR();
        checks.checkRemainingIsWholeBuckets();
    }

    /// @notice `effectiveLockEnd` tracks `grid(now) + R` between touches, with
    ///         no transaction at all (immediately after a touch the stored end
    ///         already equals it, so this warps away from the touch).
    function test_effectiveLockEndTracksWithoutATouch() public {
        uint256 id = 1;
        handler.increaseAmount(0, 50 ether);          // establish a known stored end
        uint64 stored = veHemi.getLockedBalance(id).end;

        for (uint256 k = 1; k <= 4; ++k) {
            vm.warp(block.timestamp + handler.SIX_DAYS() + 7_777);
            uint256 r = veHemi.autoRelockRemaining(id);
            uint256 expected = _grid(block.timestamp) + r;
            assertTrue(expected != uint256(stored), "test is vacuous: the pure function did not move");
            assertEq(veHemi.effectiveLockEnd(id), expected,
                "effectiveLockEnd is NOT the pure function grid(now) + R");
            checks.checkEffectiveLockEndIsGridPlusR();
        }
    }
}

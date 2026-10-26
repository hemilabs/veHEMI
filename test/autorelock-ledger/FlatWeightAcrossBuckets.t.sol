// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {AutoRelockLedgerHandler} from "./AutoRelockLedgerHandler.sol";

/**
 * @title FlatWeightAcrossBucketsTest
 * @notice A flat position's weight is wei-identical across every SIX_DAYS
 *         boundary and at arbitrary offsets inside a bucket, and so is its
 *         contribution to `totalVeHemiSupply()` (no sawtooth).
 * @dev The first body walks 240 buckets (MAX_TIME / SIX_DAYS) one at a time,
 *      with a permissionless `checkpoint()` interleaved so the aggregate is
 *      re-derived, next to a decaying control that must reach zero.
 */
contract FlatWeightAcrossBucketsTest is Test {
    address admin = makeAddr("admin");
    address[5] users = [makeAddr("u0"),makeAddr("u1"),makeAddr("u2"),makeAddr("u3"),makeAddr("u4")];

    function test_flatAcross240Buckets() public {
        AutoRelockLedgerHandler handler = new AutoRelockLedgerHandler(admin, users);
        VeHemi veHemi = handler.veHemi();
        uint256 sixDays = handler.SIX_DAYS();

        handler.setActorIdx(0); handler.createLock(1_000e18, 200 * sixDays);
        handler.setActorIdx(1); handler.createLock(500e18, 100 * sixDays); // decaying control
        handler.seedNow();
        handler.clearActor();

        handler.enableAutoRelock(0);
        uint256 flatWeight = veHemi.balanceOfNFT(1);
        assertGt(flatWeight, 0, "flat position has no weight");

        uint256 minControl = type(uint256).max;
        for (uint256 i; i < 240; ++i) {
            vm.warp(block.timestamp + sixDays);
            // Force the aggregate to walk buckets AND re-derive the head point.
            if (i % 7 == 0) veHemi.checkpoint();
            assertEq(veHemi.balanceOfNFT(1), flatWeight, "FLAT POSITION DROOPED at a SIX_DAYS boundary");
            // supply must contain the flat term in full, at every bucket
            assertGe(veHemi.totalVeHemiSupply(), flatWeight, "totalVeHemiSupply lost the flat term");
            uint256 controlWeight = veHemi.balanceOfNFT(2);
            if (controlWeight < minControl) minControl = controlWeight;
        }
        // The decaying control MUST have died - otherwise the test proves nothing
        // about flatness (a frozen clock would pass trivially).
        assertEq(minControl, 0, "NEGATIVE CONTROL: the decaying position never expired");
        // 240 buckets is exactly MAX_TIME; the flat position is still at full weight.
        assertEq(veHemi.balanceOfNFT(1), flatWeight, "flat position moved over MAX_TIME");
        assertEq(veHemi.totalVeHemiSupply(), flatWeight, "supply != the single surviving flat position");
    }

    /// @notice The mid-bucket case: flatness must hold at arbitrary offsets too,
    ///         not only on the grid.
    function test_flatAtArbitraryOffsets() public {
        AutoRelockLedgerHandler handler = new AutoRelockLedgerHandler(admin, users);
        VeHemi veHemi = handler.veHemi();
        uint256 sixDays = handler.SIX_DAYS();
        handler.setActorIdx(0); handler.createLock(777e18, 50 * sixDays);
        handler.seedNow();
        handler.clearActor();
        handler.enableAutoRelock(0);
        uint256 flatWeight = veHemi.balanceOfNFT(1);
        assertGt(flatWeight, 0, "flat position has no weight");
        uint256[8] memory offsets =
            [uint256(1), 61, 3607, 86_399, sixDays / 3, sixDays - 1, sixDays + 1, 5 * sixDays + 12345];
        for (uint256 i; i < offsets.length; ++i) {
            vm.warp(block.timestamp + offsets[i]);
            assertEq(veHemi.balanceOfNFT(1), flatWeight, "flat position drooped mid-bucket");
            assertEq(veHemi.totalVeHemiSupply(), flatWeight, "supply drooped mid-bucket");
        }
    }
}

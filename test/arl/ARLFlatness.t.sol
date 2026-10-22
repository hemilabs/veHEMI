// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {ARLHandler} from "./ARLHandler.sol";

/**
 * @title ARLFlatness
 * @notice A flat position's weight is wei-identical across every SIX_DAYS
 *         boundary and at arbitrary offsets inside a bucket, and so is its
 *         contribution to `totalVeHemiSupply()` (no sawtooth).
 * @dev The first body walks 240 buckets (MAX_TIME / SIX_DAYS) one at a time,
 *      with a permissionless `checkpoint()` interleaved so the aggregate is
 *      re-derived, next to a decaying control that must reach zero.
 */
contract ARLFlatness is Test {
    address admin = makeAddr("admin");
    address[5] users = [makeAddr("u0"),makeAddr("u1"),makeAddr("u2"),makeAddr("u3"),makeAddr("u4")];

    function test_flatAcross240Buckets() public {
        ARLHandler h = new ARLHandler(admin, users);
        VeHemi v = h.veHemi();
        uint256 SIX = h.SIX_DAYS();

        h.setActorIdx(0); h.createLock(1_000e18, 200 * SIX);
        h.setActorIdx(1); h.createLock(500e18, 100 * SIX); // decaying control
        h.seedNow();
        h.clearActor();

        h.arlEnable(0);
        uint256 w0 = v.balanceOfNFT(1);
        assertGt(w0, 0, "flat position has no weight");

        uint256 minControl = type(uint256).max;
        for (uint256 i; i < 240; ++i) {
            vm.warp(block.timestamp + SIX);
            // Force the aggregate to walk buckets AND re-derive the head point.
            if (i % 7 == 0) v.checkpoint();
            assertEq(v.balanceOfNFT(1), w0, "FLAT POSITION DROOPED at a SIX_DAYS boundary");
            // supply must contain the flat term in full, at every bucket
            assertGe(v.totalVeHemiSupply(), w0, "totalVeHemiSupply lost the flat term");
            uint256 c = v.balanceOfNFT(2);
            if (c < minControl) minControl = c;
        }
        // The decaying control MUST have died - otherwise the test proves nothing
        // about flatness (a frozen clock would pass trivially).
        assertEq(minControl, 0, "NEGATIVE CONTROL: the decaying position never expired");
        // 240 buckets is exactly MAX_TIME; the flat position is still at full weight.
        assertEq(v.balanceOfNFT(1), w0, "flat position moved over MAX_TIME");
        assertEq(v.totalVeHemiSupply(), w0, "supply != the single surviving flat position");
    }

    /// @notice The mid-bucket case: flatness must hold at arbitrary offsets too,
    ///         not only on the grid.
    function test_flatAtArbitraryOffsets() public {
        ARLHandler h = new ARLHandler(admin, users);
        VeHemi v = h.veHemi();
        uint256 SIX = h.SIX_DAYS();
        h.setActorIdx(0); h.createLock(777e18, 50 * SIX);
        h.seedNow();
        h.clearActor();
        h.arlEnable(0);
        uint256 w0 = v.balanceOfNFT(1);
        assertGt(w0, 0, "flat position has no weight");
        uint256[8] memory offs = [uint256(1), 61, 3607, 86_399, SIX / 3, SIX - 1, SIX + 1, 5 * SIX + 12345];
        for (uint256 i; i < offs.length; ++i) {
            vm.warp(block.timestamp + offs[i]);
            assertEq(v.balanceOfNFT(1), w0, "flat position drooped mid-bucket");
            assertEq(v.totalVeHemiSupply(), w0, "supply drooped mid-bucket");
        }
    }
}

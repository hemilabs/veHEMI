// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./RewardFlatLifeBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A flat position sends no transaction, so a distributor that does
///         per-bucket work pays for the whole untouched span on the first touch
///         that comes. VeHemi calls the distributor with a fixed gas ceiling
///         (`REWARD_GAS_CEILING`, 8,000,000); that ceiling must sit above the
///         cost of an honest catch-up at the longest span a flat position can
///         reach, or the settlement stalls for good.
contract RewardCatchupGasTest is RewardTwinBase {
    /// @dev Hemi's per-transaction gas cap.
    uint256 internal constant HEMI_TX_CAP = 29_930_000;
    uint256 internal constant SPAN = 240; // MAX_TIME in SIX_DAYS buckets

    /// @dev An armed position idle for 240 buckets, then touched by its owner
    ///      (`increaseAmount`, which re-books an ARMED position and so needs
    ///      the removal gas floor too) inside the Hemi per-tx limit. The
    ///      historical-weight distributor (`priceAtHistoricalWeight`: one
    ///      `balanceOfNFTAt` per bucket) must complete the whole 240-bucket
    ///      catch-up inside VeHemi's ceiling: no `RewardUpdateFailed`, 240
    ///      iterations, and every bucket credited at the flat weight.
    function test_historicalWeightCatchUpFitsRewardGasCeiling() public {
        setUpTwinOracle();
        CatchUpDistributor distributor = new CatchUpDistributor(address(X.ve), true);
        X.ve.updateRewardDistributor(IRewardDistributor(address(distributor)));

        address owner_ = address(0xFEED);
        uint256 positionIndex = spawn(true, owner_, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        vm.prank(owner_);
        X.ve.enableAutoRelock(id); // the notify bracket seeds the cursor
        uint256 flatWeight = X.ve.balanceOfNFT(id);
        uint256 enableBucket = block.timestamp / distributor.BUCKET_LENGTH();
        assertEq(distributor.cursor(id), enableBucket, "premise: cursor seeded at enable");
        assertEq(distributor.totalIterations(), 0, "premise: no catch-up yet");

        vm.warp(block.timestamp + SPAN * SIX_DAYS);
        vm.roll(block.number + SPAN * 100);
        // The global curve is kept current by other users' traffic; only this
        // position (and its distributor cursor) is idle.
        X.ve.checkpoint();

        X.hemi.mint(owner_, 1);
        vm.startPrank(owner_);
        X.hemi.approve(address(X.ve), type(uint256).max);
        vm.recordLogs();
        X.ve.increaseAmount{gas: HEMI_TX_CAP}(id, 1);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IVeHemi.RewardUpdateFailed.selector,
                "honest historical-weight catch-up exceeded the reward gas ceiling"
            );
        }
        assertEq(distributor.totalIterations(), SPAN, "catch-up did not walk every idle bucket");
        assertEq(distributor.cursor(id), enableBucket + SPAN, "cursor not advanced to now");
        assertEq(distributor.credited(id), SPAN * flatWeight, "an idle bucket was not credited at the flat weight");
    }
}

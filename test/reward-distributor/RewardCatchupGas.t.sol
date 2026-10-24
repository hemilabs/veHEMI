// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./RewardFlatLife.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A flat position sends no transaction, so a distributor that does
///         per-epoch work pays for the whole untouched span on the first touch
///         that comes. VeHemi calls the distributor with a fixed gas ceiling
///         (`REWARD_GAS_CEILING`, 8,000,000); that ceiling must sit above the
///         cost of an honest catch-up at the longest span a flat position can
///         reach, or the settlement stalls for good.
contract RewardCatchupGasTest is RewardTwinBase {
    /// @dev Hemi's per-transaction gas ceiling.
    uint256 internal constant HEMI_TX_GAS = 29_930_000;
    uint256 internal constant SPAN = 240; // MAX_TIME in SIX_DAYS buckets

    /// @dev An armed position idle for 240 buckets, then touched by its owner
    ///      (`increaseAmount`, which re-books an ARMED position and so needs
    ///      the removal gas floor too) inside the Hemi per-tx limit. The heavy
    ///      distributor (one `balanceOfNFTAt` per epoch) must complete the
    ///      whole 240-epoch catch-up inside VeHemi's ceiling: no
    ///      `RewardUpdateFailed`, 240 iterations, and every epoch credited at
    ///      the flat weight.
    function test_heavy_distributor_catchup() public {
        setUpTwinOracle();
        CatchUpDistributor cu = new CatchUpDistributor(address(X.ve), true);
        X.ve.updateRewardDistributor(IRewardDistributor(address(cu)));

        address o = address(0xFEED);
        uint256 xa = spawn(true, o, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[xa].tokenId;
        vm.prank(o);
        X.ve.enableAutoRelock(id); // the notify bracket seeds the cursor
        uint256 w = X.ve.balanceOfNFT(id);
        uint256 e0 = block.timestamp / cu.EPOCH();
        assertEq(cu.cursor(id), e0, "precondition: cursor seeded at enable");
        assertEq(cu.totalIterations(), 0, "precondition: no catch-up yet");

        vm.warp(block.timestamp + SPAN * SIX_DAYS);
        vm.roll(block.number + SPAN * 100);
        // The global curve is kept current by other users' traffic; only this
        // position (and its distributor cursor) is idle.
        X.ve.checkpoint();

        X.hemi.mint(o, 1);
        vm.startPrank(o);
        X.hemi.approve(address(X.ve), type(uint256).max);
        vm.recordLogs();
        X.ve.increaseAmount{gas: HEMI_TX_GAS}(id, 1);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IVeHemi.RewardUpdateFailed.selector,
                "honest heavy catch-up exceeded the reward gas ceiling"
            );
        }
        assertEq(cu.totalIterations(), SPAN, "catch-up did not walk every idle epoch");
        assertEq(cu.cursor(id), e0 + SPAN, "cursor not advanced to now");
        assertEq(cu.credited(id), SPAN * w, "an idle epoch was not credited at the flat weight");
    }
}

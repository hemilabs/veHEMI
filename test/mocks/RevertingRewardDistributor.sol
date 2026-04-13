// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

/// @notice Reward distributor that reverts on every updateRewards call. Used to prove
///         that VeHemi's try/catch wrapper around _updateReward keeps core operations
///         working when the reward distributor is broken.
contract RevertingRewardDistributor is IRewardDistributor {
    error AlwaysReverts();

    function updateRewards(uint256) external pure override {
        revert AlwaysReverts();
    }
}

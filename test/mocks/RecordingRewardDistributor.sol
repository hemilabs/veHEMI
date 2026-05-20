// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

/// @notice Reward distributor that records every updateRewards call. Used to prove
///         that VeHemi actually invokes the distributor when one is configured.
contract RecordingRewardDistributor is IRewardDistributor {
    uint256 public callCount;
    mapping(uint256 => uint256) public callsForToken;
    uint256 public lastTokenId;

    function updateRewards(uint256 tokenId_) external override {
        callCount += 1;
        callsForToken[tokenId_] += 1;
        lastTokenId = tokenId_;
    }
}

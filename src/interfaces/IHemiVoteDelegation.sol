// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IHemiVoteDelegation {
    struct Delegation {
        uint256 delegatee;
        uint64 firstDelegationTimestamp;
        uint64 end;
        uint128 slope;
        uint128 bias;
        uint128 fixedBias;
        uint256 amount;
    }

    /// A representation of a delegate and all its delegators at a particular timestamp
    struct DelegateCheckpoint {
        uint128 normalizedBias;
        uint128 fixedBias;
        uint128 totalAmount;
        uint64 normalizedSlope;
        uint64 timestamp;
    }

    /// Represents the total bias, slope, and Hemi amount of all accounts that expire for a specific delegate
    /// in a particular week
    struct Expiration {
        uint96 bias;
        uint96 amount;
        uint64 slope;
    }

    // Only used in memory
    struct NormalizedVeHemiLockInfo {
        uint256 bias;
        uint256 fixedBias;
        uint256 slope;
        uint256 amount;
        uint256 end;
    }

    function delegate(uint256 delegator_, uint256 delegatee_) external;

    function getVotes(uint256 tokenId_) external view returns (uint256);

    function getPastVotes(uint256 tokenId_, uint256 timestamp_) external view returns (uint256);
}

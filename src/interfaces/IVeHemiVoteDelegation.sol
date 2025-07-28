// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IVeHemiVoteDelegation {
    struct Delegation {
        address delegatee;
        uint48 end;
        uint96 bias;
        uint96 amount;
        uint64 slope;
    }

    /// A representation of a delegate and all its delegators at a particular timestamp
    struct DelegateCheckpoint {
        uint128 normalizedBias;
        uint128 fixedBias; // for v2+ use
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
        uint256 slope;
        uint256 amount;
        uint256 end;
    }

    function delegate(uint256 delegator_, address delegatee_) external;

    function delegation(uint256 tokenId_) external view returns (Delegation memory);

    function getVotes(address account_) external view returns (uint256);

    function getPastVotes(address account_, uint256 timestamp_) external view returns (uint256);
}

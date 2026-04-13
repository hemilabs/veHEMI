// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev KNOWN LIMITATION — uint64 slope fields
///      The `slope` (uint64) fields in Delegation, DelegateCheckpoint, and Expiration
///      overflow when a single position or aggregate delegation exceeds ~2.328 billion
///      HEMI (slope = amount / MAX_TIME; uint64 max ≈ 1.844e19; threshold ≈ 2.328e27 wei).
///      With 10B total supply, this caps effective delegation at ~23.3% of supply per
///      delegatee. Overflow causes a clean SafeCast revert (not silent corruption).
///      The struct slots are maximally packed (32B each) — slope cannot be widened without
///      adding a storage slot, which would corrupt existing proxy data. A future V2
///      delegation contract with wider types can be deployed and activated via
///      VeHemi.updateVoteDelegation(). See also: uint96 bias overflow at ~5.35B HEMI
///      (current era, time-dependent, secondary to slope).
interface IVeHemiVoteDelegation {
    struct Delegation {
        address delegatee;
        uint48 end;
        uint96 bias;
        uint96 amount;
        uint64 slope; // see KNOWN LIMITATION above — overflows at ~2.328B HEMI
    }

    /// A representation of a delegate and all its delegators at a particular timestamp
    struct DelegateCheckpoint {
        uint128 normalizedBias;
        uint128 fixedBias; // for v2+ use
        uint128 totalAmount;
        uint64 normalizedSlope; // see KNOWN LIMITATION above — aggregate overflow at ~2.328B HEMI per delegatee
        uint64 timestamp;
    }

    /// Represents the total bias, slope, and Hemi amount of all accounts that expire for a specific delegate
    /// in a particular SIX_DAYS bucket (YEAR/60 ≈ 6.0875 days — not a calendar week).
    struct Expiration {
        uint96 bias;
        uint96 amount;
        uint64 slope; // see KNOWN LIMITATION above
    }

    // Only used in memory
    struct NormalizedVeHemiLockInfo {
        uint256 bias;
        uint256 slope;
        uint256 amount;
        uint256 end;
    }

    /**
     * @dev Emitted when an account changes their delegate.
     */
    event DelegateChanged(
        uint256 indexed delegator,
        address indexed fromDelegatee,
        address indexed toDelegatee
    );

    /**
     * @dev Emitted when a token transfer or delegate change results in changes to a delegate's number of voting units.
     */
    event DelegateVotesChanged(address indexed delegatee, uint256 previousVotes, uint256 newVotes);

    /**
     * @dev Emitted when the trusted adapter is changed via setTrustedAdapter.
     */
    event TrustedAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    function delegate(uint256 delegator_, address delegatee_) external;

    function delegation(uint256 tokenId_) external view returns (Delegation memory);

    function getVotes(address account_) external view returns (uint256);

    function getPastVotes(address account_, uint256 timestamp_) external view returns (uint256);

    /// @notice Returns the auto-delegate address for an account. When set, new veHEMI
    ///         positions created for this account will be automatically delegated to
    ///         this address instead of self-delegating.
    function autoDelegate(address account_) external view returns (address);

    function clearAutoDelegate() external;

    function refreshVotingPower(address delegatee_) external;

    function refreshVotingPowerBatch(address[] calldata delegatees_) external;
}

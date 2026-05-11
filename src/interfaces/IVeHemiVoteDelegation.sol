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

    /**
     * @dev Emitted when an account's auto-delegate target changes via
     *      setAutoDelegate, clearAutoDelegate, or delegateAllFor (which
     *      sets it as a side effect). Indexers can reconstruct the
     *      account → auto-delegate mapping from this event stream alone.
     */
    event AutoDelegateSet(
        address indexed owner,
        address indexed previousDelegate,
        address indexed newDelegate
    );

    function delegate(uint256 delegator_, address delegatee_) external;

    function delegation(uint256 tokenId_) external view returns (Delegation memory);

    function getVotes(address account_) external view returns (uint256);

    function getPastVotes(address account_, uint256 timestamp_) external view returns (uint256);

    /// @notice Returns the auto-delegate address for an account. When set, new veHEMI
    ///         positions created for this account will be automatically delegated to
    ///         this address instead of self-delegating.
    function autoDelegate(address account_) external view returns (address);

    function clearAutoDelegate() external;

    /// @notice Set the caller's auto-delegate target without iterating their
    ///         existing positions. New positions minted to the caller after
    ///         this call will auto-delegate to `delegatee_`. Existing
    ///         positions retain their current delegations until explicitly
    ///         re-delegated (per-tokenId via `delegate`, or in bulk via the
    ///         adapter's `delegate(address)` which proxies to `delegateAllFor`).
    /// @dev Use case: users with too many positions to fit a `delegateAllFor`
    ///      call within a block can still set their auto-delegate target so
    ///      newly-minted positions go to the right place. Combine with
    ///      per-tokenId `delegate()` calls to migrate existing positions
    ///      incrementally.
    function setAutoDelegate(address delegatee_) external;

    function refreshVotingPower(address delegatee_) external;

    function refreshVotingPowerBatch(address[] calldata delegatees_) external;
}

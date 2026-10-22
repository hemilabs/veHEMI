// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev KNOWN LIMITATION — uint64 slope fields
///      The `slope` (uint64) fields in Delegation, DelegateCheckpoint, and Expiration
///      overflow when a single position or aggregate delegation exceeds ~2.328 billion
///      HEMI (slope = amount / MAX_TIME; uint64 max ≈ 1.844e19; threshold ≈ 2.328e27 wei).
///      With 10B total supply, this caps effective delegation at ~23.3% of supply per
///      delegatee. Overflow reverts `DelegationSlopeOverflow()` (a SafeCast or
///      checked-add revert only when a bucket's uint96 bias overflows first; see
///      `_calculateCheckpoint`), never silent corruption.
///      `slope` shares a FULL 32-byte slot: in `Delegation` and `Expiration` with 12 B of
///      bias and 12 B of amount, in `DelegateCheckpoint` with 16 B of `totalAmount` and
///      8 B of `timestamp` (`normalizedBias` and `fixedBias` fill its slot 0), so `slope`
///      cannot be widened without adding a storage slot, which would corrupt existing proxy
///      data. (`Delegation`'s first slot, `delegatee` and `end`, has 6 free bytes.) A future V2
///      delegation contract with wider types can be deployed and activated via
///      VeHemi.updateVoteDelegation(). See also: uint96 bias overflow at ~5.35B HEMI
///      (current era, time-dependent, secondary to slope).
interface IVeHemiVoteDelegation {
    /// @dev For an auto-relock position the record is flat: `slope == 0` and `bias` is its
    ///      constant weight; `end` is the stored lock end, not an expiry. For a decaying
    ///      position `bias` is its user point's bias normalized to time 0
    ///      (`bias + slope * timestamp` of that point).
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
        uint128 fixedBias; // aggregate constant weight of auto-relock delegators; never decays or expires
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
        /// @notice The constant (non-decaying, non-expiring) part of the delegator's
        ///         weight: its whole weight for an auto-relock position, 0 otherwise.
        uint256 fixedBias;
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


    // ─── Legacy state import ─────────────────────────────────────────────

    /// @notice Emitted when a legacy per-tokenId delegation is imported from
    ///         an older VeHemiVoteDelegation contract into this one as part
    ///         of an `updateVoteDelegation` migration.
    event LegacyDelegationImported(
        uint256 indexed tokenId, address indexed delegatee, address indexed legacy
    );

    /// @notice Emitted when a legacy `autoDelegate[owner]` value is imported.
    event LegacyAutoDelegateImported(
        address indexed owner, address indexed delegatee, address indexed legacy
    );

    /// @notice One-time flip to `true` when the migration window is sealed.
    event MigrationFinalizedEvent();

    /// @notice Replay per-tokenId delegations from a legacy VeHemiVoteDelegation
    ///         contract into this contract's storage. Owner-only (the VeHemi
    ///         owner). Idempotent. Reverts after `finalizeMigration()`.
    function importDelegationsFromLegacy(
        IVeHemiVoteDelegation legacy_, uint256[] calldata tokenIds_
    ) external;

    /// @notice Replay per-owner `autoDelegate` config from a legacy contract.
    ///         Owner-only. Idempotent. Reverts after `finalizeMigration()`.
    function importAutoDelegatesFromLegacy(
        IVeHemiVoteDelegation legacy_, address[] calldata owners_
    ) external;

    /// @notice Permanently seal the import functions. One-way latch.
    function finalizeMigration() external;

    /// @notice Whether `finalizeMigration()` has been called.
    function migrationFinalized() external view returns (bool);
}

/// @notice The surface `VeHemiVoteDelegation` added with auto-relock: checkpoint
///         paging, the booking time of each record, the upgrade-hour window and
///         the repair entry point for a stranded flat term. Declared apart from
///         `IVeHemiVoteDelegation` so that existing implementers of that
///         interface keep compiling.
interface IVeHemiVoteDelegationAutoRelock is IVeHemiVoteDelegation {
    // ─── Checkpoint paging ───────────────────────────────────────────────

    /// @notice Number of checkpoints stored for `delegatee_`. The array grows by up to two elements
    ///         per block that touches the delegatee, so the one-argument
    ///         `getDelegationCheckpoints(address)` view (declared on `VeHemiVoteDelegation`, not in
    ///         this interface), which returns it whole, can outgrow an `eth_call` gas budget for a
    ///         very deep array; read it with this view and `getDelegationCheckpointsPage` instead.
    ///         Vote reads binary-search the array and are not affected.
    function getDelegationCheckpointsLength(address delegatee_) external view returns (uint256);

    /// @notice Up to `limit_` checkpoints of `delegatee_`, starting at index `offset_` and
    ///         clamped to the end of the array; an `offset_` at or past the end returns an empty
    ///         array, so a paging loop ends on a short read.
    function getDelegationCheckpointsPage(
        address delegatee_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (DelegateCheckpoint[] memory);

    // ─── Booking time and the upgrade-hour window ────────────────────────

    /// @notice The upgrade-hour window was set to end at `until`, an hour boundary.
    ///         `viaUpgradeCall` is true when `armLegacyDatingWindow` set it inside the proxy
    ///         upgrade, false when an upgrade made without that call was closed by its first
    ///         delegation write.
    event LegacyDatingWindowArmed(uint256 until, bool viaUpgradeCall);

    /// @notice The instant from which `delegation(tokenId_)` is in effect in its delegatee's
    ///         checkpoint history: `block.timestamp + 1` of the booking transaction (not the
    ///         next hour boundary), except inside the upgrade-hour window, where it is the
    ///         window's end, an hour boundary. Zero means already in effect: never delegated,
    ///         cleared when VeHemi removed the position's delegation (withdraw, forfeit, or an
    ///         armed transfer whose move was refused; that removal itself takes effect at
    ///         `block.timestamp + 1`, or at the window's end inside the upgrade-hour window),
    ///         or booked by an earlier implementation (except a booking the replaced
    ///         hour-boundary implementation made earlier in the upgrade hour, which takes
    ///         effect at that hour's boundary). After an in-window rollback and a re-forward, a
    ///         stamp written before the rollback can outlive a rebooking or burn of that id by
    ///         the hour-boundary implementation in between (it never writes this slot); it is
    ///         exact again from the id's next booking.
    function delegationBookedAt(uint256 tokenId_) external view returns (uint64);

    /// @notice End of this proxy's upgrade-hour window, an hour boundary. While the next hour
    ///         boundary is at or before it, every delegation write is dated at that boundary and
    ///         every vote event is read there, as the replaced implementation dated them; after
    ///         it, writes are dated `block.timestamp + 1`. 0: upgraded without the arm, the window
    ///         stays open until the first delegation write closes it at the next boundary.
    ///         1: fresh deployment, no window.
    function legacyDatingUntil() external view returns (uint64);

    /// @notice True iff a delegation write made now takes effect later than
    ///         `block.timestamp + 1`, i.e. inside the upgrade-hour window. VeHemi refuses to
    ///         enable auto-relock while it is true (`VoteDelegationTransitionInProgress`).
    function legacyDatingActive() external view returns (bool);

    // ─── Auto-relock repair ──────────────────────────────────────────────

    /// @notice Permissionless repair of a stranded flat term. If `delegation(delegator_)` is flat
    ///         (`slope == 0 && bias > 0`) while VeHemi no longer has auto-relock enabled for the
    ///         position (including a burned id), it re-delegates the position to the same
    ///         delegatee, which retires the flat term and books the current decaying weight, or
    ///         nothing once the lock ends at or before the next hour boundary. Reverts
    ///         `FlatTermNotRetryable` for any other record. Use it after VeHemi's
    ///         `AutoRelockRetirementUnverified`, on the module that holds the record. A re-booking
    ///         the delegatee cannot absorb reverts `DelegationSlopeOverflow`: the owner of a live
    ///         position can re-delegate it elsewhere with `delegate`; otherwise retry later, and
    ///         at the latest once the lock has ended, when nothing is booked.
    function retireStrandedFlatTerm(uint256 delegator_) external;
}

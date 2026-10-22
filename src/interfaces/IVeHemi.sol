// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IVeHemiVoteDelegation} from "./IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "./IRewardDistributor.sol";

interface IVeHemi is IERC721Enumerable {
    // --- Structs ---
    struct Point {
        int128 bias;
        int128 slope;
        uint64 timestamp;
        uint64 blockNumber;
        uint128 amount; // user point: locked HEMI; GLOBAL point: aggregate constant weight of auto-relock positions (supply = walked bias + amount)
        uint256 fixedBias; // unused (always 0)
    }

    struct UserPoint {
        Point point;
        address owner;
    }

    struct LockedBalance {
        int128 amount;
        uint64 end;
    }

    // --- Events ---
    /// @dev `lockTime` is the position's new stored `end`; for an auto-relock position that is
    ///      not an unlock time (see `effectiveLockEnd`).
    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 lockTime,
        uint256 timestamp
    );

    event Withdraw(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Auto-relock was enabled (`enableAutoRelock` or `createLockWithAutoRelock`). The
    ///         position's weight is now the CONSTANT `slope * (remaining - SIX_DAYS/2)`, the mean
    ///         over the current SIX_DAYS bucket of the weight it would have decaying
    ///         (`slope = amount / MAX_TIME`). Reading it as `slope * remaining` overstates it by the
    ///         factor `N / (N - 1/2)`, `N = remaining / SIX_DAYS`: 1.3333x at the minimum N = 2,
    ///         1.0021x at N = 240 (MAX_TIME); the absolute error is `slope * SIX_DAYS/2` at every N.
    ///
    /// @dev An indexer must handle five auto-relock events: this one, `AutoRelockDisabled`,
    ///      `AutoRelockRefreshed`, `AutoRelockRetired` and `AutoRelockRetirementUnverified`. Each of
    ///      `AutoRelockEnabled` and `AutoRelockDisabled` is emitted BEFORE the `Checkpoint` it
    ///      describes, so a consumer that applies logs in order knows whether the position is flat
    ///      when its point lands (on enable that `Checkpoint` carries identical `oldLock` and
    ///      `newLock`: only the weight changes). Order within a transaction:
    ///      - enable: `AutoRelockEnabled`, `Checkpoint`, then the delegation module's re-booking;
    ///      - `disableAutoRelock` / `retireStaleAutoRelock`: `AutoRelockRetired` (stale retire
    ///        only), `AutoRelockDisabled`, `Checkpoint`, the re-booking, then
    ///        `AutoRelockRetirementUnverified` if raised;
    ///      - transfer to another account: `AutoRelockDisabled`, `Checkpoint`, `Transfer`, the
    ///        move to the recipient's delegatee, `AutoRelockRetirementUnverified` if raised, and a
    ///        final `Checkpoint`;
    ///      - `refreshAutoRelock`: `AutoRelockRefreshed` only.
    ///      `forfeit` of an auto-relock position emits none of them: its `Checkpoint` with a zeroed
    ///      `newLock` and the burn end the position.
    ///
    /// @param tokenId The position that went flat.
    /// @param remaining R, the frozen remaining lock duration in seconds (a whole number of
    ///        SIX_DAYS buckets). R can later grow through `increaseUnlockTime` with no
    ///        auto-relock event; read `autoRelockRemaining`.
    event AutoRelockEnabled(uint256 indexed tokenId, uint64 remaining);

    /// @notice Auto-relock was disabled (`disableAutoRelock`, `retireStaleAutoRelock`, or a
    ///         transfer to another account): the weight decays again, toward `restoredEnd`.
    /// @dev Emitted before the `Checkpoint` it describes; see `AutoRelockEnabled` for the order.
    /// @param tokenId The position that resumed decaying.
    /// @param restoredEnd The new `getLockedBalance(tokenId).end`: the start of the current
    ///        SIX_DAYS bucket plus R, an absolute timestamp on the SIX_DAYS grid.
    event AutoRelockDisabled(uint256 indexed tokenId, uint64 restoredEnd);

    /// @notice The owner called `refreshAutoRelock`. `refreshedAt` is the new
    ///         `autoRelockRefreshedAt(tokenId)`; `retireStaleAutoRelock` stays closed until
    ///         `refreshedAt + STALE_FLAT_BUCKETS * SIX_DAYS`. (`AutoRelockEnabled` starts the same
    ///         clock at its block's timestamp.)
    event AutoRelockRefreshed(uint256 indexed tokenId, uint64 refreshedAt);

    /// @notice A stale auto-relock position was ended through `retireStaleAutoRelock`
    ///         (permissionless; the owner may also call it). `AutoRelockDisabled` with the
    ///         restored end follows in the same transaction, after the reward-distributor
    ///         notification, so a state-reconstructing indexer needs no new handler; this event
    ///         only tells a stale retire from a `disableAutoRelock`.
    event AutoRelockRetired(uint256 indexed tokenId, address indexed caller);

    /// @notice After auto-relock ended, VeHemi could not confirm that the delegation module
    ///         stopped booking the position's constant weight: a delegatee may still hold it as a
    ///         flat term that never expires, i.e. votes that no locked HEMI backs. The state change
    ///         that raised it is committed. Raised when:
    ///         - after `disableAutoRelock` or `retireStaleAutoRelock` (whether or not the module
    ///           accepted the re-delegation), or after a transfer to another account whose move the
    ///           module accepted, `delegation(tokenId)` reads back flat (`slope == 0 && bias > 0`)
    ///           or cannot be read;
    ///         - on a transfer to another account, the module refused both the move to the
    ///           recipient's delegatee and the fallback removal (two `DelegationUpdateFailed`).
    ///         It is conservative: behind a broken module it can fire for a record that is already
    ///         empty or decaying.
    ///         Response: fix the cause of any refusal (`DelegationUpdateFailedReason`) first. Then,
    ///         if `delegation(tokenId)` is flat and `isAutoRelockEnabled(tokenId)` is false, call
    ///         `retireStrandedFlatTerm(tokenId)` (permissionless) on the module that holds the
    ///         record; after a refused transfer it re-books the weight at the previous owner's
    ///         delegatee until the new owner calls `delegate`. If it reverts
    ///         `DelegationSlopeOverflow`, the delegatee cannot absorb the restored slope: the owner
    ///         of a live position cures it at once with the module's
    ///         `delegate(tokenId, <a delegatee with room>)`; otherwise retry later (each retry nets
    ///         the delegatee's expirations itself) and, at the latest, after the position's
    ///         restored end, when the re-booking books nothing.
    /// @dev    A position armed while this VeHemi runs over a delegation module without the
    ///         upgrade-hour window (a split upgrade or a rollback of only one of the two contracts)
    ///         is booked by that module as DECAYING weight with an expiry bucket although its
    ///         shape is flat. Once the current module is back, every move of that record either
    ///         reverts or takes its weight out of the delegatee's other flat terms, the last of
    ///         which can then never be removed (`retireStrandedFlatTerm` reverts too): permanent
    ///         votes with no locked HEMI behind them. Upgrade VeHemi and the delegation module
    ///         together, in one transaction.
    event AutoRelockRetirementUnverified(uint256 indexed tokenId);

    event Lock(
        address indexed provider,
        address indexed account,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 start,
        uint256 lockTime,
        uint256 extraData,
        bool transferable,
        bool forfeitable
    );
    event Checkpoint(uint256 epoch, uint256 tokenId, LockedBalance oldLock, LockedBalance newLock);

    event VoteDelegationUpdated(
        IVeHemiVoteDelegation indexed oldVoteDelegation,
        IVeHemiVoteDelegation indexed newVoteDelegation
    );

    event RewardDistributorUpdated(
        IRewardDistributor indexed oldRewardDistributor,
        IRewardDistributor indexed newRewardDistributor
    );

    event ForfeitAdminUpdated(address indexed oldForfeitAdmin, address indexed newForfeitAdmin);

    // --- V2 Events ---
    event LockedSeedingFinalized(uint256 epoch);
    event RewardUpdateFailed(uint256 indexed tokenId);
    event DelegationUpdateFailed(uint256 indexed delegator);

    /// @notice Emitted with `DelegationUpdateFailed` when VeHemi swallowed a revert of the
    ///         delegation module's `delegate`: `reason` is the first four bytes of the revert data
    ///         (the custom-error selector, e.g. `CheckpointLayoutViolated`), so failure causes can
    ///         be told apart on chain. It is zero when the callee reverted with no data, as an
    ///         out-of-gas does. A starved call is refused with `DelegationCallStarved` only when the
    ///         module is called directly; behind a delegatecall proxy, as the module is deployed, an
    ///         out-of-gas can commit with reason zero, as an under-count of an UNARMED position's
    ///         own weight. VeHemi checks its removal gas floor (8,176,984 gas) before the
    ///         re-delegation of a delegated armed position by `enableAutoRelock`,
    ///         `createLockWithAutoRelock`, `increaseAmount` and `increaseUnlockTime`, before the
    ///         re-delegation that ends auto-relock, and before an armed transfer's fallback
    ///         removal, so a starved one reverts `DelegationCallStarved` instead. An owner's
    ///         self-transfer of an armed position and an armed transfer's move are not
    ///         floor-checked (a starved one is a refusal that leaves the record as it was; a
    ///         refused move meets the floor at the fallback removal), nor are the `withdraw` and
    ///         `forfeit` removals (a starved one leaves too little gas to finish the burn, and
    ///         the call reverts).
    /// @param delegator The position whose delegation update failed
    /// @param reason The callee's revert selector, or `0x00000000`
    event DelegationUpdateFailedReason(uint256 indexed delegator, bytes4 reason);

    /// @notice VeHemi did not forward this token's delegation update to the delegation module:
    ///         nothing was written there and nothing failed. Emitted for an UNARMED position (an
    ///         ordinary transfer or `increaseAmount`) whose lock ends at or before the next hour
    ///         boundary, which the delegation module refuses (`CanNotDelegateExpiredLocks`) unless
    ///         the stored record is a stranded flat term (see `AutoRelockRetirementUnverified`;
    ///         `retireStrandedFlatTerm` still repairs it): in the last `((end - 1) mod 3600) + 1`
    ///         seconds of the lock (360 to 3,600 s, as every `end` is on the SIX_DAYS grid), and at
    ///         any time after `end` (for example a transfer of an expired, not yet withdrawn
    ///         position).
    /// @dev    The escrow has taken the deposit or moved the NFT, but the delegatee's booked weight
    ///         has NOT moved, and the record still names the PREVIOUS delegatee: every later
    ///         re-booking of the position (`increaseUnlockTime`, then `increaseAmount`,
    ///         `enableAutoRelock`, `disableAutoRelock` or `retireStaleAutoRelock`) books its weight
    ///         at that delegatee, constant while auto-relock is on. The new owner cannot move the
    ///         weight with `delegate()` while the lock ends at or before the next hour boundary
    ///         (the delegation module refuses it with `CanNotDelegateExpiredLocks`, the refusal
    ///         this event surfaces, unless the record is a stranded flat term, which that call
    ///         retires, booking nothing); extending the lock with `increaseUnlockTime` first
    ///         re-books the weight to the PREVIOUS delegatee, after which the new owner must call
    ///         `delegate()` to take it back. A position transferred after `end` has no weight to
    ///         recover.
    event DelegationUpdateSkipped(uint256 indexed delegator);
    /// @notice Emitted by `markSeedingStarted` once the seeding window opens.
    ///         `seedingTargetId` is the exclusive upper bound for `seedBatch`.
    ///         The per-batch accumulator (`_seedingProgress`) is internal so
    ///         operators monitoring progress mid-flow should probe its storage
    ///         slots directly (slots 23-26; see VeHemiStorageV2 layout block).
    ///         `finalizeSeeding` emits the terminating `LockedSeedingFinalized`.
    event SeedingStarted(uint256 seedingTargetId);

    // --- Errors ---
    // Declared in VeHemi.sol (not here) to avoid Solidity duplicate-identifier
    // conflicts when both IVeHemi and VeHemi are imported in the same compilation unit.
    // Errors are included in VeHemi's ABI and can be decoded from revert data.
    //
    // AddressIsNull, AmountIsZero, AmountTooSmall, ForfeitWindowExpired,
    // InvalidConfiguration, LockDurationTooLong, LockDurationTooShort, LockExpired,
    // LockNotExpired, NewLockDurationNotGreater, NoExistingLock, NotForfeitAdmin,
    // NotForfeitable, NotOwner, NotTransferable, OwnerIsZero,
    // SeedingAlreadyFinalized, SeedingAlreadyStarted, SeedingNotStarted,
    // SeedingInProgress, SeedingIncomplete, AutoRelockAlreadyEnabled,
    // AutoRelockNotEnabled, AutoRelockDurationTooShort, AutoRelockNotStale,
    // VoteDelegationTransitionInProgress, EndBelowTransferableAfter,
    // DelegationCallStarved, SeedingNotFinalized, VoteDelegationHasNoCode,
    // DelegationSlopeOverflow

    // --- External/Public Functions ---
    function HEMI() external view returns (IERC20);
    function initialize(address owner) external;
    /// @notice Writes the global point up to now; permissionless. Every lock change, transfer
    ///         and withdrawal first catches the global point up one SIX_DAYS bucket at a time (at
    ///         most 300 buckets per call). After hundreds of buckets with no such call, that
    ///         catch-up no longer fits in a transaction and all of them, `withdraw` included,
    ///         revert out of gas until an upgrade; calling `checkpoint()` periodically while the
    ///         contract is otherwise idle prevents it. Calls that book or retire an auto-relock
    ///         term also need about 8.2 million gas left after the catch-up, so they hit the block
    ///         gas limit sooner, after roughly 135 to 240 idle buckets for a typical call, fewer
    ///         the more curves still carry slope (plan for about 135, roughly 2.2 years, on the
    ///         Hemi deployment, where each idle bucket costs about 150,000 gas; a
    ///         `createLockWithAutoRelock` that needs 17 million fits only about 85); calling
    ///         `checkpoint()` first restores them while `checkpoint()` itself still fits
    ///         (roughly 200 to 300 idle buckets).
    function checkpoint() external;
    function createLock(uint256 amount, uint256 lockDuration) external returns (uint256 tokenId);
    function createLockFor(
        uint256 amount,
        uint256 lockDuration,
        address account,
        bool transferable,
        bool forfeitable
    ) external returns (uint256 tokenId);
    /// @notice Creates a lock for the caller with auto-relock enabled in the same transaction:
    ///         `createLockFor(amount, lockDuration, msg.sender, transferable, forfeitable)`
    ///         followed by the owner's `enableAutoRelock(tokenId)`, with the same preconditions; a
    ///         failing one, including `SeedingNotFinalized` and
    ///         `VoteDelegationTransitionInProgress`, reverts the whole mint. Always mints to
    ///         `msg.sender`. Needs a gas LIMIT of about 9.2 million while no reward distributor is
    ///         installed (the removal-floor requirement described on `enableAutoRelock` plus the
    ///         mint and first booking before it), more, up to about 17 million, when the owner
    ///         already holds many positions or the first booking goes to a delegatee not
    ///         checkpointed for months (see `VeHemi.createLockWithAutoRelock`). Under a reward
    ///         distributor that spends more than about 6.8 million gas per `updateRewards` call
    ///         (less for an owner with many positions) it cannot fit in a block; use `createLock`,
    ///         then `enableAutoRelock`.
    function createLockWithAutoRelock(
        uint256 amount,
        uint256 lockDuration,
        bool transferable,
        bool forfeitable
    ) external returns (uint256 tokenId);
    /// @notice Adds `amount` HEMI to the caller's lock (owner only, else `NotOwner`). Reverts
    ///         `LockExpired` after `end` unless auto-relock is enabled. On an auto-relock position
    ///         the constant weight is recomputed from the new amount and `end` is set to
    ///         `effectiveLockEnd`; that case needs the gas limit described on `enableAutoRelock`.
    function increaseAmount(uint256 tokenId, uint256 amount) external;

    /// @notice R, the frozen remaining lock duration of an auto-relock position, in SECONDS (a
    ///         whole number of SIX_DAYS buckets, e.g. 63,115,200 s = 120 buckets); 0 when
    ///         auto-relock is disabled.
    /// @dev Off-chain consumers that only need "is this position auto-relocking?" should use
    ///      `isAutoRelockEnabled`, and those that need "when does it unlock?" `effectiveLockEnd`,
    ///      so that they do not depend on R's encoding.
    function autoRelockRemaining(uint256 tokenId) external view returns (uint64);

    /// @notice True while auto-relock is enabled: the position's weight is constant and it is
    ///         alive whatever `getLockedBalance(tokenId).end` says.
    /// @dev The flat-liveness predicate for off-chain consumers, equal to
    ///      `autoRelockRemaining(tokenId) != 0`. `VeHemiVoteDelegation` reads that expression
    ///      directly, so a change to R's encoding must change that module too.
    function isAutoRelockEnabled(uint256 tokenId) external view returns (bool);

    /// @notice The unlock time an integrator should read. Equals
    ///         `getLockedBalance(tokenId).end` when auto-relock is off; when it is on, the end
    ///         `disableAutoRelock` would restore in this block (the start of the current SIX_DAYS
    ///         bucket plus R), which moves forward with every bucket until auto-relock is disabled.
    function effectiveLockEnd(uint256 tokenId) external view returns (uint256);

    /// @notice Enable auto-relock (owner only). The remaining lock duration is frozen at R, the
    ///         whole SIX_DAYS buckets from the start of the current bucket to `end` (at least two,
    ///         else `AutoRelockDurationTooShort`), and the weight becomes the constant
    ///         `slope * (R - SIX_DAYS/2)`, up to `slope * SIX_DAYS / 2` above or below the current
    ///         decaying weight depending on where in the bucket the call lands. The unlock time
    ///         then moves forward with time (`effectiveLockEnd`) until auto-relock is disabled.
    ///         While it is enabled: `withdraw` reverts; a transfer to another account disables it
    ///         inside the transfer; and the owner MUST call `refreshAutoRelock` at least every
    ///         `STALE_FLAT_BUCKETS * SIX_DAYS` (365.25 days), after which anyone may call
    ///         `retireStaleAutoRelock`. Reverts `VoteDelegationTransitionInProgress` during the
    ///         delegation module's upgrade-hour window (`legacyDatingActive`), and
    ///         `SeedingNotFinalized` for a still non-transferable position before seeding is
    ///         finalized. Gas: when the position is delegated, needs a gas LIMIT of about 8.8
    ///         million while no reward distributor is installed (8,176,984 must remain when the
    ///         delegation module is called, on top of what the call spends before it,
    ///         reward-distributor notifications included), far above the gas it uses. A lower limit
    ///         reverts `DelegationCallStarved`, so an `eth_estimateGas` of a direct call accounts
    ///         for it; a caller that catches reverts must forward that gas explicitly.
    /// @dev `autoRelockRemaining` (R) is written only by `enableAutoRelock` and
    ///      `createLockWithAutoRelock` (set); `disableAutoRelock`, `retireStaleAutoRelock` and a
    ///      transfer to another account (cleared, with `AutoRelockDisabled`); `increaseUnlockTime`
    ///      (raised while enabled, no event); and the burn in `withdraw` and `forfeit` (cleared).
    ///      `withdraw` refuses an enabled position, so its clear is a no-op. `forfeit` has no
    ///      auto-relock guard: the forfeit admin clears a live R with no auto-relock event (its
    ///      `Checkpoint` with a zeroed `newLock` and the burn announce it). A guard on auto-relock
    ///      state must be reviewed on every one of these paths.
    function enableAutoRelock(uint256 tokenId) external;

    /// @notice Disable auto-relock (owner only): `end` becomes `effectiveLockEnd` (the start of
    ///         the current SIX_DAYS bucket plus R) and the weight decays from there; the delegation
    ///         module re-books the position as decaying at its current delegatee. Reverts
    ///         `AutoRelockNotEnabled`, and `DelegationSlopeOverflow` (re-raised from the module)
    ///         when that delegatee cannot absorb the restored slope: delegate the position
    ///         elsewhere first. Any other refusal by the module is swallowed
    ///         (`DelegationUpdateFailed`) and announced by `AutoRelockRetirementUnverified`. Gas:
    ///         when the position is delegated, needs a gas LIMIT of about 8.8 million while no
    ///         reward distributor is installed (8,176,984 must remain when the delegation module is
    ///         called, on top of what the call spends before it, reward-distributor notifications
    ///         included), far above the gas it uses. A lower limit reverts `DelegationCallStarved`,
    ///         so an `eth_estimateGas` of a direct call accounts for it; a caller that catches
    ///         reverts must forward that gas explicitly.
    function disableAutoRelock(uint256 tokenId) external;
    /// @notice Owner heartbeat for an auto-relock position: sets `autoRelockRefreshedAt` to now,
    ///         which keeps `retireStaleAutoRelock` closed for another
    ///         `STALE_FLAT_BUCKETS * SIX_DAYS` (365.25 days). Call it at least that often while
    ///         auto-relock is enabled. Changes no weight and calls no other contract. Reverts
    ///         `NotOwner`, `AutoRelockNotEnabled`.
    function refreshAutoRelock(uint256 tokenId) external;
    /// @notice Permissionless: ends auto-relock on a position whose owner has not refreshed it for
    ///         `STALE_FLAT_BUCKETS * SIX_DAYS` (from `autoRelockStaleAt(tokenId)` on). The position
    ///         is disarmed exactly as by `disableAutoRelock` (emitting `AutoRelockRetired`, then
    ///         `AutoRelockDisabled`), except that a refusal by the delegation module, including
    ///         `DelegationSlopeOverflow`, is swallowed and announced by
    ///         `AutoRelockRetirementUnverified`. Reverts `AutoRelockNotEnabled`,
    ///         `AutoRelockNotStale`. Gas: when the position is delegated, needs a gas LIMIT of
    ///         about 8.8 million while no reward distributor is installed (8,176,984 must remain
    ///         when the delegation module is called, on top of what the call spends before it,
    ///         reward-distributor notifications included), far above the gas it uses. A lower limit
    ///         reverts `DelegationCallStarved`, so an `eth_estimateGas` of a direct call accounts
    ///         for it; a caller that catches reverts must forward that gas explicitly.
    function retireStaleAutoRelock(uint256 tokenId) external;
    /// @notice The time from which `retireStaleAutoRelock(tokenId)` is open:
    ///         `autoRelockRefreshedAt(tokenId) + STALE_FLAT_BUCKETS * SIX_DAYS`.
    /// @dev Reverts `AutoRelockNotEnabled()` for an unarmed, burned or nonexistent id; batch
    ///      readers should gate on `isAutoRelockEnabled` or allow failure.
    function autoRelockStaleAt(uint256 tokenId) external view returns (uint256);
    /// @notice The last owner heartbeat of an auto-relock position: the time of
    ///         `enableAutoRelock` / `createLockWithAutoRelock` or of the latest
    ///         `refreshAutoRelock`; 0 while auto-relock is disabled.
    function autoRelockRefreshedAt(uint256 tokenId) external view returns (uint64);
    /// @notice The abandonment horizon in SIX_DAYS buckets: 60, i.e. 365.25 days.
    function STALE_FLAT_BUCKETS() external view returns (uint256);
    /// @notice One bucket of the slope-change grid: `YEAR / 60` = 525,960 s (about 6.09 days).
    ///         Every lock `end` and every R is a multiple of it.
    function SIX_DAYS() external view returns (uint256);
    /// @notice Extends the caller's lock to `block.timestamp + lockDuration`, rounded down to the
    ///         SIX_DAYS grid and at most four years ahead (owner only). On an auto-relock position
    ///         it raises R instead: the new unlock time must be later than `effectiveLockEnd`, R
    ///         becomes the new unlock time minus the start of the current bucket, and no
    ///         auto-relock event is emitted (read `autoRelockRemaining`); that case needs the gas
    ///         limit described on `enableAutoRelock`.
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;
    /// @notice Withdraws the HEMI of an expired lock to the owner and burns the NFT. Reverts
    ///         `LockNotExpired` before `end` and, whatever `getLockedBalance(tokenId).end` says,
    ///         while auto-relock is enabled: call `disableAutoRelock` and wait for the restored end.
    function withdraw(uint256 tokenId) external;
    function forfeit(uint256 tokenId) external;
    /// @notice The position's user point at `epoch`. For an auto-relock position the user point
    ///         has `slope == 0` and a constant `bias`; until `transferableAfter` the position still
    ///         contributes `amount / MAX_TIME * (transferableAfter - t)` to the non-transferable
    ///         subcurve (and, if forfeitable, to the forfeitable one).
    function getUserPoint(uint256 tokenId, uint256 epoch) external view returns (UserPoint memory);
    function getGlobalPoint(uint256 epoch) external view returns (Point memory);
    /// @notice Locked amount and stored end. While `isAutoRelockEnabled(tokenId)`, `end` is NOT
    ///         the unlock time and may lie in the past (`withdraw` reverts); read
    ///         `effectiveLockEnd`. A transfer to another account disables auto-relock inside the
    ///         transfer and rewrites `end` and the weight, so the recipient holds a decaying
    ///         position.
    function getLockedBalance(uint256 tokenId) external view returns (LockedBalance memory);
    function isTransferable(uint256 tokenId) external view returns (bool);
    function totalLocked() external view returns (uint256);
    function epoch() external view returns (uint256);
    function userPointEpoch(uint256 tokenId) external view returns (uint256);
    function nextTokenId() external view returns (uint256);
    function provider(uint256 tokenId) external view returns (address);
    function transferableAfter(uint256 tokenId) external view returns (uint256);
    function forfeitable(uint256 tokenId) external view returns (bool);
    function forfeitAdmin() external view returns (address);
    function slopeChanges(uint256 timestamp) external view returns (int128);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);
    function balanceAndOwnerOfNFTAt(
        uint256 tokenId,
        uint256 timestamp
    ) external view returns (uint256, address);
    function totalVeHemiSupply() external view returns (uint256);
    function totalVeHemiSupplyAt(uint256 timestamp_) external view returns (uint256);

    // --- V2 Locked + Forfeitable Curve Functions ---
    function markSeedingStarted() external;
    function seedBatch(uint256 maxIterations) external;
    function finalizeSeeding() external;
    function seedingStarted() external view returns (bool);
    function seedingStartedAt() external view returns (uint64);
    function seedingTargetId() external view returns (uint256);
    /// @notice Last token ID processed by `seedBatch`. Off-chain seeding drivers
    ///         poll this to detect cursor completion without depending on the
    ///         private `_seedingProgress` storage slot index.
    function seedingCursor() external view returns (uint256);
    function nonTransferableTotalVeHemiSupply() external view returns (uint256);
    function nonTransferableTotalVeHemiSupplyAt(uint256 timestamp) external view returns (uint256);
    function forfeitableTotalVeHemiSupply() external view returns (uint256);
    function forfeitableTotalVeHemiSupplyAt(uint256 timestamp) external view returns (uint256);
    function supplyBreakdown() external view returns (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable);
    // lockedSeedingFinalized(), lockedSlopeChanges(uint256), and forfeitableSlopeChanges(uint256)
    // are exposed as public state variables via VeHemiStorageV2 (auto-generated getters).
}

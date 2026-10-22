// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IVeHemiVoteDelegation, IVeHemiVoteDelegationAutoRelock} from "./interfaces/IVeHemiVoteDelegation.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {VeHemiStorageV2} from "./storage/VeHemiStorageV2.sol";
import {VeHemiStorageV3} from "./storage/VeHemiStorageV3.sol";
import {VeHemiCurveLib} from "./lib/VeHemiCurveLib.sol";
import {VeHemiSupplyLib} from "./lib/VeHemiSupplyLib.sol";
import {VeHemiTime} from "./lib/VeHemiTime.sol";

/**
 * @title VeHemi
 * @notice Vesting and yield system based on Curve's veCRV and AERO voting escrow mechanism. Users lock HEMI for up to 4 years.
 * @dev The contract maintains a global curve and two parallel subcurves
 *      (locked and forfeitable) tracking non-transferable and forfeitable
 *      stake weight. The subcurves are gated behind `lockedSeedingFinalized`,
 *      a one-way latch:
 *
 *        - `lockedSeedingFinalized == false`: `_checkpoint` skips all
 *          subcurve accumulation. The global curve behaves identically with
 *          or without the latch flipped.
 *        - `markSeedingStarted` + repeated `seedBatch(maxIterations)` +
 *          `finalizeSeeding` performs the on-chain enumeration that
 *          materializes the locked + forfeitable `LockedPoint`s for all
 *          existing non-transferable positions, then flips the latch to
 *          true. There is no un-finalize path; a position missed at
 *          seeding time permanently understates the locked subcurve with
 *          no on-chain recovery.
 *        - `lockedSeedingFinalized == true`: subcurve logic is live; every
 *          `_checkpoint` updates the locked and forfeitable curves in
 *          parallel with the global one.
 *
 *      Checkpoint math is strictly additive: the global curve produces
 *      identical values whether or not the latch is flipped. Only the
 *      subcurve reads (`supplyBreakdown`, `nonTransferableTotalVeHemiSupply`,
 *      `forfeitableTotalVeHemiSupply`) depend on seeding having run.
 *
 *      Behavior notes:
 *        - `createLock` / `createLockFor` / `createLockWithAutoRelock` reject amounts below
 *          `MIN_LOCK_AMOUNT` (10 HEMI) with `AmountTooSmall`.
 *        - `createLockFor` reverts `InvalidConfiguration` if both
 *          `transferable_` and `forfeitable_` are true (mutually exclusive).
 *        - `forfeit` is bounded by `transferableAfter` rather than
 *          `lock.end`: once a position becomes transferable, the forfeit
 *          window closes (reverts `ForfeitWindowExpired`).
 *        - Between `markSeedingStarted()` and `finalizeSeeding()` (a
 *          multi-block window: owner opens with `markSeedingStarted`,
 *          anyone drives `seedBatch` until the cursor reaches
 *          `seedingTargetId - 1`, anyone calls `finalizeSeeding`),
 *          `_createLock` for non-transferable positions, `forfeit`, and
 *          `increaseAmount` / `increaseUnlockTime` on non-transferable
 *          positions all revert with `SeedingInProgress`. Transferable
 *          positions are unaffected. Operators MUST complete the flow
 *          inside one SIX_DAYS bucket: every `subEnd` is a multiple of
 *          `SIX_DAYS`, so finalize stays ahead of every seeded position's
 *          `subEnd` whenever the window does not cross a bucket boundary
 *          (see `finalizeSeeding` NatSpec).
 *        - Auto-relock (`enableAutoRelock`, `createLockWithAutoRelock`)
 *          freezes a position's remaining term R (whole SIX_DAYS buckets);
 *          while it is on, the weight is the constant
 *          `slope * (R - SIX_DAYS/2)`, `withdraw` reverts, the owner must
 *          send the `refreshAutoRelock` heartbeat at least every
 *          `STALE_FLAT_BUCKETS` buckets (else anyone may
 *          `retireStaleAutoRelock`), and a transfer to another account
 *          disarms it. Calls that book or retire a delegated position's flat
 *          vote term (arming, `disableAutoRelock`, `retireStaleAutoRelock`,
 *          top-ups or extensions while armed, and the fallback removal of an
 *          armed transfer whose move was refused) need a gas LIMIT of about
 *          8.8 million (about 9.2 million for `createLockWithAutoRelock`, up
 *          to about 17 million when its owner already holds many positions or
 *          its delegatee was not checkpointed for months; the fallback
 *          removal also needs what the refused move spent) while no reward
 *          distributor is installed, far above the gas they use: 8,176,984
 *          gas must remain at the re-delegation, on top of what the call
 *          spends before it, reward-distributor notifications included (see
 *          `REMOVAL_GAS_FLOOR`).
 *        - Owner-only per-position operations (`increaseAmount`,
 *          `increaseUnlockTime`, `withdraw`, `enableAutoRelock`,
 *          `disableAutoRelock`, `refreshAutoRelock`) honour `ownerOf` only,
 *          not ERC-721 approvals (see `_requireTokenOwner`).
 *        - `transferFrom` and both `safeTransferFrom` overloads carry the
 *          `nonReentrant` guard (the 3-argument overload through the
 *          4-argument one it forwards to), and the guard is held ACROSS
 *          `onERC721Received`: composed contracts that re-enter a guarded
 *          VeHemi function from it revert with
 *          `ReentrancyGuardReentrantCall`. The guarantee is not total. Of the
 *          19 state-changing entry points open to holders and other callers
 *          (owner-only, pending-owner and initializer functions aside), 15
 *          carry the guard and 4 are ENTERED, not refused, from inside a
 *          held guard: `approve` and `setApprovalForAll` (VeHemi overrides
 *          neither, deliberately -- see `_requireTokenOwner`), and
 *          `seedBatch` and `finalizeSeeding` while the seeding latches are
 *          open, so `lockedSeedingFinalized` -- a ONE-WAY LATCH -- can be
 *          flipped from inside another call's reentrancy guard. Pure
 *          ERC-721 receivers and callbacks that only read VeHemi state are
 *          unaffected either way.
 */
contract VeHemi is
    ERC721EnumerableUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    VeHemiStorageV3
{
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using SafeERC20 for IERC20;

    IERC20 public immutable HEMI;

    // --- Constants ---
    uint256 private constant YEAR = VeHemiTime.YEAR;
    /// @dev See `VeHemiTime` — shared with the DELEGATECALL libraries so the
    ///      SIX_DAYS slope-change grid cannot diverge between them. One bucket
    ///      is `YEAR / 60` = 525,960 s; MAX_TIME is exactly 240 buckets. Public
    ///      so companion contracts (a reward distributor, for instance) can
    ///      check their epoch against this grid.
    uint256 public constant SIX_DAYS = VeHemiTime.SIX_DAYS;
    uint256 private constant MAX_TIME = VeHemiTime.MAX_TIME;

    /// @notice The abandonment horizon, in SIX_DAYS buckets (60 buckets =
    ///         365.25 days): an auto-relock position whose owner has sent no
    ///         `refreshAutoRelock` heartbeat for this long, counted from the
    ///         arm or the last refresh, may be retired by anyone
    ///         (`retireStaleAutoRelock`).
    uint256 public constant STALE_FLAT_BUCKETS = 60;
    uint256 private constant MULTIPLIER = VeHemiTime.MULTIPLIER;
    uint256 private constant MIN_LOCK_AMOUNT = VeHemiTime.MIN_LOCK_AMOUNT;
    string public constant version = "3.0.0";
    uint8 public constant decimals = 18;

    // --- Errors ---
    error AddressIsNull();
    /// @notice `updateVoteDelegation` was given an address with no code.
    error VoteDelegationHasNoCode();
    error AmountIsZero();
    error AmountTooSmall();
    error LockExpired();
    error LockNotExpired();
    error LockDurationTooShort();
    error LockDurationTooLong();
    error NoExistingLock();
    error NotOwner();
    error NewLockDurationNotGreater();
    error NotForfeitable();
    error NotForfeitAdmin();
    error OwnerIsZero();
    error NotTransferable();
    error SeedingAlreadyFinalized();
    error SeedingAlreadyStarted();
    error SeedingNotStarted();
    error SeedingInProgress();
    error SeedingIncomplete(uint256 lastProcessedId, uint256 expectedEnd);
    /// @notice Auto-relock cannot be armed (`enableAutoRelock`, or
    ///         `createLockWithAutoRelock` through `_createLock`) before
    ///         `lockedSeedingFinalized` on a position the seeding scan will
    ///         enrol, i.e. one with `transferableAfter[id] > block.timestamp`.
    /// @dev The seeding guard. Its predicate is the exact inverse of
    ///      `VeHemi.sol::seedBatch`'s skip: positions the scan skips are never
    ///      subcurve members (`VeHemiCurveLib.sol::checkpoint`) and are not
    ///      refused. It is defence in depth: an armed member's subcurve
    ///      contribution is `slope * (transferableAfter - now)`, exactly what
    ///      `seedBatch` enrols for it (`end >= transferableAfter` for life), so
    ///      a pre-seed arm does not desynchronise a subcurve with the current
    ///      curve library; the guard keeps that from depending on how the
    ///      library treats armed positions. Mainnet's latch is already true, so
    ///      this guards a future re-seeding window.
    error SeedingNotFinalized();
    error ForfeitWindowExpired();
    error InvalidConfiguration();
    error AutoRelockAlreadyEnabled();
    error AutoRelockNotEnabled();
    error AutoRelockDurationTooShort();
    /// @notice `retireStaleAutoRelock` was called before
    ///         `autoRelockStaleAt(tokenId)`.
    error AutoRelockNotStale();
    /// @notice Auto-relock cannot be armed while the vote-delegation module
    ///         dates writes at the next hour boundary
    ///         (`VeHemiVoteDelegation.sol::legacyDatingActive`): during its
    ///         upgrade-hour window, or, after an upgrade that did not arm the
    ///         window, until the hour boundary after its first delegation
    ///         write of any kind (refreshes and the expiration amortiser do
    ///         not end it). Retry once `legacyDatingActive()` is false.
    error VoteDelegationTransitionInProgress();
    /// @notice A write of `lock.end` would put it below the position's
    ///         `transferableAfter`; every end write keeps
    ///         `end >= transferableAfter`.
    error EndBelowTransferableAfter();
    /// @notice A call into the vote-delegation module was refused for lack of
    ///         gas. Raised (1) by the starvation tripwire, when a directly
    ///         called module consumed the 63/64 of the gas it was handed and
    ///         came back with at most 1/64 left -- the EIP-150 signature of a
    ///         caller-chosen gas limit, not of a broken module; and (2) when
    ///         less than `REMOVAL_GAS_FLOOR` (8,176,984 gas) is left before a
    ///         call that books or retires a flat term: the re-delegation in
    ///         `enableAutoRelock`, `createLockWithAutoRelock`,
    ///         `disableAutoRelock`, `retireStaleAutoRelock` and in
    ///         `increaseAmount` / `increaseUnlockTime` on an armed position, and
    ///         the fallback removal of an armed transfer whose move was
    ///         refused. Resend with a higher gas limit.
    error DelegationCallStarved();
    /// @notice Re-raised from the vote-delegation module by `disableAutoRelock`
    ///         when the current delegatee cannot absorb the restored slope.
    ///         Delegate the position elsewhere first, then disable.
    error DelegationSlopeOverflow();

    constructor(address hemi_) {
        // The SIX_DAYS grid must divide MAX_TIME exactly (240 buckets):
        // `increaseUnlockTime` relies on it to keep R <= MAX_TIME. A constant
        // change that broke it reverts the deployment (Panic 0x01).
        assert(MAX_TIME % SIX_DAYS == 0);
        if (hemi_ == address(0)) revert AddressIsNull();
        HEMI = IERC20(hemi_);

        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the owner address
     * @param owner_ The address of the contract owner
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert OwnerIsZero();
        __ERC721_init("veHemi", "veHemi");
        __Ownable_init_unchained(owner_);
        globalPointHistory[0].blockNumber = block.number.toUint64();
        globalPointHistory[0].timestamp = block.timestamp.toUint64();
        nextTokenId = 1;
    }

    /**
     * @notice Returns the current stake weight for a given NFT
     * @dev Decaying position: slope * (lock.end - now). Auto-relock position
     *      (`isAutoRelockEnabled`): the constant slope * (R - SIX_DAYS/2),
     *      whatever `lock.end` is. This is NOT the deposited HEMI amount — use
     *      getLockedBalance() for that.
     * @param tokenId_ The token ID
     * @return _balance The stake weight (0 if expired or non-existent)
     */
    function balanceOfNFT(uint256 tokenId_) external view returns (uint256 _balance) {
        (_balance, ) = _balanceOfNFTAt(tokenId_, block.timestamp);
    }

    /**
     * @notice Returns the stake weight for a given NFT at a specific timestamp
     * @dev The user point in force at `timestamp_`: a decaying point gives
     *      slope * (the lock end it recorded - timestamp); an auto-relock point
     *      (slope 0) gives its constant weight. This is NOT the deposited HEMI
     *      amount.
     * @param tokenId_ The token ID
     * @param timestamp_ The timestamp to query
     * @return _balance The stake weight at the given timestamp
     */
    function balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256 _balance) {
        (_balance, ) = _balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Returns the stake weight and recorded owner for a given NFT at a specific timestamp
     * @dev The owner is the address recorded in the user point history at that time
     *      (may differ from current ownerOf after transfers or burns).
     * @param tokenId_ The token ID
     * @param timestamp_ The timestamp to query
     * @return _balance The stake weight at the given timestamp
     * @return _owner The owner recorded in the user point at that timestamp
     */
    function balanceAndOwnerOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256 _balance, address _owner) {
        return _balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Checkpoints the contract state to update global and user point histories
     * @dev Permissionless. Every checkpointing write (lock creation, top-ups,
     *      extensions, withdrawals, forfeits, transfers, auto-relock changes)
     *      first walks the global point forward one SIX_DAYS bucket at a time
     *      (`VeHemiCurveLib.sol::checkpoint`, at most `CATCHUP_LIMIT` = 300
     *      buckets per call). After very long total inactivity (hundreds of
     *      buckets with no write to VeHemi) that walk can need more gas than a
     *      transaction can use; every such write, `withdraw` included, then
     *      reverts out of gas until an upgrade. Calling this function
     *      periodically keeps the global point fresh. A call that books or
     *      retires an auto-relock term must still have `REMOVAL_GAS_FLOOR`
     *      left after that walk, so it reaches the block gas limit sooner
     *      (after roughly 135 to 240 idle buckets for a typical call, fewer
     *      the more curves still carry slope; plan for about 135, roughly 2.2
     *      years, on the Hemi deployment, where each idle bucket costs about
     *      150,000 gas; a `createLockWithAutoRelock` that needs 17 million fits
     *      only about 85); calling this function first restores it while this
     *      function itself still fits (roughly 200 to 300 idle buckets).
     */
    function checkpoint() external nonReentrant {
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));
    }

    /**
     * @notice Creates a new lock for the sender
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @return _tokenId The ID of the created lock NFT
     */
    function createLock(
        uint256 amount_,
        uint256 lockDuration_
    ) external nonReentrant returns (uint256 _tokenId) {
        _tokenId = _createLock(amount_, lockDuration_, _msgSender(), true, false, false);
    }

    /**
     * @notice Creates a new lock for a specified account
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @param account_ The address to assign the lock NFT to
     * @return _tokenId The ID of the created lock NFT
     */
    function createLockFor(
        uint256 amount_,
        uint256 lockDuration_,
        address account_,
        bool transferable_,
        bool forfeitable_
    ) external nonReentrant returns (uint256 _tokenId) {
        if (account_ == address(0)) revert AddressIsNull();
        _tokenId = _createLock(amount_, lockDuration_, account_, transferable_, forfeitable_, false);
    }

    /**
     * @notice Creates a new lock for the caller, ARMED with auto-relock in the
     *         same transaction (the position is constant-weight from inception).
     *         Reverts as `enableAutoRelock` does (`SeedingNotFinalized`,
     *         `VoteDelegationTransitionInProgress`); either reverts the whole
     *         mint. Needs a gas LIMIT of about 9.2 million (8,176,984 gas must
     *         remain at the arming re-delegation, on top of what the call
     *         spends before it), far above the gas it uses; more when the owner
     *         already holds many positions (the deployed adapter walks them in
     *         the unarmed first booking, before the floor; up to about 17
     *         million) or when that first booking goes to a delegatee not
     *         checkpointed for months (it walks the delegatee's expiration
     *         buckets, also before the floor) or when a reward distributor is
     *         installed (it is notified three times before the floor; above
     *         about 6.8 million gas per notification, less when the owner
     *         already holds many positions, this function cannot fit in a
     *         block: use `createLock`, then `enableAutoRelock`). A shorter
     *         limit reverts `DelegationCallStarved`, so an `eth_estimateGas` of
     *         a transaction that calls VeHemi directly already accounts for it;
     *         a caller that catches the revert (a try/catch loop, Multicall3
     *         with `allowFailure`, a Safe transaction with `safeTxGas != 0`, an
     *         action allowed to fail) must forward that much gas explicitly and
     *         check the result.
     * @dev Equivalent to `createLockFor(amount_, lockDuration_, msg.sender,
     *      transferable_, forfeitable_)` immediately followed by the caller
     *      (now the owner) calling `enableAutoRelock(_tokenId)`, but atomic.
     *      The lock is always minted to `msg.sender`, so arming is
     *      self-service only: nobody can arm a position minted for someone
     *      else. The `R >= 2 * SIX_DAYS` floor and liveness hold by
     *      construction for a fresh lock; the seeding guard is re-checked in
     *      `_createLock`. To create an UNARMED lock use `createLock` or
     *      `createLockFor`.
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @param transferable_ Whether the position is transferable
     * @param forfeitable_ Whether the position is forfeitable
     * @return _tokenId The ID of the created lock NFT
     */
    function createLockWithAutoRelock(
        uint256 amount_,
        uint256 lockDuration_,
        bool transferable_,
        bool forfeitable_
    ) external nonReentrant returns (uint256 _tokenId) {
        _tokenId = _createLock(amount_, lockDuration_, _msgSender(), transferable_, forfeitable_, true);
    }

    /**
     * @notice Forfeit a lock position — callable only by the forfeit admin.
     * @dev The locked HEMI is transferred to the forfeit admin (msg.sender), NOT the position owner.
     *      V2: The forfeit window is bounded by transferableAfter. Once block.timestamp >= transferableAfter,
     *      the position can no longer be forfeited (reverts ForfeitWindowExpired). This prevents punishing
     *      users who voluntarily extended their lock past the original non-transferability term.
     *
     *      There is no `Forfeit` event: the only on-chain signal of a seizure is
     *      a `Withdraw` whose `provider` is the forfeit admin, which an indexer
     *      reading the log cannot tell apart from an owner's own withdrawal. The
     *      owner can appoint an admin (`updateForfeitAdmin`) and forfeit in one
     *      transaction. An appointed `forfeitAdmin` SURVIVES an ownership
     *      handover (transferring ownership does not revoke it), and after
     *      `renounceOwnership` it can no longer be removed.
     * @param tokenId_ The token ID to forfeit
     */
    function forfeit(uint256 tokenId_) external nonReentrant {
        if (_msgSender() != forfeitAdmin) revert NotForfeitAdmin();
        if (!forfeitable[tokenId_]) revert NotForfeitable();
        if (locked[tokenId_].end < block.timestamp) revert LockExpired();
        // V2: Forfeit window is bounded by transferableAfter. Once the position
        // becomes transferable, it can no longer be forfeited — this prevents
        // punishing users who voluntarily extend their lock past the original term.
        if (block.timestamp >= transferableAfter[tokenId_]) revert ForfeitWindowExpired();
        // Every forfeitable position minted since V2 is non-transferable
        // (`_createLock` refuses both flags); a V1-minted id may carry
        // `forfeitable == true` with `transferableAfter == 0`, which is inert:
        // never seeded, never in a subcurve, never forfeitable (the window
        // check above reverts). So always check.
        _requireSeedingNotActiveForNonTransferable(true);
        _delegate(tokenId_, address(0));
        _withdraw(tokenId_);
    }

    /**
     * @notice Get the locked balance information for a specific token
     * @dev While `isAutoRelockEnabled(tokenId_)`, `end` is NOT the unlock time:
     *      it is the value `effectiveLockEnd` had at the last arm, top-up or
     *      extension, nothing consults it for liveness, and it may lie in the
     *      past (`withdraw` reverts while armed). Read
     *      `effectiveLockEnd(tokenId_)`. A transfer to another account disarms
     *      the position and rewrites `end` and the weight inside that call, so
     *      value an armed position only after holding it.
     * @param tokenId_ The token ID to get locked balance for
     * @return The LockedBalance struct containing amount and end time
     */
    function getLockedBalance(uint256 tokenId_) external view returns (LockedBalance memory) {
        return locked[tokenId_];
    }

    /**
     * @notice Returns the user point for a given token and epoch
     * @param tokenId_ The token ID
     * @param epoch_ The epoch number
     * @return The Point struct for the user at the given epoch
     */
    function getUserPoint(
        uint256 tokenId_,
        uint256 epoch_
    ) external view returns (UserPoint memory) {
        return userPointHistory[tokenId_][epoch_];
    }

    /**
     * @notice Returns the global point for a given epoch. On a global point
     *         `amount` is the aggregate constant (auto-relock) weight, not a
     *         HEMI amount: supply is the walked bias plus `amount`.
     * @param epoch_ The epoch number
     * @return The Point struct for the global point at the given epoch
     */
    function getGlobalPoint(uint256 epoch_) external view returns (Point memory) {
        return globalPointHistory[epoch_];
    }

    /**
     * @notice Enable auto-relock (owner only): the position's weight becomes
     *         CONSTANT at `slope * (R - SIX_DAYS/2)`, where R is the whole
     *         SIX_DAYS buckets from the start of the current bucket to `end`
     *         (R >= 2 buckets, else `AutoRelockDurationTooShort`); that
     *         differs from the current decaying weight by up to
     *         `slope * SIX_DAYS / 2` either way, depending on where in the
     *         bucket the call lands (a third of the constant weight at the
     *         minimum R of two buckets, about 0.2% at 240). While
     *         enabled: `withdraw` reverts, a transfer to another account
     *         disables it, and the owner MUST call `refreshAutoRelock` at least
     *         every `STALE_FLAT_BUCKETS * SIX_DAYS` (365.25 days) or anyone may
     *         `retireStaleAutoRelock`. Reverts `VoteDelegationTransitionInProgress`
     *         while the vote-delegation module is in its upgrade-hour window,
     *         and `SeedingNotFinalized` before seeding for a position the scan
     *         will enrol. When the position is delegated it needs a gas LIMIT of
     *         about 8.8 million while no reward distributor is installed
     *         (8,176,984 gas must remain at the re-delegation, on top of what the
     *         call spends before it, reward-distributor notifications included),
     *         far above the gas it uses. A shorter limit reverts
     *         `DelegationCallStarved`, so an `eth_estimateGas` of a transaction
     *         that calls VeHemi directly already accounts for it; a caller that
     *         catches the revert (a try/catch loop, Multicall3 with
     *         `allowFailure`, a Safe transaction with `safeTxGas != 0`, an action
     *         allowed to fail) must forward that much gas explicitly and check
     *         the result.
     * @dev `lock.end` is NOT touched. While the flag is set nothing consults it
     *      for liveness (the flag decides), and neither
     *      `getLockedBalance(id).end` nor `Deposit.lockTime` is the unlock time
     *      (`effectiveLockEnd` is). The `Checkpoint` emitted here carries
     *      identical old and new locks: only the flag changed.
     * @param tokenId_ The position to freeze.
     */
    function enableAutoRelock(uint256 tokenId_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        // The seeding guard (see `SeedingNotFinalized`): the same
        // subcurve-membership test `VeHemiCurveLib.sol::checkpoint` uses, and
        // the exact inverse of `VeHemi.sol::seedBatch`'s skip; it must change
        // with both, and with its copy in `_createLock`. `block.timestamp` is
        // non-decreasing, so an id already open at arm time is still open at
        // every later `seedBatch` block. The latch SLOAD comes first, so a
        // finalized deployment pays nothing more.
        if (!lockedSeedingFinalized && transferableAfter[tokenId_] > block.timestamp) {
            revert SeedingNotFinalized();
        }
        if (autoRelockRemaining[tokenId_] != 0) revert AutoRelockAlreadyEnabled();

        LockedBalance memory _lock = locked[tokenId_];
        if (_lock.amount <= 0) revert NoExistingLock();
        if (_lock.end <= block.timestamp) revert LockExpired();

        _enableAutoRelock(tokenId_, _lock);
    }

    /**
     * @dev Shared arming body for `enableAutoRelock` and arm-at-creation
     *      (`createLockWithAutoRelock`, through `_createLock`). The CALLER owns
     *      every precondition: ownership, existence (`amount > 0`), liveness
     *      (`end > block.timestamp`), not-already-armed
     *      (`autoRelockRemaining == 0`), and the seeding guard. This body
     *      refuses arming inside the upgrade-hour window, computes R, enforces
     *      the `2 * SIX_DAYS` floor, notifies the reward distributor before and
     *      after, writes the flag, emits `AutoRelockEnabled`, re-checkpoints the
     *      position as flat and re-books its current delegation record as flat
     *      (`_reDelegate`; an empty record stays empty).
     * @param tokenId_ The position to arm.
     * @param lock_ The position's current (caller-validated) LockedBalance.
     */
    function _enableAutoRelock(uint256 tokenId_, LockedBalance memory lock_) internal {
        // No position may be ARMED while the module dates writes at the next
        // hour boundary: a decaying-to-flat re-booking dated there leaves the
        // old decaying weight live at the delegatee until the boundary while
        // the escrow is already flat. This covers both arming callers; nothing
        // else arms. (While the window word is 0 -- an upgrade that did not
        // arm the window -- the probe reads false at each hour's last second,
        // where the dating equals `block.timestamp + 1`; an UNDELEGATED
        // position armed there and delegated later books its flat term at the
        // next boundary, with no live weight before it: an under-count, never
        // a double count.)
        if (_voteDelegationDefersWrites()) revert VoteDelegationTransitionInProgress();
        // R in WHOLE SIX_DAYS buckets, reckoned from grid(now) (the start of
        // the current bucket), stored in seconds: `autoRelockRemaining` is a
        // uint64 of seconds. `lock_.end` is on the grid (every writer of
        // `lock.end` floor-snaps to it), so R is exactly `end - grid(now)` and
        // the stored end equals `grid(now) + R`, the value `effectiveLockEnd`
        // reports at this instant.
        uint256 _remaining = ((uint256(lock_.end) - (block.timestamp / SIX_DAYS) * SIX_DAYS) / SIX_DAYS) * SIX_DAYS;
        // R >= 2 * SIX_DAYS, the floor `_createLock` applies to every new lock.
        // `_disarmAutoRelock` restores `grid(now) + R`: one bucket is the
        // arithmetic floor that keeps that strictly after `block.timestamp`;
        // the second keeps it more than SIX_DAYS - 1 hour past the next hour
        // boundary, so the disarm re-delegation is never near-expiry (see
        // `_endAutoRelock`). With R == SIX_DAYS the restored end could fall
        // inside the next hour.
        if (_remaining < 2 * SIX_DAYS) revert AutoRelockDurationTooShort();

        // Settle the old segment with the reward distributor before the weight
        // moves, as every weight-changing entry point does.
        _updateReward(tokenId_);

        // Publish the new-side flag BEFORE `_checkpoint`: the library reads it
        // from storage.
        autoRelockRemaining[tokenId_] = uint64(_remaining);
        // Start the abandonment clock.
        autoRelockRefreshedAt[tokenId_] = uint64(block.timestamp);

        // Emitted BEFORE the `Checkpoint` (and the re-delegation) it describes,
        // so a stream-ordered indexer that applies logs as they arrive already
        // knows the position is flat when the point lands.
        emit AutoRelockEnabled(tokenId_, uint64(_remaining));

        // Same LockedBalance on both sides: only the flag changed. The library
        // recovers the old (decaying) point from `lock_` and builds the new
        // (flat) point from the flag. `_reDelegate` then re-books the record as
        // flat at the same delegatee (with a delegatee, behind the removal gas
        // floor).
        _checkpoint(tokenId_, lock_, lock_);
        _reDelegate(tokenId_);
        // Re-anchor the distributor on the new weight. One notification cannot
        // carry both sides of a discontinuity: the notify-before reported the
        // old weight, and without this second call the distributor interpolates
        // from it across the whole next segment.
        _updateReward(tokenId_);
    }

    /**
     * @notice Disable auto-relock (owner only): the position decays again from
     *         the restored end `grid(now) + R` (`effectiveLockEnd`), i.e. the
     *         frozen term floor-snapped onto the SIX_DAYS grid, so up to
     *         SIX_DAYS - 1 seconds short of `now + R`. The position is re-booked
     *         at its current delegatee. Reverts `DelegationSlopeOverflow()`
     *         (re-raised from the vote-delegation module) when the current
     *         delegatee cannot absorb the restored slope; delegate the position
     *         elsewhere first. When the position is delegated it needs a gas
     *         LIMIT of about 8.8 million while no reward distributor is
     *         installed (8,176,984 gas must remain at the retirement step, on
     *         top of what the call spends before it, reward-distributor
     *         notifications included), far above the gas it uses. A shorter
     *         limit reverts `DelegationCallStarved`, so an `eth_estimateGas` of
     *         a transaction that calls VeHemi directly already accounts for it;
     *         a caller that catches the revert (a try/catch loop, Multicall3
     *         with `allowFailure`, a Safe transaction with `safeTxGas != 0`, an
     *         action allowed to fail) must forward that much gas explicitly and
     *         check the result.
     * @dev FLOOR is mandatory: ceil, round-to-nearest and bucket-anchored all
     *      admit a strictly increasing end across repeated enable/disable
     *      cycles, i.e. an IMMORTAL position (see `_disarmAutoRelock`). The
     *      `R >= 2 * SIX_DAYS` floor enforced at arming puts the restored end
     *      more than one bucket after `block.timestamp`. The flag is cleared
     *      BEFORE `_checkpoint`.
     *
     *      Strict: a `DelegationSlopeOverflow` refusal is re-raised rather than
     *      committing a cleared flag over a surviving flat term, because the
     *      holder is the one party who can act on it (`delegate(id, other)` on
     *      the vote-delegation module). Every other module refusal is swallowed
     *      and announced (`DelegationUpdateFailed`, and
     *      `AutoRelockRetirementUnverified` when the record still reads flat).
     * @param tokenId_ The position to thaw.
     */
    function disableAutoRelock(uint256 tokenId_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        // `strict_ = true`: see the @dev above.
        _endAutoRelock(tokenId_, true);
    }

    /// @notice The heartbeat (owner only, armed positions only): restarts the
    ///         abandonment clock. Call it at least every
    ///         `STALE_FLAT_BUCKETS * SIX_DAYS` (365.25 days) while auto-relock
    ///         is enabled; after that anyone may call `retireStaleAutoRelock`.
    ///         One SSTORE: it changes no weight, supply, delegation or end, and
    ///         calls neither the vote-delegation module nor the reward
    ///         distributor.
    /// @dev The one thing auto-relock cannot do for the holder, because
    ///      "abandoned" and "idle" are the same on-chain observation.
    ///      `nonReentrant` because it is reachable from callbacks in the middle
    ///      of another call (`onERC721Received` inside `safeTransferFrom`, a
    ///      delegation-notify hook).
    function refreshAutoRelock(uint256 tokenId_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        if (autoRelockRemaining[tokenId_] == 0) revert AutoRelockNotEnabled();
        autoRelockRefreshedAt[tokenId_] = uint64(block.timestamp);
        emit AutoRelockRefreshed(tokenId_, uint64(block.timestamp));
    }

    /// @notice Ends auto-relock on a position whose heartbeat has lapsed
    ///         (`block.timestamp >= autoRelockStaleAt(tokenId_)`).
    ///         Permissionless. Same end state as `disableAutoRelock` (decaying
    ///         from `grid(now) + R`, re-booked at the current delegatee) and it
    ///         takes no principal, but a refusal by the vote-delegation module
    ///         is swallowed and announced, never re-raised. Emits
    ///         `AutoRelockRetired`, then `AutoRelockDisabled`. When the position
    ///         is delegated it needs a gas LIMIT of about 8.8 million while no
    ///         reward distributor is installed (8,176,984 gas must remain at the
    ///         retirement step, on top of what the call spends before it,
    ///         reward-distributor notifications included), far above the gas it
    ///         uses. A shorter limit reverts `DelegationCallStarved`, so an
    ///         `eth_estimateGas` of a transaction that calls VeHemi directly
    ///         already accounts for it; a caller that catches the revert (a
    ///         try/catch loop, Multicall3 with `allowFailure`, a Safe
    ///         transaction with `safeTxGas != 0`, an action allowed to fail)
    ///         must forward that much gas explicitly and check the result.
    /// @dev A flat position books NO `slopeChanges` bucket (slope 0), and its
    ///      delegatee's `DelegateCheckpoint.fixedBias` books no expiration
    ///      either (`VeHemiVoteDelegation.sol::_moveVotingPowerToNewDelegate`
    ///      writes no bucket for a flat delegator), so nothing
    ///      in either contract can retire it: without this its weight would
    ///      stand for ever on a position whose owner is gone. It is the only
    ///      PERMISSIONLESS entry point that ends it; without the owner, only
    ///      an approved operator (a transfer to another account) or the
    ///      forfeit admin (`forfeit`, before `transferableAfter`) can.
    ///
    ///      `strict_ = false` is deliberate: the flag clears for every module
    ///      whose return data decodes, so the principal becomes withdrawable at
    ///      the restored end. Re-raising here, as `disableAutoRelock` does,
    ///      would let a delegatee whose slope is saturated
    ///      (`DelegationSlopeOverflow`) block this entry point indefinitely.
    ///
    ///      THE MOVE IS SIGNED. The restored decaying weight is
    ///      `slope * (R - (now mod SIX_DAYS))` against the flat
    ///      `slope * (R - SIX_DAYS/2)`, so the caller's choice of instant inside
    ///      the bucket raises or lowers the position's weight by up to
    ///      `slope * SIX_DAYS/2` (a 20% step at R = 3 buckets, smaller as R
    ///      grows); the restored end is the same at every instant of the
    ///      bucket. No principal moves. An owner who returns may re-enable
    ///      while `end - grid(now) >= 2 * SIX_DAYS` (otherwise `enableAutoRelock`
    ///      reverts `AutoRelockDurationTooShort`; extend with
    ///      `increaseUnlockTime` first): re-arming in the same bucket restores
    ///      the same R, and each whole bucket after the retirement shortens the
    ///      re-armed term by one bucket.
    function retireStaleAutoRelock(uint256 tokenId_) external nonReentrant {
        if (block.timestamp < autoRelockStaleAt(tokenId_)) revert AutoRelockNotStale();
        emit AutoRelockRetired(tokenId_, _msgSender());
        // `strict_ = false`: see the @dev above.
        _endAutoRelock(tokenId_, false);
    }

    /// @notice The instant from which `retireStaleAutoRelock(tokenId_)` is
    ///         allowed: `autoRelockRefreshedAt + STALE_FLAT_BUCKETS * SIX_DAYS`.
    ///         Reverts `AutoRelockNotEnabled` for an unarmed, burned or
    ///         nonexistent id; batch readers should gate on
    ///         `isAutoRelockEnabled` or allow failure.
    function autoRelockStaleAt(uint256 tokenId_) public view returns (uint256) {
        if (autoRelockRemaining[tokenId_] == 0) revert AutoRelockNotEnabled();
        return uint256(autoRelockRefreshedAt[tokenId_]) + STALE_FLAT_BUCKETS * SIX_DAYS;
    }

    /// @dev The full disarm, for `disableAutoRelock` (`strict_ = true`) and the
    ///      permissionless `retireStaleAutoRelock` (`strict_ = false`):
    ///      `_disarmAutoRelock` (the VeHemi half), then the retirement of the
    ///      flat term at the position's CURRENT delegatee, the retirement
    ///      read-back and the reward re-anchor. The armed transfer to another
    ///      account does NOT come here: it runs `_disarmAutoRelock` alone and
    ///      retires the flat term with its own post-transfer re-delegation
    ///      (see `_transferFromUnguarded`).
    function _endAutoRelock(uint256 tokenId_, bool strict_) internal {
        _disarmAutoRelock(tokenId_);
        // This re-delegation RETIRES the flat term the position booked into
        // its delegatee's `DelegateCheckpoint.fixedBias`. Skipped silently, it
        // would leave votes with no position behind them for ever (a flat
        // term writes no expiration bucket, so
        // `writeNewCheckpointForExpiredDelegations` cannot clear it). It
        // re-books at the SAME delegatee, so the holder keeps their delegatee.
        //
        // `force_` bypasses `_delegate`'s near-expiry skip. It changes nothing
        // today -- R >= 2 * SIX_DAYS puts the restored end more than
        // SIX_DAYS - 1 hour past the next hour boundary -- but KEEP IT: that
        // equivalence rests on the `AutoRelockDurationTooShort` floor in
        // `_enableAutoRelock`; were the floor weakened, dropping `force_` would
        // leave a standing phantom flat term. `force_` also makes `_reDelegate`
        // require `REMOVAL_GAS_FLOOR`, so no gas limit can starve this
        // retirement into committing with the flat term booked.
        _reDelegate(tokenId_, true, strict_);
        // The retirement is complete when the record says so, not when the
        // call returns (see `_requireFlatTermRetired`).
        _requireFlatTermRetired(tokenId_);
        // Re-anchor the distributor on the new weight (`_disarmAutoRelock`
        // sent the notify-before).
        _updateReward(tokenId_);
    }

    /// @dev The VeHemi half of every disarm: reward notify-before, flag clear,
    ///      floor-snapped end, the `end >= transferableAfter` check,
    ///      `AutoRelockDisabled`, `_checkpoint`. It makes NO `voteDelegation`
    ///      call: the caller owns the retirement of the flat term booked at the
    ///      delegatee and the reward re-anchor. Reached from `disableAutoRelock`
    ///      and `retireStaleAutoRelock` (through `_endAutoRelock`) and from the
    ///      armed transfer to another account in `_transferFromUnguarded`. It is
    ///      the only writer that ZEROES `autoRelockRemaining` on a surviving
    ///      position.
    function _disarmAutoRelock(uint256 tokenId_) private {
        uint64 _remaining = autoRelockRemaining[tokenId_];
        if (_remaining == 0) revert AutoRelockNotEnabled();

        LockedBalance memory _oldLocked = locked[tokenId_];

        // FLOOR-snap onto the SIX_DAYS grid. `_remaining >= 2 * SIX_DAYS` was
        // enforced at enable time, so `_newEnd > block.timestamp` always.
        //
        // FLOOR IS MANDATORY and stays: ceil, round-to-nearest and
        // bucket-anchored all admit a strictly increasing end across repeated
        // cycles, i.e. an IMMORTAL position.
        //
        // What the floor does and does not bound. R is whole buckets reckoned
        // from grid(t_enable), so one enable/disable episode moves the end by
        // `grid(t_disable) - grid(t_enable)`: the flat time plus
        // (phase_enable - phase_disable), a SIGNED residue of up to
        // SIX_DAYS - 1 seconds either way. The holder picks both phases, and
        // the residue is linear in the number of episodes (one second of flat
        // time can buy a whole bucket of end). Against wall-clock time the
        // terms telescope: the end extension cycling yields is less than the
        // elapsed time plus one SIX_DAYS bucket. R is NOT monotone
        // (`increaseUnlockTime` raises it, a disarm zeroes it); what bounds the
        // position is `R <= MAX_TIME` at every writer. No principal moves:
        // every second of end gained is backed by lock-up already served, and
        // the owner-gated `increaseUnlockTime` reaches the same ceiling
        // directly. `retireStaleAutoRelock` and an approved operator's transfer
        // reach this snap without the owner. Test with sub-bucket offsets: on
        // whole-bucket warps (phase_enable == phase_disable) the residue is
        // identically zero.
        uint256 _newEnd = ((block.timestamp / SIX_DAYS) + uint256(_remaining) / SIX_DAYS) * SIX_DAYS;

        // Settle the old segment with the reward distributor before the weight
        // moves.
        _updateReward(tokenId_);

        // Clear the new-side flag BEFORE `_checkpoint`: the library reads it
        // from storage.
        autoRelockRemaining[tokenId_] = 0;
        delete autoRelockRefreshedAt[tokenId_];

        LockedBalance memory _newLocked;
        (_newLocked.amount, _newLocked.end) = (_oldLocked.amount, uint64(_newEnd));
        // Every end write keeps `end >= transferableAfter`.
        if (_newLocked.end < transferableAfter[tokenId_]) revert EndBelowTransferableAfter();
        locked[tokenId_] = _newLocked;

        // Emitted before the `Checkpoint` it describes (see `_enableAutoRelock`).
        emit AutoRelockDisabled(tokenId_, uint64(_newEnd));

        _checkpoint(tokenId_, _oldLocked, _newLocked);
    }

    /**
     * @notice `true` while auto-relock is enabled on `tokenId_`: its weight is
     *         constant and it is live whatever `getLockedBalance(tokenId_).end`
     *         says (that value may lie in the past).
     * @dev This is the flat-liveness predicate for off-chain consumers
     *      (subgraphs, front ends), so they need not spell it as
     *      `autoRelockRemaining(id) != 0`, which hard-codes the ENCODING of R.
     *      VeHemiVoteDelegation reads `autoRelockRemaining(id) != 0` directly --
     *      the same predicate -- so a change to R's encoding must change that
     *      module too; the Aragon adapter reads neither. A historical question
     *      ("was it live at t") needs the point history (`getUserPoint`), not
     *      this flag. A burned id reads `false`: `_withdraw`, the only burn
     *      path, deletes the flag before `_burn`.
     */
    function isAutoRelockEnabled(uint256 tokenId_) external view returns (bool) {
        return autoRelockRemaining[tokenId_] != 0;
    }

    /**
     * @notice The unlock time an integrator should read for `tokenId_`:
     *         `getLockedBalance(tokenId_).end` while auto-relock is off; while
     *         it is on, the end `disableAutoRelock` would restore if called in
     *         this block, `grid(now) + R`.
     * @dev A pure view: no curve consults it. An armed transfer to another
     *      account writes exactly this value (evaluated in the transfer block)
     *      as the position's new end.
     */
    function effectiveLockEnd(uint256 tokenId_) external view returns (uint256) {
        uint64 _r = autoRelockRemaining[tokenId_];
        if (_r == 0) return locked[tokenId_].end;
        // Must mirror `_disarmAutoRelock`'s end snap exactly.
        return ((block.timestamp / SIX_DAYS) + uint256(_r) / SIX_DAYS) * SIX_DAYS;
    }

    /// @dev The authorization predicate for owner-only per-position
    ///      operations (`increaseAmount`, `increaseUnlockTime`, `withdraw`;
    ///      `enableAutoRelock`, `disableAutoRelock` and `refreshAutoRelock`
    ///      apply the same test inline): strict `ownerOf` equality. ERC-721
    ///      approvals confer NO power here, deliberately. An approval
    ///      authorizes moving the token OUT of the owner's control; a top-up
    ///      moves value IN, irreversibly, and fires a re-delegation of the
    ///      owner's governance weight (both legs at `block.timestamp + 1`, so it
    ///      is conserved; inside the vote-delegation upgrade-hour window, at
    ///      that hour's boundary). Listing an NFT on a marketplace is not
    ///      consent to that, and since `VeHemi` overrides neither `approve` nor
    ///      `setApprovalForAll`, honouring blanket operator grants would give
    ///      every such operator an unconsented third-party mutation of every
    ///      approved owner's delegation ledger. This is the gate's intent, not a
    ///      property of the contract: `transferFrom` moves governance weight on
    ///      any approval.
    ///
    ///      Revocation caveat: an operator holding `setApprovalForAll` can set
    ///      a per-token `approve` for every id the owner holds, and those grants
    ///      SURVIVE `setApprovalForAll(op, false)` and are invisible on
    ///      `isApprovedForAll`; a holder who revokes an operator must also check
    ///      `getApproved(id)` for every position.
    ///
    ///      `_ownerOf` returns `address(0)` for a nonexistent or burned id, so
    ///      this reverts `NotOwner` (not `NoExistingLock`) for those.
    function _requireTokenOwner(uint256 tokenId_) internal view {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
    }

    /**
     * @notice Increases the amount of HEMI locked for a given token. **Owner
     *         only**: any other caller, an approved operator included, gets
     *         `NotOwner`, so a third party cannot top up another holder's lock.
     *         On an auto-relock position the constant weight rises with the
     *         amount and is re-booked at the current delegatee; when such a
     *         position is delegated this needs a gas LIMIT of about 8.8
     *         million while no reward distributor is installed (8,176,984 gas
     *         must remain at the re-delegation, on top of what the call
     *         spends before it, reward-distributor notifications included),
     *         far above the gas it uses.
     *         A shorter limit reverts `DelegationCallStarved`, so an
     *         `eth_estimateGas` of a transaction that calls VeHemi directly
     *         already accounts for it; a caller that catches the revert (a
     *         try/catch loop, Multicall3 with `allowFailure`, a Safe
     *         transaction with `safeTxGas != 0`, an action allowed to fail)
     *         must forward that much gas explicitly and check the result.
     * @dev Owner-only because a top-up re-books the position's delegation: a
     *      party with no stake must not be able to mutate another holder's
     *      delegation ledger. Scope is `ownerOf` only; see `_requireTokenOwner`.
     *
     *      PLACEMENT: here, NOT in `_depositFor`. `_depositFor` is the shared
     *      body of `increaseAmount`, `increaseUnlockTime` (gated at its own
     *      head) and `_createLock`. `createLockFor(amount, dur, account_, ...)`
     *      mints to `account_` and then deposits, so the token is owned by
     *      `account_` and not by `_msgSender()`; a check in `_depositFor` would
     *      break `createLockFor`, which is permissionless BY DESIGN (it cannot
     *      touch an existing position's delegation).
     *
     * @param tokenId_ The token ID
     * @param amount_ The additional amount to lock
     */
    function increaseAmount(uint256 tokenId_, uint256 amount_) external nonReentrant {
        _requireTokenOwner(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];

        if (amount_ == 0) revert AmountIsZero();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        // An auto-relock position is live whatever its stored end says, so
        // liveness consults the flag (as in `increaseUnlockTime`, `withdraw`
        // and `_delegate`).
        if (autoRelockRemaining[tokenId_] == 0 && _oldLocked.end <= block.timestamp) {
            revert LockExpired();
        }

        _requireSeedingNotActiveForNonTransferable(transferableAfter[tokenId_] != 0);

        _depositFor(tokenId_, amount_, 0, _oldLocked);
    }

    /**
     * @notice Increases the unlock time for a given lock NFT.
     *         On an auto-relock position the new end must lie beyond
     *         `effectiveLockEnd` (else `NewLockDurationNotGreater`) and the
     *         extension is folded into R, so the constant weight rises. When
     *         such a position is delegated this needs a gas LIMIT of about
     *         8.8 million while no reward distributor is installed (8,176,984
     *         gas must remain at the re-delegation, on top of what the call
     *         spends before it, reward-distributor notifications included),
     *         far above the gas it uses. A shorter limit reverts
     *         `DelegationCallStarved`, so an `eth_estimateGas` of a
     *         transaction that calls VeHemi directly already accounts for it;
     *         a caller that catches the revert (a try/catch loop, Multicall3
     *         with `allowFailure`, a Safe transaction with `safeTxGas != 0`,
     *         an action allowed to fail) must forward that much gas
     *         explicitly and check the result.
     * @dev On an auto-relock position no auto-relock event is emitted (only
     *      `Deposit` and `Checkpoint`): an indexer that tracks R must re-read
     *      `autoRelockRemaining` after a `Deposit` on an armed position.
     * @param tokenId_ The token ID
     * @param lockDuration_ The new lock duration (from now)
     */
    function increaseUnlockTime(uint256 tokenId_, uint256 lockDuration_) external nonReentrant {
        _requireTokenOwner(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];
        uint64 _r = autoRelockRemaining[tokenId_];
        // Liveness consults the flag (see `increaseAmount`).
        if (_r == 0 && _oldLocked.end <= block.timestamp) revert LockExpired();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        uint256 _unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) * SIX_DAYS; // unlock time is rounded down to SIX_DAYS
        if (_unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();

        // An auto-relock position's weight is `slope * (R - SIX_DAYS/2)` and
        // `disableAutoRelock` restores `grid(now) + R`; neither reads
        // `lock.end`, so the extension must be folded into R or it would be
        // silently discarded. The new R is `_unlockTime - grid(now)`: the lock
        // the holder asked for, reckoned from the same `grid(now)` origin R
        // uses everywhere, so R stays a whole number of buckets. (Crediting
        // `_unlockTime - oldEnd` instead would grant free duration, because
        // the stored end can lie far in the past.)
        //
        // Compare ENDS, never subtract first: `_unlockTime` is a floor-snap of
        // `now + lockDuration_` and can land before `block.timestamp`, so a
        // subtraction first would Panic (0x11) where a decaying position gets
        // `NewLockDurationNotGreater`. `_gridNow + uint256(_r)` cannot
        // overflow (`_r` is a uint64).
        if (_r != 0) {
            uint256 _gridNow = (block.timestamp / SIX_DAYS) * SIX_DAYS;
            if (_unlockTime <= _gridNow + uint256(_r)) revert NewLockDurationNotGreater();
            uint256 _newR = _unlockTime - _gridNow;
            // Defence in depth, unreachable while `MAX_TIME % SIX_DAYS == 0`
            // (asserted in the constructor): `_unlockTime` is on the grid and
            // at most `block.timestamp + MAX_TIME`, so its largest admissible
            // value is `_gridNow + MAX_TIME` and `_newR <= MAX_TIME`, with
            // equality attained at the maximum extension. Keep it: it is the
            // check that would bind if the grid stopped dividing MAX_TIME.
            if (_newR > MAX_TIME) revert LockDurationTooLong();
            autoRelockRemaining[tokenId_] = uint64(_newR);
            // A silent write of R: no auto-relock event (see the @dev above).
        } else {
            if (_unlockTime <= _oldLocked.end) revert NewLockDurationNotGreater();
        }

        _requireSeedingNotActiveForNonTransferable(transferableAfter[tokenId_] != 0);

        // V2: transferableAfter is NOT extended when the user voluntarily extends their lock.
        // The user was promised transferability at the original unlock time, and extending the
        // lock should not move that goalpost. After transferableAfter passes, the position:
        //   - becomes transferable (can be traded via transferFrom)
        //   - is no longer forfeitable (admin cannot claw it back)
        //   - exits the locked/forfeitable subcurves (tracked in global only)
        //   - retains its full voting power until the new lock.end

        _depositFor(tokenId_, 0, _unlockTime.toUint64(), _oldLocked);
    }

    /**
     * @notice Check if a token is currently transferable.
     * @dev True when `transferableAfter[tokenId_] <= block.timestamp`. The
     *      `<=` makes the position transferable AT its `transferableAfter`
     *      timestamp. Transferable-at-mint positions store
     *      `transferableAfter == 0` and therefore return true unconditionally.
     *
     *      Non-existent and burned ids share the default `transferableAfter`
     *      value of 0 and so this predicate returns true for them too —
     *      `transferFrom` rejects them via its own `_ownerOf == 0` check,
     *      but external callers using this view as a membership test
     *      should pair it with an `ownerOf` query. Folding an
     *      `_ownerOf(tokenId_) != address(0)` SLOAD into this predicate is
     *      deferred until bytecode headroom is reclaimed via library
     *      extraction.
     * @param tokenId_ The token ID.
     * @return True if the token is transferable now.
     */
    function isTransferable(uint256 tokenId_) public view returns (bool) {
        return (transferableAfter[tokenId_] <= block.timestamp);
    }

    /**
     * @notice Get the total veHEMI stake weight at the current timestamp
     * @return Aggregate stake weight: the decaying curve plus the constant weight of every auto-relock position.
     */
    function totalVeHemiSupply() public view returns (uint256) {
        return _supplyAt(block.timestamp);
    }

    /**
     * @notice Get the total veHEMI stake weight at a specific timestamp
     * @param timestamp_ The timestamp to query
     * @return The aggregate stake weight at the given timestamp
     */
    function totalVeHemiSupplyAt(uint256 timestamp_) external view returns (uint256) {
        return _supplyAt(timestamp_);
    }

    /**
     * @notice Update the reward distributor contract address
     * @dev Only callable by the contract owner. Can be set to address(0) to disable rewards.
     * @param newRewardDistributor_ The new reward distributor contract address
     */
    function updateRewardDistributor(IRewardDistributor newRewardDistributor_) external onlyOwner {
        // Allowed to set to 0x0
        IRewardDistributor _oldRewardDistributor = rewardDistributor;
        rewardDistributor = newRewardDistributor_;
        emit RewardDistributorUpdated(_oldRewardDistributor, newRewardDistributor_);
    }

    /**
     * @notice Update the forfeit admin address
     * @dev Only callable by the contract owner. Can be set to address(0) to disable forfeits.
     *      An appointed forfeit admin survives an ownership handover, and after
     *      `renounceOwnership` it can no longer be removed; see `forfeit`.
     * @param newForfeitAdmin_ The new forfeit admin address
     */
    function updateForfeitAdmin(address newForfeitAdmin_) external onlyOwner {
        address _oldForfeitAdmin = forfeitAdmin;
        forfeitAdmin = newForfeitAdmin_;
        emit ForfeitAdminUpdated(_oldForfeitAdmin, newForfeitAdmin_);
    }

    /**
     * @notice Replace the vote delegation contract pointer.
     *
     * @dev    ⚠️ CRITICAL: this is a single-SSTORE pointer swap that performs
     *         ZERO state migration. Every cached delegation (per-tokenId
     *         `delegations[id]`, per-account `autoDelegate[owner]`,
     *         `delegateCheckpoints[delegatee][]` history, slope-change
     *         buckets, EIP-712 nonces, and `trustedAdapter`) lives entirely
     *         inside the OLD VeHemiVoteDelegation proxy's storage. The NEW
     *         contract starts empty. After this call:
     *
     *         1. `_reDelegate(tokenId)` reads the NEW contract, sees
     *            `delegations[id].delegatee == address(0)`, and SILENTLY
     *            SKIPS re-delegation (no event, no revert). Every voter's
     *            stake is effectively undelegated until each user manually
     *            calls `delegate()` on the new contract.
     *
     *         2. Aragon proposals snapshotted BEFORE this call read
     *            `getPastVotes(voter, snapshotBlock)` against the NEW
     *            (empty) contract and return 0 for every voter. In-flight
     *            proposals can become unwinnable — even users who
     *            re-delegate immediately after the swap cannot vote on
     *            them, because the snapshot block is fixed in the past.
     *            NOTE: `importDelegationsFromLegacy` builds FORWARD-ONLY
     *            checkpoints dated from the import (`block.timestamp + 1` on
     *            a freshly deployed, initialized module); it does not
     *            back-fill historical `getPastVotes`. Pre-swap snapshot
     *            queries are unrecoverable on the new contract.
     *
     *         3. The Aragon event relay (`notifyDelegateChanged`,
     *            `notifyVotesChanged`) stops firing until `setTrustedAdapter`
     *            is called on the new contract.
     *
     *         4. `autoDelegate[owner]` mappings are empty — users who had
     *            "auto-delegate all future mints to X" lose that config.
     *
     *      ⚠️ MANDATORY OPERATOR RUNBOOK: `docs/VOTE_DELEGATION_RECOVERY.md`
     *         in this repository (`scripts/plan-legacy-migration.ts` prints its
     *         Safe transactions for the live chain). It rests on these
     *         properties of this contract and of `VeHemiVoteDelegation`:
     *         - The new module is seeded with `importDelegationsFromLegacy` and
     *           `importAutoDelegatesFromLegacy`, re-wired with
     *           `setTrustedAdapter` and sealed with `finalizeMigration`; this
     *           call goes LAST, in one MultiSend with `finalizeMigration`.
     *         - At today's size the imports span many Safe transactions, and
     *           the OLD module stays authoritative until this call.
     *         - Each import is a snapshot that skips an id or owner the new
     *           module already holds. An id or owner that changes after its
     *           import, and a record or `autoDelegate` written directly on the
     *           new module before this call, keep what the new module holds:
     *           the runbook reconciles them after this call.
     *         - Arming cannot be blocked between the first import and this
     *           call: the upgrade-hour window probe in `_enableAutoRelock`
     *           reads the CURRENT module.
     *         - A position FORFEITED after its import and before this call
     *           keeps its decaying imported record on the new module, and no
     *           call can remove it (the id is burned: `delegate` reverts,
     *           `retireStrandedFlatTerm` refuses a decaying record). Disable
     *           `forfeit` from before the first import until after this call.
     *
     *      ⚠️ DO NOT call this function while Aragon proposals are in
     *         flight (snapshotted but not yet executed). Wait for all
     *         pending proposals to resolve, OR schedule the migration
     *         during a deliberate governance freeze.
     *
     *      ⚠️ This function is a RECOVERY PRIMITIVE for when the deployed
     *         VeHemiVoteDelegation proxy is irreparably broken. For routine
     *         implementation changes, prefer the TransparentProxy upgrade
     *         path which preserves all storage.
     *
     *      ⚠️ The new module must return decodable data from
     *         `delegation(uint256)` and `autoDelegate(address)`: VeHemi's
     *         `try ... returns` sites (`_reDelegate`, `_requireFlatTermRetired`,
     *         `_resolveAutoDelegate`) cannot catch a decode failure, which
     *         reverts the caller. For an armed position that blocks
     *         `disableAutoRelock` and `retireStaleAutoRelock` (and `withdraw`
     *         refuses while armed), so its principal stays locked until the
     *         module is replaced again.
     *
     * @param newVoteDelegation_ Address of the new VeHemiVoteDelegation
     *        proxy. Must have its `delegations[]` / `autoDelegate[]` /
     *        `trustedAdapter` already populated via the new contract's
     *        import functions BEFORE this swap lands.
     */
    function updateVoteDelegation(IVeHemiVoteDelegation newVoteDelegation_) external onlyOwner {
        if (address(newVoteDelegation_) == address(0)) revert AddressIsNull();
        // Mirror of `VeHemiVoteDelegation.setTrustedAdapter`'s code-length
        // check, and it matters more here: `trustedAdapter` drives an optional,
        // try/catch'd relay, while this pointer is the module every lifecycle
        // operation calls. Calls into a codeless module revert the CALLING
        // frame, uncaught by `try` (the call in `_delegate` fails the
        // compiler's code-existence check; the `try ... returns (T)` sites
        // cannot decode empty return data), so `disableAutoRelock`, `withdraw`
        // and `createLock` would all revert: a protocol-wide principal freeze.
        // This does NOT make the module trusted -- a contract that misbehaves
        // is still only contained by the try/catch -- and it closes only the
        // codeless shape, for one EXTCODESIZE. It is not the only shape the
        // try/catch cannot contain: a contract module whose `delegation(uint256)`
        // or `autoDelegate(address)` return data does not decode reverts the
        // caller at the same sites (`_reDelegate`, `_requireFlatTermRetired`,
        // `_resolveAutoDelegate`); for an armed position that blocks
        // `disableAutoRelock` and `retireStaleAutoRelock`, so its principal
        // stays locked until this pointer is replaced.
        if (address(newVoteDelegation_).code.length == 0) revert VoteDelegationHasNoCode();
        IVeHemiVoteDelegation _oldVoteDelegation = voteDelegation;
        voteDelegation = newVoteDelegation_;
        emit VoteDelegationUpdated(_oldVoteDelegation, newVoteDelegation_);
    }

    /**
     * @notice Withdraws HEMI after the lock has expired and burns the NFT.
     *         Reverts `LockNotExpired` while auto-relock is enabled, whatever
     *         `getLockedBalance(id).end` says; call `disableAutoRelock` and wait
     *         for the restored end.
     * @param tokenId_ The token ID to withdraw from
     */
    function withdraw(uint256 tokenId_) external nonReentrant {
        _requireTokenOwner(tokenId_);
        // An auto-relock position is never withdrawable: its stored end falls
        // into the past while its weight stays constant, so without this guard
        // it would hold full weight with no remaining lock-up.
        if (autoRelockRemaining[tokenId_] != 0) revert LockNotExpired();
        if (block.timestamp < locked[tokenId_].end) revert LockNotExpired();
        // Clear the stale `delegations[tokenId]` cache and emit
        // `DelegateChanged(tokenId, X, 0)` so indexers see a clean lifecycle
        // for the burned token. `_delegate` routes `delegatee_ == address(0)`
        // through unconditionally so this works even when the lock has just
        // expired.
        _delegate(tokenId_, address(0));
        _withdraw(tokenId_);
    }

    function _balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256, address) {
        return VeHemiSupplyLib.balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Internal function to checkpoint user and global point histories.
     * @dev V2: Maintains parallel locked and forfeitable subcurves.
     *      - Locked curve: all non-transferrable positions (transferableAfter != 0)
     *      - Forfeitable curve: forfeitable non-transferrable positions (strict subset of locked)
     *      Both share the same epoch counter as the global curve.
     *      All subcurve tracking is gated on `lockedSeedingFinalized` to prevent corruption
     *      during the seeding window.
     *
     *      The curve math runs in `VeHemiCurveLib` (DELEGATECALL). For non-auto-relock
     *      positions the global curve is unchanged from V2; auto-relock positions
     *      contribute a constant term to the global `Point.amount` and no slope. The
     *      subcurves use `transferableAfter` as the effective end (auto-relock is
     *      invisible to them).
     *
     *      The library reads the NEW side's auto-relock flag (`autoRelockRemaining`),
     *      `transferableAfter` and `forfeitable` from storage, so callers write the
     *      flag BEFORE this call and delete the other two only AFTER it (see
     *      `_withdraw`).
     * @param tokenId_ The token ID (0 for external checkpoint)
     * @param oldLocked_ The previous locked balance
     * @param newLocked_ The new locked balance
     */
    function _checkpoint(
        uint256 tokenId_,
        LockedBalance memory oldLocked_,
        LockedBalance memory newLocked_
    ) internal {
        VeHemiCurveLib.checkpoint(tokenId_, oldLocked_, newLocked_);
    }

    /**
     * @dev Internal lock creation: validates params, mints NFT, sets transferableAfter/forfeitable
     *      BEFORE _depositFor (so _checkpoint can read them for subcurve membership), then deposits.
     *      Forfeitable positions are non-transferable (transferableAfter != 0). Holds for every
     *      mint since V2 (InvalidConfiguration below); a V1-minted id may carry
     *      forfeitable == true with transferableAfter == 0, which is inert: never seeded, never
     *      in a subcurve, never forfeitable. With `autoRelock_` the new position is armed after
     *      the `Lock` event.
     */
    function _createLock(
        uint256 amount_,
        uint256 lockDuration_,
        address account_,
        bool transferable_,
        bool forfeitable_,
        bool autoRelock_
    ) internal returns (uint256 _tokenId) {
        if (lockDuration_ < 2 * SIX_DAYS) revert LockDurationTooShort();
        uint256 unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) * SIX_DAYS; // Lock time is rounded down to SIX_DAYS

        if (amount_ == 0) revert AmountIsZero();
        if (amount_ < MIN_LOCK_AMOUNT) revert AmountTooSmall();
        if (unlockTime <= block.timestamp) revert LockDurationTooShort();
        if (unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();
        // A position cannot be both transferable and forfeitable; this line is
        // what enforces it.
        if (transferable_ && forfeitable_) revert InvalidConfiguration();

        _requireSeedingNotActiveForNonTransferable(!transferable_);

        _tokenId = nextTokenId++;
        _mint(account_, _tokenId);

        // V2: Set transferableAfter and forfeitable BEFORE _depositFor so that
        // _checkpoint can read them to determine locked/forfeitable curve membership.
        if (!transferable_) {
            transferableAfter[_tokenId] = unlockTime;
        }
        if (forfeitable_) forfeitable[_tokenId] = true;

        _depositFor(_tokenId, amount_, unlockTime.toUint64(), locked[_tokenId]);

        _delegate(_tokenId, _resolveAutoDelegate(account_));

        address _sender = _msgSender();

        provider[_tokenId] = _sender;

        emit Lock(
            _sender,
            account_,
            _tokenId,
            amount_,
            block.timestamp,
            lockDuration_,
            0,
            transferable_,
            forfeitable_
        );

        // Arm-at-creation, through the same `_enableAutoRelock` body. It runs
        // AFTER `_delegate` above, so the re-delegation re-books an existing
        // record as flat, and AFTER `Lock`, so indexers see Lock, then
        // AutoRelockEnabled. Liveness, not-already-armed and the
        // `R >= 2 * SIX_DAYS` floor hold by construction (`lockDuration_ >=
        // 2 * SIX_DAYS` on the same grid); ownership holds because the only
        // arming caller, `createLockWithAutoRelock`, mints to `_msgSender()`.
        //
        // The seeding guard is NOT moot here:
        // `_requireSeedingNotActiveForNonTransferable` blocks non-transferable
        // mints only while the seeding window is OPEN, and before
        // `markSeedingStarted` a non-transferable position can be minted. So
        // the `enableAutoRelock` predicate is re-applied verbatim (it must stay
        // the inverse of `seedBatch`'s skip). A finalized deployment pays one
        // SLOAD.
        if (autoRelock_) {
            if (!lockedSeedingFinalized && transferableAfter[_tokenId] > block.timestamp) {
                revert SeedingNotFinalized();
            }
            _enableAutoRelock(_tokenId, locked[_tokenId]);
        }

        return _tokenId;
    }

    /**
     * @dev Internal deposit: pulls HEMI (if amount > 0), updates lock, checkpoints, re-delegates.
     *      Token transfer happens BEFORE state update (CEI for pull patterns: receiving tokens
     *      before updating books is correct; the nonReentrant modifier on all callers prevents
     *      re-entry during the pre-effects external call).
     */
    function _depositFor(
        uint256 tokenId_,
        uint256 amount_,
        uint64 unlockTime_,
        LockedBalance memory oldLocked_
    ) internal {
        _updateReward(tokenId_);

        // Pull tokens FIRST (CEI for pull patterns: interaction before effects
        // is correct when receiving tokens, not sending them).
        address from = _msgSender();
        if (amount_ != 0) {
            HEMI.safeTransferFrom(from, address(this), amount_);
        }

        totalLocked += amount_;

        // Set newLocked to _oldLocked without mangling memory
        LockedBalance memory _newLocked;
        (_newLocked.amount, _newLocked.end) = (oldLocked_.amount, oldLocked_.end);

        // Adding to existing lock, or if a lock is expired - creating a new one
        _newLocked.amount += amount_.toInt256().toInt128();
        if (unlockTime_ != 0) {
            _newLocked.end = unlockTime_;
        } else {
            // An armed position touched without a new unlock time
            // re-materialises its stored end as `grid(now) + R`, the value
            // `effectiveLockEnd` reports at this instant.
            uint64 _rr = autoRelockRemaining[tokenId_];
            if (_rr != 0) {
                _newLocked.end = uint64(((block.timestamp / SIX_DAYS) + uint256(_rr) / SIX_DAYS) * SIX_DAYS);
            }
        }
        // Every end write keeps `end >= transferableAfter`.
        if (_newLocked.end < transferableAfter[tokenId_]) revert EndBelowTransferableAfter();
        locked[tokenId_] = _newLocked;

        // Possibilities:
        // Both _oldLocked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // newLocked.end > block.timestamp (always)
        _checkpoint(tokenId_, oldLocked_, _newLocked);

        _reDelegate(tokenId_);
        // Re-anchor the distributor: `_depositFor` steps the weight up
        // discontinuously (amount or end; on an auto-relock position, slope or
        // R), the notify at the top of this function reported the pre-step
        // weight, and without this one the distributor interpolates from it
        // across the whole next segment. An auto-relock position may send no
        // other notifying transaction for a long time: the `refreshAutoRelock`
        // heartbeat does not call the distributor.
        _updateReward(tokenId_);
        emit Deposit(from, tokenId_, amount_, _newLocked.end, block.timestamp);
    }

    /// @dev The window probe: true iff the vote-delegation module reports
    ///      `legacyDatingActive()`. It fails OPEN on any failure (a revert, a
    ///      module without the view, short return data), so a broken or older
    ///      module cannot block arming. A starved probe cannot be used to skip
    ///      the check: the rest of the arm needs far more gas than the probe's
    ///      remainder (about 1/32 of it behind a delegatecall proxy).
    ///
    ///      Failing open has a cost if VeHemi and the module are ever upgraded
    ///      separately: while this VeHemi runs over a module without the view
    ///      (the replaced implementation), arming is admitted. That module
    ///      books such a record as DECAYING weight with an expiry bucket while
    ///      its shape is flat; once the new module is in place every move of it
    ///      either reverts or takes its weight out of the delegatee's other flat
    ///      terms, the last of which then can never be removed (permanent votes
    ///      with no locked HEMI behind them). Upgrade both proxies in one
    ///      transaction.
    function _voteDelegationDefersWrites() private view returns (bool) {
        (bool _ok, bytes memory _ret) = address(voteDelegation).staticcall{gas: DATING_WINDOW_PROBE_GAS}(
            abi.encodeCall(IVeHemiVoteDelegationAutoRelock.legacyDatingActive, ())
        );
        return _ok && _ret.length >= 32 && abi.decode(_ret, (uint256)) != 0;
    }

    /// @dev Wrapped in try/catch so a broken voteDelegation contract cannot block
    ///      critical operations (deposit, transfer). The owner can replace
    ///      voteDelegation via updateVoteDelegation() to restore delegation.
    function _reDelegate(uint256 delegator_) internal virtual {
        _reDelegate(delegator_, false);
    }

    /// @dev `force_` bypasses the near-expiry skip in `_delegate`. Only
    ///      `_endAutoRelock` passes `true` (through the 3-argument overload):
    ///      its re-delegation retires the position's flat term, for the owner's
    ///      `disableAutoRelock` and the permissionless `retireStaleAutoRelock`
    ///      alike, so tests must cover both callers. The armed transfer passes
    ///      `force_` to `_delegate` directly (see `_transferFromUnguarded`).
    function _reDelegate(uint256 delegator_, bool force_) internal {
        _reDelegate(delegator_, force_, false);
    }

    /// @dev Re-books the position's current delegation record at its current
    ///      delegatee (an empty record stays empty). `strict_` (only from
    ///      `disableAutoRelock`) re-raises `DelegationSlopeOverflow`; see the
    ///      4-argument `_delegate`. A failed read is swallowed
    ///      (`DelegationUpdateFailed`) unless the starvation tripwire fires;
    ///      return data that does not decode is not caught and reverts the
    ///      caller (see `updateVoteDelegation`).
    function _reDelegate(uint256 delegator_, bool force_, bool strict_) internal {
        // The starvation tripwire, site 1 of 2 (see `_requireNotStarved`).
        uint256 _gasBefore = gasleft();
        try voteDelegation.delegation{gas: DELEGATION_GAS_CEILING}(delegator_) returns (
            IVeHemiVoteDelegation.Delegation memory d
        ) {
            if (d.delegatee != address(0)) {
                // The removal gas floor: a re-booking that retires a flat term
                // (`force_`) or books one (an armed position) must hand the
                // module the whole ceiling. Behind a delegatecall proxy a
                // starved call is swallowed as a refusal and would commit a
                // flat term that never expires, or leave an armed position's
                // weight uncounted. The revert sits in the `try` success
                // block, so it is not caught. Unarmed re-bookings keep the
                // replaced implementation's behaviour.
                if ((force_ || autoRelockRemaining[delegator_] != 0) && gasleft() < REMOVAL_GAS_FLOOR) {
                    revert DelegationCallStarved();
                }
                _delegate(delegator_, d.delegatee, force_, strict_);
            }
        } catch {
            _requireNotStarved(_gasBefore);
            emit DelegationUpdateFailed(delegator_);
        }
    }

    /// @dev The gas cap on every call into the vote-delegation module (the
    ///      window probe has its own). An honest call is bounded:
    ///      `_calculateExpirations` walks at most 240 SIX_DAYS buckets, one
    ///      cold SLOAD per bucket on chain, about 0.6 million gas per
    ///      delegatee at the clamp (warm, in a single test transaction, about
    ///      140k); on top of it run two `notifyVotesChanged` relays, each
    ///      capped at the module's `RELAY_GAS_BUDGET` (150,000), and the
    ///      deployed Aragon adapter's uncapped `notifyDelegateChanged`, which
    ///      walks every position of the token's owner at the call (the
    ///      recipient, on a transfer), about 5.5k gas each, with no bound.
    ///      That relay is the module's last statement and is try/catch'd, so
    ///      above roughly 1,450 positions only the `DelegateChanged` relay is
    ///      lost: the delegation is still recorded and an honest call still
    ///      RETURNS inside the ceiling.
    ///
    ///      So a call that consumed the whole ceiling and still failed is the
    ///      module's fault, not a starved caller's, and the starvation tripwire
    ///      tolerates it (refusing would only trap principal). Called directly,
    ///      this keeps the swallow closed to a caller-chosen gas limit: the
    ///      inner call would have to consume more than the ceiling AND fail.
    ///      Behind the delegatecall proxy `REMOVAL_GAS_FLOOR` does that job
    ///      for the re-delegations that arm, disarm or re-book an armed
    ///      position and for the armed transfer's fallback removal (an
    ///      owner's self-transfer of an armed position and the transfer's
    ///      move are not floored: a starved one is a refusal that leaves the
    ///      record as it was, and a refused move meets the floor at the
    ///      fallback): `_reDelegate` checks it first, so `disableAutoRelock`
    ///      and `retireStaleAutoRelock` revert `DelegationCallStarved` rather
    ///      than commit with the flat term booked, whatever gas limit the
    ///      caller sends. The gas response stays MONOTONE: a holder behind a
    ///      module that exhausts its allowance escapes by sending more gas.
    uint256 private constant DELEGATION_GAS_CEILING = 8_000_000;
    /// @dev Gas cap for the window probe (`legacyDatingActive`).
    uint256 private constant DATING_WINDOW_PROBE_GAS = 50_000;

    /// @dev Gas cap on the reward-distributor call. It bounds waste, not
    ///      starvation: under EIP-150 the literal binds only while more than
    ///      64/63 of it (8,126,984 gas) remains at the call; in a smaller frame
    ///      the distributor still gets all but 1/64. It must stay well above an
    ///      honest distributor's catch-up cost, which grows with the number of
    ///      untouched SIX_DAYS buckets: a cap below it does not bound an
    ///      attacker, it stalls an honest settlement for good, because the span
    ///      only grows. The cap also bounds `createLockWithAutoRelock`: it
    ///      calls the distributor three times before the arming re-delegation,
    ///      which needs `REMOVAL_GAS_FLOOR` left, so under a distributor that
    ///      spends more than about 6.8 million gas per call (less when the
    ///      owner already holds many positions) it cannot fit in a 30M block
    ///      (the owner then uses `createLock`, then `enableAutoRelock`). A
    ///      distributor must keep its per-call cost well below that.
    uint256 private constant REWARD_GAS_CEILING = 8_000_000;

    /// @dev `bytes4(keccak256("DelegationSlopeOverflow()"))`: the one module
    ///      revert `disableAutoRelock` re-raises.
    bytes4 private constant DELEGATION_SLOPE_OVERFLOW_SELECTOR = 0xf2b4513c;

    /// @dev The removal gas floor (8,176,984 gas): what must still be left
    ///      before a call that retires or books a flat term -- the armed
    ///      transfer's FALLBACK REMOVAL (see `_transferFromUnguarded`) and every
    ///      re-delegation `_reDelegate` makes with `force_` or for an armed
    ///      position (`enableAutoRelock`, `createLockWithAutoRelock`,
    ///      `disableAutoRelock`, `retireStaleAutoRelock`, and `increaseAmount` /
    ///      `increaseUnlockTime` while armed): enough for the CALL to hand the
    ///      module the whole `DELEGATION_GAS_CEILING` (EIP-150 forwards 63/64 of
    ///      what is left), plus a reserve for the code between this check and
    ///      the CALL. `_requireNotStarved` cannot stand in for it: behind a
    ///      delegatecall proxy -- which is how the live `VeHemiVoteDelegation`
    ///      is deployed -- a callee that runs out of gas hands back about 1/32
    ///      of the frame, above the 1/63 tripwire, so a starved call reads as a
    ///      refusal. Without this floor a caller who picks the gas limit could
    ///      commit a flat term that never expires (a starved retirement, or a
    ///      refused move followed by a starved removal) or leave an armed
    ///      position's weight uncounted. With it those calls always get the full
    ///      ceiling, and the gas response stays monotone: a caller that sends
    ///      too little gets `DelegationCallStarved` and resends. It is a
    ///      gas-LIMIT requirement (8,176,984 at the check plus what the call
    ///      spends before it: with no reward distributor installed and the
    ///      global point current, about 8.8 million for a typical call and
    ///      about 9.2 million for `createLockWithAutoRelock`, more, up to about
    ///      17 million, when its owner already holds many positions or its
    ///      first booking goes to a delegatee not checkpointed for months (both
    ///      costs fall inside that booking, capped at
    ///      `DELEGATION_GAS_CEILING`); the armed transfer's fallback removal
    ///      needs more when the refused move's delegatees were not checkpointed
    ///      for months; each distributor notification before the check adds its
    ///      own cost, up to 8,000,000 gas: one for most of these calls, two for
    ///      the armed transfer's fallback removal, three for
    ///      `createLockWithAutoRelock`; each SIX_DAYS bucket the global point
    ///      lags adds up to about 150,000 gas of catch-up), far above the gas
    ///      these calls use.
    uint256 private constant REMOVAL_GAS_FLOOR =
        DELEGATION_GAS_CEILING + DELEGATION_GAS_CEILING / 63 + 50_000;

    /// @dev The starvation tripwire. VeHemi wraps every call into the
    ///      vote-delegation module in a try/catch so a broken module cannot
    ///      lock a user's principal; that swallow is load-bearing and stays.
    ///      The tripwire tells a BROKEN module from a STARVED one.
    ///
    ///      EIP-150: a CALL is handed `g - g/64` of the gas available at the
    ///      CALL opcode and the caller keeps `g/64`. A module called DIRECTLY
    ///      that runs out of gas therefore returns leaving at most
    ///      `gasBefore_/64` here; a callee that reverted for any other reason
    ///      returns leaving nearly all of `gasBefore_`; `gasBefore_ / 63`
    ///      separates the two. Behind a delegatecall proxy -- how the live
    ///      vote-delegation module is deployed -- the proxy keeps and returns
    ///      its own 1/64, so a starved call leaves about `gasBefore_/32` and
    ///      reads as a refusal.
    ///
    ///      Reverting on the starved branch therefore turns "outer commits,
    ///      inner is swallowed" into "the whole transaction reverts" only for a
    ///      directly called module. Behind the proxy the re-delegations
    ///      listed at `REMOVAL_GAS_FLOOR` are guarded by that floor instead;
    ///      the `forfeit` and `withdraw` removals are not, and a starved one
    ///      leaves too little gas to finish the burn, so the call reverts out
    ///      of gas. A starved re-book of an UNARMED position can still
    ///      commit, with `DelegationUpdateFailed`, as an under-count, as on
    ///      the replaced implementation.
    ///
    ///      The ratio cannot tell a caller who under-funds the call from a
    ///      module that eats its whole allowance; the absolute consumption can
    ///      (second condition below, see `DELEGATION_GAS_CEILING`).
    ///
    ///      It does not close the swallow class: a module that reverts for a
    ///      REAL reason is still swallowed, deliberately, so a version-skewed
    ///      module that refuses every write (where `createLock` succeeds and
    ///      silently stops delegating) stays possible. The retirement read-back
    ///      (`_requireFlatTermRetired`) covers the retirement paths only.
    function _requireNotStarved(uint256 gasBefore_) internal view {
        uint256 _left = gasleft();
        if (_left < gasBefore_ / 63 && gasBefore_ - _left < DELEGATION_GAS_CEILING) {
            revert DelegationCallStarved();
        }
    }

    /// @dev The retirement read-back. After a call that should have retired
    ///      a flat term, read the record back instead of inferring success
    ///      from the call returning. `(slope == 0 && bias > 0)` is the flat
    ///      discriminator `VeHemiVoteDelegation.sol::_delegate` uses on its own
    ///      old side; after a real retirement the record is decaying or carries
    ///      zero weight. Callers: `_endAutoRelock` and the armed transfer, which
    ///      reads back only after its move was accepted. A STARVED retirement
    ///      never reaches this read behind the delegatecall proxy:
    ///      `REMOVAL_GAS_FLOOR` is checked before the re-delegation in
    ///      `_endAutoRelock`, and a starved transfer move reads as a refusal and
    ///      meets the floor at the fallback removal. (`forfeit`, `withdraw` and
    ///      the transfer's fallback removal clear a flat term with a
    ///      `_delegate(id, address(0))` removal and are not read back.)
    ///
    ///      It catches what leaves the module's OWN RECORD flat (an out-of-gas
    ///      inner call, a call site that forgets `force_`, a module that
    ///      returns without writing), not every failure: the flat term lives in
    ///      the delegatee's checkpoint `fixedBias`, and a module that writes a
    ///      truthful, non-flat record but leaves the term on the checkpoint
    ///      passes. The record test is a proxy for record-checkpoint coherence.
    ///
    ///      It ANNOUNCES (`AutoRelockRetirementUnverified`) whether the record
    ///      reads flat or cannot be read, and does not revert: a revert would
    ///      close `disableAutoRelock`, `retireStaleAutoRelock` and -- since
    ///      `withdraw` refuses while armed -- `withdraw` at once, trapping the
    ///      principal while the flat term stands exactly as it does in the
    ///      committed state. A flat term books no expiration bucket, so no
    ///      amortiser clears it; a later re-delegation,
    ///      `VeHemiVoteDelegation.sol::retireStrandedFlatTerm` (permissionless)
    ///      or the `withdraw` removal does. A STARVED read reverts: through
    ///      the tripwire on a directly called module, and behind the
    ///      delegatecall proxy because the gas left cannot finish the call;
    ///      return data that does not decode reverts the caller.
    ///      (The name is kept; the function requires nothing.)
    function _requireFlatTermRetired(uint256 tokenId_) internal {
        uint256 _gasBefore = gasleft();
        try voteDelegation.delegation{gas: DELEGATION_GAS_CEILING}(tokenId_) returns (
            IVeHemiVoteDelegation.Delegation memory d
        ) {
            // Announce, do not revert (see the @dev above and
            // `IVeHemi.sol::AutoRelockRetirementUnverified`).
            if (d.slope == 0 && d.bias > 0) emit AutoRelockRetirementUnverified(tokenId_);
        } catch {
            _requireNotStarved(_gasBefore);
            emit AutoRelockRetirementUnverified(tokenId_);
        }
    }

    /// @dev Revert with SeedingInProgress if the seeding window is open AND the
    ///      caller's operation targets a non-transferable position (the only
    ///      class whose state is reflected in the in-progress accumulator).
    function _requireSeedingNotActiveForNonTransferable(bool isNonTransferable) internal view {
        if (isNonTransferable && seedingStarted && !lockedSeedingFinalized) {
            revert SeedingInProgress();
        }
    }

    /// @dev Shared precondition for `seedBatch` and `finalizeSeeding`.
    ///      Factored so the two SLOADs and two reverts contribute their
    ///      bytecode once.
    ///
    ///      The seeding window spans arbitrarily many blocks, gated only by
    ///      the `seedingStarted` latch and the `!lockedSeedingFinalized`
    ///      invariant. Cross-block correctness rests on three immutability
    ///      properties holding for every seeded position throughout the
    ///      window:
    ///        * `_createLock` rejects new non-transferable mints
    ///          (`_requireSeedingNotActiveForNonTransferable(!transferable_)`),
    ///        * `forfeit` / `increaseAmount` / `increaseUnlockTime` reject
    ///          mutations on non-transferable positions (same guard at each
    ///          entry point),
    ///        * `withdraw` is harmless: by the time a non-transferable
    ///          position becomes withdrawable, `block.timestamp >= lock.end
    ///          >= subEnd`, so its seeded bias has already decayed to zero
    ///          via the `lockedSlopeChanges[subEnd]` write — the seeded
    ///          totals are insensitive to mid-window withdraws.
    ///      `transferableAfter[id]` is written once at mint and never moved;
    ///      `_withdraw` deletes it, but a withdraw requires `block.timestamp >=
    ///      lock.end >= subEnd`, so a deleted entry's seeded bias has already
    ///      decayed to zero. So `(slope, subEnd)` is immutable for every
    ///      scanned id that still exists between its `seedBatch` and
    ///      `finalizeSeeding`. The time-independent
    ///      accumulators (slope·subEnd, slope) therefore remain valid
    ///      regardless of how many blocks the scan spans, and the curve
    ///      materialized at finalize time is `Σ slope·(subEnd − tsFinalize)`
    ///      — identical to a single-block execution at `tsFinalize`, provided
    ///      no seeded `subEnd` falls inside the window (see `finalizeSeeding`).
    ///
    ///      Check order is UX-driven (revert clarity):
    ///        1. `lockedSeedingFinalized` first — `SeedingAlreadyFinalized`
    ///           is the most informative error when an operator calls the
    ///           batched entrypoints after the flow has completed.
    ///        2. `!seedingStarted` second — fires when the batched
    ///           entrypoints are called before `markSeedingStarted`.
    ///
    ///      The state `(finalized=true, started=false)` is unreachable:
    ///      `finalizeSeeding` calls this function first (so latch-flip
    ///      requires `seedingStarted = true`), and neither flag is ever
    ///      cleared. The order therefore matters only for revert clarity.
    function _requireSeedingActive() internal view {
        if (lockedSeedingFinalized) revert SeedingAlreadyFinalized();
        if (!seedingStarted) revert SeedingNotStarted();
    }

    /// @dev Returns the auto-delegate target for an account, or the account itself
    ///      if no auto-delegate is set. try/catch ensures backwards compatibility
    ///      if voteDelegation hasn't been upgraded to support autoDelegate yet.
    function _resolveAutoDelegate(address account_) internal view returns (address) {
        // The starvation tripwire applies here too: this catch SUBSTITUTES
        // `account_` for the configured auto-delegate, with no revert and no
        // event, so a starved read must not be able to redirect a delegation
        // (on a directly called module the tripwire reverts it; behind the
        // proxy the remainder cannot pay for the write that follows).
        uint256 _gasBefore = gasleft();
        try voteDelegation.autoDelegate{gas: DELEGATION_GAS_CEILING}(account_) returns (address result) {
            if (result != address(0)) return result;
        } catch {
            _requireNotStarved(_gasBefore);
        }
        return account_;
    }

    /// @dev Wrapped in try/catch so a broken `voteDelegation` contract can
    ///      never block lock lifecycle operations.
    /// @dev The near-expiry skip below applies only to NEW delegations
    ///      (the module refuses a new delegation for an unarmed lock that
    ///      ends at or before the next hour boundary). The
    ///      `delegatee_ == address(0)` carve-out routes
    ///      forfeit/withdraw cleanup calls through unconditionally;
    ///      `VeHemiVoteDelegation._delegate` handles `delegatee_ == 0`
    ///      expiry-tolerantly so cleanup always succeeds, even after
    ///      `lock.end` has passed.
    /// @dev The `1 hours` literal below MUST stay in sync with
    ///      `VeHemiVoteDelegation.CHECKPOINT_INTERVAL` and `EPOCH_OFFSET=0`
    ///      so the outer guard threshold matches the inner
    ///      `_checkpointTimestamp` formula. If either constant changes in
    ///      `VeHemiVoteDelegation`, update this expression in lock-step.
    function _delegate(uint256 delegator_, address delegatee_) internal {
        _delegate(delegator_, delegatee_, false);
    }

    /// @dev `force_ == true` bypasses the near-expiry skip.
    function _delegate(uint256 delegator_, address delegatee_, bool force_) internal {
        _delegate(delegator_, delegatee_, force_, false);
    }

    /// @dev `strict_` (only from `disableAutoRelock`) re-raises a module
    ///      revert whose selector is `DelegationSlopeOverflow`, with its full
    ///      revert data; every other failure is swallowed and announced
    ///      (`DelegationUpdateFailed`, `DelegationUpdateFailedReason`).
    ///      `committed_` is true iff the module call RETURNED: false when it
    ///      reverted and was swallowed, and false when the near-expiry skip
    ///      ran. Only the armed transfer reads it. It means the module ACCEPTED
    ///      the write, not that it performed it: after the transfer's move a
    ///      module that returns without writing is caught by the retirement
    ///      read-back; the fallback removal is not read back, so a no-op
    ///      removal is silent.
    function _delegate(
        uint256 delegator_,
        address delegatee_,
        bool force_,
        bool strict_
    ) internal returns (bool committed_) {
        // Delegation changes take effect at `block.timestamp + 1` (both legs,
        // `VeHemiVoteDelegation.sol::_moveVotingPowerFromPreviousDelegate` and
        // `VeHemiVoteDelegation.sol::_moveVotingPowerToNewDelegate`); inside
        // the module's upgrade-hour window
        // (`VeHemiVoteDelegation.sol::legacyDatingActive`) at that hour's
        // boundary. The module still refuses a new delegation for an unarmed
        // lock that ends at or before the next hour boundary
        // (`CanNotDelegateExpiredLocks`), so the call is skipped (and
        // announced, below) for such a lock — except when
        // `delegatee_ == address(0)`, which is the forfeit/withdraw cleanup
        // path: it must always run so `delegations[tokenId]` is cleared even
        // when the lock is at or past expiry.
        // An auto-relock position is live whatever its stored end says: the
        // flag, not the date, decides. `force_` admits the disarm
        // re-delegations, which retire a flat term and must never be skipped.
        // (The armed transfer's move passes `force_` too; it would be admitted
        // without it, because the restored end clears the next hour boundary
        // by days. Were the `R >= 2 * SIX_DAYS` floor weakened, dropping it
        // would SKIP the move and fall back to the removal: an under-count,
        // not a phantom. The fallback removal is admitted by the
        // `address(0)` disjunct regardless.)
        uint256 _newDelegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        if (
            force_ ||
            delegatee_ == address(0) ||
            autoRelockRemaining[delegator_] != 0 ||
            _newDelegationStarts < locked[delegator_].end
        ) {
            // The starvation tripwire, site 2 of 2 (see `_requireNotStarved`).
            uint256 _gasBefore = gasleft();
            // The only vote-delegation catch site that calls
            // `voteDelegation.delegate` (the other three are views), so the
            // only one a `CheckpointLayoutViolated` can reach. That revert is
            // cheap, so the tripwire stays silent, and it is KEPT (fail-closed:
            // the corrupt array is not written through). It is swallowed like
            // any other failure -- the NFT transfer stands, the delegatee's
            // record is frozen -- and `DelegationUpdateFailedReason` names the
            // selector, so the freeze is attributable. (On an armed transfer a
            // refused move falls back to the removal; if the corrupt array is
            // the OLD delegatee's, the removal is refused too and
            // `AutoRelockRetirementUnverified` is emitted.)
            try voteDelegation.delegate{gas: DELEGATION_GAS_CEILING}(delegator_, delegatee_) {
                committed_ = true;
            } catch {
                _requireNotStarved(_gasBefore);
                // Bounded copy: read at most 4 bytes of the selector straight
                // from return data into scratch space, so a module returning a
                // huge revert payload cannot make the swallow itself run out of
                // gas. Shorter data is zero-padded (the `mstore` clears the
                // word), so an empty revert -- an out-of-gas -- yields
                // `0x00000000` and does not revert inside the catch. The word
                // is left-aligned with its low 28 bytes clean, which is the
                // `bytes4` representation.
                bytes4 _reason;
                assembly ("memory-safe") {
                    mstore(0x00, 0)
                    let _n := returndatasize()
                    if gt(_n, 4) { _n := 4 }
                    returndatacopy(0x00, 0x00, _n)
                    _reason := mload(0x00)
                }
                // `strict_` is true on the holder's `disableAutoRelock` only;
                // every other caller -- including the permissionless
                // `retireStaleAutoRelock` -- keeps the swallow, so the flag
                // clears for every module whose return data decodes. The
                // re-raise forwards the module's full revert data; the branch
                // always reverts, so copying the payload cannot turn a swallow
                // into an out-of-gas. It is copied at the free-memory pointer,
                // which keeps the block memory-safe.
                if (strict_ && _reason == DELEGATION_SLOPE_OVERFLOW_SELECTOR) {
                    assembly ("memory-safe") {
                        let _p := mload(0x40)
                        returndatacopy(_p, 0x00, returndatasize())
                        revert(_p, returndatasize())
                    }
                }
                emit DelegationUpdateFailed(delegator_);
                emit DelegationUpdateFailedReason(delegator_, _reason);
            }
        } else {
            // The skip is announced: the escrow changed (an `increaseAmount`
            // or an unarmed transfer in the last stretch of a lock) while the
            // delegation did not. `VeHemiVoteDelegation` refuses the same
            // state with `CanNotDelegateExpiredLocks` for a direct caller.
            emit DelegationUpdateSkipped(delegator_);
        }
    }

    // =========================================================================
    // V2: Non-transferrable position weight tracking
    // =========================================================================

    /**
     * @notice Open the seeding window and freeze the seeding range. Subsequent
     *         `seedBatch` calls iterate token IDs in `[1, seedingTargetId)`.
     *         While the window is open and `lockedSeedingFinalized` is false,
     *         `_createLock` rejects new non-transferable positions — without
     *         that guard a permissionless mint could extend `nextTokenId` past
     *         the snapshotted range and the new position would be silently
     *         dropped from the seeded set.
     *
     *         Idempotent against accidental re-call: reverts with
     *         `SeedingAlreadyStarted` once invoked. The `seedingStarted`
     *         latch is monotonic and never cleared, so the same revert
     *         fires after finalization too.
     *
     * @dev    Owner-only because the call snapshots `nextTokenId` into
     *         `seedingTargetId` (the scan upper bound). Once open the
     *         window stays open across blocks until `finalizeSeeding`
     *         completes the scan. While the window is open:
     *           - new non-transferable mints are blocked (`_createLock`),
     *           - non-transferable mutations are blocked (`forfeit`,
     *             `increaseAmount`, `increaseUnlockTime`),
     *           - `seedBatch(...)` and `finalizeSeeding()` are
     *             permissionless so any keeper / community caller can
     *             advance the cursor and finalize once the cursor reaches
     *             the target.
     *
     *         The `seedingStarted` latch is monotonic with no on-chain
     *         reset. The window closes exclusively when `finalizeSeeding`
     *         flips `lockedSeedingFinalized`, which itself requires the
     *         cursor to have reached `seedingTargetId - 1`. If the window
     *         is opened but never finalized, non-transferable mints stay
     *         blocked until an implementation upgrade clears the state;
     *         transferable mints and existing positions are unaffected.
     */
    function markSeedingStarted() external onlyOwner {
        if (seedingStarted) revert SeedingAlreadyStarted();
        seedingStarted = true;
        // `seedingStartedAt` is informational only; it records when the
        // window opened so off-chain monitors can observe progress. The
        // implicit narrowing of `block.timestamp` to uint64 is safe (uint64
        // covers ~584 billion years past the unix epoch).
        seedingStartedAt = uint64(block.timestamp);
        seedingTargetId = nextTokenId;
        emit SeedingStarted(nextTokenId);
    }

    /**
     * @notice Last token ID processed by `seedBatch`. Exposes the otherwise
     *         internal `_seedingProgress.lastProcessedId` so off-chain
     *         drivers (e.g., `scripts/run-seeding-loop.ts`) can detect
     *         cursor completion without depending on a private storage
     *         slot index.
     * @return The most recently processed token ID, or 0 if no batches
     *         have run yet.
     */
    function seedingCursor() external view returns (uint256) {
        return _seedingProgress.lastProcessedId;
    }

    /**
     * @notice Iterate up to `maxIterations` token IDs forward from the last
     *         processed cursor, accumulating slope/bias deltas for
     *         non-transferable positions and writing the matching
     *         slope-change entries on each subcurve.
     * @dev Permissionless: any caller may advance the cursor. The
     *      per-iteration math is a deterministic read of
     *      `(locked[id], transferableAfter[id], forfeitable[id])`; those
     *      values are immutable for non-transferable positions while the
     *      window is open. The skip predicates are NOT time-independent: two
     *      of them compare against `block.timestamp` (`_ta == 0 || _ta <=
     *      block.timestamp`, and the `_lock.end <= block.timestamp` arm), so
     *      WHEN an id is scanned decides WHETHER it is enrolled, and the same
     *      population can produce different seeds with an identical cursor.
     *      The cursor is a witness for the scan, never for the seed; the
     *      operator constraint in `finalizeSeeding` is what makes the seed
     *      equal a single-block scan.
     *      The latch only flips once the cursor reaches the target, so
     *      permissionless advancement cannot prematurely finalize an
     *      incomplete seed.
     *
     *      Each accepted position contributes:
     *        * `slope = lock.amount / MAX_TIME`
     *        * `bias += slope * subEnd` (time-independent; the bias-at-T
     *          is derived in `finalizeSeeding`)
     *        * `lockedSlopeChanges[subEnd] -= slope`
     *        * if `forfeitable[id]`: same accumulation against the
     *          forfeitable subcurve totals + `forfeitableSlopeChanges`.
     *
     *      Burned, transferable, expired, and already-mature positions are
     *      silently skipped. Slope-change writes during batches are
     *      invisible to `_checkpoint` because `lockedSeedingFinalized` is
     *      still false (the global epoch advance happens once, inside
     *      `finalizeSeeding`).
     *
     *      `maxIterations` has no upper bound: the caller picks the chunk
     *      size that fits the block gas limit, and the cursor is clamped
     *      to `seedingTargetId` so a generous value harmlessly converges.
     * @param maxIterations Maximum number of token IDs to scan in this call.
     */
    function seedBatch(uint256 maxIterations) external {
        _requireSeedingActive();

        SeedingProgress storage progress = _seedingProgress;
        // `lastProcessedId` is 0 when no batch has run yet, so 0+1 = 1 is
        // the first scannable id either way.
        uint256 startId = progress.lastProcessedId + 1;
        // Cursor at the end — no-op convergence. Callers can monitor
        // progress via the `seedingCursor()` view; `finalizeSeeding`
        // reverts `SeedingIncomplete(lastProcessedId, expectedEnd)` on an
        // unfinished scan, the practical end-of-flow signal.
        if (startId >= seedingTargetId) return;
        // Compute endIdExclusive without overflowing when callers pass
        // type(uint256).max as maxIterations. Clamp BEFORE the add.
        uint256 remaining = seedingTargetId - startId;
        uint256 step = maxIterations < remaining ? maxIterations : remaining;
        uint256 endIdExclusive = startId + step;

        // Accumulate per-batch in stack-locals to avoid one SSTORE per token.
        int128 batchSlope;
        int128 batchBias;
        int128 batchForfSlope;
        int128 batchForfBias;
        uint256 batchCount;

        // IMPORTANT — skip-condition coupling: the same filter is duplicated
        // in `test/Invariant.t.sol` (`invariant_nonTransferableEqualsPerPositionSum`
        // and `invariant_forfeitableEqualsPerPositionSum`). Any change to the
        // skip predicates below (e.g., a future V3 slash-skip) MUST be
        // mirrored in both invariant reconstructions, otherwise both sides
        // diverge by the same amount and the invariant becomes a tautology.
        //
        // THIRD MIRROR: the seeding guard, in BOTH arming paths
        // (`enableAutoRelock` and the arm-at-creation block of `_createLock`),
        // is the exact inverse of the `_ta` skip below -- it refuses a
        // pre-seed arm only for ids this loop would ENROL. Any change to the
        // `_ta` predicate MUST be mirrored in both, or the guard starts
        // admitting a position the scan enrols (a dependence on how the curve
        // library treats armed positions, which the guard exists to avoid) or
        // refusing one it skips (feature DoS).
        for (uint256 id = startId; id < endIdExclusive; ++id) {
            if (_ownerOf(id) == address(0)) continue;
            uint256 _ta = transferableAfter[id];
            // Skip transferable positions (transferableAfter == 0) and
            // positions whose transferability window has already opened
            // (no subcurve membership).
            if (_ta == 0 || _ta <= block.timestamp) continue;
            LockedBalance memory _lock = locked[id];
            if (_lock.amount <= 0 || _lock.end <= block.timestamp) continue;

            int128 slope = _lock.amount / MAX_TIME.toInt256().toInt128();
            uint256 _subEnd = _lock.end < _ta ? _lock.end : _ta;
            int128 _subEndI = uint256(_subEnd).toInt256().toInt128();

            batchSlope += slope;
            batchBias += slope * _subEndI;
            lockedSlopeChanges[_subEnd] -= slope;
            unchecked {
                ++batchCount;
            }

            if (forfeitable[id]) {
                batchForfSlope += slope;
                batchForfBias += slope * _subEndI;
                forfeitableSlopeChanges[_subEnd] -= slope;
            }
        }

        // Flush batch into the persistent accumulator.
        progress.lastProcessedId = endIdExclusive - 1;
        progress.totalSlope += batchSlope;
        progress.totalBias += batchBias;
        progress.totalForfeitableSlope += batchForfSlope;
        progress.totalForfeitableBias += batchForfBias;
        progress.count += batchCount;
    }

    /**
     * @notice Materialize the accumulated totals into the locked +
     *         forfeitable `LockedPoint`s and flip the seeding latch.
     *         Requires `seedBatch` to have advanced the cursor all the way
     *         to `seedingTargetId - 1`; an incomplete cursor reverts with
     *         `SeedingIncomplete` so the caller can finish the scan before
     *         finalizing.
     * @dev Permissionless: any caller may finalize once the cursor reaches
     *      `seedingTargetId - 1`. This is the "latch only unlatches at max
     *      position" property — `finalizeSeeding` reverts on an incomplete
     *      cursor, so an attacker cannot prematurely flip
     *      `lockedSeedingFinalized` regardless of caller identity. Once the
     *      cursor is complete, the resulting `LockedPoint` values are a
     *      deterministic function of the accumulator state and
     *      `block.timestamp` — identical no matter who calls.
     *
     *      Materialization advances the global epoch with `_checkpoint(0, …)`
     *      (subcurve logic stays skipped because `lockedSeedingFinalized` is
     *      still false at this point), writes both `LockedPoint`s at
     *      `block.timestamp`, flips the latch, and clears the accumulator.
     *      The aggregate math is identical regardless of how many
     *      `seedBatch` calls produced the totals or which blocks they
     *      spanned.
     *
     *      OPERATIONAL CONSTRAINT — THE VARIABLE IS PHASE, NOT PROMPTNESS.
     *      The materialized LockedPoint uses `bias = totalBias - totalSlope *
     *      tsFinal`. If `tsFinal >= subEnd` for any seeded position, that
     *      position contributes a negative term to the bias AND its slope
     *      change at `subEnd` has already been written by `seedBatch` — the
     *      post-finalize supply walk will not revisit that bucket, so the
     *      position is carried in the subcurve past its true subEnd.
     *      Every `subEnd` is a multiple of `SIX_DAYS`: every writer of
     *      `lock.end` (`VeHemi.sol::_createLock`, `VeHemi.sol::increaseUnlockTime`,
     *      and on auto-relock positions `VeHemi.sol::_disarmAutoRelock` and the
     *      re-materialisation in `VeHemi.sol::_depositFor`) and the single
     *      writer of `transferableAfter` (in `VeHemi.sol::_createLock`) produce a
     *      multiple of `SIX_DAYS`, and `min` of two multiples of `SIX_DAYS` is
     *      one. So a seeded `subEnd` can fall in `(t_batch, t_final]` only if
     *      the seeding window straddles a `SIX_DAYS` boundary: a three-day
     *      window inside one bucket cannot fire it; a twelve-second window
     *      across one can. The operator check is therefore
     *      `floor(t_mark / SIX_DAYS) == floor(t_final / SIX_DAYS)`, planned
     *      before calling `markSeedingStarted` and confirmed before calling
     *      `finalizeSeeding`.
     */
    function finalizeSeeding() external {
        _requireSeedingActive();

        SeedingProgress storage progress = _seedingProgress;
        // seedingTargetId is the EXCLUSIVE upper bound of the scan, so the
        // last scannable ID is seedingTargetId - 1. If seedingTargetId is 1
        // (i.e., markSeedingStarted ran before any mint), there is nothing
        // to scan and the cursor stays at 0 — that's still "complete".
        uint256 expectedEnd = seedingTargetId == 0 ? 0 : seedingTargetId - 1;
        if (progress.lastProcessedId < expectedEnd) {
            revert SeedingIncomplete(progress.lastProcessedId, expectedEnd);
        }

        // Snapshot totals before clearing the accumulator. SLOADs are
        // cheaper than re-deriving from per-position data.
        int128 _totalSlope = progress.totalSlope;
        int128 _totalBias = progress.totalBias;
        int128 _totalForfeitableSlope = progress.totalForfeitableSlope;
        int128 _totalForfeitableBias = progress.totalForfeitableBias;

        // Advance the global epoch to block.timestamp. Subcurve logic in
        // `_checkpoint` remains gated on `lockedSeedingFinalized`, which is
        // still false here, so the slope-change entries written by the
        // batches are invisible to the catchup walk.
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));

        uint256 _epoch = epoch;
        int128 _tsInt = uint256(block.timestamp).toInt256().toInt128();

        // Locked point: derive bias at block.timestamp from time-independent total.
        int128 _lockedBias = _totalBias - _totalSlope * _tsInt;
        if (_lockedBias < 0) _lockedBias = 0;

        lockedGlobalPointHistory[_epoch] = LockedPoint({
            bias: _lockedBias,
            slope: _totalSlope,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64()
        });

        // Forfeitable point: always write (even if zero) so timestamp != 0 for view functions.
        int128 _forfeitableBias = _totalForfeitableBias - _totalForfeitableSlope * _tsInt;
        if (_forfeitableBias < 0) _forfeitableBias = 0;

        forfeitableGlobalPointHistory[_epoch] = LockedPoint({
            bias: _forfeitableBias,
            slope: _totalForfeitableSlope,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64()
        });

        lockedSeedingFinalized = true;
        delete _seedingProgress;

        emit LockedSeedingFinalized(_epoch);
    }

    /**
     * @notice Get the total non-transferrable veHEMI supply at the current timestamp.
     * @return The subcurve weight of all non-transferable positions; each
     *         decays to zero at its `transferableAfter`, also while
     *         auto-relock holds its voting weight constant
     */
    function nonTransferableTotalVeHemiSupply() public view returns (uint256) {
        return _subcurveSupplyAt(block.timestamp, false);
    }

    /**
     * @notice Get the total non-transferrable veHEMI supply at a specific timestamp.
     * @param timestamp_ The timestamp to query
     * @return The subcurve weight of all non-transferable positions at that time; each
     *         decays to zero at its `transferableAfter`, also while
     *         auto-relock holds its voting weight constant
     */
    function nonTransferableTotalVeHemiSupplyAt(uint256 timestamp_) public view returns (uint256) {
        return _subcurveSupplyAt(timestamp_, false);
    }

    /**
     * @notice Get the total forfeitable (non-transferrable) veHEMI supply at the current timestamp.
     * @return The subcurve weight of all forfeitable positions; each
     *         decays to zero at its `transferableAfter`, also while
     *         auto-relock holds its voting weight constant
     */
    function forfeitableTotalVeHemiSupply() public view returns (uint256) {
        return _subcurveSupplyAt(block.timestamp, true);
    }

    /**
     * @notice Get the total forfeitable veHEMI supply at a specific timestamp.
     * @param timestamp_ The timestamp to query
     * @return The subcurve weight of all forfeitable positions at that time; each
     *         decays to zero at its `transferableAfter`, also while
     *         auto-relock holds its voting weight constant
     */
    function forfeitableTotalVeHemiSupplyAt(uint256 timestamp_) public view returns (uint256) {
        return _subcurveSupplyAt(timestamp_, true);
    }

    /**
     * @notice Combined supply breakdown avoiding redundant binary searches.
     * @dev `forfeitable_ <= locked_` holds STRUCTURALLY: the forfeitable subcurve is
     *      accumulated from a subset of the locked subcurve's membership events with
     *      identical deltas, so no clamp is required and none is applied.
     *
     *      `locked_ <= total` does NOT hold. An auto-relock non-transferable position
     *      contributes its constant weight `slope * (R - SIX_DAYS/2)` to `total` and
     *      its decaying weight `slope * (transferableAfter - now)` to `locked_`, and
     *      the second can exceed the first by up to `slope * SIX_DAYS/2` (most
     *      right after an arm in the first half of a bucket). The excess is bounded
     *      by `SUM(slope_i) * SIX_DAYS/2` over those positions, at most a third of the
     *      global point's `amount` (R >= 2 * SIX_DAYS). `transferable` therefore
     *      SATURATES AT ZERO rather than underflowing. `locked_` and `forfeitable_`
     *      are returned RAW and equal `nonTransferableTotalVeHemiSupply()` and
     *      `forfeitableTotalVeHemiSupply()` in the same block. The saturating
     *      `transferable` also absorbs rounding skew between the curves and the
     *      period before `finalizeSeeding`, when the subcurve points are unwritten
     *      and read 0. No value is clamped, because a clamp that fires is
     *      indistinguishable from a correct answer to every downstream consumer.
     * @return total Total veHEMI supply
     * @return locked_ Non-transferrable veHEMI supply (RAW; == nonTransferableTotalVeHemiSupply())
     * @return forfeitable_ Forfeitable non-transferrable veHEMI supply (RAW; == forfeitableTotalVeHemiSupply())
     * @return transferable Transferrable veHEMI supply (`total - locked_`, saturating at 0)
     */
    function supplyBreakdown() external view returns (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) {
        return VeHemiSupplyLib.supplyBreakdown();
    }

    function _subcurveSupplyAt(uint256 timestamp_, bool isForfeitable_) internal view returns (uint256) {
        return VeHemiSupplyLib.subcurveSupplyAt(timestamp_, isForfeitable_);
    }

    function _supplyAt(uint256 timestamp_) internal view returns (uint256) {
        return VeHemiSupplyLib.supplyAt(timestamp_);
    }

    /// @dev Notifies the reward distributor of a position change. Fails silently (try/catch)
    ///      so a broken distributor cannot block core operations.
    ///      A reverting distributor is swallowed (`RewardUpdateFailed`), and unlike
    ///      the vote-delegation sites there is no starvation tripwire: an
    ///      out-of-gas distributor call is absorbed, not refused, so the
    ///      distributor can never trap principal. `REWARD_GAS_CEILING` caps waste
    ///      only. With `rewardDistributor == address(0)` the `!= address(0)` gate
    ///      below short-circuits; a distributor address with no code is skipped
    ///      without an event.
    function _updateReward(uint256 tokenId_) internal {
        address _rd = address(rewardDistributor);
        if (_rd != address(0) && _rd.code.length != 0) {
            try rewardDistributor.updateRewards{gas: REWARD_GAS_CEILING}(tokenId_) {} catch {
                emit RewardUpdateFailed(tokenId_);
            }
        }
    }

    /**
     * @dev Internal withdraw: clears lock, checkpoints curves, burns NFT, transfers HEMI to msg.sender.
     *      Used by both withdraw() (owner receives HEMI) and forfeit() (forfeit admin receives HEMI).
     *      Checkpoint is called BEFORE burn so the final user point records the real owner.
     *      transferableAfter/forfeitable/provider are deleted AFTER checkpoint (which reads them).
     */
    function _withdraw(uint256 tokenId_) internal {
        _updateReward(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];
        uint256 _amount = _oldLocked.amount.toUint256();
        delete locked[tokenId_];
        // Clear the auto-relock flag BEFORE `_checkpoint` so the library sees a
        // dead new side and removes the flat term from the global aggregate.
        delete autoRelockRemaining[tokenId_];
        delete autoRelockRefreshedAt[tokenId_]; // the heartbeat stamp dies with the token
        totalLocked -= _amount;
        // Checkpoint BEFORE burn so the final user point records the real owner
        // (not address(0)). newLocked is zero, so _checkpoint correctly subtracts
        // the old position's bias/slope from the global curve. For expired locks,
        // the old bias/slope are already zero. For forfeit (non-expired), the
        // subtraction is necessary to maintain global curve correctness.
        // NOTE: transferableAfter must NOT be deleted before this call — _checkpoint
        // reads it to determine locked-curve membership for non-transferrable positions.
        _checkpoint(tokenId_, _oldLocked, LockedBalance(0, 0));
        // Clean up remaining state AFTER checkpoint.
        // forfeitable must also be deleted here (not just in forfeit()) so that
        // naturally-expired forfeitable positions are properly cleaned up on withdraw.
        delete transferableAfter[tokenId_];
        delete forfeitable[tokenId_];
        delete provider[tokenId_];
        _burn(tokenId_);

        address _sender = _msgSender();
        if (_amount > 0) {
            HEMI.safeTransfer(_sender, _amount);
        }

        emit Withdraw(_sender, tokenId_, _amount, block.timestamp);
    }

    /**
     * @notice ERC721 transfer override with veHEMI-specific semantics.
     * @dev Transfer re-delegation: the NFT's delegation is reset on every transfer via
     *      `_resolveAutoDelegate(to_)`. If the recipient has set an auto-delegate target
     *      via `VeHemiVoteDelegation.delegateAllFor` (typically through the Aragon
     *      adapter's `delegate(address)`), the position is delegated to that target;
     *      otherwise it self-delegates to the recipient. This means a transfer into
     *      an account that has already chosen a governance delegatee does NOT
     *      silently re-point voting power at the new owner — it tracks their
     *      declared delegate. If the delegation module refuses that write, the
     *      position keeps its old delegation record (an armed position normally
     *      loses it instead — see below); so does an UNARMED position transferred
     *      in the last `((end - 1) mod 3600) + 1` seconds (360-3600 s) of its lock,
     *      or after its end, where VeHemi skips the update
     *      (`DelegationUpdateSkipped`; see `IVeHemi.sol::DelegationUpdateSkipped`).
     *      This is accepted behaviour, with a consequence: such a record still
     *      names the PREVIOUS owner's delegatee, and a later `increaseUnlockTime`,
     *      `increaseAmount`, `enableAutoRelock` (and a later
     *      `retireStaleAutoRelock`) re-books the position's weight to that
     *      delegatee (constant while auto-relock is on). The new owner cannot move
     *      the weight with `delegate()` while the lock ends at or before the next
     *      hour boundary (`CanNotDelegateExpiredLocks`; a stranded flat record is
     *      the exception: that call retires it, booking nothing); extending it with
     *      `increaseUnlockTime` first re-books the weight to the PREVIOUS
     *      delegatee, after which the new owner must call `delegate()` to take it
     *      back. A position transferred after its end has no weight to recover.
     *
     *      Auto-relock: transferring an ARMED position to a different account
     *      disarms it first and retires its flat weight in the same re-delegation.
     *      The recipient receives an ordinary decaying lock whose end is
     *      `effectiveLockEnd(tokenId)` as evaluated in the transfer block (while a
     *      position is armed, `getLockedBalance(tokenId).end` is NOT its unlock
     *      time). The disarm emits `AutoRelockDisabled` before `Transfer`, with no
     *      `AutoRelockRetired`, whether the owner or an approved operator sends.
     *      If the module refuses the move to the target, the delegation record is
     *      REMOVED instead, so the position arrives undelegated until the new owner
     *      delegates it — its votes are missing, not counted twice. The removal is
     *      attempted only with at least 8,176,984 gas left after the refused move
     *      (`REMOVAL_GAS_FLOOR`); with less, the transfer reverts
     *      `DelegationCallStarved` (resend with more gas). That is a gas-LIMIT
     *      requirement far above the gas the transfer uses, so size the limit with
     *      a success-based estimate of a direct call (not from simulated gasUsed,
     *      and not through a frame that catches reverts). If the module
     *      refuses the removal too, the record is left as it was and
     *      `AutoRelockRetirementUnverified` is emitted. An owner's transfer to
     *      themself keeps the position armed.
     *
     *      Mints never reach this function: OZ `_mint` goes through `_update`, and a
     *      call with `from_ == address(0)` always reverts inside `super.transferFrom`.
     *      Initial delegation for minted positions happens inside the mint flow
     *      (`createLock` / `createLockFor` / `createLockWithAutoRelock`) via
     *      `_resolveAutoDelegate`.
     */
    function transferFrom(
        address from_,
        address to_,
        uint256 tokenId_
    ) public override(ERC721Upgradeable, IERC721) nonReentrant {
        _transferFromUnguarded(from_, to_, tokenId_);
    }

    /// @notice Same veHEMI semantics as `transferFrom` (re-delegation,
    ///         auto-relock disarm-on-transfer, move-or-remove, the
    ///         `DelegationCallStarved` gas floor); see `transferFrom`'s
    ///         developer notes. The 3-arg overload forwards here.
    /// @dev    `safeTransferFrom` takes the guard ITSELF and holds it across
    ///         `checkOnERC721Received`, so a receiver hook that re-enters a
    ///         guarded VeHemi function reverts with
    ///         `ReentrancyGuardReentrantCall`.
    function safeTransferFrom(
        address from_,
        address to_,
        uint256 tokenId_,
        bytes memory data_
    ) public override(ERC721Upgradeable, IERC721) nonReentrant {
        _transferFromUnguarded(from_, to_, tokenId_);
        ERC721Utils.checkOnERC721Received(_msgSender(), from_, to_, tokenId_, data_);
    }

    function _transferFromUnguarded(
        address from_,
        address to_,
        uint256 tokenId_
    ) private {
        bool _disarmed;
        if (from_ != address(0)) {
            // An OPERATOR self-transfer changes no ownership and consumes no
            // approval, yet would reset the delegatee via
            // `_resolveAutoDelegate`: an unconsented third-party mutation of
            // the position's delegatee (both legs land at the same instant, so
            // weight is conserved, not blacked out). The OWNER's own
            // self-transfer (re-apply my autoDelegate) is a supported flow and
            // is allowed.
            if (from_ == to_ && _msgSender() != from_) revert NotOwner();
            if (!isTransferable(tokenId_)) revert NotTransferable();
            // DISARM-ON-TRANSFER, "MOVE OR REMOVE" (see `transferFrom`): a
            // transfer to another account disarms an armed position, so nobody
            // is left holding a position armed without their consent (an
            // operator's arm-then-transfer-back delivers it DISARMED). Only the
            // VeHemi half runs here, BEFORE super.transferFrom
            // (`_disarmAutoRelock`; no module call). The flat term stays booked
            // at the OLD delegatee until the post-transfer re-delegation below:
            //   1. MOVE it to the recipient's resolved delegate (`force_`,
            //      non-strict) and, if accepted, read the record back.
            //   2. If refused (a slope-saturated target, an overflowing whale
            //      position, a broken module), REMOVE the record behind the
            //      removal gas floor; a removal only subtracts and cannot
            //      overflow. The position arrives UNDELEGATED: an under-count,
            //      never a phantom at the old delegatee behind an honest module
            //      (a module that accepts the removal without performing it is
            //      not detected). The module then reports
            //      `DelegateChanged(id, oldDelegatee, 0)` for a LIVE token.
            //   3. If the removal is refused too, announce
            //      `AutoRelockRetirementUnverified`; the record stays flat at
            //      the OLD delegatee.
            // Unlike `disableAutoRelock` the transfer re-books at the NEW
            // delegatee and is never strict: a transfer resets the delegation
            // anyway, and an approved operator cannot act on a refusal. Its
            // armed-only refusals are gas (`DelegationCallStarved`) and return
            // data that does not decode at the read-back. A position disarmed
            // earlier (e.g. by `retireStaleAutoRelock`) takes the unarmed path:
            // one non-forced move and no removal fallback; an accepted move
            // clears a flat record a swallowed retirement left behind, a
            // refused or skipped one leaves it. `isTransferable` is checked
            // first, so an armed position inside its transfer floor is never
            // disarmed, and the `end >= transferableAfter` check in
            // `_disarmAutoRelock` cannot fire here (`grid(now) + R >=
            // grid(now) + 2 * SIX_DAYS > now >= transferableAfter`). The
            // owner's own self-transfer (`from_ == to_`) changes no ownership
            // and keeps the position armed.
            if (from_ != to_ && autoRelockRemaining[tokenId_] != 0) {
                _disarmed = true;
                _disarmAutoRelock(tokenId_);
            }
            // The transfer's one reward notify; after a disarm it re-anchors on
            // the new (decaying) weight -- `_disarmAutoRelock` already sent the
            // notify-before.
            _updateReward(tokenId_);
        }

        // ERC721 ownership transfer happens BEFORE _delegate so that the
        // notifyDelegateChanged hook (which resolves ownerOf(tokenId) inside
        // VeHemiVoteDelegation._delegate) sees `to_` as the current owner.
        // On an armed transfer every delegation write, the flat-term
        // retirement included, therefore comes after this line.
        // Without this ordering, the IVotes-shaped DelegateChanged event would
        // incorrectly attribute the delegation change to the SELLER (from_),
        // silently corrupting subgraphs that reconstruct delegation state from
        // the event stream. Math is unaffected: locked[tokenId] is unchanged
        // across the ERC721 transfer and the cached delegation values used by
        // _delegate are identical pre- and post-super.transferFrom.
        super.transferFrom(from_, to_, tokenId_);

        if (from_ != address(0)) {
            address _target = _resolveAutoDelegate(to_);
            if (!_disarmed) {
                _delegate(tokenId_, _target);
            } else if (_delegate(tokenId_, _target, true, false)) {
                // Step 1: the move was accepted; confirm it retired the flat
                // term (announces; reverts only on a STARVED read or on return
                // data that cannot be decoded).
                _requireFlatTermRetired(tokenId_);
            } else {
                // Step 2: the move was refused; remove the record, first making
                // sure the removal gets the full ceiling (the removal gas floor).
                if (gasleft() < REMOVAL_GAS_FLOOR) revert DelegationCallStarved();
                if (!_delegate(tokenId_, address(0), true, false)) {
                    // Step 3: both writes refused. Behind an honest module this
                    // happens only after the two contracts were upgraded
                    // separately or without arming the window, or on a corrupt
                    // old-delegatee array (`CheckpointLayoutViolated`); see
                    // `IVeHemi.sol::AutoRelockRetirementUnverified`.
                    emit AutoRelockRetirementUnverified(tokenId_);
                }
            }
            LockedBalance memory _locked = locked[tokenId_];
            _checkpoint(tokenId_, _locked, _locked);
        }
    }
}

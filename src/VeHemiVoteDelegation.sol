// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IVeHemi} from "./interfaces/IVeHemi.sol";
import {IVeHemiVoteDelegation} from "./interfaces/IVeHemiVoteDelegation.sol";
import {VeHemiDelegationStorageV4} from "./storage/VeHemiDelegationStorageV4.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @dev Minimal interface for reading VeHemi's Ownable2Step owner.
interface IOwnable {
    function owner() external view returns (address);
}

/// @dev Callback interface for relaying DelegateVotesChanged and DelegateChanged events to the adapter.
interface IAdapterNotify {
    function notifyVotesChanged(address delegatee, uint256 previousVotes, uint256 newVotes) external;
    function notifyDelegateChanged(address delegator, address fromDelegate, address toDelegate) external;
}

/**
 * @title VeHemiVoteDelegation
 * @notice Vote delegation system for veHemi tokens. Allows token holders to delegate their voting power
 * to other token holders without transferring ownership. Delegations take effect on the next block
 * (`block.timestamp + 1`), except inside this proxy's upgrade-hour window (`legacyDatingUntil`), where
 * they take effect at the next hour boundary. A decaying delegation expires when the delegator's lock
 * expires; an auto-relock (flat) delegation carries a constant weight in `fixedBias`, books no
 * expiration bucket and does not expire.
 * @dev Based on veFXS and veCRV delegation mechanism with adaptations for veHemi
 */
contract VeHemiVoteDelegation is ReentrancyGuardTransientUpgradeable, VeHemiDelegationStorageV4, IERC5267 {
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for int256;

    // --- Constants ---
    uint256 private constant YEAR = 365.25 days;
    /// @dev SIX_DAYS is the week-ish expiration bucket that must match VeHemi's
    ///      rounding grid exactly: YEAR / 60 = 525,960 seconds ≈ 6.0875 days.
    ///      MONTH is only used as an intermediate to make that division explicit.
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;
    uint256 private constant MAX_LOCK_DURATION = 4 * YEAR;
    /// @dev The hour grid. Delegation writes are dated `_imm()`: `block.timestamp + 1`,
    ///      or the next hour boundary inside this proxy's upgrade-hour window. The grid
    ///      still dates the deferred (pending) checkpoint leg and the expiration
    ///      amortiser, and gates liveness: an unarmed lock that ends at or before the next
    ///      boundary cannot be delegated. A delegation never counts in the block that
    ///      makes it: both legs land after `block.timestamp`, the latest instant
    ///      `getPastVotes` serves.
    uint256 private constant CHECKPOINT_INTERVAL = 1 hours;
    uint256 private constant EPOCH_OFFSET = 0;
    /// @dev `legacyDatingUntil` value meaning "no upgrade-hour window", written by the
    ///      constructor (bare implementation) and by `initialize` (fresh proxy). A proxy
    ///      created with empty data reads 0 until `initialize`, like an un-armed upgrade.
    uint64 private constant NO_LEGACY_WINDOW = 1;

    /// @notice The EIP-712 domain name for this contract.
    string private constant EIP712_NAME = "veHEMIDelegation";
    /// @notice The EIP-712 domain version. Changing this invalidates all outstanding off-chain signatures.
    string private constant EIP712_VERSION = "1.0.0";

    /// @notice The EIP-712 typehash for the contract's domain (4-field form with version per EIP-712).
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @notice EIP-712 typehash for the delegation struct.
    /// @dev    Includes a `uint256 delegator` (tokenId) field — veHEMI's
    ///         delegation is per-tokenId, not account-wide, so a signer
    ///         authorizes the redelegation of ONE specific NFT. This
    ///         diverges from OpenZeppelin's canonical IVotes Delegation
    ///         hash (`Delegation(address delegatee,uint256 nonce,uint256
    ///         expiry)`); tooling assuming the OZ shape will produce digests
    ///         that fail verification here. Integrators wanting an account-
    ///         wide signed flow should issue per-tokenId signatures in a
    ///         batch. See `VeHemiAragonAdapter.delegateBySig`, which is
    ///         declared but reverts for the same reason.
    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice The veHemi contract that manages locked balances
    IVeHemi public immutable veHemi;

    // --- Errors ---
    error InvalidVeHemi();
    error CanNotDelegateExpiredLocks();
    error NotOwner();
    error TimestampInFuture();
    error NoExpirations();
    error InvalidSignature();
    error InvalidNonce();
    error SignatureExpired();
    error InvalidDelegatee();
    error CallerIsNotAuthorized();
    error NotTrustedAdapter();

    /// @dev Gas budget for each `notifyVotesChanged` relay to the adapter (four sites:
    ///      both vote-move legs, `writeNewCheckpointForExpiredDelegations` and
    ///      `refreshVotingPower`). Uncapped, EIP-150 hands the callee 63/64 of the frame,
    ///      and a callee that runs out of gas leaves 1/64, which may not be enough to
    ///      finish the vote move and reach the delegation write; the whole frame then
    ///      unwinds while a VeHemi caller, which catches the failure, commits without the
    ///      update (`DelegationUpdateFailed`). The adapter's `notifyVotesChanged` is a
    ///      check and an emit, so the budget never binds on it; a costlier future adapter
    ///      (set only through `setTrustedAdapter`) would have its relay dropped instead.
    ///
    ///      The `notifyDelegateChanged` relay is deliberately NOT capped. The adapter
    ///      walks every position of the owner (about 5.5k gas each, no bound), and the
    ///      relay is the last statement of `_delegate`, after the record is written, and
    ///      doubly caught: a walk that runs out of gas loses only that relay, never the
    ///      write. Under VeHemi's 8,000,000-gas call ceiling that happens above roughly
    ///      1,450 positions; a cap would lose the `DelegateChanged` event the Aragon
    ///      subgraph indexes for owners with far fewer.
    uint256 internal constant RELAY_GAS_BUDGET = 150_000;
    error NotVeHemiOwner();
    error MigrationFinalizedError();
    error LegacyAddressInvalid();
    error InvalidAdapter();
    error AdditiveBranchExpectsZeroEnd();
    error DelegationSlopeOverflow();
    /// @dev The checkpoint-array layout invariant (see `_applyToCheckpoints`) does not hold
    ///      at the array's tail; raised instead of writing through it. Only a writer of
    ///      `delegateCheckpoints` that breaks the invariant can trigger it. Through VeHemi
    ///      the revert is caught and announced (`DelegationUpdateFailedReason`), and the
    ///      delegatee's checkpoints are left unchanged.
    error CheckpointLayoutViolated();
    /// @dev `armLegacyDatingWindow` called other than as the data of the proxy's
    ///      `upgradeToAndCall` (msg.sender is not the EIP-1967 admin).
    error NotUpgradeCall();
    modifier onlyAuthorized(uint256 tokenId_) {
        address _msgSender = msg.sender;
        if (_msgSender != veHemi.ownerOf(tokenId_) && _msgSender != address(veHemi))
            revert CallerIsNotAuthorized();
        _;
    }

    /**
     * @notice Constructor to initialize the vote delegation contract
     * @param veHemi_ Address of the veHemi contract
     */
    constructor(address veHemi_) {
        if (veHemi_ == address(0)) revert InvalidVeHemi();
        veHemi = IVeHemi(veHemi_);
        legacyDatingUntil = NO_LEGACY_WINDOW; // this instance's OWN storage; a proxy never sees it
        _disableInitializers();
    }

    function initialize() external initializer {
        if (legacyDatingUntil == 0) legacyDatingUntil = NO_LEGACY_WINDOW; // fresh proxy; never clobbers an arm
    }

    /// @notice Arms the upgrade-hour window. Meant only as the data of the upgrade call that
    ///         installs this implementation over the hour-boundary-dating one:
    ///         `ProxyAdmin.upgradeAndCall(proxy, impl, abi.encodeCall(this.armLegacyDatingWindow, ()))`.
    ///         Until the hour boundary that ends the executing block's hour, every write keeps the
    ///         replaced implementation's next-boundary dating (`VeHemiVoteDelegation.sol::_imm`).
    ///         Reachable ONLY inside the proxy's `upgradeToAndCall`: msg.sender must be the EIP-1967
    ///         admin, and a transparent proxy never forwards its admin's calls through its fallback;
    ///         a bare implementation, or a proxy with no EIP-1967 admin, has none. NOT an initializer:
    ///         it touches no Initializable state, so a re-forward after a rollback can arm again.
    function armLegacyDatingWindow() external {
        if (msg.sender != ERC1967Utils.getAdmin()) revert NotUpgradeCall();
        _armLegacyDating(true);
    }

    /// @notice True iff a delegation write made now takes effect LATER than
    ///         `block.timestamp + 1`, i.e. inside this proxy's upgrade-hour window. VeHemi
    ///         refuses to arm auto-relock while it is true (`VeHemi.sol::_voteDelegationDefersWrites`).
    function legacyDatingActive() external view returns (bool) {
        return _imm() != block.timestamp + 1;
    }

    /**
     * @dev Clock used for flagging checkpoints.
     */
    function clock() public view returns (uint48) {
        return block.timestamp.toUint48();
    }

    /**
     * @dev Machine-readable description of the clock as specified in ERC-6372.
     */
    function CLOCK_MODE() public view virtual returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc IERC5267
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f", // fields bitmap: name (0x01) | version (0x02) | chainId (0x04) | verifyingContract (0x08)
            EIP712_NAME,
            EIP712_VERSION,
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    /**
     * @notice Delegate the voting power of a single veHEMI position to an address.
     * @dev Takes effect at `block.timestamp + 1`, the next block; inside this proxy's
     *      upgrade-hour window (`legacyDatingActive`), at the next hour boundary. The
     *      delegator's voting power is moved to the delegatee. A decaying delegation
     *      expires when the delegator's lock expires; an auto-relock delegation is flat
     *      (constant weight in `fixedBias`, no expiration bucket) and does not.
     *      Reverts `CanNotDelegateExpiredLocks` for an UNARMED position whose lock ends at
     *      or before the next hour boundary, unless its stored record is a flat term, which
     *      is then retired and nothing is booked. An auto-relock position can always be
     *      delegated.
     *      To self-delegate, pass the NFT owner's address as delegatee_.
     *      External callers cannot pass address(0) — that path reverts with
     *      InvalidDelegatee. VeHemi passes address(0) to clear the record of a
     *      position it is ABOUT TO BURN (forfeit/withdraw; the clear must run
     *      before the burn, because `onlyAuthorized` calls `ownerOf`, which
     *      reverts for a burned token, and VeHemi swallows that revert) and of a
     *      LIVE auto-relock position, disarmed by its transfer, whose move to the
     *      new owner's delegatee was refused (the position stays owned and
     *      undelegated).
     * @param delegator_ The veHEMI NFT token ID to delegate from (caller must be the NFT owner, or VeHemi)
     * @param delegatee_ The address that will receive this token's voting power (non-zero for every caller except VeHemi)
     */
    function delegate(
        uint256 delegator_,
        address delegatee_
    ) external onlyAuthorized(delegator_) nonReentrant {
        _delegate(delegator_, delegatee_);
    }

    /**
     * @notice Set the trusted adapter contract that can call delegateAllFor.
     * @dev    Non-zero adapters MUST have non-empty bytecode (`code.length > 0`),
     *         else the call reverts `InvalidAdapter`. The notify relays
     *         (`notifyVotesChanged` / `notifyDelegateChanged`) are wrapped in
     *         try/catch and a CALL to a zero-code address returns success
     *         with empty data, so an EOA configured here would silently drop
     *         every relay; the explicit code-length check surfaces the
     *         misconfiguration at set time.
     *
     *         `address(0)` is preserved as an explicit disable; consumers
     *         can monitor `TrustedAdapterUpdated(_, address(0))` to
     *         distinguish a deliberate teardown from a typo. A staticcall
     *         liveness probe of the candidate would always fail against a
     *         conforming adapter because `notifyVotesChanged` emits a log
     *         and `LOG*` is forbidden inside a STATICCALL.
     *
     *         Trust: the adapter may call `delegateAllFor(owner, x)` for ANY owner, so
     *         it can re-delegate any holder's positions and set the holder's
     *         auto-delegate (voting weight only; the holder can undo it). Only
     *         VeHemi's owner can set it, and that owner can already replace this whole
     *         module through `VeHemi.updateVoteDelegation`.
     * @param adapter_ The adapter address (or address(0) to disable).
     */
    function setTrustedAdapter(address adapter_) external {
        if (msg.sender != IOwnable(address(veHemi)).owner()) revert NotVeHemiOwner();
        if (adapter_ != address(0) && adapter_.code.length == 0) revert InvalidAdapter();
        address oldAdapter = trustedAdapter;
        trustedAdapter = adapter_;
        emit TrustedAdapterUpdated(oldAdapter, adapter_);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Legacy state import
    //
    //  When the VeHemi owner calls `veHemi.updateVoteDelegation(newVVD)`,
    //  the pointer swap performs ZERO state migration — every voter's
    //  cached delegation lives in the OLD VVD's storage and the NEW
    //  contract starts empty. To prevent silent vote-zeroing, operators
    //  MUST seed this contract from the legacy one BEFORE the swap.
    //
    //  Operator runbook: docs/VOTE_DELEGATION_RECOVERY.md in this
    //  repository (see also `VeHemi.updateVoteDelegation`). The imports
    //  span several Safe transactions; `finalizeMigration` and the pointer
    //  swap go last, in one MultiSend, and a reconcile follows the swap.
    //
    //  Sealing semantics:
    //    `migrationFinalized` is a one-way latch (slot 50 in V3 storage).
    //    Initially `false`; flipped by `finalizeMigration()`. Both import
    //    functions check `!migrationFinalized` and revert with
    //    `MigrationFinalizedError` once flipped. The latch can NOT be
    //    cleared by any caller (including the owner) — preventing
    //    post-migration state injection that would corrupt the
    //    `getPastVotes` history for snapshots taken after finalize.
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @notice Replay per-tokenId delegations from a legacy VVD into this
     *         contract. Owner-only. Idempotent (already-populated tokenIds
     *         are skipped). Reverts after `finalizeMigration()`.
     *
     * @dev Each (tokenId, delegatee) is replayed via the normal `_delegate`
     *      flow so checkpoint history begins building forward from this
     *      block. Historical `getPastVotes` queries against this contract
     *      for blocks BEFORE the import return zero — that is a fundamental
     *      limitation of the pointer-swap model. Operators should schedule
     *      the migration during a governance freeze (no in-flight
     *      proposals) to avoid bricking active proposals.
     *
     *      Each record is a snapshot: a position that changes while VeHemi still
     *      points at the legacy contract (auto-relock armed or disarmed, an
     *      increase, a transfer) keeps its imported record here, and a re-run
     *      skips it, as it skips a record written here directly before the swap.
     *      Such records are reconciled after the pointer swap; the runbook is
     *      `docs/VOTE_DELEGATION_RECOVERY.md` in this repository. A burned id
     *      with a decaying record (a forfeit between its import and the swap)
     *      cannot be repaired, so disable forfeits from before the first import
     *      until after the swap.
     *
     *      Why not bypass `_delegate`? Replaying via `_delegate`:
     *        (a) emits the standard `DelegateChanged` + `DelegateVotesChanged`
     *            events so indexers see the import as ordinary delegation;
     *        (b) re-runs the same slope/bias math used by future updates,
     *            so the resulting checkpoint state is byte-identical to
     *            what a fresh `delegate()` call would produce; (c) keeps
     *            this function's storage-write surface tiny — the heavy
     *            lifting lives in `_delegate`.
     *
     * @param legacy_  The OLD VeHemiVoteDelegation contract to read from.
     *                 MUST be non-zero. No check that it's the contract
     *                 currently pointed at by `veHemi.voteDelegation()`,
     *                 since this contract typically runs the import
     *                 BEFORE the pointer swap.
     * @param tokenIds_ Pagination cursor — token IDs to replay. Caller is
     *                 responsible for enumeration; operator should run
     *                 this function repeatedly in chunks until the full
     *                 set is covered.
     */
    function importDelegationsFromLegacy(
        IVeHemiVoteDelegation legacy_, uint256[] calldata tokenIds_
    ) external {
        if (msg.sender != IOwnable(address(veHemi)).owner()) revert NotVeHemiOwner();
        if (migrationFinalized) revert MigrationFinalizedError();
        if (address(legacy_) == address(0)) revert LegacyAddressInvalid();
        if (address(legacy_) == address(this)) revert LegacyAddressInvalid();

        uint256 n = tokenIds_.length;
        // Compute next-epoch boundary once — matches the gate that
        // `_getNormalizedLockedInfo` would apply on each call inside
        // `_delegate`'s else branch. Pre-checking here lets us skip
        // expired/empty locks BEFORE `_delegate` reverts the whole batch.
        uint256 _nextCheckpoint = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL)
            + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds_[i];
            // Idempotency: skip tokenIds we've already imported / written.
            if (delegations[id].delegatee != address(0)) continue;
            Delegation memory legacyD = legacy_.delegation(id);
            if (legacyD.delegatee == address(0)) continue;
            // Skip locks that would cause `_getNormalizedLockedInfo` to revert
            // (ending at or before the next hour boundary, or burned/withdrawn):
            // at most their last hour of decaying weight is left unbooked.
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (_lock.amount == 0) continue;
            // An auto-relock position is live whatever its stored `end` says: test
            // the flag, as `_getNormalizedLockedInfo` does.
            if (veHemi.autoRelockRemaining(id) == 0 && _lock.end <= _nextCheckpoint) continue;
            // Replay via the standard delegation flow. Reads current
            // locked state from veHemi for the (slope, bias, end) tuple.
            _delegate(id, legacyD.delegatee);
            emit LegacyDelegationImported(id, legacyD.delegatee, address(legacy_));
        }
    }

    /**
     * @notice Replay per-owner `autoDelegate` config from a legacy contract.
     *         Owner-only. Idempotent. Reverts after `finalizeMigration()`.
     *
     * @dev Owner enumeration must happen off-chain (no on-chain owner
     *      registry). Enumerate every address that ever emitted
     *      `AutoDelegateSet` on the legacy contract plus the live owners:
     *      `setAutoDelegate` is permissionless, so an address that never held
     *      a position can carry one (`scripts/plan-legacy-migration.ts`).
     *
     * @param legacy_ The OLD VeHemiVoteDelegation contract to read from.
     * @param owners_ Pagination cursor — owner addresses to migrate.
     */
    function importAutoDelegatesFromLegacy(
        IVeHemiVoteDelegation legacy_, address[] calldata owners_
    ) external {
        if (msg.sender != IOwnable(address(veHemi)).owner()) revert NotVeHemiOwner();
        if (migrationFinalized) revert MigrationFinalizedError();
        if (address(legacy_) == address(0)) revert LegacyAddressInvalid();
        if (address(legacy_) == address(this)) revert LegacyAddressInvalid();

        uint256 n = owners_.length;
        for (uint256 i; i < n; ++i) {
            address o = owners_[i];
            if (o == address(0)) continue;
            if (autoDelegate[o] != address(0)) continue; // idempotent
            address t = legacy_.autoDelegate(o);
            if (t == address(0)) continue;
            autoDelegate[o] = t;
            emit AutoDelegateSet(o, address(0), t);
            emit LegacyAutoDelegateImported(o, t, address(legacy_));
        }
    }

    /**
     * @notice Permanently seal the import functions. Owner-only. One-way.
     *
     * @dev Called once, AFTER the legacy state import is complete and
     *      BEFORE `veHemi.updateVoteDelegation(newVVD)` flips the pointer.
     *      After this call, neither `importDelegationsFromLegacy` nor
     *      `importAutoDelegatesFromLegacy` can ever run again, preventing
     *      post-migration state injection that would corrupt the
     *      `getPastVotes` history for snapshots taken after finalize.
     *
     *      Idempotent: a second call is a no-op. Does not emit on no-op.
     */
    function finalizeMigration() external {
        if (msg.sender != IOwnable(address(veHemi)).owner()) revert NotVeHemiOwner();
        if (migrationFinalized) return; // idempotent
        migrationFinalized = true;
        emit MigrationFinalizedEvent();
    }

    /**
     * @notice Clear the auto-delegate setting for the caller.
     * @dev Sets autoDelegate[msg.sender] to address(0) so future positions
     *      created for this address will self-delegate by default.
     *      Does NOT re-delegate existing positions — call delegate() per-position
     *      or adapter.delegate(self) to also re-delegate existing positions.
     */
    function clearAutoDelegate() external {
        address _previous = autoDelegate[msg.sender];
        if (_previous == address(0)) return;
        autoDelegate[msg.sender] = address(0);
        emit AutoDelegateSet(msg.sender, _previous, address(0));
    }

    /**
     * @notice Set the caller's auto-delegate target without iterating any
     *         existing positions. New positions minted to the caller after
     *         this call auto-delegate to `delegatee_`; existing positions
     *         keep their current delegations until explicitly re-delegated.
     * @dev Companion to `delegateAllFor` for users with too many positions
     *      to fit a single bulk-delegate call within a block. Idempotent:
     *      a no-op call (delegatee_ unchanged) returns without an SSTORE
     *      or event emission.
     * @param delegatee_ The address future positions should auto-delegate to.
     *        Pass `address(0)` to clear (equivalent to `clearAutoDelegate`).
     */
    function setAutoDelegate(address delegatee_) external {
        address _previous = autoDelegate[msg.sender];
        if (_previous == delegatee_) return;
        autoDelegate[msg.sender] = delegatee_;
        emit AutoDelegateSet(msg.sender, _previous, delegatee_);
    }

    /**
     * @notice Delegate all of an owner's veHEMI positions to a single delegatee.
     * @dev Can only be called by the trusted adapter, which passes through the
     *      real msg.sender as the owner parameter. Unarmed locks that end at or
     *      before the next hour boundary are silently skipped (at most their last
     *      hour of decaying weight); auto-relock positions are never skipped,
     *      whatever their stored `end`. Sets autoDelegate[owner_] so
     *      future locks created for this owner auto-delegate to delegatee_.
     * @param owner_ The NFT owner whose positions should be delegated
     * @param delegatee_ The address to delegate all voting power to
     */
    function delegateAllFor(
        address owner_,
        address delegatee_
    ) external nonReentrant {
        if (msg.sender != trustedAdapter) revert NotTrustedAdapter();
        if (delegatee_ == address(0)) revert InvalidDelegatee();

        // Set auto-delegate so future positions created for this owner
        // are automatically delegated to the same address. Skip the SSTORE
        // and the event when the value is already correct so indexers can
        // treat AutoDelegateSet as an idempotent state-change marker.
        address _previousAutoDelegate = autoDelegate[owner_];
        if (_previousAutoDelegate != delegatee_) {
            autoDelegate[owner_] = delegatee_;
            emit AutoDelegateSet(owner_, _previousAutoDelegate, delegatee_);
        }

        uint256 checkpointTs = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
        uint256 count = veHemi.balanceOf(owner_);
        for (uint256 i; i < count;) {
            uint256 tokenId = veHemi.tokenOfOwnerByIndex(owner_, i);
            // Skip unarmed locks that end at or before the next hour boundary:
            // _delegate would revert with CanNotDelegateExpiredLocks. An
            // auto-relock position is live whatever its stored `end` says.
            if (
                veHemi.autoRelockRemaining(tokenId) != 0 ||
                veHemi.getLockedBalance(tokenId).end > checkpointTs
            ) {
                _delegate(tokenId, delegatee_);
            }
            unchecked { ++i; }
        }
    }

    /**
     * @dev Delegates votes from signatory to `delegatee`
     * @param delegator_ The token ID to delegate from (must be owned by the signer)
     * @param delegatee_ delegatee address
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        uint256 delegator_,
        address delegatee_,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // Short-circuit stale signatures before paying ECDSA.recover, the
        // ownerOf SLOAD, and the nonce SLOAD/SSTORE pair. The nonce is
        // consumed only after a valid signature for a non-expired window
        // is proven below, so an expired signature cannot burn a nonce.
        if (block.timestamp > expiry) revert SignatureExpired();

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegator_, delegatee_, nonce, expiry)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        address _signer = ECDSA.recover(digest, v, r, s);
        if (_signer == address(0)) revert InvalidSignature();
        if (veHemi.ownerOf(delegator_) != _signer) revert NotOwner();
        if (nonce != nonces[_signer]++) revert InvalidNonce();
        _delegate(delegator_, delegatee_);
    }

    /**
     * @notice Get the delegation checkpoints for a delegatee
     * @dev Returns the whole array. It grows by up to two elements per block that
     *      touches the delegatee (one dated `block.timestamp + 1`, one pending at the
     *      next hour boundary), so anyone holding a position can deepen it, and the
     *      memory and ABI-encoding cost of returning it grow faster than linearly: for a
     *      very deep array this view no longer fits an `eth_call` gas budget. Use
     *      `getDelegationCheckpointsLength` and `getDelegationCheckpointsPage` instead.
     * @param delegatee_ The delegatee_ to get checkpoints for
     * @return The array of delegation checkpoints
     */
    function getDelegationCheckpoints(
        address delegatee_
    ) external view returns (DelegateCheckpoint[] memory) {
        return delegateCheckpoints[delegatee_];
    }

    /**
     * @notice Number of delegation checkpoints stored for `delegatee_`.
     * @dev With `getDelegationCheckpointsPage`, the bounded way to read the array. Vote
     *      reads do not degrade with its length: `getVotes` and `getPastVotes`
     *      binary-search it (O(log n)), and writers touch only its last two elements.
     * @param delegatee_ The delegatee to count checkpoints for
     */
    function getDelegationCheckpointsLength(
        address delegatee_
    ) external view returns (uint256) {
        return delegateCheckpoints[delegatee_].length;
    }

    /**
     * @notice A bounded window of `delegatee_`'s delegation checkpoints: at most `limit_`
     *         elements, oldest first, starting at index `offset_` and clamped to the end of
     *         the array. An `offset_` at or past the end returns an EMPTY array rather than
     *         reverting, so a paging loop terminates on a short read and never has to catch.
     * @dev Elements dated at or before `block.timestamp` never change. The last one or two
     *      (dated later) can still be rewritten, and the one dated at the next hour boundary
     *      can move to a higher index, so a reader paging across blocks should re-read from
     *      the last two indices it saw.
     * @param delegatee_ The delegatee to read checkpoints for
     * @param offset_ Index of the first checkpoint to return
     * @param limit_ Maximum number of checkpoints to return
     */
    function getDelegationCheckpointsPage(
        address delegatee_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (DelegateCheckpoint[] memory _window) {
        DelegateCheckpoint[] storage _all = delegateCheckpoints[delegatee_];
        uint256 _length = _all.length;
        if (offset_ >= _length) return _window;
        uint256 _count = _length - offset_;
        if (_count > limit_) _count = limit_;
        _window = new DelegateCheckpoint[](_count);
        for (uint256 i; i < _count;) {
            _window[i] = _all[offset_ + i];
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get the delegation information for a token
     * @dev For an auto-relock position the record is flat: `slope == 0` and `bias` is
     *      its constant weight; `end` is the stored lock end, not an expiry.
     * @param tokenId_ The token ID to check
     * @return The delegation information
     */
    function delegation(uint256 tokenId_) external view returns (Delegation memory) {
        return delegations[tokenId_];
    }

    /**
     * @notice Get the current voting power for an account
     * @param account_ The account to check voting power for
     * @return The current voting power (includes both self votes and delegated votes)
     */
    function getVotes(address account_) external view returns (uint256) {
        return _getPastVotes(account_, block.timestamp);
    }

    /**
     * @notice Get the voting power for an account at a specific timestamp
     * @param account_ The account to check voting power for
     * @param timestamp_ The timestamp to check voting power at (must not be in the future)
     * @return _totalVotes The voting power at the given timestamp
     */
    function getPastVotes(
        address account_,
        uint256 timestamp_
    ) external view returns (uint256 _totalVotes) {
        if (timestamp_ > block.timestamp) revert TimestampInFuture();

        _totalVotes = _getPastVotes(account_, timestamp_);
    }

    /**
     * @dev Total veHEMI supply at `timestamp_ - 1` (0 for `timestamp_ == 0`): read one second
     * earlier so the denominator sees exactly the lock changes `getPastVotes(., timestamp_)` sees,
     * since delegation changes land at `block.timestamp + 1`; for `timestamp_ == block.timestamp`
     * the value is already final. Inside the upgrade-hour window (`legacyDatingUntil`) delegation
     * changes land at the window's boundary, so for that hour the denominator counts in-window lock
     * changes that `getPastVotes` counts only from the boundary. Reverts `TimestampInFuture` for a
     * future timestamp.
     *
     * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
     * Votes that have not been delegated are still part of total supply, even though they would not participate in a
     * vote.
     */
    function getPastTotalSupply(
        uint256 timestamp_
    ) external view returns (uint256 pastTotalSupply) {
        if (timestamp_ > block.timestamp) revert TimestampInFuture();

        pastTotalSupply = timestamp_ == 0 ? 0 : veHemi.totalVeHemiSupplyAt(timestamp_ - 1);
    }

    /**
     * @notice Calculate all expired delegations for an account since the last checkpoint.
     * @dev Can be used in tandem with writeNewCheckpointForExpiredDelegations() to
     *      write a new checkpoint. Long time periods between checkpoints can increase
     *      gas costs for delegate() because the catch-up walk must iterate more
     *      SIX_DAYS expiration buckets.
     * @param delegatee_ The delegatee whose expirations should be calculated
     * @return _calculatedCheckpoint A new DelegateCheckpoint to write based on expirations since the previous checkpoint
     */
    function calculateExpiredDelegations(
        address delegatee_
    ) public view returns (DelegateCheckpoint memory _calculatedCheckpoint) {
        DelegateCheckpoint[] storage delegationCheckpoints = delegateCheckpoints[delegatee_];

        uint256 _checkpointsLength = delegationCheckpoints.length;

        // Nothing to expire if no one delegated to you
        if (_checkpointsLength == 0) return _calculatedCheckpoint;

        DelegateCheckpoint memory _lastCheckpoint = delegationCheckpoints[_checkpointsLength - 1];

        // This ensures that checkpoints take effect at the next epoch
        uint256 _checkpointTimestamp = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;

        // Nothing expired because the most recent checkpoint is already written
        if (_lastCheckpoint.timestamp == _checkpointTimestamp) {
            return _calculatedCheckpoint;
        }

        (
            uint256 totalExpiredBias_,
            uint256 totalExpiredSlope_,
            uint256 totalExpiredAmount_
        ) = _calculateExpirations({
                delegatee_: delegatee_,
                start_: _lastCheckpoint.timestamp,
                end_: _checkpointTimestamp,
                checkpoint_: _lastCheckpoint
            });

        // All will be 0 if no expirations, only need to check one of them
        if (totalExpiredAmount_ == 0) return _calculatedCheckpoint;

        // `fixedBias` is CARRIED FORWARD, not reset. This struct replaces
        // `_lastCheckpoint`, and `writeNewCheckpointForExpiredDelegations` pushes it
        // verbatim (permissionless). Flat terms book no expiration bucket, so no
        // expiration nets them, `_calculateExpirations`' MAX_LOCK_DURATION branch
        // included. Writing 0 would let anyone erase a delegatee's whole flat weight,
        // and the next flat retirement there would underflow `fixedBias`.
        _calculatedCheckpoint = DelegateCheckpoint({
            timestamp: _checkpointTimestamp.toUint64(),
            normalizedBias: (_lastCheckpoint.normalizedBias - totalExpiredBias_).toUint128(),
            normalizedSlope: (_lastCheckpoint.normalizedSlope - totalExpiredSlope_).toUint64(),
            totalAmount: (_lastCheckpoint.totalAmount - totalExpiredAmount_).toUint128(),
            fixedBias: _lastCheckpoint.fixedBias
        });
    }

    /**
     * @notice Write a new checkpoint if any weight has expired since the previous checkpoint.
     * @dev Long time periods between checkpoints can increase gas costs for subsequent
     *      delegate() calls because the catch-up walk must iterate more SIX_DAYS
     *      expiration buckets. Anyone can call this to amortize that cost.
     * @param delegatee_ The delegatee whose expired delegations should be materialized in storage
     */
    function writeNewCheckpointForExpiredDelegations(address delegatee_) external nonReentrant {
        // Read at `_imm()`, the instant `_delegate`'s vote events report, so an indexer
        // sees one series. The push only materialises expirations every reader already
        // nets off, so `_previousVotes == _newVotes`.
        uint256 _previousVotes = _getPastVotes(delegatee_, _imm());

        DelegateCheckpoint memory _newCheckpoint = calculateExpiredDelegations(delegatee_);

        if (_newCheckpoint.timestamp == 0) revert NoExpirations();

        delegateCheckpoints[delegatee_].push(_newCheckpoint);

        uint256 _newVotes = _getPastVotes(delegatee_, _imm());

        emit DelegateVotesChanged({
            delegatee: delegatee_,
            previousVotes: _previousVotes,
            newVotes: _newVotes
        });

        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged{gas: RELAY_GAS_BUDGET}(
                delegatee_, _previousVotes, _newVotes
            ) {} catch {}
        }
    }

    /**
     * @notice Emit DelegateVotesChanged with the delegatee's voting power at `block.timestamp + 1`
     * (the next hour boundary inside the upgrade-hour window), and relay it to the adapter.
     * @dev This function writes no state. It exists so that off-chain indexers
     * (e.g. Aragon's subgraph) can be informed of voting-power decay between
     * checkpoints. Anyone can call it (permissionless).
     *
     * Both previousVotes and newVotes in the emitted event are set to that
     * power. This signals "the authoritative power is now X"
     * without implying any delegation change occurred.
     *
     * This does NOT duplicate writeNewCheckpointForExpiredDelegations, which
     * writes a new checkpoint to reflect expired delegations in storage. This
     * function is purely for event emission.
     * @param delegatee_ The delegatee whose voting power to refresh
     */
    function refreshVotingPower(address delegatee_) public {
        // Read at `_imm()`, the instant `_delegate` dates its checkpoints and reports
        // its events. A read at `block.timestamp` would miss a checkpoint written in
        // this block (it is dated later), and the Aragon subgraph would overwrite the
        // delegation event's correct value with that stale one.
        uint256 currentVotes = _getPastVotes(delegatee_, _imm());

        emit DelegateVotesChanged({
            delegatee: delegatee_,
            previousVotes: currentVotes,
            newVotes: currentVotes
        });

        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged{gas: RELAY_GAS_BUDGET}(
                delegatee_, currentVotes, currentVotes
            ) {} catch {}
        }
    }

    /**
     * @notice Batch version of refreshVotingPower for multiple delegatees.
     * @dev Iterates over the array and calls refreshVotingPower for each.
     * The caller is responsible for keeping the array length within gas limits.
     * @param delegatees_ Array of delegatee addresses to refresh
     */
    function refreshVotingPowerBatch(address[] calldata delegatees_) external {
        uint256 length = delegatees_.length;
        for (uint256 i; i < length;) {
            refreshVotingPower(delegatees_[i]);
            unchecked { ++i; }
        }
    }

    /// @dev `previousDelegationEnd_` is consumed ONLY on the subtractive branch
    ///      (`isDeltaPositive_ == false`), where it gates the
    ///      "don't subtract an already-expired contribution" check. Additive
    ///      callers pass 0; the entry guard reverts
    ///      `AdditiveBranchExpectsZeroEnd` if the additive branch is ever
    ///      entered with a non-zero end, so any future caller that forgets to
    ///      thread a real value fails loudly instead of silently behaving as
    ///      if the previous delegation had expired at unix 0.
    /// @dev The delta (`bias`, `slope`, `amount`, `fixedBias`) travels in a memory
    ///      `NormalizedVeHemiLockInfo` rather than as scalar parameters: one more
    ///      parameter is Stack too deep (the build does not use via_ir).
    function _calculateCheckpoint(
        DelegateCheckpoint memory previousCheckpoint_,
        address delegatee_,
        bool isDeltaPositive_,
        NormalizedVeHemiLockInfo memory delta_,
        uint256 checkpointTimestamp_,
        uint256 previousDelegationEnd_
    ) private view returns (DelegateCheckpoint memory _newCheckpoint) {
        if (isDeltaPositive_ && previousDelegationEnd_ != 0) {
            revert AdditiveBranchExpectsZeroEnd();
        }
        // First checkpoint for this delegatee: create from the deltas and
        // return. A single lock's slope is `amount / MAX_TIME`; a position above
        // `uint64.max * MAX_TIME` wei (about 2.33 billion HEMI, an amount within
        // HEMI's supply) cannot be booked: it reverts `DelegationSlopeOverflow` at
        // its expiration bucket, before this checked `toUint64` is reached. On a
        // mint VeHemi swallows that revert, so such a position mints but is not
        // delegated. The aggregate cap is enforced in the additive branch below.
        if (previousCheckpoint_.timestamp == 0) {
            return
                DelegateCheckpoint({
                    timestamp: checkpointTimestamp_.toUint64(),
                    normalizedBias: delta_.bias.toUint128(),
                    normalizedSlope: delta_.slope.toUint64(),
                    totalAmount: delta_.amount.toUint128(),
                    fixedBias: delta_.fixedBias.toUint128()
                });
        }

        _newCheckpoint.timestamp = previousCheckpoint_.timestamp;
        _newCheckpoint.normalizedBias = previousCheckpoint_.normalizedBias;
        _newCheckpoint.normalizedSlope = previousCheckpoint_.normalizedSlope;
        _newCheckpoint.totalAmount = previousCheckpoint_.totalAmount;
        _newCheckpoint.fixedBias = previousCheckpoint_.fixedBias;

        // Add or subtract the delta to the previous checkpoint.
        if (isDeltaPositive_) {
            // The aggregate per-delegate slope is stored as uint64; the
            // ceiling translates to ~2.328 B HEMI delegated to a single
            // delegatee (uint64.max × MAX_TIME). Surface that boundary via
            // a self-describing `DelegationSlopeOverflow` instead of an
            // opaque SafeCast/checked-add revert. Bias/amount are stored
            // as uint128 (checkpoint) or uint96 (expiration) and rely on
            // SafeCast. The uint96 expiration bias is NORMALIZED
            // (`slope * end`), so its ceiling falls as `end` grows: at ends
            // near 1.92e9 s it is about 5.2 billion HEMI of four-year lock in
            // one bucket. In `_moveVotingPowerToNewDelegate` the bucket's bias
            // add runs before its slope guard, so for lock ends past 2^31 s,
            // or a single position whose own normalized bias exceeds uint96, a
            // slope overflow surfaces there as a SafeCast/checked-add revert
            // instead of `DelegationSlopeOverflow`.
            uint256 _newSlope = uint256(_newCheckpoint.normalizedSlope) + delta_.slope;
            if (_newSlope > type(uint64).max) revert DelegationSlopeOverflow();
            _newCheckpoint.normalizedBias += delta_.bias.toUint128();
            _newCheckpoint.normalizedSlope = uint64(_newSlope);
            _newCheckpoint.totalAmount += delta_.amount.toUint128();
            _newCheckpoint.fixedBias += delta_.fixedBias.toUint128();
        } else {
            // A flat contribution is retired here, ungated. It has no expiration
            // bucket and its `end` is not an expiry, so the "already expired" gate
            // below must not apply to it: a frozen past `end` would strand the
            // term on the old delegatee for good. Its decaying components are 0
            // (the callers pass them as 0), so this is the only place its weight
            // moves.
            if (delta_.fixedBias != 0) {
                _newCheckpoint.fixedBias -= delta_.fixedBias.toUint128();
                // `amount` is booked together with `fixedBias` by the additive
                // branch, so it is retired with it here, not by the gated decaying
                // retirement below. A DECLINE, not a clamp: if the aggregate holds
                // less than this term's `amount` it is left as it is; a clamp to 0
                // would erase every other position's `amount`.
                if (_newCheckpoint.totalAmount >= delta_.amount) {
                    _newCheckpoint.totalAmount -= delta_.amount.toUint128();
                }
            }
            // only subtract the weight from this tokenID if it has not already expired
            if (previousDelegationEnd_ > checkpointTimestamp_) {
                _newCheckpoint.normalizedBias -= delta_.bias.toUint128();
                _newCheckpoint.normalizedSlope -= delta_.slope.toUint64();
                // A flat delta's `bias` and `slope` are 0 and its `amount` was
                // retired above, hence `fixedBias == 0` below. The `>=` test is the
                // same decline as above.
                if (delta_.fixedBias == 0 && _newCheckpoint.totalAmount >= delta_.amount) {
                    _newCheckpoint.totalAmount -= delta_.amount.toUint128();
                }
            }
        }

        // If there have been expirations, incorporate the adjustments by subtracting them from the checkpoint
        if (_newCheckpoint.timestamp != checkpointTimestamp_) {
            (
                uint128 totalExpiredBias,
                uint64 totalExpiredSlope,
                uint128 totalExpiredAmount
            ) = _calculateExpirations(
                    delegatee_,
                    _newCheckpoint.timestamp,
                    checkpointTimestamp_,
                    // `checkpoint_` is read only by the MAX_LOCK_DURATION branch, which
                    // retires that checkpoint's whole decaying aggregate. A retirement
                    // passes the post-delta aggregate (the pre-delta one would make
                    // `(prev - delta) - prev` underflow); a booking passes the
                    // pre-delta one, so the contribution added in this call is not
                    // retired with the stale aggregate.
                    isDeltaPositive_ ? previousCheckpoint_ : _newCheckpoint
                );

            _newCheckpoint.timestamp = checkpointTimestamp_.toUint64();
            _newCheckpoint.normalizedBias -= totalExpiredBias;
            _newCheckpoint.normalizedSlope -= totalExpiredSlope;
            // Saturating: `totalAmount` feeds no vote or supply value (only the
            // checkpoint views report it).
            _newCheckpoint.totalAmount = _newCheckpoint.totalAmount > totalExpiredAmount
                ? _newCheckpoint.totalAmount - totalExpiredAmount
                : 0;
        }
    }

    function _calculateExpirations(
        address delegatee_,
        uint256 start_,
        uint256 end_,
        DelegateCheckpoint memory checkpoint_
    )
        private
        view
        returns (uint128 totalExpiredBias, uint64 totalExpiredSlope, uint128 totalExpiredAmount)
    {
        // The walk is clamped to `start_ + MAX_LOCK_DURATION` and always runs. The
        // clamp loses nothing: a contribution booked at `t` keys its bucket at
        // `end <= t + MAX_LOCK_DURATION` and dates a checkpoint at or after `t`, so no
        // bucket the walk needs lies past `start_ + MAX_LOCK_DURATION`. It bounds the
        // walk at MAX_LOCK_DURATION / SIX_DAYS = 240 iterations.
        bool _beyondMaxLock = end_ > start_ + MAX_LOCK_DURATION;
        uint256 _walkEnd = _beyondMaxLock ? start_ + MAX_LOCK_DURATION : end_;
        {
            // Total values will always be less than or equal to a checkpoint's values
            uint256 currentSixDayWindow = SIX_DAYS + (start_ / SIX_DAYS) * SIX_DAYS;
            mapping(uint256 => Expiration) storage delegateExpirations = expiredDelegations[
                delegatee_
            ];
            // Sum values from currentSixDayWindow until end
            while (currentSixDayWindow <= _walkEnd) {
                Expiration memory expiration = delegateExpirations[currentSixDayWindow];
                totalExpiredBias += expiration.bias;
                totalExpiredSlope += expiration.slope;
                totalExpiredAmount += expiration.amount;
                currentSixDayWindow += SIX_DAYS;
            }
        }
        if (_beyondMaxLock) {
            // Past MAX_LOCK_DURATION every DECAYING contribution has expired, so
            // retiring the whole decaying aggregate is exact. `normalizedBias` and
            // `normalizedSlope` are decaying-only: a flat contribution books 0 into
            // both.
            totalExpiredBias = checkpoint_.normalizedBias;
            totalExpiredSlope = checkpoint_.normalizedSlope;
            // `totalAmount` is NOT decaying-only: it also carries flat principal,
            // which never expires and has no bucket. The expired decaying principal
            // is the bucket sum the walk above already computed, so
            // `totalExpiredAmount` keeps it. Taking `checkpoint_.totalAmount` instead
            // would erase live flat principal while its `fixedBias` stays; the term's
            // later retirement would then take that principal from other delegators'
            // and leave the aggregate short of its own buckets, so
            // `calculateExpiredDelegations` (a view, and the permissionless amortiser)
            // would underflow for this delegatee.
        }
    }

    function _checkpointBinarySearch(
        DelegateCheckpoint[] storage checkpoints_,
        uint256 timestamp_
    ) private view returns (DelegateCheckpoint memory closestCheckpoint_) {
        uint256 checkpointsLength_ = checkpoints_.length;

        // The search spans the whole array (`low = 0`). An epoch-counting lower bound
        // would be unsound: an hour can hold several checkpoints (writes are dated
        // `block.timestamp + 1`), so counting hours undercounts elements and the search
        // would return a checkpoint dated after `timestamp_`.
        uint256 low = 0;

        uint256 high = checkpointsLength_;
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (checkpoints_[mid].timestamp > timestamp_) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        closestCheckpoint_ = high == 0 ? closestCheckpoint_ : checkpoints_[high - 1];
    }

    /// @notice Retire a flat (auto-relock) term whose position is no longer armed.
    ///         Permissionless. A committed `disableAutoRelock`, `retireStaleAutoRelock` or
    ///         armed transfer whose re-delegation VeHemi could not complete leaves the record
    ///         flat (slope 0, bias > 0) while VeHemi reports the position unarmed; VeHemi
    ///         announces it with `AutoRelockRetirementUnverified`. This re-runs the delegation
    ///         to the record's own delegatee: the flat term is retired and the position's
    ///         current weight is booked (nothing, if its lock has ended or the id is burned).
    ///         Call it on the contract that booked the term (after a pointer move, the old one).
    /// @dev    Reverts `FlatTermNotRetryable` unless the record is flat and
    ///         `veHemi.autoRelockRemaining(delegator_) == 0`, so it writes nothing outside
    ///         that state.
    function retireStrandedFlatTerm(uint256 delegator_) external nonReentrant {
        Delegation memory _d = delegations[delegator_];
        if (_d.slope != 0 || _d.bias == 0) revert FlatTermNotRetryable();
        if (veHemi.autoRelockRemaining(delegator_) != 0) revert FlatTermNotRetryable();
        _delegate(delegator_, _d.delegatee);
    }

    /// @notice `retireStrandedFlatTerm` on a position that is not stranded.
    error FlatTermNotRetryable();

    function _delegate(uint256 delegator_, address delegatee_) internal {
        if (msg.sender != address(veHemi) && delegatee_ == address(0)) revert InvalidDelegatee();
        // A proxy upgraded from the hour-boundary-dating implementation without
        // `armLegacyDatingWindow` reads 0, which `_imm` serves as an open window (the
        // replaced implementation's dating). The first `_delegate` closes it at the next
        // hour boundary. No other entry point closes it, so `refreshVotingPower` and the
        // amortiser stay free of new state writes.
        if (legacyDatingUntil == 0) _armLegacyDating(false);

        Delegation memory _previousDelegation = delegations[delegator_];

        // The next hour boundary: the date of the deferred (pending) leg and of the
        // liveness gate in `_getNormalizedLockedInfo`.
        uint256 _checkpointTimestamp = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;

        // Event order: `DelegateChanged` first, then the `DelegateVotesChanged` pair, the
        // order of OpenZeppelin `Votes._delegate` (this event is tokenId-scoped, not the
        // address-scoped ERC-5805 one). The adapter's `notifyDelegateChanged` relay stays
        // at the end, after the record is written, because the adapter resolves the
        // account-wide delegatee from `delegations`; the adapter's stream is therefore
        // DelegateVotesChanged, DelegateVotesChanged, DelegateChanged. Each `newVotes` is
        // read at `_imm()`, so an event leads `getVotes` by one second (by up to 3,600 s
        // inside the upgrade-hour window).
        emit DelegateChanged({
            delegator: delegator_,
            fromDelegatee: _previousDelegation.delegatee,
            toDelegatee: delegatee_
        });

        _moveVotingPowerFromPreviousDelegate({
            previousDelegation_: _previousDelegation,
            checkpointTimestamp_: _checkpointTimestamp
        });

        // When delegatee_ is address(0) (forfeit / burn cleanup), skip the
        // _moveVotingPowerToNewDelegate path entirely. Otherwise that helper
        // would push a checkpoint into delegateCheckpoints[address(0)] and
        // increment expiredDelegations[address(0)][end] every forfeit,
        // accumulating non-trivial state at the zero address over the
        // protocol's lifetime — making getVotes(address(0)) return real
        // values, bloating storage, and inflating gas on any view that walks
        // address(0)'s expirations. The cleanup branch ONLY deletes the
        // stale per-token record; it MUST work even when the lock is at or
        // past expiry, because forfeit-near-expiry and any future cleanup
        // path on a fully-expired lock would otherwise revert inside
        // `_getNormalizedLockedInfo` (`CanNotDelegateExpiredLocks`) and
        // leave `delegations[delegator_]` stale forever. That is why
        // `_getNormalizedLockedInfo` is now invoked ONLY in the
        // new-delegatee branch — its normalized values are not needed to
        // delete a record.
        //
        // See `VeHemi._delegate` for the symmetric outer-guard carve-out
        // (`delegatee_ == address(0) ||`) that routes forfeit-near-expiry
        // cleanup into this branch.
        //
        // CRITICAL: DO NOT REMOVE the address(0) branch or move
        // `_getNormalizedLockedInfo` above this if/else. `_getNormalizedLockedInfo`
        // reverts for expired locks, so calling it on the cleanup path would
        // leave `delegations[delegator_]` populated forever after the NFT
        // burns.
        if (delegatee_ == address(0)) {
            delete delegations[delegator_];
            // Cleared with the record. The removal above lands at `_imm()` for a live
            // or flat term (the old delegatee still counts the token through
            // `block.timestamp`), and at the next hour boundary for a decaying term
            // that has already ended, which counts 0 anyway.
            delete delegationBookedAt[delegator_];
        } else {
            // A stored record is flat iff (slope == 0 && bias > 0), the discriminator
            // `_moveVotingPowerFromPreviousDelegate` uses. If it is, the call above has
            // just retired a flat term and this branch must not revert, or the
            // retirement rolls back and the term is stranded: for an unarmed position
            // whose lock ends at or before the next hour boundary,
            // `_getNormalizedLockedInfo` would revert `CanNotDelegateExpiredLocks`
            // (swallowed by `VeHemi._delegate`; permanent for a holder's `delegate`).
            // That cannot happen as auto-relock ends (the restored end is more than one
            // SIX_DAYS bucket away), but can when a stranded term is retired later. So
            // it tolerates the expired lock and returns a zero-weight record: nothing
            // is booked, and an empty, already-expired record is stored -- the shape
            // an ordinary expired delegation leaves behind.
            bool _prevFlat = (_previousDelegation.slope == 0 && _previousDelegation.bias > 0);
            NormalizedVeHemiLockInfo memory _normalizedVeLockInfo = _getNormalizedLockedInfo(
                delegator_,
                _checkpointTimestamp,
                _prevFlat
            );
            // Called even for a zero-weight record: it is the only writer that
            // creates `delegateCheckpoints[delegatee_]`, and
            // `_moveVotingPowerFromPreviousDelegate` relies on a non-zero
            // `delegations[id].delegatee` implying a non-empty array. A zero delta
            // books nothing.
            _moveVotingPowerToNewDelegate({
                newDelegatee_: delegatee_,
                delegatorVeLockInfo_: _normalizedVeLockInfo,
                checkpointTimestamp_: _checkpointTimestamp
            });
            delegations[delegator_] = Delegation({
                delegatee: delegatee_,
                end: _normalizedVeLockInfo.end.toUint48(),
                bias: _normalizedVeLockInfo.bias.toUint96(),
                amount: _normalizedVeLockInfo.amount.toUint96(),
                slope: _normalizedVeLockInfo.slope.toUint64()
            });
            // The stamp is the instant this record takes effect: `_imm()`, the date of
            // both legs. No code in this contract reads it; it is the public per-token
            // answer to "from when is this record in effect" (checkpoint dates are
            // per-delegatee). It is in the ABI (public getter) and occupies storage
            // slot 100 of the contract's 12 storage-layout entries; removing it
            // changes both.
            delegationBookedAt[delegator_] = _imm().toUint64();
        }

        // Relay DelegateChanged to adapter with address-based IVotes signature.
        // `ownerOf` is resolved inside its own try: `retireStrandedFlatTerm` can run
        // on a burned id, whose `ownerOf` reverts, and a best-effort relay must not
        // veto that repair. A burned id has no owner to relay.
        if (trustedAdapter != address(0)) {
            try veHemi.ownerOf(delegator_) returns (address _owner) {
                try IAdapterNotify(trustedAdapter).notifyDelegateChanged(
                    _owner,
                    _previousDelegation.delegatee,
                    delegatee_
                ) {} catch {}
            } catch {}
        }
    }

    function _getPastVotes(
        address account_,
        uint256 timestamp_
    ) internal view returns (uint256 _totalVotes) {
        return _getDelegateVotesAt(account_, timestamp_);
    }

    /// @dev The effective instant of every delegation write, bucket predicate and
    ///      vote-event read: `block.timestamp + 1`, except while the next hour boundary
    ///      is at or before `legacyDatingUntil` (or it is 0), where it is that boundary.
    ///      Then every leg takes `_applyToCheckpoints`' deferred-only branch: the dating
    ///      of the hour-boundary implementation this one replaces, and the value this
    ///      function returns anyway at `boundary - 1`. The test is on the boundary, so
    ///      the window can only end at one. Zero-argument on purpose: callers inline it
    ///      where one more local would be Stack too deep.
    function _imm() private view returns (uint256) {
        uint256 _until = legacyDatingUntil;
        if (_until != 0 && block.timestamp >= _until) return block.timestamp + 1;
        uint256 _b = _nextBoundary();
        return (_until == 0 || _b <= _until) ? _b : block.timestamp + 1;
    }

    /// @dev The next hour boundary after `block.timestamp`, the expression the entry
    ///      points inline as their checkpoint timestamp.
    function _nextBoundary() private view returns (uint256) {
        return (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL)
            + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
    }

    /// @dev Sets the upgrade-hour window to end at the next hour boundary and emits
    ///      `LegacyDatingWindowArmed` (declared in `IVeHemiVoteDelegationAutoRelock`).
    function _armLegacyDating(bool viaUpgradeCall_) private {
        uint256 _until = _nextBoundary();
        legacyDatingUntil = _until.toUint64();
        emit LegacyDatingWindowArmed(_until, viaUpgradeCall_);
    }

    function _getNormalizedLockedInfo(
        uint256 delegator_,
        uint256 checkPointTimestamp_,
        bool tolerateExpired_
    ) internal view returns (NormalizedVeHemiLockInfo memory _normalizedVeHemiLockInfo) {
        uint256 _end = veHemi.getLockedBalance(delegator_).end;
        // Liveness: an auto-relock position's stored `end` may be in the past, so the
        // flag decides, not the date (`importDelegationsFromLegacy` and
        // `delegateAllFor` skip on the same predicate). The flag is trusted alone:
        // every VeHemi path that arms or changes an armed position checkpoints a flat
        // user point (slope 0) before it re-delegates. Were the flag set over a
        // decaying point (possible after a rollback to the replaced VeHemi
        // implementation and a re-forward), the record would book about
        // `slope * end` as a constant term that no later move could remove.
        bool _flat = veHemi.autoRelockRemaining(delegator_) != 0;
        if (!_flat && _end <= checkPointTimestamp_) {
            // `tolerateExpired_` is set only when the old side of this call was a flat
            // term that has just been retired. Returning a record whose weight
            // components are all zero (`end` is carried, see below; nothing is booked
            // against it) lets that retirement commit instead of reverting.
            if (!tolerateExpired_) revert CanNotDelegateExpiredLocks();
            // `end` is carried for observability only; every weight component
            // stays 0, and `end <= checkPointTimestamp_` keeps the record
            // inert on the next move-away (the `previousDelegationEnd_ >
            // checkpointTimestamp_` gate in `_calculateCheckpoint`).
            _normalizedVeHemiLockInfo.end = _end;
            return _normalizedVeHemiLockInfo;
        }

        uint256 _epoch = veHemi.userPointEpoch(delegator_);

        IVeHemi.UserPoint memory _userPoint = veHemi.getUserPoint(delegator_, _epoch);

        // A flat delegator contributes a CONSTANT term: its user point carries
        // (slope 0, bias W), so the normalized bias is W exactly. Routing it into
        // `fixedBias` keeps it out of the `normalizedSlope * t` decay and out of the
        // SIX_DAYS expiration buckets.
        _normalizedVeHemiLockInfo.slope = _userPoint.point.slope.toUint256();
        _normalizedVeHemiLockInfo.bias =
            _userPoint.point.bias.toUint256() +
            (_normalizedVeHemiLockInfo.slope * _userPoint.point.timestamp);
        _normalizedVeHemiLockInfo.amount = _userPoint.point.amount;
        _normalizedVeHemiLockInfo.end = _end;
        // `bias` stays populated for a flat delegator: it is stored in
        // `delegations[delegator_].bias`, and the flat discriminator
        // `(slope == 0 && bias > 0)` reads it back on the next move-away; zeroed, the
        // record would look empty and strand its weight on the old delegatee. The
        // decaying components are zeroed at the point of use instead (see
        // `_moveVotingPowerToNewDelegate`).
        if (_flat) {
            _normalizedVeHemiLockInfo.fixedBias = _normalizedVeHemiLockInfo.bias;
        }
    }

    function _getDelegateVotesAt(
        address delegatee_,
        uint256 timestamp_
    ) internal view returns (uint256 _delegatedWeight) {
        // Check if delegate token has any delegations
        DelegateCheckpoint memory _checkpoint = _checkpointBinarySearch({
            checkpoints_: delegateCheckpoints[delegatee_],
            timestamp_: timestamp_
        });

        // If checkpoint is empty, short circuit and return 0 delegated weight
        if (_checkpoint.timestamp == 0) {
            return 0;
        }

        // It's possible that some delegated veHemi has expired.
        // Add up all expirations during this time period, SIX_DAYS by SIX_DAYS.
        (uint256 totalExpiredBias, uint256 totalExpiredSlope, ) = _calculateExpirations({
            delegatee_: delegatee_,
            start_: _checkpoint.timestamp,
            end_: timestamp_,
            checkpoint_: _checkpoint
        });

        uint256 expirationAdjustedBias = _checkpoint.normalizedBias - totalExpiredBias;
        uint256 expirationAdjustedSlope = _checkpoint.normalizedSlope - totalExpiredSlope;

        uint256 voteDecay = expirationAdjustedSlope * timestamp_;
        _delegatedWeight = (expirationAdjustedBias > voteDecay)
            ? expirationAdjustedBias - voteDecay
            : 0;
        // Flat weight: `fixedBias` is netted by no expiration (the MAX_LOCK_DURATION
        // branch included) and does not decay, so it is added as is.
        _delegatedWeight += _checkpoint.fixedBias;
    }

    function _moveVotingPowerFromPreviousDelegate(
        Delegation memory previousDelegation_,
        uint256 checkpointTimestamp_
    ) private {
        if (previousDelegation_.delegatee == address(0)) return;
        // Remove voting power from previous delegate, if they exist

        // Get the last Checkpoint for previous delegate
        DelegateCheckpoint[] storage previousDelegationCheckpoints = delegateCheckpoints[
            previousDelegation_.delegatee
        ];
        uint256 accountCheckpointsLength = previousDelegationCheckpoints.length;
        // NOTE: the array is non-empty because a previous delegation exists:
        // `_delegate` calls `_moveVotingPowerToNewDelegate`, the only writer that
        // creates the array, on every branch that names a delegatee, even for a
        // zero-weight record. The index below is unguarded and relies on that.
        DelegateCheckpoint memory _lastCheckpoint = previousDelegationCheckpoints[
            accountCheckpointsLength - 1
        ];

        // Event values are read at `_imm()`, the instant both legs take effect, so the
        // delta the event reports is exactly the delta booked (a read at the hour
        // boundary would report the weight decayed forward). `_imm()` is called
        // inline: one more local in this frame is Stack too deep (the build does not
        // use via_ir).
        uint256 _previousVotes = _getPastVotes(previousDelegation_.delegatee, _imm());

        // OLD-side flat discriminator, mirroring the user-point rule in
        // `VeHemiCurveLib`: a stored `Delegation` is flat iff
        // (slope == 0 && bias > 0). Unreachable for a decaying delegation: every
        // position has amount >= MAX_TIME, so slope >= 1 whenever bias > 0 (the
        // smallest V1 position on Hemi mainnet is 2.625e11 wei, slope 2,079; every
        // mint since V2 is >= MIN_LOCK_AMOUNT).
        // The test trusts the record's shape. A record of this shape booked by a
        // module without flat terms (the replaced implementation, for a position
        // VeHemi armed before this module was installed) sits in `normalizedBias`
        // and an expiration bucket, not in `fixedBias`; retiring it here would
        // revert or take its weight out of the delegatee's other flat terms. VeHemi
        // must never arm positions over such a module.
        bool _prevFlat = (previousDelegation_.slope == 0 && previousDelegation_.bias > 0);

        // A decaying term still live at `_imm()` leaves its bucket here and is
        // subtracted by the checkpoint legs; one that has already ended stays in its
        // bucket for the expiration sweep, and the legs subtract nothing (the same
        // threshold).
        if (!_prevFlat && previousDelegation_.end > _imm()) {
            // Calculations
            Expiration memory expiration = expiredDelegations[previousDelegation_.delegatee][
                previousDelegation_.end
            ];

            expiration.bias -= previousDelegation_.bias;
            expiration.slope -= previousDelegation_.slope;
            expiration.amount -= previousDelegation_.amount;

            // Effects
            expiredDelegations[previousDelegation_.delegatee][previousDelegation_.end] = expiration;
        }

        _applyToCheckpoints({
            userDelegationCheckpoints_: previousDelegationCheckpoints,
            accountCheckpointsLength_: accountCheckpointsLength,
            lastCheckpoint_: _lastCheckpoint,
            delegatee_: previousDelegation_.delegatee,
            delta_: NormalizedVeHemiLockInfo({
                // A flat contribution's DECAYING components are 0 — the
                // whole weight rides in `fixedBias`. Passing the bias in
                // both places would underflow `normalizedBias`.
                bias: _prevFlat ? 0 : previousDelegation_.bias,
                slope: previousDelegation_.slope,
                amount: previousDelegation_.amount,
                end: previousDelegation_.end,
                fixedBias: _prevFlat ? previousDelegation_.bias : 0
            }),
            isDeltaPositive_: false,
            checkpointTimestamp_: checkpointTimestamp_
        });

        // Paired with `_previousVotes` above: same instant, straddling the write,
        // so the delta the event reports is exactly the delta booked.
        uint256 _newVotesForPrevDelegatee = _getPastVotes({
            account_: previousDelegation_.delegatee,
            timestamp_: _imm()
        });

        emit DelegateVotesChanged({
            delegatee: previousDelegation_.delegatee,
            previousVotes: _previousVotes,
            newVotes: _newVotesForPrevDelegatee
        });

        // Relay to adapter so the event appears from the voting token address
        // that Aragon's subgraph indexes.
        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged{gas: RELAY_GAS_BUDGET}(
                previousDelegation_.delegatee, _previousVotes, _newVotesForPrevDelegatee
            ) {} catch {}
        }
    }

    /**
     * @notice Move voting power to the new delegate
     * @dev This function handles adding voting power to the new delegate when
     * a delegation is created or changed. It updates checkpoints and expiration records.
     * @param newDelegatee_ The new delegatee (never address(0): `_delegate` clears a record without this call)
     * @param delegatorVeLockInfo_ The normalized lock information of the delegator
     * @param checkpointTimestamp_ The timestamp for the checkpoint
     */
    function _moveVotingPowerToNewDelegate(
        address newDelegatee_,
        NormalizedVeHemiLockInfo memory delegatorVeLockInfo_,
        uint256 checkpointTimestamp_
    ) private {
        // Get the last checkpoint for the new delegate
        DelegateCheckpoint[] storage newDelegateCheckpoints = delegateCheckpoints[newDelegatee_];
        uint256 _accountCheckpointsLength = newDelegateCheckpoints.length;
        DelegateCheckpoint memory _lastCheckpoint = _accountCheckpointsLength == 0
            ? DelegateCheckpoint({
                timestamp: 0,
                normalizedBias: 0,
                normalizedSlope: 0,
                totalAmount: 0,
                fixedBias: 0
            })
            : newDelegateCheckpoints[_accountCheckpointsLength - 1];

        // Read at `_imm()`, the instant the write below takes effect (see
        // `_moveVotingPowerFromPreviousDelegate`).
        uint256 _previousVotes = _getPastVotes(newDelegatee_, _imm());

        // Update the (delegatee, end)-keyed expiration bucket. The aggregate
        // slope shares the same uint64 ceiling as the per-delegate checkpoint
        // slope, so the bound check mirrors `_calculateCheckpoint`'s guard
        // and surfaces overflow as a self-describing
        // `DelegationSlopeOverflow`.
        // A FLAT delegator books no expiration bucket: its weight is constant until
        // VeHemi re-books it as decaying when auto-relock ends, and a bucket keyed on
        // its stored (possibly past) `end` would retire it at the wrong time.
        if (delegatorVeLockInfo_.fixedBias == 0) {
            Expiration memory _expiration = expiredDelegations[newDelegatee_][delegatorVeLockInfo_.end];
            _expiration.bias += delegatorVeLockInfo_.bias.toUint96();
            {
                uint256 _newExpSlope = uint256(_expiration.slope) + delegatorVeLockInfo_.slope;
                if (_newExpSlope > type(uint64).max) revert DelegationSlopeOverflow();
                _expiration.slope = uint64(_newExpSlope);
            }
            _expiration.amount += delegatorVeLockInfo_.amount.toUint96();

            // Effects
            expiredDelegations[newDelegatee_][delegatorVeLockInfo_.end] = _expiration;
        }

        // The addition goes through the same two-leg writer as the retirement, so it
        // lands at `_imm()` too. The magnitude booked does not depend on that date:
        // `normalizedBias` is normalized to unix 0 (`bias + slope * pointTimestamp`)
        // and `_getDelegateVotesAt` re-applies `slope * queryTimestamp`.
        // `checkpointTimestamp_` is still the date of the deferred leg and the
        // instant `_getNormalizedLockedInfo` gated liveness on.
        _applyToCheckpoints({
            userDelegationCheckpoints_: newDelegateCheckpoints,
            accountCheckpointsLength_: _accountCheckpointsLength,
            lastCheckpoint_: _lastCheckpoint,
            delegatee_: newDelegatee_,
            // A FLAT delegator's whole weight rides in `fixedBias`; its
            // decaying components must be 0 so it is never touched by
            // `normalizedSlope * t` decay or by an expiration bucket.
            // A fresh struct (not a mutation of `delegatorVeLockInfo_`,
            // which the caller still needs intact for `delegations[]`).
            delta_: delegatorVeLockInfo_.fixedBias == 0
                ? delegatorVeLockInfo_
                : NormalizedVeHemiLockInfo({
                    bias: 0,
                    slope: 0,
                    amount: delegatorVeLockInfo_.amount,
                    end: delegatorVeLockInfo_.end,
                    fixedBias: delegatorVeLockInfo_.fixedBias
                }),
            isDeltaPositive_: true,
            checkpointTimestamp_: checkpointTimestamp_
        });

        // Paired with `_previousVotes` above, at the same instant.
        uint256 _newVotesForNewDelegatee = _getPastVotes({
            account_: newDelegatee_,
            timestamp_: _imm()
        });

        emit DelegateVotesChanged({
            delegatee: newDelegatee_,
            previousVotes: _previousVotes,
            newVotes: _newVotesForNewDelegatee
        });

        // Relay to adapter so the event appears from the voting token address
        // that Aragon's subgraph indexes.
        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged{gas: RELAY_GAS_BUDGET}(
                newDelegatee_, _previousVotes, _newVotesForNewDelegatee
            ) {} catch {}
        }
    }

    /**
     * @notice Apply one delegation delta (a retirement or a booking) to `delegatee_`'s
     *         checkpoints, effective from `_imm()`.
     *
     * @dev Two legs carry the same delta:
     *        IMMEDIATE -- applied to the live element (the newest dated at or before
     *                     `_imm()`) and written at `_imm()`;
     *        DEFERRED  -- applied to the pending element, if the delegatee carries one
     *                     dated `checkpointTimestamp_` (the next hour boundary), so the
     *                     change is still present after that boundary.
     *      Outside the upgrade-hour window `_imm()` is `block.timestamp + 1`, later than
     *      every timestamp `getPastVotes` serves in this block: a write restates nothing a
     *      caller could already have read, and a delegation never counts in the block that
     *      makes it. Do not date writes at the start of the current hour (that restates
     *      every reading already taken in the hour), at `block.timestamp` (that restates
     *      the current second) or at the next hour boundary (a step-down would keep the
     *      delegatee's pre-step weight for up to an hour after the escrow dropped).
     *      Retirements and bookings are dated alike, so `_delegate`'s retire and
     *      re-book leave no gap: the position counts at its old delegatee through
     *      `block.timestamp` and at its new one from `block.timestamp + 1`. The cost is
     *      that `delegateCheckpoints[d]` can grow by up to two elements per block that
     *      touches `d`.
     *
     *      LAYOUT INVARIANT of `A = delegateCheckpoints[d]` (`now = block.timestamp`,
     *      `B` = the next hour boundary, `imm = _imm()`):
     *      (1) Strictly sorted by `timestamp`. The only precondition of
     *          `_checkpointBinarySearch`; break it and `getPastVotes` can return an
     *          element dated after the query.
     *      (2) At most one element is dated after `imm` (the pending one); it is the
     *          last and is dated exactly `B`. Nothing here writes a later date.
     *      (3) The live element is `A[len-1]` without a pending element and `A[len-2]`
     *          with one (`_liveIndex`).
     *      (4) No write mutates an element dated at or before `now`. The permitted
     *          writes: overwrite the element dated `imm`, overwrite the pending
     *          element, push.
     *      (5) A delta applied to the live element is also applied to the pending one,
     *          or it is lost at the boundary.
     *      Writers of `A`: this function (with `_writeCheckpoint`) and the
     *      permissionless `writeNewCheckpointForExpiredDelegations`, which pushes at `B`
     *      only when the last element is not already dated `B` (so never a second
     *      pending element), and `B` is later than every other date. A new writer must
     *      preserve (1)-(5). `CheckpointLayoutViolated` checks (1) and (2) on the tail
     *      only; (4) and (5) are properties of the writes and are not checked.
     *
     *      UPGRADE-HOUR WINDOW. The implementation this one replaces dates every write at
     *      the next hour boundary, so in the hour of the upgrade its in-hour writes sit
     *      only in an element dated `B`; applying later deltas to a live element as well
     *      would under- or double-count. Until the window's boundary `_imm()` returns `B`,
     *      so `_immTimestamp == checkpointTimestamp_` and every write takes the
     *      deferred-only branch: the replaced implementation's own dating. From that
     *      boundary on every element is dated at or before `now` and the two legs run as
     *      above.
     */
    function _applyToCheckpoints(
        DelegateCheckpoint[] storage userDelegationCheckpoints_,
        uint256 accountCheckpointsLength_,
        DelegateCheckpoint memory lastCheckpoint_,
        address delegatee_,
        NormalizedVeHemiLockInfo memory delta_,
        bool isDeltaPositive_,
        uint256 checkpointTimestamp_
    ) private {
        // `block.timestamp + 1` outside the upgrade-hour window, the next hour boundary
        // inside it (see `_imm`).
        uint256 _immTimestamp = _imm();
        // A pending element exists iff the newest checkpoint is dated after
        // `_immTimestamp` (clause (2)). Inside the window `_immTimestamp` is the
        // boundary, so this reads false there; the first disjunct below returns before
        // it is used.
        bool _hasPending = lastCheckpoint_.timestamp > _immTimestamp;

        // For a retirement the immediate leg runs only for a flat term or a decaying
        // term still live at `_immTimestamp` (the gate below is
        // `delta_.end <= _immTimestamp`). A decaying term that has already ended has
        // nothing to subtract there; an immediate write would only shift when the
        // expiration sweep consumes its bucket, so it takes the deferred write alone.
        //
        // `previousDelegationEnd_` is read only on the subtractive branch;
        // `_calculateCheckpoint` reverts `AdditiveBranchExpectsZeroEnd` if an addition
        // passes a non-zero end, so additions pass 0.
        uint256 _deferredEnd = isDeltaPositive_ ? 0 : delta_.end;

        if (
            // No room: `_immTimestamp` is the boundary itself -- at `B - 1`, or
            // throughout the upgrade-hour window (`legacyDatingUntil`) -- so
            // the immediate leg would collide with the deferred write.
            _immTimestamp >= checkpointTimestamp_ ||
            // Retirements only: an addition's lock, if it ends at or before
            // `checkpointTimestamp_`, was already refused (or zeroed) by
            // `_getNormalizedLockedInfo`.
            (!isDeltaPositive_ && delta_.fixedBias == 0 && delta_.end <= _immTimestamp)
        ) {
            _writeCheckpoint({
                userDelegationCheckpoints_: userDelegationCheckpoints_,
                accountCheckpointsLength_: accountCheckpointsLength_,
                newCheckpoint_: _calculateCheckpoint({
                    previousCheckpoint_: lastCheckpoint_,
                    delegatee_: delegatee_,
                    isDeltaPositive_: isDeltaPositive_,
                    delta_: delta_,
                    checkpointTimestamp_: checkpointTimestamp_,
                    previousDelegationEnd_: _deferredEnd
                }),
                lastCheckpoint_: lastCheckpoint_
            });
            return;
        }

        // The delegatee's first checkpoint: no live element to copy and no order to
        // keep, so it goes straight in at `_immTimestamp`. Additions only: a
        // retirement always finds a non-empty array (see
        // `_moveVotingPowerFromPreviousDelegate`). `isDeltaPositive_` stays in the
        // condition because `_calculateCheckpoint`'s first-checkpoint branch builds the
        // element from the delta whatever its sign: a retirement reaching here would
        // silently mint votes, where without the shortcut it panics on the
        // `accountCheckpointsLength_ - 1` index.
        if (accountCheckpointsLength_ == 0 && isDeltaPositive_) {
            userDelegationCheckpoints_.push(
                _calculateCheckpoint({
                    previousCheckpoint_: lastCheckpoint_,
                    delegatee_: delegatee_,
                    isDeltaPositive_: isDeltaPositive_,
                    delta_: delta_,
                    checkpointTimestamp_: _immTimestamp,
                    previousDelegationEnd_: _deferredEnd
                })
            );
            return;
        }

        // Judged before anything is computed from it: `_pendingNew` below is built on
        // the premise that the pending element is dated exactly `checkpointTimestamp_`
        // (clause (2)), which makes `_calculateCheckpoint` skip the expiration sweep; on
        // a false premise that sweep would be wrong, or an arithmetic panic would mask
        // this error. Kept outside the branch below so that a sole pending element
        // (`len == 1`) is judged too.
        if (_hasPending && lastCheckpoint_.timestamp != checkpointTimestamp_) {
            revert CheckpointLayoutViolated();
        }

        DelegateCheckpoint memory _pendingNew;
        if (_hasPending) {
            // `lastCheckpoint_.timestamp == checkpointTimestamp_`, so
            // `_calculateCheckpoint` skips the expiration sweep: this applies the
            // delta to the pending aggregate alone.
            _pendingNew = _calculateCheckpoint({
                previousCheckpoint_: lastCheckpoint_,
                delegatee_: delegatee_,
                isDeltaPositive_: isDeltaPositive_,
                delta_: delta_,
                checkpointTimestamp_: checkpointTimestamp_,
                previousDelegationEnd_: _deferredEnd
            });
        }

        // Past the shortcut above an empty array is reachable only by a retirement,
        // which the invariant noted in `_moveVotingPowerFromPreviousDelegate` rules out
        // (it would panic on the index). The length test separates "pending only"
        // (`len == 1`) from "live (+ pending)".
        if (!_hasPending || accountCheckpointsLength_ > 1) {
            uint256 _liveIndex = _hasPending
                ? accountCheckpointsLength_ - 2
                : accountCheckpointsLength_ - 1;
            DelegateCheckpoint memory _liveCheckpoint = userDelegationCheckpoints_[_liveIndex];
            // Precondition check on the two elements `_liveIndex` arithmetic names (the
            // tail and its predecessor), nothing more; it does not audit the array's
            // interior or the content of any write:
            //   * the element treated as LIVE is dated at or before `_immTimestamp`
            //     (clause (2); otherwise writing `_immNew` there would unsort the array
            //     and `_checkpointBinarySearch` would return an element dated after the
            //     query);
            //   * the tail pair is strictly ascending (clause (1) on the tail). This
            //     costs no SLOAD with a pending element (`_liveCheckpoint` is
            //     `A[len - 2]`) and one SLOAD without.
            // The pending element's date was judged above. The predecessor's timestamp
            // is read inline: one more local here is Stack too deep.
            if (
                _liveCheckpoint.timestamp > _immTimestamp ||
                (accountCheckpointsLength_ > 1 &&
                    uint256(lastCheckpoint_.timestamp) <=
                    (
                        _hasPending
                            ? uint256(_liveCheckpoint.timestamp)
                            : uint256(
                                userDelegationCheckpoints_[accountCheckpointsLength_ - 2]
                                    .timestamp
                            )
                    ))
            ) revert CheckpointLayoutViolated();
            DelegateCheckpoint memory _immNew = _calculateCheckpoint({
                previousCheckpoint_: _liveCheckpoint,
                delegatee_: delegatee_,
                isDeltaPositive_: isDeltaPositive_,
                delta_: delta_,
                checkpointTimestamp_: _immTimestamp,
                // The "already expired" gate in `_calculateCheckpoint` compares against
                // this leg's date, `_immTimestamp`: the same threshold as the bucket
                // decrement in `_moveVotingPowerFromPreviousDelegate` (`end > _imm()`),
                // so the bucket and the checkpoint never disagree about a term. No
                // residual on this leg: a decaying term with `end <= _immTimestamp` left
                // through the deferred-only branch above; the 0 arm is reached only by a
                // flat retirement (whose decaying components are 0) and by additions.
                previousDelegationEnd_: _deferredEnd > _immTimestamp ? _deferredEnd : 0
            });

            if (_liveCheckpoint.timestamp == _immTimestamp) {
                userDelegationCheckpoints_[_liveIndex] = _immNew;
                if (_hasPending) {
                    userDelegationCheckpoints_[accountCheckpointsLength_ - 1] = _pendingNew;
                }
            } else if (_hasPending) {
                // Insert `_immNew` before the pending element, keeping the array
                // sorted: push the updated pending element, then overwrite the slot it
                // vacated.
                userDelegationCheckpoints_.push(_pendingNew);
                userDelegationCheckpoints_[accountCheckpointsLength_ - 1] = _immNew;
            } else {
                userDelegationCheckpoints_.push(_immNew);
            }
        } else if (_hasPending) {
            userDelegationCheckpoints_[accountCheckpointsLength_ - 1] = _pendingNew;
        }
    }

    function _writeCheckpoint(
        DelegateCheckpoint[] storage userDelegationCheckpoints_,
        uint256 accountCheckpointsLength_,
        DelegateCheckpoint memory newCheckpoint_,
        DelegateCheckpoint memory lastCheckpoint_
    ) internal {
        // If the newCheckpoint has the same timestamp as the last checkpoint, overwrite it
        if (
            accountCheckpointsLength_ > 0 && lastCheckpoint_.timestamp == newCheckpoint_.timestamp
        ) {
            userDelegationCheckpoints_[accountCheckpointsLength_ - 1] = newCheckpoint_;
        } else {
            // Otherwise, push a new checkpoint
            userDelegationCheckpoints_.push(newCheckpoint_);
        }
    }
}

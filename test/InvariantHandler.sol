// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";

/// @notice Minimal IAdapterNotify-compatible adapter that counts every
///         relay call. Used by the handler to drive the
///         `notifyDelegateChanged`/`notifyVotesChanged` paths and by
///         `invariant_adapterRelayParity` to assert the relays fire.
contract CountingAdapter {
    uint256 public notifyDelegateChangedCount;
    uint256 public notifyVotesChangedCount;

    function notifyDelegateChanged(address, address, address) external {
        unchecked { notifyDelegateChangedCount += 1; }
    }

    function notifyVotesChanged(address, uint256, uint256) external {
        unchecked { notifyVotesChangedCount += 1; }
    }
}

contract InvariantHandler is Test {
    VeHemi public veHemi;
    VeHemiVoteDelegation public delegation;
    MockERC20 public hemi;

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;

    uint256 private constant MIN_AMOUNT = 11e18; // must be >= VeHemi.MIN_LOCK_AMOUNT (10e18)
    uint256 private constant MAX_AMOUNT = 1_000e18;

    uint256 private constant MIN_DURATION = 2 * SIX_DAYS;
    uint256 private constant MAX_DURATION = 4 * YEAR;

    uint256 MAX_ACCUMULATED_WARP = SIX_DAYS * 255; // max duration between checkpoints the `totalVeHemiSupply()` supports
    uint256 maxWarp = MAX_ACCUMULATED_WARP;

    address[5] public users;
    address admin;

    // V2: Track non-transferrable token IDs for seeding
    uint256[] internal _lockedTokenIds;
    bool public seeded;

    /// @dev Counter incremented every time `seed()` is invoked WITH at least
    ///      one eligible non-transferable position present. Read by
    ///      `invariant_seedingAttemptCounterAndSeededLatchAreCoherent` in
    ///      `Invariant.t.sol` to prove the `seed()` action is being
    ///      exercised under fuzz AND completes cleanly (latch flips when
    ///      the counter increments) — without this metric, a future
    ///      regression that broke `markSeedingStarted` could leave every
    ///      subcurve invariant vacuously satisfied (their `if (!seeded)
    ///      return;` short-circuit) and the test suite would silently pass.
    ///
    ///      The invariant only fires once `seedAttempts > 0`, so runs whose
    ///      fuzz sequence never picks `seed()` are tolerated. About
    ///      6% of handler ticks invoke `seed()`, so at depth=128 the
    ///      probability of a fully vacuous run is ~(1-0.06)^128 ≈ 0.04% —
    ///      acceptable.
    uint256 public seedAttempts;

    /// @dev Token IDs that have been cleared via `forfeit()`. Used by
    ///      `invariant_forfeitClearsDelegations` to scope the cleanup
    ///      check to the forfeit path specifically and avoid conflating
    ///      it with natural-withdraw cleanup, which is intentionally out
    ///      of scope for that invariant.
    uint256[] public forfeitedTokenIds;

    function forfeitedTokenIdsLength() external view returns (uint256) {
        return forfeitedTokenIds.length;
    }

    /// @notice Counting adapter installed as trustedAdapter on VVD. Every
    ///         `notifyDelegateChanged` / `notifyVotesChanged` call from the
    ///         delegation contract bumps a counter. Used by
    ///         `invariant_adapterRelayParity` to prove the relay paths are
    ///         being exercised under fuzz (without it, the entire
    ///         IAdapterNotify code branch is dead in the invariant suite).
    CountingAdapter public adapter;

    /// @notice Past-votes ring buffer for `invariant_pastVotesImmutability`.
    ///         `samplePastVotes(rand)` captures `(addr, timestamp, votes)`
    ///         tuples; the invariant later asserts each tuple's `votes`
    ///         field is byte-identical when re-queried — pinning the
    ///         retroactive immutability of `getPastVotes` across every
    ///         subsequent handler tick (delegate/forfeit/transfer/extend
    ///         must not retroactively rewrite history).
    struct PastVotesSample {
        address account;
        uint256 timestamp;
        uint256 votes;
    }
    PastVotesSample[] public pastVotesSamples;

    function pastVotesSamplesLength() external view returns (uint256) {
        return pastVotesSamples.length;
    }

    constructor(address admin_, address[5] memory _users) {
        users = _users;
        admin = admin_;

        hemi = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemi));

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, admin_)
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));

        vm.startPrank(admin_);
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(admin_);
        vm.stopPrank();

        // Install a counting adapter as the trustedAdapter so the
        // IAdapterNotify relay paths (otherwise unreached under fuzz) are
        // exercised on every delegation mutation.
        adapter = new CountingAdapter();
        vm.prank(admin_);
        delegation.setTrustedAdapter(address(adapter));

        // Auto-relock presence check: without `autoRelockRemaining(uint256)` the
        // staticcall reverts and every auto-relock action below is a no-op.
        (bool _presenceOk, bytes memory _presenceRet) = address(veHemi).staticcall(
            abi.encodeWithSignature("autoRelockRemaining(uint256)", uint256(1))
        );
        autoRelockSupported = _presenceOk && _presenceRet.length >= 32;
    }

    // Return 0x0 instead of reverting if the NFT does not exist anymore
    function _ownerOf(uint256 tokenId) public returns (address from) {
        (bool ok, bytes memory data) = address(veHemi).call(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );

        if (!ok) return address(0);

        assembly {
            from := mload(add(data, 32))
        }
    }

    // ── Position creation actions ────────────────────────────────────────

    /// @dev Creates a transferable lock (tracked in global curve only)
    function createLock(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(msg.sender);
        hemi.mint(msg.sender, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    /// @dev Creates a non-transferrable, non-forfeitable lock (locked curve only).
    ///      Tracks the token ID for seeding.
    function createLockedPosition(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(admin);
        hemi.mint(admin, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLockFor(amount, duration, msg.sender, false, false);
        vm.stopPrank();

        if (!seeded) _lockedTokenIds.push(tokenId);

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    /// @dev Creates a non-transferrable, forfeitable lock (locked + forfeitable curves).
    ///      Tracks the token ID for seeding.
    function createForfeitablePosition(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(admin);
        hemi.mint(admin, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLockFor(amount, duration, msg.sender, false, true);
        vm.stopPrank();

        if (!seeded) _lockedTokenIds.push(tokenId);

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    // ── Seeding action ───────────────────────────────────────────────────

    /// @dev Seeds the locked + forfeitable curves via the 3-phase flow:
    ///      markSeedingStarted → seedBatch(all) → finalizeSeeding. Can only
    ///      succeed once. Skipped if no non-transferable positions exist yet
    ///      (the seed would produce a zero-supply LockedPoint).
    function seed() public {
        if (seeded) return;
        if (_lockedTokenIds.length == 0) return;

        // Confirm at least one tracked token survived (not burned) and has
        // an active non-transferable lock. If everything has been forfeited
        // or expired we skip — the seeding flow accepts an all-empty scan
        // but the tests assert post-seed totals, so the handler keeps a
        // skip-when-empty semantic.
        bool anyEligible;
        for (uint256 i; i < _lockedTokenIds.length; i++) {
            uint256 id = _lockedTokenIds[i];
            if (_ownerOf(id) == address(0)) continue;
            if (veHemi.getLockedBalance(id).amount <= 0) continue;
            anyEligible = true;
            break;
        }
        if (!anyEligible) return;

        // Record that an eligible seeding attempt was made. Read by
        // `invariant_seedingAttemptCounterAndSeededLatchAreCoherent` in
        // Invariant.t.sol to defend against the vacuity-on-broken-seed
        // regression class.
        seedAttempts += 1;

        vm.startPrank(admin);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        vm.stopPrank();

        seeded = true;
        maxWarp = MAX_ACCUMULATED_WARP;
    }

    /// @dev Multi-block seeding probe: open the window, advance time, drive
    ///      a permissionless `seedBatch` from a non-admin caller, and then a
    ///      permissionless `finalizeSeeding` (also cross-block). Seeding
    ///      has no single-block atomicity guard — cross-block execution
    ///      MUST succeed and the seeded totals must match a single-block
    ///      scan.
    ///
    ///      This probe pins three properties under fuzz:
    ///        1. `seedBatch` is callable by ANY address (not just owner).
    ///        2. `finalizeSeeding` is callable by ANY address.
    ///        3. Cross-block execution produces a correctly-finalized latch.
    ///
    ///      Side-effect-free: snapshots VM state, runs the probe, then
    ///      reverts. The companion `seed()` path remains the only way to
    ///      complete the flow on the live invariant timeline.
    function probeSeedingPermissionlessMultiBlock(uint256 mode) public {
        if (seeded) return;
        if (_lockedTokenIds.length == 0) return;

        // Only run if at least one eligible non-transferable position exists,
        // mirroring `seed()`'s pre-flight.
        bool anyEligible;
        for (uint256 i; i < _lockedTokenIds.length; i++) {
            uint256 id = _lockedTokenIds[i];
            if (_ownerOf(id) == address(0)) continue;
            if (veHemi.getLockedBalance(id).amount <= 0) continue;
            anyEligible = true;
            break;
        }
        if (!anyEligible) return;

        // Snapshot the entire VM state before the probe. The probe opens
        // the seeding window and advances time, which would otherwise leak
        // side-effects into later handler ticks. Snapshotting +
        // reverting keeps the probe truly side-effect-free.
        uint256 snap = vm.snapshotState();

        vm.prank(admin);
        veHemi.markSeedingStarted();

        // Advance time to T + 1 (any positive delta exercises multi-block
        // execution).
        vm.warp(block.timestamp + 1);

        // Pick a non-admin caller to prove permissionless semantics.
        address keeper = address(uint160(0xBADBAD));

        if (mode % 2 == 0) {
            // Path A: keeper drives both seedBatch and finalizeSeeding.
            vm.prank(keeper);
            veHemi.seedBatch(type(uint256).max);
            vm.prank(keeper);
            veHemi.finalizeSeeding();
        } else {
            // Path B: admin drives seedBatch, keeper drives finalizeSeeding.
            vm.prank(admin);
            veHemi.seedBatch(type(uint256).max);
            vm.prank(keeper);
            veHemi.finalizeSeeding();
        }

        // Roll back every state change the probe made. Subsequent handler
        // ticks see the same world they would have without this probe.
        vm.revertToState(snap);
    }

    // ── Mutation actions ─────────────────────────────────────────────────

    function forfeit() public {
        for (uint256 id; id < veHemi.nextTokenId(); id++) {
            if (!veHemi.forfeitable(id)) continue;
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (_lock.end <= block.timestamp) continue;
            // V2: Forfeit window expires at transferableAfter
            if (block.timestamp >= veHemi.transferableAfter(id)) continue;

            vm.prank(veHemi.forfeitAdmin());
            veHemi.forfeit(id);
            forfeitedTokenIds.push(id);
            _clearGhostOnBurn(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    /// @notice Deliberately warp into the
    ///         `[lock.end - CHECKPOINT_INTERVAL, lock.end)` window and forfeit.
    ///         A forfeit there must still run the delegation cleanup and
    ///         clear `voteDelegation.delegations[id]`.
    ///         The generic `forfeit()` handler above almost never lands here
    ///         under uniform warps (1-hour window out of multi-year horizon),
    ///         so this dedicated action gives the fuzzer determined coverage
    ///         of that window.
    function forfeitNearExpiry(uint256 seed) public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            if (!veHemi.forfeitable(id)) continue;
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            // Need at least one full checkpoint interval of headroom and a
            // live (not-yet-expired) lock to land inside that window.
            if (_lock.end <= block.timestamp + 1) continue;
            if (_lock.end <= 1 hours) continue;

            // Pick an offset in [1, 1 hours - 1) so we land strictly inside
            // (lockEnd - 1h, lockEnd). The 1-tick boundaries (0 and exactly
            // 1 hour out) are already pinned by unit tests in
            // DelegationBehavior.t.sol; here we sweep the interior.
            uint256 offset = (seed % (1 hours - 1)) + 1;
            if (_lock.end <= offset) continue;
            uint256 target = _lock.end - offset;
            if (target <= block.timestamp) continue;
            if (target >= veHemi.transferableAfter(id)) continue;

            vm.warp(target);
            // Re-check the forfeit-window precondition after the warp.
            if (block.timestamp >= veHemi.transferableAfter(id)) continue;

            vm.prank(veHemi.forfeitAdmin());
            veHemi.forfeit(id);
            forfeitedTokenIds.push(id);
            _clearGhostOnBurn(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            return;
        }
    }

    function increaseAmount(uint256 amount) public {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            if (_lock.amount == 0) continue;
            if (_lock.end <= block.timestamp) continue;

            address owner = veHemi.ownerOf(id);

            vm.startPrank(owner);
            hemi.mint(owner, amount);
            hemi.approve(address(veHemi), amount);
            veHemi.increaseAmount(id, amount);
            vm.stopPrank();

            // A top-up re-bases a flat position's weight (slope * (R - S/2));
            // R itself must not move.
            _resyncFlatWeight(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function increaseUnlockTime(uint256 duration) public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            // Flat positions are extended by `extendFlatPosition`, which
            // re-anchors the auto-relock ghost.
            if (isFlat(id)) continue;
            if (block.timestamp >= _lock.end) continue;
            uint256 currentDuration = _lock.end - block.timestamp;
            if (currentDuration + SIX_DAYS > MAX_DURATION) continue;

            duration = bound(duration, currentDuration + SIX_DAYS, MAX_DURATION);

            vm.prank(owner);
            veHemi.increaseUnlockTime(id, duration);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function transfer(uint256 rand) public {
        address to = users[rand % users.length];

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address from = _ownerOf(id);

            if (from == address(0) || to == from) continue;
            // Skip non-transferrable positions (would revert)
            if (!veHemi.isTransferable(id)) continue;

            bool _wasFlat = isFlat(id);
            vm.prank(from);
            veHemi.transferFrom(from, to, id);
            // A transfer to another account disarms auto-relock.
            if (_wasFlat) _flatGhosts[id].enabled = false;

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function withdraw() public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            if (block.timestamp < _lock.end) continue;
            // A flat position's stored `lock.end` may be in the past, but it is
            // not withdrawable (`probeFlatWithdrawBlocked` asserts the refusal).
            if (isFlat(id)) continue;

            vm.prank(owner);
            veHemi.withdraw(id);
            _clearGhostOnBurn(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function delegate(uint256 rand) public {
        address delegatee = users[rand % users.length];

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            uint256 nextHourBoundary = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;

            if (nextHourBoundary >= _lock.end) continue;

            vm.prank(owner);
            delegation.delegate(id, delegatee);

            break;
        }
    }

    /// @dev Exercises the standalone setAutoDelegate path. The fuzz
    ///      invariant checks then assert that this never mutates existing
    ///      per-tokenId delegations and never causes address(0) state to
    ///      accumulate.
    function setAutoDelegate(uint256 rand, uint256 callerIdx) public {
        address caller = users[callerIdx % users.length];
        address target = users[rand % users.length];
        vm.prank(caller);
        delegation.setAutoDelegate(target);
    }

    /// @dev Companion to setAutoDelegate — exercises the clear path so the
    ///      fuzzer can drive arbitrary set/clear/set sequences.
    function clearAutoDelegate(uint256 callerIdx) public {
        address caller = users[callerIdx % users.length];
        vm.prank(caller);
        delegation.clearAutoDelegate();
    }

    function warp(uint256 time) public {
        if (maxWarp == 0) return;

        time = bound(time, 1, maxWarp);
        vm.warp(block.timestamp + time);

        maxWarp -= time;
    }

    /// @dev Companion to `warp()` biased toward sub-CHECKPOINT_INTERVAL
    ///      jumps. The generic `warp` draws uniformly from `[1, ~4 years]`
    ///      so most ticks overshoot every hour boundary at once and the
    ///      fuzzer rarely probes inter-checkpoint edges. `warpSmall`
    ///      restricts to `[1, 3 hours]` so the fuzzer can land between
    ///      hour buckets and exercise the boundary code paths, such as
    ///      the near-expiry forfeit delegation cleanup.
    function warpSmall(uint256 time) public {
        if (maxWarp == 0) return;

        uint256 cap = maxWarp < 3 hours ? maxWarp : 3 hours;
        time = bound(time, 1, cap);
        vm.warp(block.timestamp + time);

        maxWarp -= time;
    }

    /// @notice Capture a `(account, timestamp, votes)` snapshot for the
    ///         `invariant_pastVotesImmutability` assertion. Drawn from
    ///         the `users` array; the captured timestamp is `block.timestamp`
    ///         at sample time. Subsequent invariant ticks will re-query
    ///         `getPastVotes(account, timestamp)` and assert byte-equality
    ///         against the saved `votes` — pinning retroactive immutability.
    ///
    ///         Bounded to 32 samples to keep invariant gas modest; once full,
    ///         new samples overwrite the oldest entry (ring-buffer semantics).
    function samplePastVotes(uint256 rand) public {
        address account = users[rand % users.length];
        uint256 votes = delegation.getVotes(account);
        uint256 ts = block.timestamp;

        if (pastVotesSamples.length < 32) {
            pastVotesSamples.push(PastVotesSample({account: account, timestamp: ts, votes: votes}));
        } else {
            uint256 slot = rand % 32;
            pastVotesSamples[slot] = PastVotesSample({account: account, timestamp: ts, votes: votes});
        }
    }

    /// @dev Permissionless bare-checkpoint path. Exercises `_checkpoint(0, ...)`
    ///      which writes to globalPointHistory / lockedGlobalPointHistory /
    ///      forfeitableGlobalPointHistory without an accompanying user mutation.
    function checkpoint() public {
        veHemi.checkpoint();
    }

    // =====================================================================
    // Auto-relock actions and ghost state
    // =====================================================================
    //
    // The feature is reached through the ABI only (`abi.encodeWithSignature`
    // plus `autoRelockSupported`, checked in the constructor), so on a build
    // without it every action below is a no-op and the invariants of
    // test/Invariant.t.sol run unchanged; `invariant_autoRelockAbiIsPresent`
    // (test/AutoRelockInvariant.t.sol) fails in that case.
    //
    // Notation: R = autoRelockRemaining(id), S = SIX_DAYS, and
    // grid(t) = floor(t / S) * S, the start of t's six-day bucket.

    bool public autoRelockSupported;

    /// @dev Enables whose weight step was not the bucket-mean closed form
    ///      `slope * (off - SIX_DAYS/2)` (signed), `off = now - grid(now)`.
    uint256 public autoRelockEnableStepViolations;

    /// @notice Committed auto-relock actions in this run: enables, owner
    ///         disables and flat extensions (`extendFlatPosition`), counted
    ///         on the success path only. Floored across runs by
    ///         `AutoRelockInvariantTest.afterInvariant`.
    uint256 public autoRelockEnableSuccesses;
    uint256 public autoRelockDisableSuccesses;
    uint256 public autoRelockExtendSuccesses;

    /// @notice Per-token auto-relock ghost, written by this handler at each
    ///         auto-relock action.
    struct FlatGhost {
        uint64 enabledAt;        // timestamp of the enable (or of the last flat extension)
        uint64 endBeforeEnable;  // lock.end just before the enable (or the end bought by the last flat extension)
        uint64 remainingAuthored; // R computed here: floor((endBeforeEnable - grid(enabledAt)) / S) * S
        uint64 disabledAt;       // timestamp of the last owner disable
        uint64 endAfterDisable;  // lock.end just after the last owner disable
        uint256 flatWeight;      // balanceOfNFT just after the enable, re-based by top-ups
        bool enabled;            // the handler believes auto-relock is enabled (the position is flat)
        bool everEnabled;
        bool ownerDisabled;      // the last exit from flat was an owner disable
    }

    mapping(uint256 => FlatGhost) internal _flatGhosts;
    uint256[] public everEnabledIds;

    function flatGhost(uint256 tokenId) external view returns (FlatGhost memory) {
        return _flatGhosts[tokenId];
    }

    function everEnabledIdsLength() external view returns (uint256) {
        return everEnabledIds.length;
    }

    /// @notice Reads `autoRelockRemaining(tokenId)` from the contract; 0 when the feature
    ///         is absent.
    function readAutoRelockRemaining(uint256 tokenId) public view returns (uint64) {
        if (!autoRelockSupported) return 0;
        (bool ok, bytes memory returnData) = address(veHemi).staticcall(
            abi.encodeWithSignature("autoRelockRemaining(uint256)", tokenId)
        );
        if (!ok || returnData.length < 32) return 0;
        return abi.decode(returnData, (uint64));
    }

    function isFlat(uint256 tokenId) public view returns (bool) {
        return readAutoRelockRemaining(tokenId) != 0;
    }

    /// @dev `mustSucceed == true` re-throws the callee's revert data, so under
    ///      `fail_on_revert = true` a refused mandatory call fails the run.
    function _autoRelockCall(bytes memory data, bool mustSucceed) internal returns (bool ok) {
        bytes memory ret;
        (ok, ret) = address(veHemi).call(data);
        if (!ok && mustSucceed) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _recordFirstEnable(uint256 tokenId) internal {
        if (!_flatGhosts[tokenId].everEnabled) {
            _flatGhosts[tokenId].everEnabled = true;
            everEnabledIds.push(tokenId);
        }
    }

    /// @dev Re-snapshot only the flat weight after an action that may
    ///      legitimately change it (a top-up or a flat extension).
    function _resyncFlatWeight(uint256 tokenId) internal {
        if (!autoRelockSupported) return;
        FlatGhost storage g = _flatGhosts[tokenId];
        if (!g.everEnabled || !g.enabled) return;
        g.flatWeight = veHemi.balanceOfNFT(tokenId);
    }

    /// @dev The position was burned (withdraw / forfeit).
    function _clearGhostOnBurn(uint256 tokenId) internal {
        if (!autoRelockSupported) return;
        _flatGhosts[tokenId].enabled = false;
    }

    /// @notice Enable auto-relock on the first eligible position at or after a
    ///         fuzz-chosen index, as its owner.
    /// @dev Mirrors the contract's preconditions: not already flat, live lock,
    ///      and `lock.end >= now + 2 * SIX_DAYS` (so R is at least two whole
    ///      buckets). The one refusal the handler tolerates is
    ///      `SeedingNotFinalized` on a non-transferable position before seeding
    ///      is finalized; every other enable is mandatory-success.
    function enableAutoRelock(uint256 rand) public {
        if (!autoRelockSupported) return;

        uint256 next = veHemi.nextTokenId();
        if (next <= 1) return;
        uint256 start = 1 + (rand % (next - 1));

        for (uint256 k; k < next - 1; ++k) {
            uint256 id = 1 + ((start - 1 + k) % (next - 1));

            address owner = _ownerOf(id);
            if (owner == address(0)) continue;
            if (isFlat(id)) continue;

            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(id);
            if (lb.amount <= 0) continue;
            if (lb.end < block.timestamp + 2 * SIX_DAYS) continue;

            bool mandatory =
                veHemi.lockedSeedingFinalized() || veHemi.transferableAfter(id) <= block.timestamp;

            uint256 weightBefore = veHemi.balanceOfNFT(id);
            vm.prank(owner);
            bool ok = _autoRelockCall(abi.encodeWithSignature("enableAutoRelock(uint256)", id), mandatory);
            if (!ok) return;
            autoRelockEnableSuccesses += 1;

            _recordFirstEnable(id);
            FlatGhost storage g = _flatGhosts[id];
            g.enabledAt = uint64(block.timestamp);
            g.endBeforeEnable = lb.end;
            g.remainingAuthored = uint64(
                ((uint256(lb.end) - (block.timestamp / SIX_DAYS) * SIX_DAYS) / SIX_DAYS) * SIX_DAYS
            );
            g.ownerDisabled = false;
            g.flatWeight = veHemi.balanceOfNFT(id);
            g.enabled = true;
            // The enable step: the flat level is `slope * (R - S/2)` and the
            // decaying weight just before was `slope * (R - off)`, so
            //     flatWeight - weightBefore == slope * off - slope * S/2   (signed, exact).
            {
                uint256 _slope = uint256(uint128(lb.amount)) / MAX_DURATION;
                uint256 _slopeTimesOffset =
                    _slope * (block.timestamp - (block.timestamp / SIX_DAYS) * SIX_DAYS);
                uint256 _slopeTimesHalfBucket = _slope * (SIX_DAYS / 2);
                uint256 _expectUp =
                    _slopeTimesOffset >= _slopeTimesHalfBucket ? _slopeTimesOffset - _slopeTimesHalfBucket : 0;
                uint256 _expectDown =
                    _slopeTimesHalfBucket > _slopeTimesOffset ? _slopeTimesHalfBucket - _slopeTimesOffset : 0;
                uint256 _actualUp = g.flatWeight >= weightBefore ? g.flatWeight - weightBefore : 0;
                uint256 _actualDown = weightBefore > g.flatWeight ? weightBefore - g.flatWeight : 0;
                if (_actualUp != _expectUp || _actualDown != _expectDown) {
                    autoRelockEnableStepViolations += 1;
                }
            }

            maxWarp = MAX_ACCUMULATED_WARP;
            return;
        }
    }

    /// @notice Disable auto-relock on the first flat position at or after a
    ///         fuzz-chosen index, as its owner. Mandatory-success: a disable
    ///         that reverts would lock the principal.
    function disableAutoRelock(uint256 rand) public {
        if (!autoRelockSupported) return;
        uint256 n = everEnabledIds.length;
        if (n == 0) return;
        uint256 start = rand % n;

        for (uint256 k; k < n; ++k) {
            uint256 id = everEnabledIds[(start + k) % n];
            if (!isFlat(id)) continue;
            address owner = _ownerOf(id);
            if (owner == address(0)) continue;

            vm.prank(owner);
            _autoRelockCall(abi.encodeWithSignature("disableAutoRelock(uint256)", id), true);
            autoRelockDisableSuccesses += 1;

            FlatGhost storage g = _flatGhosts[id];
            g.enabled = false;
            g.ownerDisabled = true;
            g.disabledAt = uint64(block.timestamp);
            g.endAfterDisable = veHemi.getLockedBalance(id).end;

            maxWarp = MAX_ACCUMULATED_WARP;
            return;
        }
    }

    /// @notice `increaseUnlockTime` on a flat position. The contract accepts it
    ///         and sets `R = unlockTime - grid(now)`; the ghost is re-anchored
    ///         from the handler's own inputs (the end it asked for and its own
    ///         clock), never from the contract.
    function extendFlatPosition(uint256 rand) public {
        if (!autoRelockSupported) return;
        uint256 n = everEnabledIds.length;
        if (n == 0) return;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = everEnabledIds[(start + k) % n];
            if (!isFlat(id)) continue;
            address owner = _ownerOf(id);
            if (owner == address(0)) continue;
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (block.timestamp >= _lock.end) continue;
            uint256 currentDuration = _lock.end - block.timestamp;
            if (currentDuration + SIX_DAYS > MAX_DURATION) continue;
            uint256 duration = bound(rand, currentDuration + SIX_DAYS, MAX_DURATION);

            vm.prank(owner);
            bool ok = _autoRelockCall(
                abi.encodeWithSignature("increaseUnlockTime(uint256,uint256)", id, duration),
                false
            );
            if (ok) {
                autoRelockExtendSuccesses += 1;
                _resyncFlatWeight(id);
                uint256 _authoredEnd = ((block.timestamp + duration) / SIX_DAYS) * SIX_DAYS;
                uint256 _gridNow = (block.timestamp / SIX_DAYS) * SIX_DAYS;
                FlatGhost storage g = _flatGhosts[id];
                g.remainingAuthored = uint64(_authoredEnd - _gridNow);
                g.enabledAt = uint64(block.timestamp);
                g.endBeforeEnable = uint64(_authoredEnd);
            }
            maxWarp = MAX_ACCUMULATED_WARP;
            return;
        }
    }

    /// @notice Enable / disable / enable inside one tick: cycling must not
    ///         ratchet (`invariant_autoRelockDisableIsAntiRatchet`).
    function autoRelockChurn(uint256 rand) public {
        if (!autoRelockSupported) return;
        enableAutoRelock(rand);
        disableAutoRelock(rand);
        enableAutoRelock(rand >> 8);
    }

    /// @notice Warp to (or one second past) a disabled position's restored
    ///         `lock.end` and checkpoint there, so a restored slope that was
    ///         never scheduled for retirement would show up in the supply
    ///         invariants. Capped at the warp ceiling.
    function warpToRestoredEnd(uint256 rand) public {
        if (!autoRelockSupported) return;
        uint256 n = everEnabledIds.length;
        if (n == 0) return;
        uint256 start = rand % n;

        for (uint256 k; k < n; ++k) {
            uint256 id = everEnabledIds[(start + k) % n];
            FlatGhost memory g = _flatGhosts[id];
            if (!g.ownerDisabled) continue;
            if (isFlat(id)) continue;
            if (_ownerOf(id) == address(0)) continue;
            uint256 end_ = veHemi.getLockedBalance(id).end;
            if (end_ <= block.timestamp) continue;
            uint256 delta = end_ - block.timestamp + (rand & 1);
            if (delta > MAX_ACCUMULATED_WARP) continue;

            vm.warp(block.timestamp + delta);
            veHemi.checkpoint();

            maxWarp = MAX_ACCUMULATED_WARP;
            return;
        }
    }

    /// @notice A flat position must not be withdrawable, even once its stored
    ///         `lock.end` is in the past. Issues the call and fails the run if
    ///         it succeeds; state is rolled back either way.
    function probeFlatWithdrawBlocked(uint256 rand) public {
        if (!autoRelockSupported) return;
        uint256 n = everEnabledIds.length;
        if (n == 0) return;
        uint256 start = rand % n;

        for (uint256 k; k < n; ++k) {
            uint256 id = everEnabledIds[(start + k) % n];
            if (!isFlat(id)) continue;
            address owner = _ownerOf(id);
            if (owner == address(0)) continue;

            uint256 snap = vm.snapshotState();
            vm.prank(owner);
            (bool ok, ) = address(veHemi).call(
                abi.encodeWithSignature("withdraw(uint256)", id)
            );
            vm.revertToState(snap);

            assertFalse(ok, "withdraw() succeeded on an auto-relock-enabled position");
            return;
        }
    }

    /// @notice A flat position must stay delegatable (its stored `lock.end`
    ///         may be in the past). A revert fails the run with a named reason.
    function delegateFlatPosition(uint256 rand) public {
        if (!autoRelockSupported) return;
        uint256 n = everEnabledIds.length;
        if (n == 0) return;
        address delegatee = users[rand % users.length];
        uint256 start = rand % n;

        for (uint256 k; k < n; ++k) {
            uint256 id = everEnabledIds[(start + k) % n];
            if (!isFlat(id)) continue;
            address owner = _ownerOf(id);
            if (owner == address(0)) continue;

            vm.prank(owner);
            (bool ok, bytes memory ret) = address(delegation).call(
                abi.encodeWithSignature("delegate(uint256,address)", id, delegatee)
            );
            if (!ok) {
                emit log_named_uint("delegate() reverted on a flat position, tokenId", id);
                emit log_named_bytes("  revert data", ret);
                assertTrue(false, "an auto-relock-enabled position is not delegatable");
            }
            return;
        }
    }

    /// @notice The owner tops a flat position up by 1 wei. R must not move
    ///         (`invariant_autoRelockRemainingMatchesAuthored`); the weight may,
    ///         so the weight ghost is re-based. (A stranger's top-up reverts
    ///         `NotOwner`, which would abort the run under `fail_on_revert`.)
    function topUpFlatPosition(uint256 rand) public {
        if (!autoRelockSupported) return;
        uint256 n = everEnabledIds.length;
        if (n == 0) return;
        uint256 start = rand % n;

        for (uint256 k; k < n; ++k) {
            uint256 id = everEnabledIds[(start + k) % n];
            if (!isFlat(id)) continue;
            address owner = _ownerOf(id);
            if (owner == address(0)) continue;

            vm.startPrank(owner);
            hemi.mint(owner, 1);
            hemi.approve(address(veHemi), 1);
            veHemi.increaseAmount(id, 1);
            vm.stopPrank();

            _resyncFlatWeight(id);

            maxWarp = MAX_ACCUMULATED_WARP;
            return;
        }
    }

    // =====================================================================
    // Lock-final-hour operations, for `invariant_pastVotesNeverExceedPastTotalSupply`
    //
    // The delegation module books a change at the next hour boundary `H`,
    // except that when a lock's `end <= H` (the near-expiry branch) its
    // retirement is deferred to `H`, which happens only in the lock's final
    // hour, its last `end % 3600` seconds. `warp` and `warpSmall` cannot aim
    // at `end`, so this action warps into that final hour and makes one
    // escrow-changing call there, recording the call instant and `end` so the
    // invariant can sample instants around both.
    // =====================================================================

    struct LockFinalHourRecord {
        uint64 calledAt;  // the instant the escrow-changing call was made
        uint64 endBefore; // the subject lock's `end` immediately BEFORE it
    }

    LockFinalHourRecord[] internal _lockFinalHourRecords;
    uint256 private constant LOCK_FINAL_HOUR_RING = 8;
    /// @dev Records written so far; once the ring is full, the next write
    ///      replaces slot `_lockFinalHourWrites % LOCK_FINAL_HOUR_RING`, the oldest.
    uint256 private _lockFinalHourWrites;

    function lockFinalHourRecordCount() external view returns (uint256) {
        return _lockFinalHourRecords.length;
    }

    function lockFinalHourRecord(uint256 i) external view returns (uint64 calledAt, uint64 endBefore) {
        LockFinalHourRecord storage r = _lockFinalHourRecords[i];
        return (r.calledAt, r.endBefore);
    }

    function _nextHourBoundary(uint256 t) internal pure returns (uint256) {
        return (t / 3600) * 3600 + 3600;
    }

    function _recordLockFinalHourOp(uint256 calledAt_, uint256 endBefore_) private {
        LockFinalHourRecord memory r =
            LockFinalHourRecord({calledAt: uint64(calledAt_), endBefore: uint64(endBefore_)});
        if (_lockFinalHourRecords.length < LOCK_FINAL_HOUR_RING) _lockFinalHourRecords.push(r);
        else _lockFinalHourRecords[_lockFinalHourWrites % LOCK_FINAL_HOUR_RING] = r;
        ++_lockFinalHourWrites;
    }

    /// @notice Warp into a live, decaying lock's final hour, to the earliest
    ///         `tau` with `H(tau) >= end`, and make one escrow-changing call
    ///         there: an extension, a top-up, a transfer or an unrelated mint.
    /// @dev Every branch is precondition-complete (`fail_on_revert = true`).
    ///      When no subject exists it creates one.
    function lockFinalHourOp(uint256 rand, uint256 actionSeed) public {
        uint256 next = veHemi.nextTokenId();
        if (next <= 1) {
            _primeLockFinalHourSubject(rand);
            return;
        }
        uint256 start = 1 + (rand % (next - 1));
        for (uint256 k; k < next - 1; ++k) {
            uint256 id = 1 + ((start - 1 + k) % (next - 1));
            address owner_ = _ownerOf(id);
            if (owner_ == address(0)) continue;
            if (isFlat(id)) continue; // a flat lock's stored `end` is not where it expires
            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(id);
            if (lb.amount <= 0) continue;
            uint256 end_ = lb.end;
            if (end_ <= block.timestamp + 1) continue;

            uint256 tau = (end_ / 3600) * 3600;
            if (tau <= block.timestamp) tau = block.timestamp + 1;
            if (tau >= end_) continue;
            if (_nextHourBoundary(tau) < end_) continue;      // not the near-expiry branch
            if (tau - block.timestamp > maxWarp) continue;

            vm.warp(tau);

            uint256 action = actionSeed % 4;
            if (action == 0) {
                uint256 currentDuration = end_ - block.timestamp;
                if (currentDuration + SIX_DAYS > MAX_DURATION) return;
                vm.prank(owner_);
                veHemi.increaseUnlockTime(id, MAX_DURATION / 2);
            } else if (action == 1) {
                vm.startPrank(owner_);
                hemi.mint(owner_, MIN_AMOUNT);
                hemi.approve(address(veHemi), MIN_AMOUNT);
                veHemi.increaseAmount(id, MIN_AMOUNT);
                vm.stopPrank();
            } else if (action == 2 && veHemi.isTransferable(id)) {
                address to = users[rand % users.length];
                // Reduce before adding: `rand` may be type(uint256).max.
                if (to == owner_) to = users[(rand % users.length + 1) % users.length];
                if (to == owner_) return;
                vm.prank(owner_);
                veHemi.transferFrom(owner_, to, id);
            } else {
                address maker = users[rand % users.length];
                vm.startPrank(maker);
                hemi.mint(maker, MIN_AMOUNT);
                hemi.approve(address(veHemi), MIN_AMOUNT);
                veHemi.createLock(MIN_AMOUNT, MIN_DURATION);
                vm.stopPrank();
            }

            _recordLockFinalHourOp(tau, end_);
            maxWarp = MAX_ACCUMULATED_WARP;
            return;
        }
        _primeLockFinalHourSubject(rand);
    }

    /// @dev Make a plain transferable lock so a later draw has a subject.
    function _primeLockFinalHourSubject(uint256 rand) private {
        address maker = users[rand % users.length];
        vm.startPrank(maker);
        hemi.mint(maker, MIN_AMOUNT);
        hemi.approve(address(veHemi), MIN_AMOUNT);
        veHemi.createLock(MIN_AMOUNT, MIN_DURATION);
        vm.stopPrank();
        maxWarp = MAX_ACCUMULATED_WARP;
    }
}

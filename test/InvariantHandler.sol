// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";

/// @notice Minimal IAdapterNotify-compatible adapter that counts every
///         relay call. Used by the handler to drive the previously-dead
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
    ///      fuzz sequence never picks `seed()` are tolerated. Empirically
    ///      ~6% of handler ticks invoke `seed()` (per N4-A7 measurement),
    ///      so at depth=128 the probability of a fully vacuous run is
    ///      ~(1-0.06)^128 ≈ 0.04% — acceptable.
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
    ///         being exercised under fuzz (pre-addition, the entire
    ///         IAdapterNotify code branch was dead in the invariant suite).
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
        // IAdapterNotify relay paths (previously dead under fuzz) are
        // exercised on every delegation mutation.
        adapter = new CountingAdapter();
        vm.prank(admin_);
        delegation.setTrustedAdapter(address(adapter));
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
        // or expired we skip — the new flow accepts an all-empty scan but
        // existing tests assert post-seed totals, so we mirror the old
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
        // regression class (MUT-Q7 in N4-A2's analysis).
        seedAttempts += 1;

        vm.startPrank(admin);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        vm.stopPrank();

        seeded = true;
        maxWarp = MAX_ACCUMULATED_WARP;
    }

    /// @dev Adversarial seeding probe: split the 3-phase flow across two
    ///      handler ticks so that `block.timestamp` advances between
    ///      `markSeedingStarted` and the subsequent `seedBatch` /
    ///      `finalizeSeeding`. The atomicity guard in `_requireSeedingActive`
    ///      MUST revert both follow-up calls with `SeedingInProgress`. If a
    ///      future refactor weakens the guard (e.g., relaxes the timestamp
    ///      check to `<=` or drops the check entirely), this probe surfaces
    ///      the regression under fuzz instead of leaving it as a unit-test-
    ///      only invariant.
    ///
    ///      Side-effect-free: every path either no-ops or runs an expected
    ///      revert and returns, so the handler's seeded/maxWarp state is
    ///      untouched. The companion `seed()` path remains the only way to
    ///      complete the flow legitimately.
    function probeSeedingAtomicityRevert(uint256 mode) public {
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

        // Snapshot the entire VM state before the probe. Both
        // `markSeedingStarted` (writes `seedingStarted` + `seedingStartedAt`)
        // and the subsequent `vm.warp` would otherwise leak side-effects into
        // later handler ticks — `seed()` would then revert at the next call
        // because `block.timestamp != seedingStartedAt`. Snapshotting +
        // reverting keeps the probe truly side-effect-free.
        uint256 snap = vm.snapshotState();

        vm.prank(admin);
        veHemi.markSeedingStarted();

        // Advance time to T + 1 (any positive delta breaks atomicity).
        vm.warp(block.timestamp + 1);

        // The cross-block guard MUST fire on whichever follow-up the fuzz
        // mode selects. Both `seedBatch` and `finalizeSeeding` route through
        // `_requireSeedingActive`, so both branches assert the same revert.
        if (mode % 2 == 0) {
            vm.prank(admin);
            vm.expectRevert(VeHemi.SeedingInProgress.selector);
            veHemi.seedBatch(type(uint256).max);
        } else {
            vm.prank(admin);
            vm.expectRevert(VeHemi.SeedingInProgress.selector);
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

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    /// @notice Deliberately warp into the previously-buggy
    ///         `[lock.end - CHECKPOINT_INTERVAL, lock.end)` window and forfeit.
    ///         Pre-fix, this window silently skipped the delegation cleanup
    ///         call and left `voteDelegation.delegations[id]` stale forever.
    ///         The generic `forfeit()` handler above almost never lands here
    ///         under uniform warps (1-hour window out of multi-year horizon),
    ///         so this dedicated action gives the fuzzer determined coverage
    ///         of the previously-broken regime.
    function forfeitNearExpiry(uint256 seed) public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            if (!veHemi.forfeitable(id)) continue;
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            // Need at least one full checkpoint interval of headroom and a
            // live (not-yet-expired) lock to land inside the buggy window.
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

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function increaseUnlockTime(uint256 duration) public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
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

            vm.prank(from);
            veHemi.transferFrom(from, to, id);

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

            vm.prank(owner);
            veHemi.withdraw(id);

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

            uint256 _nextCheckpoint = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;

            if (_nextCheckpoint >= _lock.end) continue;

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
    ///      hour buckets and exercise the boundary code paths that the
    ///      forfeit-stale-delegation fix specifically targeted.
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
}

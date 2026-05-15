// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/VeHemiVoteDelegation.sol";
import "../src/adapter/VeHemiAragonAdapter.sol";
import "../src/interfaces/IVeHemi.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";

/// @title  ForkE2EDeploymentTest
/// @notice End-to-end forked-mainnet upgrade dress rehearsal.
///
///         Simulates the FULL Hemi mainnet V2 upgrade sequence — every
///         transaction the Gnosis Safe will execute, every keeper step
///         the post-Safe runner script will perform, every guard / view /
///         user-facing operation that must work at each phase. Catches
///         deploy-time integration bugs (e.g., scripts/run-seeding-loop.ts
///         referencing an undefined slot constant after a half-finished
///         migration) before they surface against real funds.
///
///         Operational phases mirrored:
///           0. Pre-state snapshot   — sanity-check V1 mainnet state.
///           1. Safe MultiSend       — upgrade VVD, upgrade VeHemi,
///                                     markSeedingStarted, deploy adapter,
///                                     setTrustedAdapter.
///           2. Seeding-window guards — every mutation entry point that
///                                     should revert SeedingInProgress
///                                     actually does (and the ones that
///                                     should succeed actually do).
///           3. Permissionless seedBatch loop — multi-block, multi-keeper
///                                     (mirroring scripts/run-seeding-loop.ts
///                                     semantics, including the
///                                     `seedingCursor()` view that the
///                                     runner uses).
///           4. Permissionless finalizeSeeding — incomplete-cursor revert
///                                     guard, then real finalize.
///           5. Post-finalize ops    — V2 functionality wakes up; all
///                                     previously-blocked mutators unblock;
///                                     subcurve views return real values;
///                                     supply math is consistent.
///           6. Aragon governance    — adapter IVotes surface, delegate
///                                     flows, historical reads.
///           7. Decay across time    — multi-bucket forward warp,
///                                     supplyAt monotonicity, slope
///                                     transitions.
///           8. Final state          — storage-layout sanity post-flow
///                                     (slot probes for the V2 fields).
///
///         If any phase's invariants change in a future refactor, this
///         test fails loudly with a phase-tagged assertion message — the
///         operator never finds out during the live Safe execution.
contract ForkE2EDeploymentTest is Test {
    // ─────────────────────────────────────────────────────────────────────
    // Hemi mainnet addresses (immutable across this branch)
    // ─────────────────────────────────────────────────────────────────────

    address constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address constant VOTE_DELEGATION_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;
    address constant PROXY_ADMIN = 0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F;
    address constant GNOSIS_SAFE = 0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6;
    address constant HEMI_TOKEN = 0x99e3dE3817F6081B2568208337ef83295b7f591D;

    // Known non-transferable token ID range on mainnet (~28625-28808). Scanning
    // the full 0..nextTokenId range exceeds public RPC rate limits.
    uint256 constant LOCKED_RANGE_START = 28625;
    uint256 constant LOCKED_RANGE_END = 28809; // exclusive

    // VeHemiStorageV2 absolute slots (used for raw probes in Phase 8).
    uint256 constant SLOT_LOCKED_SEEDING_FINALIZED = 18;
    uint256 constant SLOT_SEEDING_STARTED = 21; // packed: bool@0 + uint64 seedingStartedAt@1
    uint256 constant SLOT_SEEDING_TARGET_ID = 22;
    uint256 constant SLOT_SEEDING_PROGRESS_BASE = 23;

    // Year/SIX_DAYS constants for time math (mirror VeHemi).
    uint256 constant YEAR = 365.25 days;
    uint256 constant SIX_DAYS = YEAR / 60;
    uint256 constant MAX_TIME = 4 * YEAR;
    uint256 constant MIN_LOCK_DURATION = 2 * SIX_DAYS;

    VeHemi veHemi;
    VeHemiVoteDelegation voteDelegation;
    IERC20 hemiToken;

    // Pre-upgrade snapshots
    uint256 preTotalLocked;
    uint256 preTotalSupply;
    uint256 preEpoch;
    uint256 preNextTokenId;
    uint256 preTotalNFTs;

    modifier onlyFork() {
        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }

        veHemi = VeHemi(VEHEMI_PROXY);
        voteDelegation = VeHemiVoteDelegation(VOTE_DELEGATION_PROXY);
        hemiToken = IERC20(HEMI_TOKEN);

        preTotalLocked = veHemi.totalLocked();
        preTotalSupply = veHemi.totalVeHemiSupply();
        preEpoch = veHemi.epoch();
        preNextTokenId = veHemi.nextTokenId();
        preTotalNFTs = veHemi.totalSupply();
    }

    // ═════════════════════════════════════════════════════════════════════
    // ENTRY: the full E2E walkthrough
    // ═════════════════════════════════════════════════════════════════════

    /// @notice End-to-end dress rehearsal for the V2 upgrade. Runs every
    ///         deployment phase against live Hemi mainnet state and
    ///         asserts the invariants we expect at each transition. Any
    ///         regression that would have shipped a broken deploy fails
    ///         this test with a phase-tagged message.
    function testE2E_FullDeployment() public onlyFork {
        // ── Phase 0: pre-deploy state sanity ────────────────────────────
        _phase0_preDeploySanity();

        // ── Phase 1: Safe MultiSend (5 entries) ─────────────────────────
        (uint256[] memory lockedIds, VeHemiAragonAdapter adapter) =
            _phase1_safeMultiSend();

        // ── Phase 2: in-window guards (mutators blocked, transferables ok) ──
        _phase2_verifyWindowGuards();

        // ── Phase 3: permissionless multi-block seedBatch loop ──────────
        _phase3_runSeedingLoopAsKeepers(lockedIds.length);

        // ── Phase 4: permissionless finalize (incomplete revert, then real) ─
        _phase4_finalizeSeeding(lockedIds);

        // ── Phase 5: V2 wakes up — non-destructive operations only ──────
        //    (mints + non-transferable mutations + forfeit). No large
        //    time warps here so Phases 6 and 7 see realistic mainnet
        //    state, not the all-expired degenerate after a MAX_TIME warp.
        _phase5_postFinalizeOperations();

        // ── Phase 6: Aragon governance through the adapter ──────────────
        //    Runs against realistic, lightly-warped post-finalize state.
        _phase6_aragonGovernance(adapter);

        // ── Phase 7: decay across time ──────────────────────────────────
        //    SIX_DAYS warp; mainnet positions are mostly multi-month so
        //    they decay materially but stay alive — the monotonicity and
        //    historical-supplyAt assertions are meaningful.
        _phase7_decayAcrossTime();

        // ── Phase 8 (raw storage probes) ────────────────────────────────
        _phase8_finalStorageProbes();

        // ── Phase 9: destructive withdraw test (intentionally last) ─────
        //    Warps past a freshly-minted MIN_LOCK_DURATION transferable's
        //    expiry and exercises the burn path. The ~12-day warp is the
        //    smallest possible (createLock enforces 2*SIX_DAYS minimum)
        //    and is run last so it can't pollute the realistic-state
        //    phases above.
        _phase9_withdrawDestructive();
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 0 — pre-deploy sanity
    // ═════════════════════════════════════════════════════════════════════

    function _phase0_preDeploySanity() internal {
        // Pre-existing mainnet state must be non-trivial: HEMI locked, NFTs
        // minted, supply > 0. If any of these are zero we are not on a
        // real Hemi fork and downstream phases would be meaningless.
        assertGt(preTotalLocked, 0, "phase0: mainnet should have HEMI locked");
        assertGt(preTotalNFTs, 0, "phase0: mainnet should have minted NFTs");
        assertGt(preTotalSupply, 0, "phase0: mainnet totalVeHemiSupply should be > 0");
        assertGt(preNextTokenId, 1, "phase0: mainnet should have minted at least 1 NFT");

        // Token conservation pre-upgrade.
        assertEq(
            hemiToken.balanceOf(address(veHemi)),
            preTotalLocked,
            "phase0: HEMI vault balance != totalLocked"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 1 — Safe MultiSend
    // ═════════════════════════════════════════════════════════════════════

    function _phase1_safeMultiSend()
        internal
        returns (uint256[] memory lockedIds, VeHemiAragonAdapter adapter)
    {
        // Step 1: upgrade VeHemiVoteDelegation impl → V2.
        _safeUpgradeVoteDelegation();

        // Verify VVD V1 state survived (totalSupply still works; delegations
        // still readable for live tokens; nonces unchanged).
        assertEq(
            address(voteDelegation.veHemi()),
            VEHEMI_PROXY,
            "phase1: VVD veHemi pointer changed"
        );

        // Step 2: upgrade VeHemi impl → V2.
        _safeUpgradeVeHemi();

        // V1 invariants must be byte-identical post-upgrade.
        assertEq(veHemi.totalLocked(), preTotalLocked, "phase1: totalLocked drift");
        assertEq(
            veHemi.totalVeHemiSupply(),
            preTotalSupply,
            "phase1: totalVeHemiSupply drift"
        );
        assertEq(veHemi.epoch(), preEpoch, "phase1: epoch drift");
        assertEq(veHemi.nextTokenId(), preNextTokenId, "phase1: nextTokenId drift");
        assertEq(veHemi.totalSupply(), preTotalNFTs, "phase1: ERC721 totalSupply drift");

        // V2 storage is zero-initialized: latch false, subcurve supplies 0.
        assertFalse(
            veHemi.lockedSeedingFinalized(),
            "phase1: lockedSeedingFinalized must default to false"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "phase1: locked subcurve must be empty pre-seeding"
        );
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            0,
            "phase1: forfeitable subcurve must be empty pre-seeding"
        );
        assertFalse(veHemi.seedingStarted(), "phase1: seeding latch must be false");
        assertEq(veHemi.seedingTargetId(), 0, "phase1: seedingTargetId must default to 0");
        assertEq(veHemi.seedingCursor(), 0, "phase1: seedingCursor must default to 0");

        // Pre-flight: capture the eligible non-transferable position set.
        lockedIds = _findNonTransferablePositions();
        emit log_named_uint("phase1: eligible non-transferable positions", lockedIds.length);

        // Access-control negative test: a non-owner caller MUST be rejected
        // by `markSeedingStarted`'s `onlyOwner` guard. Regression of the
        // guard would let any keeper open the window with a wrong target.
        address attackerOwner = makeAddr("phase1-non-owner");
        vm.prank(attackerOwner);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attackerOwner)
        );
        veHemi.markSeedingStarted();

        // Step 3: markSeedingStarted (owner-only).
        uint256 expectedTarget = veHemi.nextTokenId();
        vm.recordLogs();
        vm.prank(GNOSIS_SAFE);
        veHemi.markSeedingStarted();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // markSeedingStarted side-effects
        assertTrue(veHemi.seedingStarted(), "phase1: seedingStarted latch must flip");
        assertEq(
            veHemi.seedingTargetId(),
            expectedTarget,
            "phase1: seedingTargetId must snapshot nextTokenId"
        );
        assertEq(
            veHemi.seedingStartedAt(),
            uint64(block.timestamp),
            "phase1: seedingStartedAt must record block.timestamp"
        );
        _phase1_seedingStartedAt = veHemi.seedingStartedAt();
        assertEq(veHemi.seedingCursor(), 0, "phase1: seedingCursor must start at 0");

        // SeedingStarted event check.
        bool foundEvent;
        bytes32 sig = keccak256("SeedingStarted(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                uint256 emitted = abi.decode(logs[i].data, (uint256));
                assertEq(emitted, expectedTarget, "phase1: SeedingStarted arg mismatch");
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "phase1: SeedingStarted event must fire");

        // Re-calling markSeedingStarted reverts with SeedingAlreadyStarted.
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        veHemi.markSeedingStarted();

        // Step 4: deploy the Aragon adapter (immutable, no proxy).
        adapter = new VeHemiAragonAdapter(VEHEMI_PROXY);
        assertEq(
            adapter.supportsInterface(0x01ffc9a7),
            true,
            "phase1: adapter must advertise ERC-165"
        );
        // IVotes interface (canonical IVotes id) must also be advertised so
        // Aragon's ERC-165 probe accepts the adapter.
        assertEq(
            adapter.supportsInterface(type(IVotes).interfaceId),
            true,
            "phase1: adapter must advertise IVotes"
        );

        // Step 5: setTrustedAdapter (owner-only on VVD, gated by veHemi.owner()).
        // Access-control negative: a non-owner caller MUST be rejected by
        // the `NotVeHemiOwner` guard. Catches a regression that drops the
        // owner check entirely.
        address attackerAdapter = makeAddr("phase1-adapter-attacker");
        vm.prank(attackerAdapter);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        voteDelegation.setTrustedAdapter(address(adapter));

        // LOW-5 regression guard: setTrustedAdapter MUST reject an EOA (a
        // typo'd address with no code). The new InvalidAdapter revert path
        // is verified locally; re-pin against forked state so a future
        // VVD upgrade that drops the check fails this E2E loudly.
        address eoaTypo = makeAddr("phase1-eoa-typo");
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemiVoteDelegation.InvalidAdapter.selector);
        voteDelegation.setTrustedAdapter(eoaTypo);

        // Real contract must succeed.
        vm.prank(GNOSIS_SAFE);
        voteDelegation.setTrustedAdapter(address(adapter));
        assertEq(
            voteDelegation.trustedAdapter(),
            address(adapter),
            "phase1: trustedAdapter must be set to deployed adapter"
        );

        // V1 user-facing behavior is preserved: pre-existing positions still
        // queryable through V1 paths.
        assertEq(
            veHemi.totalLocked(),
            preTotalLocked,
            "phase1: totalLocked must survive Phase 1 entirely"
        );
        assertEq(
            hemiToken.balanceOf(address(veHemi)),
            preTotalLocked,
            "phase1: token conservation must survive Phase 1"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 2 — seeding window guards (mutators blocked, transferables ok)
    // ═════════════════════════════════════════════════════════════════════

    function _phase2_verifyWindowGuards() internal {
        // Adversary tries to mint a non-transferable position into the gap.
        address attacker = makeAddr("phase2-attacker");
        deal(HEMI_TOKEN, attacker, 100 ether);
        vm.startPrank(attacker);
        hemiToken.approve(address(veHemi), type(uint256).max);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(100 ether, MAX_TIME, attacker, false, false);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(100 ether, MAX_TIME, attacker, false, true);
        vm.stopPrank();

        // Transferable mint must STILL succeed during the window (not in subcurve).
        vm.startPrank(attacker);
        uint256 transferableId = veHemi.createLock(100 ether, MAX_TIME);
        vm.stopPrank();
        assertEq(
            veHemi.ownerOf(transferableId),
            attacker,
            "phase2: transferable mint must succeed in window"
        );

        // Non-transferable mutations must revert on a real mainnet position.
        // Pick the first eligible locked id we can find.
        uint256 sampleLockedId = _firstEligibleLockedId();
        if (sampleLockedId != 0) {
            address owner = veHemi.ownerOf(sampleLockedId);

            // increaseAmount blocked.
            deal(HEMI_TOKEN, owner, 100 ether);
            vm.startPrank(owner);
            hemiToken.approve(address(veHemi), type(uint256).max);
            vm.expectRevert(VeHemi.SeedingInProgress.selector);
            veHemi.increaseAmount(sampleLockedId, 50 ether);
            // increaseUnlockTime blocked.
            vm.expectRevert(VeHemi.SeedingInProgress.selector);
            veHemi.increaseUnlockTime(sampleLockedId, MAX_TIME);
            vm.stopPrank();
        }

        // increaseAmount on the freshly-minted TRANSFERABLE position must
        // still succeed mid-window.
        deal(HEMI_TOKEN, attacker, 50 ether);
        vm.startPrank(attacker);
        hemiToken.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(transferableId, 50 ether);
        vm.stopPrank();
        assertGt(
            uint256(int256(veHemi.getLockedBalance(transferableId).amount)),
            100 ether,
            "phase2: transferable increaseAmount must succeed"
        );

        // View functions during window: subcurve totals are 0 (latch false).
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "phase2: locked subcurve must read as 0 pre-finalize"
        );
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            0,
            "phase2: forfeitable subcurve must read as 0 pre-finalize"
        );

        // seedingCursor() readable as 0 (no batches yet).
        assertEq(
            veHemi.seedingCursor(),
            0,
            "phase2: seedingCursor must be 0 before any seedBatch"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 3 — permissionless multi-block seedBatch loop
    // ═════════════════════════════════════════════════════════════════════

    /// @dev Mirrors `scripts/run-seeding-loop.ts` exactly: rotates between
    ///      three non-owner keepers, reads progress via `seedingCursor()`,
    ///      issues `seedBatch(N)` in modest chunks, advances time + block
    ///      between iterations. Verifies the exact properties the runner
    ///      depends on: cursor monotonic, `finalizeSeeding` reverts while
    ///      incomplete, view returns match expectations.
    function _phase3_runSeedingLoopAsKeepers(uint256 expectedNonTransferableCount) internal {
        address keeper1 = makeAddr("phase3-keeper-1");
        address keeper2 = makeAddr("phase3-keeper-2");
        address keeper3 = makeAddr("phase3-keeper-3");

        uint256 target = veHemi.seedingTargetId();
        require(target > 1, "phase3: target must be > 1 to seed");
        uint256 expectedEnd = target - 1;

        // First batch: small chunk to verify cursor advances.
        uint256 cursorBefore = veHemi.seedingCursor();
        assertEq(cursorBefore, 0, "phase3: cursor should start at 0");

        // Drive seedBatch in rotating-keeper, multi-block chunks. Use a
        // chunk size that requires at least 2 batches for the mainnet
        // position count, so we genuinely exercise the cross-block path.
        // Mainnet has ~28k IDs; 10k/batch → 3 batches.
        uint256 chunkSize = 10_000;
        uint256 iterations;
        uint256 maxIterations = 100; // safety cap

        while (veHemi.seedingCursor() < expectedEnd && iterations < maxIterations) {
            _warpAndRoll(12);
            address caller = iterations % 3 == 0 ? keeper1
                : iterations % 3 == 1 ? keeper2
                : keeper3;
            uint256 cursorPre = veHemi.seedingCursor();

            vm.prank(caller);
            veHemi.seedBatch(chunkSize);

            uint256 cursorPost = veHemi.seedingCursor();
            assertGe(cursorPost, cursorPre, "phase3: cursor must be non-decreasing");
            assertLe(cursorPost, expectedEnd, "phase3: cursor must not exceed target-1");

            // Mid-loop finalize attempt must revert SeedingIncomplete.
            if (cursorPost < expectedEnd) {
                vm.prank(caller);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        VeHemi.SeedingIncomplete.selector,
                        cursorPost,
                        expectedEnd
                    )
                );
                veHemi.finalizeSeeding();
            }

            ++iterations;
        }

        assertEq(
            veHemi.seedingCursor(),
            expectedEnd,
            "phase3: cursor must reach target-1 within loop budget"
        );

        // Sanity: cursor was actually advanced over MULTIPLE iterations by
        // seedBatch — not preset to expectedEnd by a buggy seedingCursor()
        // view. With chunkSize = 10_000 against ~28K mainnet IDs, we expect
        // at least 2 batches (and seeing only 1 with non-zero work is
        // already a meaningful signal — but a cursor stuck at the start
        // would loop until maxIterations, which is caught above by the
        // `cursor == expectedEnd` assertion). Pin the multi-batch
        // expectation explicitly so a "cursor returns expectedEnd
        // constant" implementation (which would exit on iteration 1) is
        // distinguishable.
        assertGe(
            iterations,
            2,
            "phase3: cursor must require >=2 batches to reach target (catches stuck-cursor or constant-view bugs)"
        );

        // Same-block concurrent seedBatch: a second keeper calling in the
        // same block (no warp) after the cursor reached target must be a
        // structural no-op — cursor unchanged, no revert. Catches a
        // permissionless-double-decrement bug.
        vm.prank(keeper2);
        veHemi.seedBatch(1);
        assertEq(
            veHemi.seedingCursor(),
            expectedEnd,
            "phase3: same-block concurrent extra seedBatch must be no-op"
        );

        // Subsequent seedBatch with cursor at target is a structural no-op.
        vm.prank(keeper1);
        veHemi.seedBatch(1);
        assertEq(
            veHemi.seedingCursor(),
            expectedEnd,
            "phase3: extra seedBatch must be structural no-op"
        );

        // seedingCursor must equal expectedEnd; this proves the view exposed
        // by VeHemi (used by scripts/run-seeding-loop.ts) actually advances
        // and is decodable. Catches the runner-script half-migration bug
        // class (referencing an undefined slot constant) by ensuring any
        // observer using `seedingCursor()` reads the same value the contract
        // uses internally for the finalize gate.
        emit log_named_uint("phase3: non-transferable positions discovered", expectedNonTransferableCount);
        emit log_named_uint("phase3: batches required", iterations);
        emit log_named_uint("phase3: final cursor", veHemi.seedingCursor());
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 4 — permissionless finalizeSeeding
    // ═════════════════════════════════════════════════════════════════════

    function _phase4_finalizeSeeding(uint256[] memory lockedIds) internal {
        address finalizer = makeAddr("phase4-finalizer");

        // Pre-finalize state: latch is false, accumulator has non-empty cursor.
        assertFalse(veHemi.lockedSeedingFinalized(), "phase4: latch must be false pre-finalize");

        // Record logs to verify LockedSeedingFinalized event.
        vm.recordLogs();
        vm.prank(finalizer);
        veHemi.finalizeSeeding();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Latch flipped, accumulator cleared.
        assertTrue(veHemi.lockedSeedingFinalized(), "phase4: latch must flip");
        assertEq(
            veHemi.seedingCursor(),
            0,
            "phase4: seedingCursor must reset (accumulator deleted)"
        );

        // LockedSeedingFinalized event must fire with the new epoch.
        bool foundEvent;
        bytes32 sig = keccak256("LockedSeedingFinalized(uint256)");
        uint256 newEpoch = veHemi.epoch();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                uint256 emitted = abi.decode(logs[i].data, (uint256));
                assertEq(emitted, newEpoch, "phase4: LockedSeedingFinalized epoch mismatch");
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "phase4: LockedSeedingFinalized event must fire");

        // Subcurve supplies must now reflect the seeded set.
        uint256 lockedSupply = veHemi.nonTransferableTotalVeHemiSupply();
        if (lockedIds.length > 0) {
            assertGt(
                lockedSupply,
                0,
                "phase4: locked subcurve must be > 0 with seeded positions"
            );

            // Magnitude sanity: the seeded bias (a stake-weight) MUST be
            // bounded above by the sum of locked HEMI amounts (since bias =
            // amount × (subEnd-now)/MAX_TIME, with (subEnd-now) ≤ MAX_TIME).
            // We do NOT assert strict per-position equality here:
            // Phase 3's per-batch warps mean seedBatch processed each
            // position at a slightly different timestamp, while a closed-
            // form oracle would have to pin a single reference time. A
            // position whose `lock.end` happens to fall between Phase 3's
            // batch timestamp and Phase 4's finalize timestamp would be
            // included by seedBatch but excluded by an oracle keyed on
            // Phase 4 `block.timestamp` (vanishingly unlikely on real
            // mainnet given MIN_LOCK_DURATION = 12 days but possible).
            // Strict per-position equality is exhaustively pinned by
            // `test_multiBlock_chunkedSeedingMatchesSingleBlockOracle` in
            // SeedingFlow.t.sol; here we assert the looser-but-robust
            // bound that any correct seeded total must satisfy.
            uint256 upperBound;
            for (uint256 i; i < lockedIds.length; ++i) {
                int128 amt = veHemi.getLockedBalance(lockedIds[i]).amount;
                if (amt > 0) upperBound += uint128(amt);
            }
            assertLe(
                lockedSupply,
                upperBound,
                "phase4: seeded supply (stake-weight) must be <= sum of locked HEMI amounts"
            );
        }

        // Re-call must revert SeedingAlreadyFinalized.
        vm.prank(finalizer);
        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.finalizeSeeding();

        // seedBatch after finalize also reverts.
        vm.prank(finalizer);
        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.seedBatch(1);

        // supplyBreakdown's outputs must match the dedicated view functions
        // (different internal code paths — `supplyBreakdown` calls
        // `_subcurveSupplyAtFromPoint` while the dedicated views call
        // `_subcurveSupplyAt`). The two tautological identity assertions
        // (`total == locked + transferable` and `forfeitable <= locked`) are
        // intentionally OMITTED — `supplyBreakdown` computes
        // `transferable = total - locked_` after clamping `locked_ <= total`
        // and `forfeitable_ <= locked_`, so those assertions trivially hold
        // even against a buggy implementation. The cross-checks below
        // genuinely fail if the two computation paths diverge OR if the
        // clamping fires (which would itself indicate a bug).
        (uint256 total, uint256 locked, uint256 forfeitable, ) =
            veHemi.supplyBreakdown();
        assertEq(total, veHemi.totalVeHemiSupply(), "phase4: supplyBreakdown.total cross-check");
        assertEq(
            locked,
            veHemi.nonTransferableTotalVeHemiSupply(),
            "phase4: supplyBreakdown.locked cross-check (catches clamp firing)"
        );
        assertEq(
            forfeitable,
            veHemi.forfeitableTotalVeHemiSupply(),
            "phase4: supplyBreakdown.forfeitable cross-check (catches clamp firing)"
        );

        // Re-fetch transferable for logging (we discarded it above to avoid
        // the tautological identity assertion).
        (, , , uint256 transferable) = veHemi.supplyBreakdown();

        emit log_named_uint("phase4: post-finalize locked supply", locked);
        emit log_named_uint("phase4: post-finalize forfeitable supply", forfeitable);
        emit log_named_uint("phase4: post-finalize transferable supply", transferable);
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 5 — post-finalize behavior (V2 wakes up)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Mints, mutations, and forfeit on a freshly-minted position.
    ///         INTENTIONALLY no destructive time warps here — Phases 6 + 7
    ///         depend on realistic post-finalize supply state, which a
    ///         MAX_TIME warp would zero out. The withdraw path is deferred
    ///         to Phase 9 (after the realistic-state phases).
    function _phase5_postFinalizeOperations() internal {
        address userA = makeAddr("phase5-userA");
        address userB = makeAddr("phase5-userB");
        deal(HEMI_TOKEN, userA, 1_000 ether);
        deal(HEMI_TOKEN, userB, 1_000 ether);

        // Transferable mint: use 3 * SIX_DAYS (just above MIN_LOCK_DURATION)
        // so that Phase 7's SIX_DAYS warp leaves at least one SIX_DAYS bucket
        // of remaining lock time before Phase 9's final warp-to-expiry. Using
        // exactly MIN_LOCK_DURATION (2 * SIX_DAYS) leaves only ~0–1 bucket
        // depending on rounding alignment, which would be fragile under any
        // future change to Phase 7's warp duration.
        vm.startPrank(userA);
        hemiToken.approve(address(veHemi), type(uint256).max);
        uint256 tidTransferable = veHemi.createLock(100 ether, 3 * SIX_DAYS);
        vm.stopPrank();
        assertEq(veHemi.ownerOf(tidTransferable), userA, "phase5: transferable mint works");

        // Non-transferable + forfeitable mints via createLockFor.
        deal(HEMI_TOKEN, address(this), 200 ether);
        hemiToken.approve(address(veHemi), type(uint256).max);
        uint256 tidNonTransferable =
            veHemi.createLockFor(100 ether, MAX_TIME, userB, false, false);
        uint256 tidForfeitable =
            veHemi.createLockFor(100 ether, MAX_TIME, userB, false, true);
        assertEq(veHemi.ownerOf(tidNonTransferable), userB, "phase5: non-transferable mint works");
        assertEq(veHemi.ownerOf(tidForfeitable), userB, "phase5: forfeitable mint works");

        // increaseAmount on the freshly-minted non-transferable (unblocked
        // post-finalize). `increaseAmount` has no ownership check (INFO-7
        // from the audit) so the test contract calling it on userB's
        // position is intentional and pulls HEMI from the test contract.
        deal(HEMI_TOKEN, address(this), 100 ether);
        veHemi.increaseAmount(tidNonTransferable, 50 ether);
        assertGt(
            uint256(int256(veHemi.getLockedBalance(tidNonTransferable).amount)),
            100 ether,
            "phase5: increaseAmount on non-transferable works post-finalize"
        );

        // Subcurve supply must lift with the new non-transferable.
        assertGt(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "phase5: new non-transferable lifts locked subcurve"
        );

        // Forfeit the freshly-minted forfeitable. Requires
        // msg.sender == forfeitAdmin AND block.timestamp < transferableAfter.
        address forfeitAdmin = veHemi.forfeitAdmin();
        if (forfeitAdmin != address(0)) {
            uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
            vm.prank(forfeitAdmin);
            veHemi.forfeit(tidForfeitable);
            // After forfeit, position burned; forfeitable subcurve must drop.
            assertLt(
                veHemi.forfeitableTotalVeHemiSupply(),
                forfeitableBefore,
                "phase5: forfeit must drop forfeitable subcurve"
            );
            // ownerOf reverts on burned NFT (ERC721 standard).
            vm.expectRevert();
            veHemi.ownerOf(tidForfeitable);
        }

        // Stash the transferable token id for Phase 9.
        _phase5_transferableId = tidTransferable;
        _phase5_user = userA;
    }

    /// @dev Phase-9-only test scaffold (carry tidTransferable out of phase 5).
    uint256 private _phase5_transferableId;
    address private _phase5_user;

    /// @dev Phase-1 → Phase-8 cross-phase scaffold: the markSeedingStarted
    ///      timestamp captured at Phase 1, re-asserted via raw slot read
    ///      at Phase 8 to detect any finalizeSeeding regression that
    ///      clobbers the packed slot.
    uint64 private _phase1_seedingStartedAt;

    // ═════════════════════════════════════════════════════════════════════
    // Phase 6 — Aragon governance through the adapter
    // ═════════════════════════════════════════════════════════════════════

    function _phase6_aragonGovernance(VeHemiAragonAdapter adapter) internal {
        // Adapter view surface must reflect on-chain state.
        address sampleHolder = _findSampleHolder();
        if (sampleHolder == address(0)) return;

        uint256 adapterBalance = adapter.balanceOf(sampleHolder);
        // balanceOf is in raw locked HEMI (per adapter NatSpec); cross-check
        // against per-position sum.
        uint256 oracle;
        uint256 count = veHemi.balanceOf(sampleHolder);
        for (uint256 i; i < count; ++i) {
            uint256 tid = veHemi.tokenOfOwnerByIndex(sampleHolder, i);
            int128 amount = veHemi.getLockedBalance(tid).amount;
            if (amount > 0) oracle += uint128(amount);
        }
        assertEq(
            adapterBalance,
            oracle,
            "phase6: adapter.balanceOf must equal per-position locked-amount sum"
        );

        // Adapter totalSupply must equal the underlying total (stake weight).
        assertEq(
            adapter.totalSupply(),
            veHemi.totalVeHemiSupply(),
            "phase6: adapter.totalSupply must equal totalVeHemiSupply"
        );

        // getPastTotalSupply must match the underlying historical supply
        // (the adapter is a thin facade). `assertGe(pastTotal, 0)` would
        // be tautological for uint256 — use a real cross-check.
        uint256 historicalTs = block.timestamp - 1;
        assertEq(
            adapter.getPastTotalSupply(historicalTs),
            veHemi.totalVeHemiSupplyAt(historicalTs),
            "phase6: adapter.getPastTotalSupply must match VeHemi.totalVeHemiSupplyAt"
        );

        // Aragon-shaped delegate() through the adapter from a fresh user.
        address voter = makeAddr("phase6-voter");
        deal(HEMI_TOKEN, voter, 100 ether);
        vm.startPrank(voter);
        hemiToken.approve(address(veHemi), type(uint256).max);
        veHemi.createLock(100 ether, MAX_TIME);
        address delegatee = makeAddr("phase6-delegatee");

        // MED-7 event-relay assertion: adapter.delegate(addr) must emit
        // EXACTLY ONE account-wide DelegateChanged(voter, prev, delegatee)
        // for a single-position owner. Mixed-state suppression and per-
        // tokenId notify suppression are pinned by the local
        // VeHemiAragonAdapter.t.sol suite; here we anchor the happy-path
        // event surface against forked state.
        vm.recordLogs();
        adapter.delegate(delegatee);
        vm.stopPrank();

        Vm.Log[] memory delegateLogs = vm.getRecordedLogs();
        bytes32 dcSig = keccak256("DelegateChanged(address,address,address)");
        uint256 dcCount;
        for (uint256 i; i < delegateLogs.length; ++i) {
            if (delegateLogs[i].topics.length >= 4 && delegateLogs[i].topics[0] == dcSig) {
                // Verify only when emitted by the adapter (not by VVD via relay)
                if (delegateLogs[i].emitter == address(adapter)) {
                    address emittedDelegator = address(uint160(uint256(delegateLogs[i].topics[1])));
                    address emittedTo = address(uint160(uint256(delegateLogs[i].topics[3])));
                    if (emittedDelegator == voter) {
                        assertEq(emittedTo, delegatee, "phase6: DelegateChanged.toDelegate must equal delegatee");
                        ++dcCount;
                    }
                }
            }
        }
        assertEq(dcCount, 1, "phase6: adapter.delegate(addr) must emit exactly one DelegateChanged");

        // adapter.delegates(voter) should now resolve to delegatee.
        assertEq(
            adapter.delegates(voter),
            delegatee,
            "phase6: adapter.delegate must propagate to delegates() view"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 7 — decay across time
    // ═════════════════════════════════════════════════════════════════════

    function _phase7_decayAcrossTime() internal {
        uint256 lockedBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        // Warp forward by exactly one SIX_DAYS bucket to cross a slope-change
        // boundary.
        _warpAndRoll(SIX_DAYS);

        uint256 lockedAfter = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalAfter = veHemi.totalVeHemiSupply();

        // Both must monotonically non-increase across the warp (slope > 0).
        assertLe(lockedAfter, lockedBefore, "phase7: locked subcurve must not grow over time");
        assertLe(totalAfter, totalBefore, "phase7: total supply must not grow over time");

        // supplyAt at the previous timestamp must match the snapshot.
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupplyAt(block.timestamp - SIX_DAYS),
            lockedBefore,
            "phase7: historical locked supply must match snapshot at prior bucket"
        );

        emit log_named_uint("phase7: locked supply before warp", lockedBefore);
        emit log_named_uint("phase7: locked supply after one SIX_DAYS warp", lockedAfter);
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 8 — final storage-slot sanity
    // ═════════════════════════════════════════════════════════════════════

    function _phase8_finalStorageProbes() internal {
        // After finalize:
        //   slot 18 (lockedSeedingFinalized): true (bool = 0x01 in low byte)
        //   slot 21 (seedingStarted + seedingStartedAt): bool true at offset 0,
        //                                                uint64 ts at offset 1
        //   slot 22 (seedingTargetId):       == nextTokenId snapshot
        //   slot 23 (_seedingProgress.lastProcessedId): 0 (cleared)
        bytes32 latch = vm.load(address(veHemi), bytes32(SLOT_LOCKED_SEEDING_FINALIZED));
        assertEq(uint256(latch) & 0xFF, 1, "phase8: latch slot must be 0x01");

        bytes32 startedPacked = vm.load(address(veHemi), bytes32(SLOT_SEEDING_STARTED));
        assertEq(uint256(startedPacked) & 0xFF, 1, "phase8: seedingStarted packed bool must be 0x01");
        // seedingStartedAt is packed at byte offset 1 of slot 21 (after the
        // bool at offset 0). Decode and assert it matches the Phase 1 capture
        // — guards against any finalizeSeeding regression that overwrites the
        // packed slot.
        uint64 startedAtFromSlot = uint64(uint256(startedPacked) >> 8);
        assertEq(
            startedAtFromSlot,
            _phase1_seedingStartedAt,
            "phase8: packed seedingStartedAt must survive finalize"
        );
        assertEq(
            veHemi.seedingStartedAt(),
            _phase1_seedingStartedAt,
            "phase8: seedingStartedAt view must match Phase 1 capture"
        );

        bytes32 cursor = vm.load(address(veHemi), bytes32(SLOT_SEEDING_PROGRESS_BASE));
        assertEq(uint256(cursor), 0, "phase8: seedingCursor slot must be cleared post-finalize");

        // Cross-check: view + raw slot agree.
        assertEq(
            veHemi.seedingCursor(),
            0,
            "phase8: seedingCursor view must match raw slot read"
        );
        assertTrue(
            veHemi.lockedSeedingFinalized(),
            "phase8: lockedSeedingFinalized view must match raw slot read"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // Phase 9 — destructive withdraw test (last; warps past position expiry)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Warp past the Phase 5 transferable position's `lock.end` and
    ///         exercise the withdraw → burn path. Bounded to MIN_LOCK_DURATION
    ///         (~12 days) by Phase 5's `createLock` duration choice; the
    ///         smaller warp keeps the broader test state recoverable in
    ///         case any future phase wants to extend further.
    function _phase9_withdrawDestructive() internal {
        uint256 tid = _phase5_transferableId;
        address user = _phase5_user;
        require(tid != 0, "phase9: missing phase5 token id");

        IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(tid);
        require(uint256(bal.end) > block.timestamp, "phase9: token already expired");
        _warpAndRoll(uint256(bal.end) - block.timestamp + 1);

        // Pre-withdraw HEMI balance.
        uint256 preHemi = hemiToken.balanceOf(user);

        vm.prank(user);
        veHemi.withdraw(tid);

        // NFT burned.
        vm.expectRevert();
        veHemi.ownerOf(tid);

        // HEMI returned to the user (full lock amount, since the position
        // was held to expiry — no forfeit).
        uint256 postHemi = hemiToken.balanceOf(user);
        assertEq(
            postHemi - preHemi,
            uint256(int256(bal.amount)),
            "phase9: withdraw must return full locked HEMI to user"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════

    function _safeUpgradeVoteDelegation() internal {
        VeHemiVoteDelegation newImpl = new VeHemiVoteDelegation(VEHEMI_PROXY);
        vm.prank(GNOSIS_SAFE);
        (bool ok,) = PROXY_ADMIN.call(
            abi.encodeWithSignature(
                "upgrade(address,address)", VOTE_DELEGATION_PROXY, address(newImpl)
            )
        );
        require(ok, "VVD upgrade failed");
    }

    function _safeUpgradeVeHemi() internal {
        VeHemi newImpl = new VeHemi(HEMI_TOKEN);
        vm.prank(GNOSIS_SAFE);
        (bool ok,) = PROXY_ADMIN.call(
            abi.encodeWithSignature("upgrade(address,address)", VEHEMI_PROXY, address(newImpl))
        );
        require(ok, "VeHemi upgrade failed");
    }

    function _warpAndRoll(uint256 secondsForward) internal {
        vm.warp(block.timestamp + secondsForward);
        vm.roll(block.number + secondsForward / 2);
    }

    function _findNonTransferablePositions() internal view returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = LOCKED_RANGE_START; i < LOCKED_RANGE_END; ++i) {
            try veHemi.ownerOf(i) returns (address) {
                if (veHemi.transferableAfter(i) != 0) {
                    IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(i);
                    if (bal.amount > 0 && uint256(bal.end) > block.timestamp) {
                        count++;
                    }
                }
            } catch {
                continue;
            }
        }
        uint256[] memory ids = new uint256[](count);
        uint256 idx;
        for (uint256 i = LOCKED_RANGE_START; i < LOCKED_RANGE_END; ++i) {
            try veHemi.ownerOf(i) returns (address) {
                if (veHemi.transferableAfter(i) != 0) {
                    IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(i);
                    if (bal.amount > 0 && uint256(bal.end) > block.timestamp) {
                        ids[idx++] = i;
                    }
                }
            } catch {
                continue;
            }
        }
        return ids;
    }

    function _firstEligibleLockedId() internal view returns (uint256) {
        for (uint256 i = LOCKED_RANGE_START; i < LOCKED_RANGE_END; ++i) {
            try veHemi.ownerOf(i) returns (address) {
                if (veHemi.transferableAfter(i) != 0) {
                    IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(i);
                    if (bal.amount > 0 && uint256(bal.end) > block.timestamp) {
                        return i;
                    }
                }
            } catch {
                continue;
            }
        }
        return 0;
    }

    function _findSampleHolder() internal view returns (address) {
        for (uint256 i = LOCKED_RANGE_START; i < LOCKED_RANGE_END; ++i) {
            try veHemi.ownerOf(i) returns (address owner) {
                if (owner != address(0)) return owner;
            } catch {
                continue;
            }
        }
        return address(0);
    }
}

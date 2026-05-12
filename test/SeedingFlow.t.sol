// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title SeedingFlow
/// @notice Behavioral coverage for the 3-phase seeding flow:
///         `markSeedingStarted` → `seedBatch(maxIterations)` (one or many)
///         → `finalizeSeeding`. The flow replaces a single-shot
///         caller-supplied-list seeder with an on-chain enumeration that
///         eliminates two failure modes:
///
///           1. Operator drift between off-chain list derivation and Safe
///              execution (omitted positions permanently understate the
///              locked subcurve).
///           2. Adversarial front-run via a permissionless non-transferable
///              mint inserted into the gap between list snapshot and Safe
///              execution.
///
///         Each test pins one observable property of the flow so a future
///         refactor that re-introduces the original bug class fails loudly.
contract SeedingFlowTest is Test {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    MockERC20 internal hemi;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant MONTH = YEAR / 12;
    uint256 internal constant SIX_DAYS = MONTH / 5;
    uint256 internal constant MAX_TIME = 4 * YEAR;
    uint256 internal constant LOCK_2Y = 2 * YEAR;
    uint256 internal constant LOCK_3Y = 3 * YEAR;
    uint256 internal constant LOCK_SHORT = 2 * SIX_DAYS;
    uint256 internal constant LOCK_AMOUNT = 100 ether;
    uint256 internal constant TOPUP_AMOUNT = 50 ether;

    /// @dev Slot constants for direct storage probes of `_seedingProgress`.
    ///      `_seedingProgress` lives at slot 23 (struct base = first member
    ///      `lastProcessedId`); the `count` field lives at slot 26 (the 4th
    ///      and final struct slot). These are pinned by
    ///      `test_VeHemi_SeedingProgressMemberLayout` in `StorageLayoutGolden.t.sol`
    ///      AND by `test_slot23to26_seedingProgressLayout` in
    ///      `VeHemiStorageLayout.t.sol`. If a future V3 reshuffle moves the
    ///      struct, update both pins AND this constant.
    uint256 internal constant SLOT_SEEDING_PROGRESS_BASE = 23;
    uint256 internal constant SLOT_SEEDING_PROGRESS_COUNT = 26;

    event SeedingStarted(uint256 seedingTargetId);
    event LockedSeedingFinalized(uint256 epoch);

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, owner)
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);

        hemi.mint(alice, 10_000 ether);
        hemi.mint(bob, 10_000 ether);
        hemi.mint(carol, 10_000 ether);
        hemi.mint(attacker, 10_000 ether);
        // The owner (test contract) calls `createLockFor` directly in
        // helpers; createLockFor pulls HEMI from msg.sender, so fund + approve.
        hemi.mint(owner, 1_000_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);

        vm.prank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(bob);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(carol);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(attacker);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────
    // markSeedingStarted: preconditions and state snapshot
    // ─────────────────────────────────────────────────────────────────────

    function test_markSeedingStarted_snapshotsTargetIdAndSetsFlag() public {
        // Mint a few positions so nextTokenId moves forward.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        uint256 nextBeforeMark = veHemi.nextTokenId();
        assertEq(nextBeforeMark, 3, "two mints => nextTokenId == 3");

        vm.expectEmit(true, true, true, true, address(veHemi));
        emit SeedingStarted(nextBeforeMark);
        veHemi.markSeedingStarted();

        assertTrue(veHemi.seedingStarted(), "flag must be set");
        assertEq(veHemi.seedingTargetId(), nextBeforeMark, "target frozen at pre-mark nextTokenId");
    }

    function test_markSeedingStarted_revertsOnDoubleCall() public {
        veHemi.markSeedingStarted();
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        veHemi.markSeedingStarted();
    }

    function test_markSeedingStarted_revertsAfterFinalization() public {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // `seedingStarted` is set on markSeedingStarted and never cleared, so
        // re-calling after finalization reverts with SeedingAlreadyStarted
        // (the dead `lockedSeedingFinalized` check was removed for bytecode).
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        veHemi.markSeedingStarted();
    }

    function test_markSeedingStarted_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        veHemi.markSeedingStarted();
    }

    /// @notice DRIFT-VECTOR REGRESSION: if `finalizeSeeding` runs at a later
    ///         block timestamp than `seedBatch` (i.e., the operator splits the
    ///         flow across multiple blocks), positions whose `subEnd` falls in
    ///         the gap window would write a slope-change entry that the
    ///         post-finalize catchup walk never visits — the walk starts at
    ///         the LockedPoint timestamp and only advances FORWARD.
    ///         The fix enforces atomicity: every step (markSeedingStarted,
    ///         every seedBatch, finalizeSeeding) must run at the same
    ///         block.timestamp. Cross-block execution reverts.
    function test_seedingFlow_revertsIfFinalizeAcrossBlockBoundary() public {
        // Mint a short-lived non-transferable so subEnd is close.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Warp forward — even one second past the mark timestamp.
        vm.warp(block.timestamp + 1);

        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.finalizeSeeding();
    }

    /// @notice DRIFT-VECTOR REGRESSION (companion to
    ///         `test_seedingFlow_revertsIfFinalizeAcrossBlockBoundary`
    ///         above): the atomicity guard MUST fire from `seedBatch` as
    ///         well as from `finalizeSeeding`. If only one of the two
    ///         entry points enforces same-block execution, an operator
    ///         splitting the flow could still write slope-changes at past
    ///         subEnds — exactly the dead-storage bug the guard was
    ///         introduced to prevent. Pins both call sites.
    function test_seedingFlow_revertsIfSeedBatchAcrossBlockBoundary() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);

        veHemi.markSeedingStarted();
        vm.warp(block.timestamp + 1);

        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.seedBatch(type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────
    // seedBatch: range, skip semantics, cursor advance
    // ─────────────────────────────────────────────────────────────────────

    function test_seedBatch_revertsIfNotStarted() public {
        vm.expectRevert(VeHemi.SeedingNotStarted.selector);
        veHemi.seedBatch(10);
    }

    function test_seedBatch_revertsAfterFinalization() public {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.seedBatch(10);
    }

    function test_seedBatch_revertsForNonOwner() public {
        veHemi.markSeedingStarted();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        veHemi.seedBatch(10);
    }

    /// @notice ORDERING REGRESSION: a non-owner call BEFORE `markSeedingStarted`
    ///         must revert with the OZ owner error, NOT with `SeedingNotStarted`.
    ///         Pins that the `onlyOwner` modifier check fires before
    ///         `_requireSeedingActive` is reached. A regression that reordered
    ///         the checks (e.g., placed `onlyOwner` after the body) would still
    ///         revert with `SeedingNotStarted` and pass `test_seedBatch_revertsForNonOwner`
    ///         silently — this test forecloses that drift.
    function test_seedBatch_revertsForNonOwner_beforeStart() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        veHemi.seedBatch(10);
    }

    function test_seedBatch_advancesCursorMonotonically() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y); // tokenId 1
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y); // tokenId 2
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // tokenId 3

        veHemi.markSeedingStarted();
        // First batch: covers IDs [1, 2)
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 1, "after 1 step: cursor == 1");

        // Second batch: covers IDs [2, 3)
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 2, "after 2 steps: cursor == 2");

        // Third batch: covers IDs [3, 4) (4 == seedingTargetId)
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 3, "after 3 steps: cursor == 3");

        // Extra batch is a no-op (cursor already at the end).
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 3, "extra batch is structural no-op");
    }

    function test_seedBatch_clampsToSeedingTargetId() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted(); // target == 3

        // Request a batch much larger than the remaining range. The cursor
        // should clamp at seedingTargetId - 1 = 2 without overflowing.
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressLastProcessedId(), 2, "cursor clamps to target - 1");
    }

    function test_seedBatch_skipsBurnedTokens() public {
        // Mint a short-lived position, burn it via withdraw, then mint two more.
        (uint256 burned,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        vm.warp(veHemi.getLockedBalance(burned).end + 1);
        vm.prank(alice);
        veHemi.withdraw(burned);
        (, uint256 e1) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // Only bob and carol contribute; alice's burned position is skipped.
        uint256 expected;
        unchecked {
            expected = (LOCK_AMOUNT / MAX_TIME) * (e1 - block.timestamp)
                + (LOCK_AMOUNT / MAX_TIME) * (e2 - block.timestamp);
        }
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expected, "burned ID must be skipped");
    }

    function test_seedBatch_skipsTransferablePositions() public {
        // Transferable positions (transferableAfter == 0) are NOT part of
        // the locked subcurve and must be silently skipped by the scan.
        _mintTransferable(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 expected = (LOCK_AMOUNT / MAX_TIME) * (e2 - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(), expected, "transferable position must be skipped"
        );
    }

    function test_seedBatch_skipsPositionsWithExpiredTransferableAfter() public {
        // A non-transferable position whose transferableAfter has elapsed is
        // no longer a member of the locked subcurve. The scan must skip it.
        (uint256 shortId, uint256 shortEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        // Warp past shortId's transferability window but before shortEnd lock end.
        // Actually for non-transferable mints, transferableAfter == unlockTime,
        // so we must warp past unlockTime. The position is then fully expired.
        vm.warp(shortEnd + 1);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 expected = (LOCK_AMOUNT / MAX_TIME) * (e2 - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "expired transferableAfter must skip from subcurve"
        );
    }

    function test_seedBatch_accumulatesAcrossMultipleCalls() public {
        // Mint 5 positions, scan in 2-id chunks, verify final aggregate
        // matches a single-shot scan.
        uint256[5] memory amts;
        for (uint256 i; i < 5; ++i) {
            (, uint256 endI) = _mintLocked(_user(i), LOCK_AMOUNT, LOCK_2Y);
            amts[i] = endI - block.timestamp;
        }

        veHemi.markSeedingStarted();
        veHemi.seedBatch(2); // ids 1-2
        veHemi.seedBatch(2); // ids 3-4
        veHemi.seedBatch(2); // id 5 (clamps)
        veHemi.finalizeSeeding();

        uint256 expected;
        for (uint256 i; i < 5; ++i) {
            expected += (LOCK_AMOUNT / MAX_TIME) * amts[i];
        }
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "multi-batch aggregate must equal sum of contributions"
        );
    }

    function test_seedBatch_writesSlopeChangesAtSubEnd() public {
        (, uint256 e1) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, MAX_TIME);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        int128 slope = int128(int256(LOCK_AMOUNT / MAX_TIME));
        // Slope changes at e1 should be -slope1 (alice).
        assertEq(veHemi.lockedSlopeChanges(e1), -slope, "slope change at alice's end");
        // Slope changes at e2 should be -slope2 (bob).
        if (e1 != e2) {
            assertEq(veHemi.lockedSlopeChanges(e2), -slope, "slope change at bob's end");
        }
    }

    /// @notice Two non-transferable positions with the SAME subEnd must
    ///         accumulate slope-changes in the same bucket (-slope1 - slope2),
    ///         not overwrite. SIX_DAYS-rounded lock.end with identical
    ///         (block.timestamp, duration) collapses to one slot.
    function test_seedBatch_accumulatesSharedSubEndSlot() public {
        (, uint256 e1) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        assertEq(e1, e2, "shared-subEnd precondition: SIX_DAYS bucketing");

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        int128 slope = int128(int256(LOCK_AMOUNT / MAX_TIME));
        // Two positions, same subEnd → bucket holds -2*slope (accumulation).
        assertEq(
            veHemi.lockedSlopeChanges(e1),
            -slope * 2,
            "shared-subEnd slot must accumulate both deltas"
        );
    }

    function test_seedBatch_idempotentOnRepeatedCallsAfterCursorReached() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Pin the absolute cursor value: with one position minted before
        // `markSeedingStarted`, `seedingTargetId == nextTokenId == 2` and
        // the cursor advances to `seedingTargetId - 1 == 1`. `assertEq` to
        // the captured value alone would miss a regression that ALSO moved
        // the captured value (e.g., off-by-one in the cursor advance).
        uint256 cursorAfterFirst = _progressLastProcessedId();
        assertEq(cursorAfterFirst, 1, "cursor after first batch must equal seedingTargetId - 1 = 1");

        veHemi.seedBatch(100);
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), cursorAfterFirst, "extra batches don't move cursor");
        assertEq(_progressLastProcessedId(), 1, "cursor remains at seedingTargetId - 1 after no-ops");
    }

    // ─────────────────────────────────────────────────────────────────────
    // seedBatch: boundary / edge cases
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Calling `seedBatch(0)` with positions present must be a
    ///         pure no-op: cursor unchanged, count unchanged, no state
    ///         mutation. A regression that wrote `progress.lastProcessedId
    ///         = endIdExclusive - 1 = -1 (underflow)` or otherwise treated
    ///         `maxIterations=0` as "process one" would fail this pin.
    function test_seedBatch_zeroMaxIterationsIsNoOp() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        uint256 cursorBefore = _progressLastProcessedId();
        uint256 countBefore = _progressCount();
        assertEq(cursorBefore, 0, "pre-call cursor is 0");
        assertEq(countBefore, 0, "pre-call count is 0");

        veHemi.seedBatch(0);

        assertEq(_progressLastProcessedId(), 0, "zero-maxIter must not advance cursor");
        assertEq(_progressCount(), 0, "zero-maxIter must not increment count");

        // Subsequent normal batches still work — the no-op did not poison state.
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressLastProcessedId(), 1, "follow-up batch advances cursor normally");
        assertEq(_progressCount(), 1, "follow-up batch counts the one eligible position");
    }

    /// @notice Boundary: a non-transferable position whose lock end is EXACTLY
    ///         `block.timestamp` at seeding time must be SKIPPED (treat as
    ///         expired). The skip predicate is `_lock.end <= block.timestamp`,
    ///         so the boundary is excluded by design — pin it so a future
    ///         refactor to strict `<` doesn't silently include zero-bias
    ///         entries.
    function test_seedBatch_positionWithLockEndAtSeedingStartedAtIsSkipped() public {
        // Mint a position whose lock end falls EXACTLY at the current block.
        // `createLockFor` rounds the unlock time DOWN to SIX_DAYS, so we
        // pick a duration whose rounded-down end is `block.timestamp`. The
        // simplest way: warp to the lock's original end before seeding so
        // `lock.end == block.timestamp`.
        (uint256 tokenId, uint256 lockEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        vm.warp(lockEnd); // now `block.timestamp == lock.end`

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // The position was iterated but the skip predicate
        // `_lock.end <= block.timestamp` excluded it.
        assertEq(_progressCount(), 0, "lock.end == block.timestamp must be skipped (zero count)");
        // Cursor still advances past the ID range (seedingTargetId = nextTokenId = 2 → cursor = 1).
        assertEq(_progressLastProcessedId(), 1, "cursor still advances past skipped positions");
        // Suppress unused-variable warning.
        tokenId;
    }

    /// @notice Boundary: a non-transferable position with `_lock.end ==
    ///         seedingStartedAt + 1` (the smallest possible non-expired)
    ///         MUST be processed and contribute exactly `slope * 1`
    ///         to the bias at finalize time. Catches a regression where the
    ///         skip predicate becomes `<` instead of `<=` (would include
    ///         the boundary case incorrectly) or a one-off in the bias arithmetic.
    function test_seedBatch_positionWithLockEndOneSecondAheadIsProcessed() public {
        // Mint with a long-enough duration to clear the SIX_DAYS rounding,
        // then warp so `lock.end == block.timestamp + 1` at seeding time.
        (uint256 tokenId, uint256 lockEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        vm.warp(lockEnd - 1); // now `lock.end == block.timestamp + 1`

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // The position contributes `slope * (subEnd - now) = slope * 1` to
        // the locked subcurve's bias.
        uint256 slope = uint256(uint128(LOCK_AMOUNT)) / MAX_TIME;
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            slope * 1,
            "one-second-ahead position must contribute exactly slope*1"
        );
        tokenId;
    }

    /// @notice POSITIVE PIN against the slope-truncation boundary: the
    ///         minimum-lock-amount gate keeps user-mintable positions
    ///         above the `slope = amount / MAX_TIME == 0` zone. This test
    ///         enforces TWO complementary properties so a future relaxation
    ///         of the floor cannot silently introduce zero-slope positions
    ///         into the seeded subcurve:
    ///
    ///           (a) `createLockFor` reverts with `AmountTooSmall` when
    ///               `amount < MIN_LOCK_AMOUNT`. There is NO owner bypass —
    ///               the floor applies to every caller, including the test
    ///               contract.
    ///           (b) `MIN_LOCK_AMOUNT > MAX_TIME`. Integer division
    ///               `MIN_LOCK_AMOUNT / MAX_TIME` is therefore `>= 1`, so
    ///               every user-mintable position has a strictly positive
    ///               slope. Specifically: `10e18 / (4 * 365.25 days) ≈ 7.93e10`.
    ///
    ///         If either property regresses (e.g., MIN_LOCK_AMOUNT lowered
    ///         below MAX_TIME, or the `AmountTooSmall` revert is removed),
    ///         this test fires loudly. Catches the exact regression that the
    ///         prior `vm.skip(true)` documented but did not enforce.
    function test_seedBatch_minLockAmountGateForcesNonZeroSlope() public {
        // (a) The floor applies to every caller — including the test contract
        // (which is the owner). There is no owner bypass. Calling with
        // amount=1 must revert with AmountTooSmall.
        vm.expectRevert(VeHemi.AmountTooSmall.selector);
        veHemi.createLockFor(1, LOCK_2Y, alice, false, false);

        // (b) The constants enforce that any acceptable user mint produces a
        // strictly positive slope via integer truncation. `MIN_LOCK_AMOUNT`
        // is internal so we can't read it directly, but we can observe its
        // effect: the boundary value `MAX_TIME` itself must already revert
        // (any non-reverting value would mean slope >= 1, by integer division
        // semantics).
        vm.expectRevert(VeHemi.AmountTooSmall.selector);
        veHemi.createLockFor(MAX_TIME, LOCK_2Y, alice, false, false);

        // Sanity-check the corollary: an amount equal to MIN_LOCK_AMOUNT
        // (= 10 ether per the contract constant) produces a positive slope
        // by construction. Mint via the helper and verify the subcurve
        // contribution is non-zero after seeding.
        (uint256 tokenId, uint256 lockEnd) = _mintLocked(alice, 10 ether, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        assertGt(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "MIN_LOCK_AMOUNT position must yield positive subcurve supply"
        );
        // Quench unused-var lints; both are observable downstream.
        tokenId;
        lockEnd;
    }

    /// @notice ID gap regression: cursor must advance past a BURNED middle
    ///         token (slot 2 between live slots 1 and 3). The existing
    ///         `test_seedBatch_skipsBurnedTokens` burns the FIRST id; this
    ///         test pins the harder middle-burn case.
    function test_seedBatch_idGapFromBurnedTokenInMiddle() public {
        (uint256 t1,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);          // id 1
        (uint256 t2, uint256 t2End) = _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);  // id 2
        (uint256 t3,) = _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);          // id 3

        // Burn id 2 by warping past its expiry and withdrawing.
        vm.warp(t2End + 1);
        vm.prank(bob);
        veHemi.withdraw(t2);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Cursor advances to seedingTargetId - 1 == 3 (the last ID, regardless
        // of which IDs were burned). Count is 2 — alice's and carol's
        // positions remain; bob's was burned.
        assertEq(_progressLastProcessedId(), 3, "cursor advances past burned-middle ID");
        assertEq(_progressCount(), 2, "burned middle ID excluded; count == 2");
        // Defense against later use:
        t1; t3;
    }

    /// @notice Cursor monotonicity under arbitrary batch sizes (chunked
    ///         seedBatch). Verifies the cursor strictly increases (or
    ///         stays equal) across a sequence of small / large /
    ///         oversize-clamped calls. A regression that reset the cursor
    ///         mid-flow would silently re-process IDs, double-counting
    ///         their contributions to the accumulator.
    function test_seedBatch_cursorMonotonicAcrossArbitraryBatchSizes() public {
        // Mint 5 non-transferable positions.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(_user(0), LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(_user(1), LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();

        // Sequence: 0, 1, 1, 3, 10, 100, type(uint256).max — pathological mix.
        uint256[] memory sizes = new uint256[](7);
        sizes[0] = 0;
        sizes[1] = 1;
        sizes[2] = 1;
        sizes[3] = 3;
        sizes[4] = 10;
        sizes[5] = 100;
        sizes[6] = type(uint256).max;

        uint256 prevCursor;
        for (uint256 i; i < sizes.length; ++i) {
            veHemi.seedBatch(sizes[i]);
            uint256 currCursor = _progressLastProcessedId();
            assertGe(
                currCursor,
                prevCursor,
                string.concat("cursor regressed at batch ", vm.toString(i))
            );
            prevCursor = currCursor;
        }

        // Final cursor reaches seedingTargetId - 1 = 5.
        assertEq(prevCursor, 5, "final cursor reaches seedingTargetId - 1");
    }

    // ─────────────────────────────────────────────────────────────────────
    // finalizeSeeding: completeness check, math correctness
    // ─────────────────────────────────────────────────────────────────────

    function test_finalizeSeeding_revertsIfNotStarted() public {
        vm.expectRevert(VeHemi.SeedingNotStarted.selector);
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_revertsIfIncomplete() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // tokenIds 1, 2, 3 — target == 4

        veHemi.markSeedingStarted();
        veHemi.seedBatch(2); // cursor at 2; target - 1 == 3 — incomplete

        // Expected payload: SeedingIncomplete(lastProcessedId=2, expectedEnd=3)
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 2, 3));
        veHemi.finalizeSeeding();
    }

    /// @notice Parametric error payload coverage at the LOWER boundary:
    ///         `markSeedingStarted` ran after mints exist, but NO
    ///         `seedBatch` call advanced the cursor at all. `lastProcessedId`
    ///         must be `0`, `expectedEnd` must be `seedingTargetId - 1`.
    ///         The companion test above only pins the `(2, 3)` payload;
    ///         this test pins `(0, n-1)` for `n > 1`.
    function test_finalizeSeeding_revertsIfIncomplete_atZeroCursor() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // 3 mints; nextTokenId = 4

        veHemi.markSeedingStarted();
        // No seedBatch call. Cursor remains at 0.

        // Expected payload: SeedingIncomplete(lastProcessedId=0, expectedEnd=3)
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 0, 3));
        veHemi.finalizeSeeding();
    }

    /// @notice Parametric error payload coverage at the NEAR-TAIL boundary:
    ///         all but the last position has been seeded. Pins
    ///         `(seedingTargetId - 2, seedingTargetId - 1)`. Catches a
    ///         regression that off-by-ones the cursor at the final position.
    function test_finalizeSeeding_revertsIfIncomplete_offByOneAtTail() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(_user(0), LOCK_AMOUNT, LOCK_2Y); // 4 mints; target = 5

        veHemi.markSeedingStarted();
        veHemi.seedBatch(3); // cursor advances to 3; target - 1 == 4

        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 3, 4));
        veHemi.finalizeSeeding();
    }

    /// @notice PRECEDENCE REGRESSION: when MULTIPLE error conditions hold
    ///         simultaneously, `_requireSeedingActive` checks
    ///         `lockedSeedingFinalized` → `seedingStarted` → block.timestamp
    ///         IN THAT ORDER, then `finalizeSeeding` checks the cursor.
    ///         So if the seeding window is open AND the cursor is incomplete
    ///         AND we're cross-block, `SeedingInProgress` (the atomicity
    ///         guard) MUST fire before `SeedingIncomplete`. Pins this order
    ///         so a refactor that reorders the checks (e.g., placing the
    ///         cursor check before the timestamp check) is caught.
    function test_finalizeSeeding_atomicityErrorWinsOverIncomplete() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y); // 2 mints; target == 3

        veHemi.markSeedingStarted(); // Cursor stays at 0 — incomplete.

        vm.warp(block.timestamp + 1); // Cross-block — atomicity fails.

        // Atomicity error has priority — must fire even though cursor is
        // also incomplete.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_revertsAfterFinalization() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_revertsForNonOwner() public {
        veHemi.markSeedingStarted();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        veHemi.finalizeSeeding();
    }

    /// @notice ORDERING REGRESSION (companion to
    ///         `test_seedBatch_revertsForNonOwner_beforeStart`): pin that
    ///         `onlyOwner` precedes `_requireSeedingActive` in `finalizeSeeding`.
    function test_finalizeSeeding_revertsForNonOwner_beforeStart() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_flipsLatchAndEmitsEvent() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        assertFalse(veHemi.lockedSeedingFinalized(), "latch is false pre-finalize");
        veHemi.checkpoint();
        uint256 expectedEpoch = veHemi.epoch();

        vm.expectEmit();
        emit LockedSeedingFinalized(expectedEpoch);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "latch must flip");
    }

    function test_finalizeSeeding_clearsAccumulator() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Pre-finalize, accumulator reflects exactly one seeded position.
        assertEq(_progressCount(), 1, "accumulator count == 1 (one position seeded)");

        veHemi.finalizeSeeding();

        // Post-finalize, accumulator is `delete`d.
        assertEq(_progressLastProcessedId(), 0, "lastProcessedId cleared");
        assertEq(_progressCount(), 0, "count cleared");
    }

    function test_finalizeSeeding_handlesEmptyScanCleanly() public {
        // Edge case: markSeedingStarted with nextTokenId == 1 (no mints).
        // The flow must complete with zero contributions.
        assertEq(veHemi.nextTokenId(), 1, "fresh proxy has nextTokenId == 1");

        veHemi.markSeedingStarted();
        assertEq(veHemi.seedingTargetId(), 1, "target frozen at 1");
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "latch flips even with empty scan");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "empty scan => zero supply");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "empty scan => zero forfeitable supply");
    }

    function test_finalizeSeeding_writesLockedAndForfeitablePoints() public {
        // Mix of locked-only and forfeitable positions; verify both
        // subcurves end up with the correct totals.
        (, uint256 e1) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintForfeitable(bob, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        // Locked subcurve includes BOTH locked-only AND forfeitable positions.
        uint256 expectedLocked = slope * (e1 - block.timestamp) + slope * (e2 - block.timestamp);
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expectedLocked, "locked supply == sum");

        // Forfeitable subcurve includes only the forfeitable position.
        uint256 expectedForfeitable = slope * (e2 - block.timestamp);
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "forfeitable supply == bob only"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mint guard: non-transferable mints blocked during active seeding
    // ─────────────────────────────────────────────────────────────────────

    function test_mintGuard_blocksNonTransferableDuringSeeding() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        // Adversarial mint: try to insert a new non-transferable position
        // into the live nextTokenId slot. Must revert.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);

        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, true); // forfeitable variant

        vm.prank(attacker);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);
    }

    function test_mintGuard_allowsTransferableDuringSeeding() public {
        veHemi.markSeedingStarted();
        // Transferable mints do NOT affect the locked subcurve being seeded;
        // they must not be blocked.
        vm.prank(attacker);
        uint256 tokenId = veHemi.createLock(LOCK_AMOUNT, LOCK_2Y);
        assertEq(veHemi.ownerOf(tokenId), attacker, "transferable mint must succeed");
    }

    function test_mintGuard_releasesAfterFinalization() public {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // Post-finalize, non-transferable mints are unblocked again.
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);
        assertEq(veHemi.balanceOf(attacker), 1, "non-transferable mint allowed post-finalize");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mutation guards: increaseAmount / increaseUnlockTime / forfeit
    // also blocked on non-transferable positions during seeding to prevent
    // mid-flow accumulator drift.
    // ─────────────────────────────────────────────────────────────────────

    function test_mutationGuard_increaseAmountBlockedOnNonTransferableDuringSeeding() public {
        (uint256 tokenId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        // alice tries to top up her non-transferable position mid-seed.
        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.increaseAmount(tokenId, TOPUP_AMOUNT);
        vm.stopPrank();
    }

    function test_mutationGuard_increaseAmountAllowedOnTransferableDuringSeeding() public {
        // Transferable positions are NOT part of the locked subcurve and
        // can be safely topped up while seeding is in flight.
        (uint256 tokenId,) = _mintTransferable(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        veHemi.increaseAmount(tokenId, TOPUP_AMOUNT);
        vm.stopPrank();
        // Tight equality: the final amount must be EXACTLY initial + topup.
        // `assertGt` would pass even if the top-up only partially applied,
        // masking a regression that under-credits the increase.
        assertEq(
            veHemi.getLockedBalance(tokenId).amount,
            int128(int256(LOCK_AMOUNT + TOPUP_AMOUNT)),
            "top-up amount must equal LOCK_AMOUNT + TOPUP_AMOUNT exactly"
        );
    }

    function test_mutationGuard_increaseUnlockTimeBlockedOnNonTransferableDuringSeeding() public {
        (uint256 tokenId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        // alice tries to extend her non-transferable position mid-seed.
        vm.prank(alice);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.increaseUnlockTime(tokenId, LOCK_3Y);
    }

    function test_mutationGuard_increaseUnlockTimeAllowedOnTransferableDuringSeeding() public {
        (uint256 tokenId,) = _mintTransferable(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        vm.prank(alice);
        veHemi.increaseUnlockTime(tokenId, LOCK_3Y);
        // The new end snaps to the SIX_DAYS-aligned bucket at or after
        // `block.timestamp + LOCK_3Y`. Pin the exact rounded-down value:
        // `((block.timestamp + LOCK_3Y) / SIX_DAYS) * SIX_DAYS`. `assertGt`
        // against `now + LOCK_2Y` would pass even if the extension only
        // bumped by 1 second, masking an extension-math regression.
        uint256 expectedEnd = ((block.timestamp + LOCK_3Y) / SIX_DAYS) * SIX_DAYS;
        assertEq(
            veHemi.getLockedBalance(tokenId).end,
            uint64(expectedEnd),
            "extension must snap to SIX_DAYS-aligned bucket"
        );
    }

    function test_mutationGuard_forfeitBlockedDuringSeeding() public {
        // Mint a forfeitable position; configure forfeit admin.
        (uint256 tokenId,) = _mintForfeitable(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.updateForfeitAdmin(owner);

        veHemi.markSeedingStarted();

        // Forfeit attempt mid-seed must revert.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.forfeit(tokenId);
    }

    function test_mutationGuard_allReleasedAfterFinalization() public {
        (uint256 lockedId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (uint256 forfId,) = _mintForfeitable(bob, LOCK_AMOUNT, LOCK_2Y);
        veHemi.updateForfeitAdmin(owner);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // All three mutation guards must release once the latch flips.
        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        veHemi.increaseAmount(lockedId, TOPUP_AMOUNT);
        veHemi.increaseUnlockTime(lockedId, LOCK_3Y);
        vm.stopPrank();

        veHemi.forfeit(forfId);
    }

    function test_mintGuard_adversarialFrontRunDoesNotExtendSeedRange() public {
        // Set up state: existing non-transferable positions present.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        // Operator opens the seeding window.
        veHemi.markSeedingStarted();
        uint256 frozenTarget = veHemi.seedingTargetId();

        // Attacker tries to mint a non-transferable position into the gap.
        // This must revert per the mint guard.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);

        // seedingTargetId did NOT move (the SSTORE in createLockFor reverted),
        // so the seed range stays bounded by the original snapshot.
        assertEq(veHemi.seedingTargetId(), frozenTarget, "target unchanged after blocked mint");

        // Operator scans and finalizes. The attacker's attempt left no
        // residue in the locked subcurve.
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // Locked supply equals exactly alice + bob's contribution.
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected = slope * (veHemi.getLockedBalance(1).end - block.timestamp)
            + slope * (veHemi.getLockedBalance(2).end - block.timestamp);
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expected, "attacker mint did not pollute");
    }

    // ─────────────────────────────────────────────────────────────────────
    // End-to-end equivalence: chunked vs single batch produces same totals
    // ─────────────────────────────────────────────────────────────────────

    function test_seedingFlow_chunkedAndSingleBatchAreEquivalent() public {
        // Path A: seed 10 positions in one big batch.
        _populateLockedPositions(10);

        uint256 snap = vm.snapshotState();

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        uint256 singleBatchLocked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 singleBatchForfeitable = veHemi.forfeitableTotalVeHemiSupply();

        vm.revertToState(snap);

        // Path B: same positions, seeded in 3-id chunks.
        veHemi.markSeedingStarted();
        veHemi.seedBatch(3);
        veHemi.seedBatch(3);
        veHemi.seedBatch(3);
        veHemi.seedBatch(type(uint256).max); // covers the tail
        veHemi.finalizeSeeding();

        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            singleBatchLocked,
            "chunked result must match single batch for locked"
        );
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            singleBatchForfeitable,
            "chunked result must match single batch for forfeitable"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _mintLocked(address account, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId, uint256 lockEnd)
    {
        tokenId = veHemi.createLockFor(amount, duration, account, false, false);
        lockEnd = veHemi.getLockedBalance(tokenId).end;
    }

    function _mintForfeitable(address account, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId, uint256 lockEnd)
    {
        tokenId = veHemi.createLockFor(amount, duration, account, false, true);
        lockEnd = veHemi.getLockedBalance(tokenId).end;
    }

    function _mintTransferable(address account, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId, uint256 lockEnd)
    {
        vm.prank(account);
        tokenId = veHemi.createLock(amount, duration);
        lockEnd = veHemi.getLockedBalance(tokenId).end;
    }

    function _populateLockedPositions(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _mintLocked(_user(i), LOCK_AMOUNT, LOCK_2Y);
        }
    }

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("seed-user", i)))));
    }

    // ─── Direct storage probes into _seedingProgress ────────────────────
    // The struct lives at VeHemi storage slot 23 (4 packed slots: 23-26).
    // Layout:
    //   slot 23: lastProcessedId (uint256)
    //   slot 24: totalSlope (int128, low) | totalBias (int128, high)
    //   slot 25: totalForfeitableSlope (int128, low) | totalForfeitableBias (int128, high)
    //   slot 26: count (uint256)

    function _progressLastProcessedId() internal view returns (uint256) {
        return uint256(vm.load(address(veHemi), bytes32(SLOT_SEEDING_PROGRESS_BASE)));
    }

    function _progressCount() internal view returns (uint256) {
        return uint256(vm.load(address(veHemi), bytes32(SLOT_SEEDING_PROGRESS_COUNT)));
    }
}

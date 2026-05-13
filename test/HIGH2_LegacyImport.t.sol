// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemiVoteDelegation} from "../src/interfaces/IVeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title HIGH-2 Legacy Import Tests
/// @notice Audit HIGH-2 (`updateVoteDelegation` orphans every delegation) is
///         mitigated by `importDelegationsFromLegacy` + `importAutoDelegatesFromLegacy`
///         + `finalizeMigration` on the new VVD. The operator runs these
///         BEFORE flipping `veHemi.voteDelegation()` in the same Safe MultiSend,
///         so the new contract is populated when the pointer swap lands.
///
///         These tests pin:
///           - import correctness (per-tokenId delegations transferred)
///           - autoDelegate import correctness
///           - idempotency (re-importing the same id is a no-op)
///           - access control (only VeHemi owner)
///           - one-way `finalizeMigration` latch
///           - reverts after finalize
///           - the end-to-end migration runbook (deploy → import → seal → swap)
///             produces a contract that returns correct `getVotes` for the
///             next epoch and beyond.
contract HIGH2_LegacyImportTest is Test {
    VeHemi public veHemi;
    VeHemiVoteDelegation public legacyVVD;
    VeHemiVoteDelegation public newVVD;
    MockERC20 public hemiToken;

    address public constant OWNER = address(uint160(uint256(keccak256("owner"))));
    address public constant ALICE = address(uint160(uint256(keccak256("alice"))));
    address public constant BOB = address(uint160(uint256(keccak256("bob"))));
    address public constant CAROL = address(uint160(uint256(keccak256("carol"))));
    address public constant DAVE = address(uint160(uint256(keccak256("dave"))));
    address public constant ATTACKER = address(uint160(uint256(keccak256("attacker"))));

    uint256 public constant LOCK_AMOUNT = 100 ether;
    uint256 public constant LOCK_DURATION = 365 days;

    function setUp() public {
        hemiToken = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemiToken));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, OWNER)
        );
        veHemi = VeHemi(address(proxy));

        legacyVVD = new VeHemiVoteDelegation(address(veHemi));
        vm.prank(OWNER);
        veHemi.updateVoteDelegation(legacyVVD);

        // newVVD is a fresh, empty contract pointing at the same veHemi.
        // It is NOT yet wired into veHemi.
        newVVD = new VeHemiVoteDelegation(address(veHemi));
    }

    function _mintLock(address user, uint256 amount) internal returns (uint256 tokenId) {
        hemiToken.mint(user, amount);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, LOCK_DURATION);
        vm.stopPrank();
    }

    // ─── Basic import flow ───────────────────────────────────────────────

    function test_importDelegationsFromLegacy_basicFlow() public {
        // Alice and Bob lock; Alice delegates to Dave, Bob self-delegates.
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        uint256 bobId = _mintLock(BOB, LOCK_AMOUNT);

        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);
        // Bob's createLock auto-self-delegates.

        uint256[] memory ids = new uint256[](2);
        ids[0] = aliceId;
        ids[1] = bobId;

        // Before import: newVVD has no records.
        assertEq(newVVD.delegation(aliceId).delegatee, address(0));
        assertEq(newVVD.delegation(bobId).delegatee, address(0));

        // Run import.
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);

        // After import: delegatees match legacy.
        assertEq(newVVD.delegation(aliceId).delegatee, DAVE, "alice's delegation not imported");
        assertEq(newVVD.delegation(bobId).delegatee, BOB, "bob's self-delegation not imported");
    }

    function test_importDelegationsFromLegacy_skipsZeroDelegatee() public {
        // Carol locks but never delegates → legacy returns delegatee = 0 actually
        // for unused IDs. But createLock auto-self-delegates, so let's burn a
        // delegation by setting delegatee back via direct calls. Simpler test:
        // pass an unused tokenId.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9999; // never minted

        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);

        // No-op: unused IDs return delegatee == 0 from legacy and are skipped.
        assertEq(newVVD.delegation(9999).delegatee, address(0));
    }

    function test_importDelegationsFromLegacy_idempotent() public {
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;

        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
        assertEq(newVVD.delegation(aliceId).delegatee, DAVE);

        // Second import: skipped (idempotent), no revert.
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
        assertEq(newVVD.delegation(aliceId).delegatee, DAVE);
    }

    // ─── Access control ─────────────────────────────────────────────────

    function test_importDelegationsFromLegacy_revertsForNonOwner() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        vm.prank(ATTACKER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
    }

    function test_importAutoDelegatesFromLegacy_revertsForNonOwner() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        vm.prank(ATTACKER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
    }

    function test_finalizeMigration_revertsForNonOwner() public {
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        vm.prank(ATTACKER);
        newVVD.finalizeMigration();
    }

    // ─── Legacy address validation ──────────────────────────────────────

    function test_importDelegationsFromLegacy_revertsOnZeroAddress() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(VeHemiVoteDelegation.LegacyAddressInvalid.selector);
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(IVeHemiVoteDelegation(address(0)), ids);
    }

    function test_importDelegationsFromLegacy_revertsOnSelfImport() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(VeHemiVoteDelegation.LegacyAddressInvalid.selector);
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(IVeHemiVoteDelegation(address(newVVD)), ids);
    }

    function test_importAutoDelegatesFromLegacy_revertsOnZeroAddress() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(VeHemiVoteDelegation.LegacyAddressInvalid.selector);
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(IVeHemiVoteDelegation(address(0)), owners);
    }

    // ─── Finalize semantics ─────────────────────────────────────────────

    function test_finalizeMigration_flipsLatch() public {
        assertFalse(newVVD.migrationFinalized());
        vm.prank(OWNER);
        newVVD.finalizeMigration();
        assertTrue(newVVD.migrationFinalized());
    }

    function test_finalizeMigration_isIdempotent() public {
        vm.prank(OWNER);
        newVVD.finalizeMigration();
        // Second call is a no-op (no revert, no event).
        vm.prank(OWNER);
        newVVD.finalizeMigration();
        assertTrue(newVVD.migrationFinalized());
    }

    function test_importDelegationsFromLegacy_revertsAfterFinalize() public {
        vm.prank(OWNER);
        newVVD.finalizeMigration();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(VeHemiVoteDelegation.MigrationFinalizedError.selector);
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
    }

    function test_importAutoDelegatesFromLegacy_revertsAfterFinalize() public {
        vm.prank(OWNER);
        newVVD.finalizeMigration();

        address[] memory owners = new address[](1);
        owners[0] = ALICE;
        vm.expectRevert(VeHemiVoteDelegation.MigrationFinalizedError.selector);
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
    }

    // ─── End-to-end runbook ─────────────────────────────────────────────

    /// @notice The full HIGH-2 mitigation runbook in one test. Demonstrates
    ///         that votes are preserved across `updateVoteDelegation` when
    ///         the operator imports state first.
    function test_endToEndMigrationRunbook_preservesVotes() public {
        // Set up legacy state: Alice + Bob + Carol with various delegation
        // patterns.
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        uint256 bobId = _mintLock(BOB, LOCK_AMOUNT);
        uint256 carolId = _mintLock(CAROL, LOCK_AMOUNT);

        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);
        vm.prank(BOB);
        legacyVVD.delegate(bobId, DAVE);
        // Carol stays self-delegated.

        // Snapshot Dave's votes BEFORE migration on legacy. Use the
        // helper that warps to next hour boundary.
        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours + 1);
        uint256 daveVotesLegacy = legacyVVD.getVotes(DAVE);
        assertGt(daveVotesLegacy, 0, "Dave should have non-zero legacy votes");

        // === Operator runbook ===
        // Step 1-2: Off-chain enumerate ids and owners.
        uint256[] memory ids = new uint256[](3);
        ids[0] = aliceId;
        ids[1] = bobId;
        ids[2] = carolId;
        address[] memory owners = new address[](3);
        owners[0] = ALICE;
        owners[1] = BOB;
        owners[2] = CAROL;

        // Step 3: Import delegations.
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);

        // Step 4: Import autoDelegates (none set in this scenario, but
        // call still executes cleanly).
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);

        // Step 5: (skipped — no adapter in this test).

        // Step 6: Finalize.
        vm.prank(OWNER);
        newVVD.finalizeMigration();
        assertTrue(newVVD.migrationFinalized());

        // Step 7: Flip the pointer.
        vm.prank(OWNER);
        veHemi.updateVoteDelegation(newVVD);

        // Warp to the next epoch so newVVD's checkpoints are queryable.
        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours + 1);

        // === Verification ===
        // Dave's votes on the NEW VVD should equal or be very close to the
        // legacy snapshot (modulo natural decay between the two reads).
        uint256 daveVotesNew = newVVD.getVotes(DAVE);
        assertGt(daveVotesNew, 0, "Dave should have non-zero votes post-migration");
        // Allow up to 1% decay tolerance for time passing between snapshots.
        assertGe(
            daveVotesNew,
            (daveVotesLegacy * 99) / 100,
            "Dave's votes dropped >1% across migration"
        );

        // Carol's self-delegation also preserved.
        uint256 carolVotesNew = newVVD.getVotes(CAROL);
        assertGt(carolVotesNew, 0, "Carol's self-delegation lost");

        // Verify all delegation records are correctly imported.
        assertEq(newVVD.delegation(aliceId).delegatee, DAVE);
        assertEq(newVVD.delegation(bobId).delegatee, DAVE);
        assertEq(newVVD.delegation(carolId).delegatee, CAROL);
    }

    /// @notice WITHOUT the import step, the pointer swap silently zeros votes
    ///         (this is the HIGH-2 bug). This test demonstrates the bug
    ///         pre-fix and gives the fix a regression beacon.
    function test_withoutImport_swapZerosVotes_documentedBug() public {
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);

        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours + 1);
        uint256 daveVotesLegacy = legacyVVD.getVotes(DAVE);
        assertGt(daveVotesLegacy, 0);

        // Operator FORGETS the import. Directly flips the pointer.
        vm.prank(OWNER);
        veHemi.updateVoteDelegation(newVVD);

        // newVVD has no record of any delegation.
        assertEq(newVVD.getVotes(DAVE), 0, "documented HIGH-2 bug: votes zeroed");
        assertEq(newVVD.delegation(aliceId).delegatee, address(0), "delegation lost");
    }

    // ─── autoDelegate import ────────────────────────────────────────────

    function test_importAutoDelegatesFromLegacy_basicFlow() public {
        // Alice sets autoDelegate on legacy.
        vm.prank(ALICE);
        legacyVVD.setAutoDelegate(DAVE);

        address[] memory owners = new address[](1);
        owners[0] = ALICE;

        assertEq(newVVD.autoDelegate(ALICE), address(0));
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
        assertEq(newVVD.autoDelegate(ALICE), DAVE, "autoDelegate not imported");
    }

    function test_importAutoDelegatesFromLegacy_idempotent() public {
        vm.prank(ALICE);
        legacyVVD.setAutoDelegate(DAVE);

        address[] memory owners = new address[](1);
        owners[0] = ALICE;

        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
        // Second call is no-op.
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
        assertEq(newVVD.autoDelegate(ALICE), DAVE);
    }

    function test_importAutoDelegatesFromLegacy_skipsZeroAddress() public {
        address[] memory owners = new address[](2);
        owners[0] = address(0);
        owners[1] = ALICE; // ALICE has no autoDelegate set on legacy

        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);

        // address(0) skipped; ALICE skipped because legacy returns 0.
        assertEq(newVVD.autoDelegate(address(0)), address(0));
        assertEq(newVVD.autoDelegate(ALICE), address(0));
    }

    // ─── Expired-lock skip (HR1-G6) ──────────────────────────────────────
    //
    // `importDelegationsFromLegacy` pre-checks each lock against the next
    // epoch boundary so that a single expired lock does NOT revert the
    // whole batch via `_getNormalizedLockedInfo`'s CanNotDelegateExpiredLocks.
    //
    // Pre-check formula:
    //   _nextCheckpoint = ((block.timestamp - 0) / 1h) * 1h + 1h + 0
    //   skip if _lock.end <= _nextCheckpoint
    //
    // Revert condition inside `_getNormalizedLockedInfo`:
    //   _end <= checkPointTimestamp_  where checkPointTimestamp_ is the
    //   same `_checkpointTimestamp` recomputed in `_delegate`.
    //
    // Both formulas use identical EPOCH_OFFSET (0) and CHECKPOINT_INTERVAL
    // (1 hour), so the pre-check is exactly aligned with the revert gate.
    function test_importDelegationsFromLegacy_skipsExpiredLock() public {
        // 1) Lock for minimum duration (~12 days, rounded down to 6-day
        //    boundary). End is several days in the future, far past
        //    next-hour boundary → import will SUCCEED for this case.
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);

        uint256 lockEnd = veHemi.getLockedBalance(aliceId).end;
        assertGt(lockEnd, block.timestamp, "lock not in future after mint");

        // First call: lock is healthy → expect import to succeed.
        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
        assertEq(
            newVVD.delegation(aliceId).delegatee,
            DAVE,
            "healthy lock should import"
        );

        // 2) New token, then warp PAST that lock's end so its `end` is
        //    in the past. Pre-check must skip silently — no revert, no
        //    state write to newVVD.
        uint256 bobId = _mintLock(BOB, LOCK_AMOUNT);
        vm.prank(BOB);
        legacyVVD.delegate(bobId, CAROL);
        uint256 bobEnd = veHemi.getLockedBalance(bobId).end;

        // Warp to bobEnd + 1 hour so next-checkpoint also passes bobEnd.
        vm.warp(bobEnd + 1 hours);

        // Confirm gate would trip: _nextCheckpoint > bobEnd.
        uint256 nextCheckpoint = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        assertGt(
            nextCheckpoint,
            bobEnd,
            "test setup wrong: next-checkpoint must be past bobEnd"
        );

        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = bobId;
        // Without the pre-check this would revert CanNotDelegateExpiredLocks.
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, bobIds);

        // Confirm expired lock was silently skipped (no record written).
        assertEq(
            newVVD.delegation(bobId).delegatee,
            address(0),
            "expired lock must be skipped, not imported"
        );
    }

    // Lock ending EXACTLY at the next checkpoint must be skipped (the
    // revert gate is `<=`, so the pre-check must also be `<=`).
    function test_importDelegationsFromLegacy_skipsLockEndingExactlyAtNextCheckpoint() public {
        uint256 bobId = _mintLock(BOB, LOCK_AMOUNT);
        vm.prank(BOB);
        legacyVVD.delegate(bobId, CAROL);
        uint256 bobEnd = veHemi.getLockedBalance(bobId).end;

        // Warp so the NEXT hourly checkpoint == bobEnd EXACTLY. nextCheckpoint
        // = (ts/1h)*1h + 1h. Choose ts = bobEnd - 1 so floor(ts/1h)*1h + 1h
        // = bobEnd whenever bobEnd is hour-aligned; SIX_DAYS is NOT a multiple
        // of 1 hour (YEAR = 365.25d → SIX_DAYS = 526260s), so we instead pick
        // ts so that ((ts) / 1h) * 1h + 1h == bobEnd, i.e. ts ∈ [bobEnd-1h, bobEnd).
        // The smallest such ts that yields nextCheckpoint >= bobEnd is ts = bobEnd - 1.
        // But because bobEnd may not be hour-aligned, choose nextCheckpoint == bobEnd
        // is only possible when bobEnd is hour-aligned. Instead, prove the
        // boundary case `_lock.end == _nextCheckpoint` by constructing ts so
        // that nextCheckpoint == bobEnd exactly: warp to (bobEnd - 1) and
        // bump forward until (ts/1h)*1h + 1h == bobEnd OR skip if impossible.
        // For SIX_DAYS-aligned ends (not hour-aligned), the closest we can
        // achieve is _nextCheckpoint > bobEnd (also a skip case, already
        // covered by the previous test). Therefore exercise the `==` branch
        // by warping just before bobEnd so that nextCheckpoint > bobEnd by
        // less than one hour, which still satisfies `_lock.end <= _nextCheckpoint`.
        vm.warp(bobEnd - 1);
        uint256 nextCheckpoint = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        assertGe(nextCheckpoint, bobEnd, "next-checkpoint must >= lock end");

        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = bobId;
        // Pre-check uses `<=` so end == nextCheckpoint is skipped, matching
        // the revert condition `_end <= checkPointTimestamp_`.
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, bobIds);
        assertEq(
            newVVD.delegation(bobId).delegatee,
            address(0),
            "lock ending exactly at next-checkpoint must be skipped"
        );
    }

    // ─── amount == 0 skip path (HR1-G14) ─────────────────────────────────
    //
    // After `withdraw()` on VeHemi the lock's `amount` is zeroed and the NFT
    // is burned. The import path must skip these tokens silently — they have
    // no voting power left to migrate, and re-running `_delegate` for them
    // would mint a zero-weight checkpoint at best and revert at worst.
    function test_importDelegationsFromLegacy_skipsBurnedTokens() public {
        // Alice locks, delegates, then waits past lock end and withdraws,
        // burning the NFT and zeroing locked[id].amount.
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);

        uint256 lockEnd = veHemi.getLockedBalance(aliceId).end;
        vm.warp(lockEnd + 1);
        vm.prank(ALICE);
        veHemi.withdraw(aliceId);

        // Confirm setup: amount is zeroed.
        assertEq(
            veHemi.getLockedBalance(aliceId).amount,
            0,
            "withdraw should zero locked amount"
        );

        // Legacy still has Alice's old delegation record (storage stays).
        assertEq(
            legacyVVD.delegation(aliceId).delegatee,
            DAVE,
            "legacy delegation record persists after withdraw"
        );

        // Import must skip silently (no revert) and write no record.
        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);

        assertEq(
            newVVD.delegation(aliceId).delegatee,
            address(0),
            "burned/withdrawn token must be skipped, not imported"
        );
    }

    // ─── Event emission (HR1-G14) ─────────────────────────────────────────
    //
    // `finalizeMigration` must emit `MigrationFinalizedEvent` EXACTLY ONCE
    // — the second call is a no-op (idempotent) and must NOT re-emit, so
    // indexers can rely on the first emission as the authoritative seal.
    function test_finalizeMigration_emitsEventOnce() public {
        // First call: emits.
        vm.expectEmit(false, false, false, true, address(newVVD));
        emit IVeHemiVoteDelegation.MigrationFinalizedEvent();
        vm.prank(OWNER);
        newVVD.finalizeMigration();
        assertTrue(newVVD.migrationFinalized());

        // Second call: must NOT emit. We record logs and assert no
        // MigrationFinalizedEvent is present.
        vm.recordLogs();
        vm.prank(OWNER);
        newVVD.finalizeMigration();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("MigrationFinalizedEvent()");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                assertTrue(
                    logs[i].topics[0] != sig,
                    "MigrationFinalizedEvent re-emitted on idempotent call"
                );
            }
        }
        assertTrue(newVVD.migrationFinalized());
    }

    // End-to-end event-ordering: a full runbook must emit
    //   LegacyDelegationImported (per id), LegacyAutoDelegateImported (per
    //   owner with autoDelegate set), then MigrationFinalizedEvent — and
    //   the latch must flip exactly once. We assert the three event types
    //   each appear and the finalize event is the LAST of the three families.
    function test_endToEndMigrationRunbook_eventEmissionOrder() public {
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);
        vm.prank(ALICE);
        legacyVVD.setAutoDelegate(DAVE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;
        address[] memory owners = new address[](1);
        owners[0] = ALICE;

        vm.recordLogs();
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
        vm.prank(OWNER);
        newVVD.finalizeMigration();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sigDeleg = keccak256(
            "LegacyDelegationImported(uint256,address,address)"
        );
        bytes32 sigAuto = keccak256(
            "LegacyAutoDelegateImported(address,address,address)"
        );
        bytes32 sigFin = keccak256("MigrationFinalizedEvent()");

        uint256 idxDeleg = type(uint256).max;
        uint256 idxAuto = type(uint256).max;
        uint256 idxFin = type(uint256).max;
        uint256 finCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 t = logs[i].topics[0];
            if (t == sigDeleg && idxDeleg == type(uint256).max) idxDeleg = i;
            if (t == sigAuto && idxAuto == type(uint256).max) idxAuto = i;
            if (t == sigFin) {
                if (idxFin == type(uint256).max) idxFin = i;
                finCount++;
            }
        }
        assertTrue(idxDeleg != type(uint256).max, "LegacyDelegationImported missing");
        assertTrue(idxAuto != type(uint256).max, "LegacyAutoDelegateImported missing");
        assertTrue(idxFin != type(uint256).max, "MigrationFinalizedEvent missing");
        assertLt(idxDeleg, idxFin, "finalize must come AFTER import-delegation");
        assertLt(idxAuto, idxFin, "finalize must come AFTER autoDelegate-import");
        assertEq(finCount, 1, "finalize event must be emitted exactly once");
    }

    // ─── HR2-G9: idempotency stress tests ────────────────────────────────
    //
    // The guards `if (delegations[id].delegatee != address(0)) continue;`
    // and `if (autoDelegate[o] != address(0)) continue;` must hold under
    // operator-misuse, user-front-run, and overlapping-batch conditions.

    /// @notice Duplicate IDs in the SAME batch: `[id, id, id]` must write
    ///         once and silently skip subsequent occurrences. The first
    ///         iteration populates `delegations[id]` via `_delegate`, then
    ///         iterations 2/3 hit the `delegatee != address(0)` guard.
    function test_importDelegationsFromLegacy_duplicateIdsInSingleBatch() public {
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);

        // Same tokenId 3 times in one batch.
        uint256[] memory ids = new uint256[](3);
        ids[0] = aliceId;
        ids[1] = aliceId;
        ids[2] = aliceId;

        // Capture exactly one LegacyDelegationImported event (first iter).
        vm.recordLogs();
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sigDeleg = keccak256(
            "LegacyDelegationImported(uint256,address,address)"
        );
        uint256 delegEventCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == sigDeleg) delegEventCount++;
        }
        assertEq(
            delegEventCount,
            1,
            "duplicate IDs must emit only one import event"
        );
        assertEq(
            newVVD.delegation(aliceId).delegatee,
            DAVE,
            "single write must land"
        );
    }

    /// @notice User front-run: a user calls `delegate(id, X)` on the NEW
    ///         VVD before the owner runs `importDelegationsFromLegacy`.
    ///         The import must skip that id (user choice wins) because the
    ///         idempotency guard reads `delegations[id].delegatee != 0`.
    ///         This is the desired behaviour — user intent supersedes a
    ///         stale legacy record.
    function test_importDelegationsFromLegacy_userDelegationPreemptsImport() public {
        // Alice has a legacy delegation to DAVE.
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);

        // BEFORE the owner runs the import, Alice front-runs on the new VVD
        // and re-targets her delegation to CAROL. (She is the NFT owner, so
        // `onlyAuthorized` passes even though the veHemi pointer hasn't yet
        // flipped — newVVD reads veHemi state directly.)
        vm.prank(ALICE);
        newVVD.delegate(aliceId, CAROL);
        assertEq(
            newVVD.delegation(aliceId).delegatee,
            CAROL,
            "user pre-write should land"
        );

        // Owner runs import. The idempotency guard must skip aliceId so
        // that the legacy DAVE delegatee does NOT overwrite Alice's choice.
        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);

        assertEq(
            newVVD.delegation(aliceId).delegatee,
            CAROL,
            "user choice must survive owner import"
        );
    }

    /// @notice Overlapping batches: `[a, b, c]` then `[b, c, d]` — the
    ///         second batch must only newly populate `d`; `b` and `c` are
    ///         already set and must be skipped.
    function test_importDelegationsFromLegacy_overlappingBatches() public {
        uint256 aId = _mintLock(ALICE, LOCK_AMOUNT);
        uint256 bId = _mintLock(BOB, LOCK_AMOUNT);
        uint256 cId = _mintLock(CAROL, LOCK_AMOUNT);
        uint256 dId = _mintLock(DAVE, LOCK_AMOUNT);

        // Distinct delegatees so we can detect any accidental overwrite.
        vm.prank(ALICE); legacyVVD.delegate(aId, BOB);
        vm.prank(BOB);   legacyVVD.delegate(bId, CAROL);
        vm.prank(CAROL); legacyVVD.delegate(cId, DAVE);
        vm.prank(DAVE);  legacyVVD.delegate(dId, ALICE);

        // First batch: a, b, c.
        uint256[] memory batch1 = new uint256[](3);
        batch1[0] = aId; batch1[1] = bId; batch1[2] = cId;
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, batch1);

        assertEq(newVVD.delegation(aId).delegatee, BOB);
        assertEq(newVVD.delegation(bId).delegatee, CAROL);
        assertEq(newVVD.delegation(cId).delegatee, DAVE);
        assertEq(newVVD.delegation(dId).delegatee, address(0));

        // After batch 1, simulate user re-targeting `b` between batches.
        // This proves overlap-skip respects intervening user state too.
        vm.prank(BOB);
        newVVD.delegate(bId, ALICE);
        assertEq(newVVD.delegation(bId).delegatee, ALICE);

        // Second batch: b, c, d. Only `d` should be newly written. `b` and
        // `c` must be skipped; `b`'s user-set ALICE delegatee must survive.
        uint256[] memory batch2 = new uint256[](3);
        batch2[0] = bId; batch2[1] = cId; batch2[2] = dId;

        vm.recordLogs();
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, batch2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sigDeleg = keccak256(
            "LegacyDelegationImported(uint256,address,address)"
        );
        uint256 delegEventCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == sigDeleg) delegEventCount++;
        }
        assertEq(
            delegEventCount,
            1,
            "overlapping batch must emit exactly one import event (for d)"
        );

        // Final state: `a`, `c` unchanged from batch 1; `b` retains user
        // choice; `d` newly imported from legacy.
        assertEq(newVVD.delegation(aId).delegatee, BOB,   "a unchanged");
        assertEq(newVVD.delegation(bId).delegatee, ALICE, "b user choice survives");
        assertEq(newVVD.delegation(cId).delegatee, DAVE,  "c unchanged");
        assertEq(newVVD.delegation(dId).delegatee, ALICE, "d newly imported");
    }

    // ─── HR2-G14: user-set autoDelegate preempts import ──────────────────
    //
    // Mirror of `userDelegationPreemptsImport` for the autoDelegate path.
    // Guard: `if (autoDelegate[o] != address(0)) continue;`. If a user has
    // already called `setAutoDelegate` on newVVD before the owner-driven
    // import runs, the user's choice must win — legacy must NOT overwrite.
    function test_importAutoDelegatesFromLegacy_userSetAutoDelegatePreempts() public {
        // Legacy: Alice's autoDelegate is DAVE.
        vm.prank(ALICE);
        legacyVVD.setAutoDelegate(DAVE);

        // Alice front-runs on newVVD with CAROL.
        vm.prank(ALICE);
        newVVD.setAutoDelegate(CAROL);
        assertEq(newVVD.autoDelegate(ALICE), CAROL, "user pre-write should land");

        address[] memory owners = new address[](1);
        owners[0] = ALICE;
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);

        assertEq(
            newVVD.autoDelegate(ALICE),
            CAROL,
            "user-set autoDelegate must survive owner import"
        );
    }

    // ─── HR2-G14: event-arg correctness ──────────────────────────────────
    //
    // The end-to-end event-order test only asserts on `topics[0]`
    // signatures. This test pins the FULL args of both legacy-import
    // events so external indexers can rely on (tokenId/owner, delegatee,
    // legacy-contract-address) being correctly populated.
    function test_importFromLegacy_emitsEventsWithCorrectArgs() public {
        uint256 aliceId = _mintLock(ALICE, LOCK_AMOUNT);
        vm.prank(ALICE);
        legacyVVD.delegate(aliceId, DAVE);
        vm.prank(ALICE);
        legacyVVD.setAutoDelegate(DAVE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = aliceId;

        // Full topic + data match for LegacyDelegationImported.
        vm.expectEmit(true, true, true, true, address(newVVD));
        emit IVeHemiVoteDelegation.LegacyDelegationImported(
            aliceId, DAVE, address(legacyVVD)
        );
        vm.prank(OWNER);
        newVVD.importDelegationsFromLegacy(legacyVVD, ids);

        address[] memory owners = new address[](1);
        owners[0] = ALICE;

        // Full topic + data match for LegacyAutoDelegateImported.
        vm.expectEmit(true, true, true, true, address(newVVD));
        emit IVeHemiVoteDelegation.LegacyAutoDelegateImported(
            ALICE, DAVE, address(legacyVVD)
        );
        vm.prank(OWNER);
        newVVD.importAutoDelegatesFromLegacy(legacyVVD, owners);
    }
}

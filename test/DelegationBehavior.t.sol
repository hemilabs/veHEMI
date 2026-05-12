// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../src/interfaces/IVeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title  DelegationBehavior
/// @notice Behavioral coverage for the VeHemi ↔ VeHemiVoteDelegation
///         interaction surfaces that govern vote attribution. Each test
///         pins an observable property so a future refactor that
///         re-introduces the original bug class fails loudly. Specifically:
///
///         * `transferFrom` runs the ERC721 ownership swap BEFORE the
///           delegation hook, so the IVotes-shaped `DelegateChanged` event
///           and the cached delegation resolve against the BUYER (the new
///           owner) rather than the SELLER.
///         * Forfeit cleanup deletes `delegations[tokenId]` and skips the
///           "move to new delegate" path when the target is `address(0)`,
///           so checkpoints and expirations never accumulate at the zero
///           address.
///         * `setAutoDelegate(address)` is a standalone, idempotent setter
///           that lets a holder configure their auto-delegate target
///           without iterating existing positions; future mints to that
///           account auto-delegate to the chosen target.
///         * `clearAutoDelegate` emits `AutoDelegateSet` so indexers can
///           reconstruct (account → auto-delegate target) from the event
///           stream alone.
contract DelegationBehaviorTest is Test {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    MockERC20 internal hemi;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant MAX_TIME = 4 * YEAR;
    uint256 internal constant LOCK_AMOUNT = 100e18;

    // Mirror the canonical event signatures so vm.expectEmit can match.
    event AutoDelegateSet(address indexed owner, address indexed previousDelegate, address indexed newDelegate);
    event DelegateChanged(uint256 indexed delegator, address indexed fromDelegatee, address indexed toDelegatee);

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, owner));
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);
    }

    // -------------------------------------------------------------------------
    // transferFrom: delegation hook resolves against the post-transfer owner
    // -------------------------------------------------------------------------

    /// @notice The cached `delegations[tokenId]` written by the
    ///         transfer-induced `_delegate` call must resolve ownership AFTER
    ///         the ERC721 swap completes — the buyer (not the seller) is the
    ///         delegator any IVotes consumer sees.
    function test_transferFrom_attributesDelegateChangeToNewOwner() public {
        uint256 tokenId = _createLock(alice, LOCK_AMOUNT, YEAR);

        // Sanity: pre-transfer, alice owns the NFT and the cached delegation
        // points at her (auto-self-delegation default for fresh mints).
        assertEq(veHemi.ownerOf(tokenId), alice, "pre-transfer: alice owns");
        assertEq(delegation.delegation(tokenId).delegatee, alice, "pre-transfer: self-delegated");

        // Transfer the position to bob. After the call:
        //   * ownerOf(tokenId) == bob
        //   * delegations[tokenId].delegatee == bob (resolved auto-delegate
        //     of the new owner; bob has no autoDelegate set, so self).
        // The presence of bob — not alice — in the delegations cache is the
        // observable evidence that _delegate ran AFTER super.transferFrom.
        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);

        assertEq(veHemi.ownerOf(tokenId), bob, "post-transfer: bob owns");
        assertEq(
            delegation.delegation(tokenId).delegatee,
            bob,
            "post-transfer: cached delegate is bob (proves _delegate ran after super.transferFrom)"
        );
    }

    /// @notice The cached delegation must reflect the recipient's
    ///         auto-delegate choice when one is set — proving that the
    ///         post-transfer call path resolves against `to_`'s state.
    function test_transferFrom_honorsRecipientAutoDelegate() public {
        // Bob configures CAROL as his auto-delegate.
        vm.prank(bob);
        delegation.setAutoDelegate(carol);

        uint256 tokenId = _createLock(alice, LOCK_AMOUNT, YEAR);

        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);

        assertEq(
            delegation.delegation(tokenId).delegatee,
            carol,
            "post-transfer: cached delegate must follow recipient (bob)'s autoDelegate"
        );
    }

    /// @notice Self-transfer (`from == to`) is a state no-op for ERC721,
    ///         but the function still runs `_delegate` + `_checkpoint`
    ///         after the (no-op) ownership swap. The cached delegation must
    ///         be re-resolved against the (unchanged) owner's auto-delegate,
    ///         and ownerOf must remain stable.
    function test_transferFrom_selfTransferIsBenign() public {
        uint256 tokenId = _createLock(alice, LOCK_AMOUNT, YEAR);
        assertEq(veHemi.ownerOf(tokenId), alice);
        assertEq(delegation.delegation(tokenId).delegatee, alice);

        // Alice has no autoDelegate set; self-transfer must keep the
        // self-delegation in place.
        vm.prank(alice);
        veHemi.transferFrom(alice, alice, tokenId);

        assertEq(veHemi.ownerOf(tokenId), alice, "ownership unchanged");
        assertEq(
            delegation.delegation(tokenId).delegatee, alice, "self-transfer must leave delegation pointing at alice"
        );

        // Now alice sets autoDelegate(carol) and self-transfers again.
        // The post-transfer _delegate should re-resolve to carol because
        // _resolveAutoDelegate(alice) now returns carol.
        vm.prank(alice);
        delegation.setAutoDelegate(carol);

        vm.prank(alice);
        veHemi.transferFrom(alice, alice, tokenId);

        assertEq(veHemi.ownerOf(tokenId), alice, "ownership still alice");
        assertEq(
            delegation.delegation(tokenId).delegatee, carol, "self-transfer must honor caller's autoDelegate after swap"
        );
    }

    /// @notice Contract recipient: a contract `to_` whose auto-delegate is
    ///         set must receive its forwarded delegation when an NFT is
    ///         transferred in via `safeTransferFrom`. The contract holds
    ///         the NFT post-call (via `onERC721Received` returning the
    ///         magic value).
    function test_safeTransferFrom_contractRecipientWithAutoDelegate() public {
        MinimalERC721Receiver receiver = new MinimalERC721Receiver();

        // Receiver sets its own autoDelegate to carol.
        vm.prank(address(receiver));
        delegation.setAutoDelegate(carol);

        uint256 tokenId = _createLock(alice, LOCK_AMOUNT, YEAR);

        vm.prank(alice);
        veHemi.safeTransferFrom(alice, address(receiver), tokenId);

        assertEq(veHemi.ownerOf(tokenId), address(receiver), "receiver owns post-transfer");
        assertEq(
            delegation.delegation(tokenId).delegatee, carol, "delegation must follow receiver's autoDelegate (carol)"
        );
    }

    // -------------------------------------------------------------------------
    // forfeit: address(0) state must remain clean
    // -------------------------------------------------------------------------

    /// @notice Forfeit cleanup must NOT push a checkpoint into
    ///         `delegateCheckpoints[address(0)]` nor bump
    ///         `expiredDelegations[address(0)][end]`. A regression that
    ///         re-routes the "move to new delegate" path on the address(0)
    ///         branch would surface here as non-zero readings.
    function test_forfeit_doesNotAccumulateAtZeroAddress() public {
        // Configure forfeit admin so VeHemi.forfeit is callable.
        veHemi.updateForfeitAdmin(owner);

        // Mint a non-transferable, forfeitable position for alice.
        hemi.mint(alice, LOCK_AMOUNT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, YEAR, alice, false, true);
        vm.stopPrank();

        // The mint flow self-delegated alice (auto-delegate default).
        assertEq(delegation.delegation(tokenId).delegatee, alice, "self-delegated on mint");

        // Forfeit triggers VeHemi.forfeit → _delegate(tokenId, address(0))
        // → cleanup path. No checkpoint or expiration entry should be
        // written under the zero-address key.
        veHemi.forfeit(tokenId);

        assertEq(delegation.getVotes(address(0)), 0, "address(0) must not accrue votes");
        assertEq(delegation.getPastVotes(address(0), block.timestamp - 1), 0, "address(0) historical votes must be 0");

        // Forfeit a second position: the property must hold across many forfeits.
        hemi.mint(bob, LOCK_AMOUNT);
        vm.startPrank(bob);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId2 = veHemi.createLockFor(LOCK_AMOUNT, YEAR, bob, false, true);
        vm.stopPrank();
        veHemi.forfeit(tokenId2);

        assertEq(delegation.getVotes(address(0)), 0, "address(0) still 0 after two forfeits");
    }

    /// @notice Forfeit cleanup must still emit
    ///         `DelegateChanged(tokenId, prev, address(0))` from the
    ///         delegation contract so subgraphs see the retirement marker —
    ///         only the to-delegate side-effects (checkpoint push, vote-
    ///         change event for the zero address) are skipped.
    function test_forfeit_emitsDelegateChangedToZero() public {
        veHemi.updateForfeitAdmin(owner);

        hemi.mint(alice, LOCK_AMOUNT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, YEAR, alice, false, true);
        vm.stopPrank();

        // Expect DelegateChanged(tokenId, alice, address(0)) from the
        // delegation contract during forfeit cleanup. We tolerate any other
        // events; only the topic combination is asserted.
        vm.recordLogs();
        veHemi.forfeit(tokenId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 dcSig = keccak256("DelegateChanged(uint256,address,address)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(delegation) && logs[i].topics[0] == dcSig
                    && uint256(logs[i].topics[1]) == tokenId && address(uint160(uint256(logs[i].topics[2]))) == alice
                    && address(uint160(uint256(logs[i].topics[3]))) == address(0)
            ) {
                found = true;
                break;
            }
        }
        assertTrue(found, "forfeit must emit DelegateChanged(tokenId, alice, 0)");
    }

    /// @notice Direct-storage probe: confirm
    ///         `delegateCheckpoints[address(0)].length` and
    ///         `expiredDelegations[address(0)][end]` both stay zero across
    ///         many forfeits. View-only assertions on `getVotes(address(0))`
    ///         cannot catch an expirations-only leak until `block.timestamp`
    ///         crosses `end`, so we read the slots directly.
    function test_forfeit_zeroAddressStorageRemainsClean() public {
        veHemi.updateForfeitAdmin(owner);

        // Forfeit ten distinct positions to amplify any per-forfeit leak.
        // Capture the EXACT lock.end before each forfeit so we can probe the
        // matching `expiredDelegations[address(0)][end]` slot directly —
        // VeHemi rounds lock.end to a SIX_DAYS bucket inside `_createLock`,
        // so an hour-grid window cannot reliably hit the slot a regression
        // would touch. Reading the rounded end straight from the NFT
        // eliminates that fragility entirely.
        uint256 forfeitCount = 10;
        uint256[] memory ends = new uint256[](forfeitCount);
        for (uint256 i; i < forfeitCount; ++i) {
            address user = address(uint160(uint256(0xC0DE0000) + i));
            hemi.mint(user, LOCK_AMOUNT);
            vm.startPrank(user);
            hemi.approve(address(veHemi), LOCK_AMOUNT);
            uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, YEAR, user, false, true);
            vm.stopPrank();
            // Snapshot the SIX_DAYS-rounded end recorded by _createLock
            // before the forfeit burns the position and zeroes `locked`.
            ends[i] = veHemi.getLockedBalance(tokenId).end;
            veHemi.forfeit(tokenId);
        }

        // 1) delegateCheckpoints[address(0)].length must be zero.
        //    delegateCheckpoints lives at slot 1 of VeHemiDelegationStorageV1
        //    (per test/VeHemiDelegationStorageLayout.t.sol). The array
        //    length for a `mapping(address => DelegateCheckpoint[])` is at
        //    `keccak256(key, slot)`.
        bytes32 lengthSlot = keccak256(abi.encode(address(0), uint256(1)));
        uint256 len = uint256(vm.load(address(delegation), lengthSlot));
        assertEq(len, 0, "delegateCheckpoints[address(0)].length must remain 0");

        // 2) expiredDelegations[address(0)][end] must be zero for the EXACT
        //    `end` slot each forfeit would have written under the regression.
        //    The nested mapping lives at slot 2: outer key is address(0),
        //    inner key is `end`. The struct slot is
        //    `keccak256(end, keccak256(address(0), 2))` and packs
        //    {uint96 bias, uint96 amount, uint64 slope} into one word.
        bytes32 innerBase = keccak256(abi.encode(address(0), uint256(2)));
        for (uint256 i; i < forfeitCount; ++i) {
            bytes32 structSlot = keccak256(abi.encode(ends[i], innerBase));
            assertEq(
                vm.load(address(delegation), structSlot),
                bytes32(0),
                "expiredDelegations[address(0)][end] must remain 0"
            );
        }

        // 3) View-side sanity: getVotes / getPastVotes still read 0 even
        //    after warping past the lock end (would have surfaced any
        //    stale expirations as decayed votes).
        uint256 maxEnd;
        for (uint256 i; i < forfeitCount; ++i) {
            if (ends[i] > maxEnd) maxEnd = ends[i];
        }
        vm.warp(maxEnd + 1 days);
        assertEq(delegation.getVotes(address(0)), 0, "getVotes(0) post-warp");
        assertEq(delegation.getPastVotes(address(0), maxEnd - 1 hours), 0, "getPastVotes(0) post-warp");
    }

    // -------------------------------------------------------------------------
    // NEAR-EXPIRY FORFEIT CLEANUP — regression for the stale-delegation bug
    // -------------------------------------------------------------------------
    //
    // Bug (pre-fix, observed via fuzz seed perturbation): when `forfeit(id)`
    // ran with `block.timestamp + 1 hour > locked[id].end`, VeHemi's
    // `_delegate` outer guard (`_newDelegationStarts < locked.end`) skipped
    // the inner `voteDelegation.delegate(id, address(0))` call entirely.
    // `delegations[id]` was left populated even though the NFT was burned.
    //
    // The fix is two parts:
    //   1. VeHemi._delegate now lets `delegatee_ == address(0)` ALWAYS pass
    //      the outer guard (cleanup intent is never expiry-blocked).
    //   2. VeHemiVoteDelegation._delegate now invokes
    //      `_getNormalizedLockedInfo` ONLY inside the new-delegatee branch,
    //      so the cleanup branch tolerates locks at/past expiry without
    //      reverting `CanNotDelegateExpiredLocks`.
    //
    // Together they ensure `delegations[id]` is cleared on EVERY forfeit
    // path, regardless of how close to lock-end the forfeit lands.

    /// @notice Forfeit invoked within ~1 hour of `lock.end` MUST still clear
    ///         `delegations[id]`. This is the exact bug the original fuzz
    ///         surfaced: pre-fix, the cached delegatee stayed pointing at the
    ///         original owner after the NFT was burned.
    function test_forfeit_nearLockEnd_clearsDelegationCache() public {
        veHemi.updateForfeitAdmin(owner);

        // Mint a forfeitable, non-transferable position with a SHORT lock
        // (must be ≥ MIN_LOCK_DURATION but small enough that we can warp
        // to within an hour of lock-end without crossing transferableAfter).
        // SIX_DAYS bucket size = ~6.087 days; 2 buckets ≈ 12 days.
        uint256 SIX_DAYS = YEAR / 60;
        hemi.mint(alice, LOCK_AMOUNT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, 2 * SIX_DAYS, alice, false, true);
        vm.stopPrank();

        // Pre-state: delegation cache populated with alice (self-delegate default).
        assertEq(delegation.delegation(tokenId).delegatee, alice, "pre-forfeit: cache points at alice");

        // Warp to 30 minutes before lock-end — strictly within the buggy
        // window where the prior `_newDelegationStarts < locked.end` guard
        // would have short-circuited the cleanup call.
        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;
        vm.warp(lockEnd - 30 minutes);

        // Forfeit. With the fix, the cleanup call now propagates through
        // BOTH the outer VeHemi guard (carve-out for address(0)) AND the
        // inner `_getNormalizedLockedInfo` skip (cleanup branch doesn't
        // need normalized values). `delegations[id]` must be fully zeroed.
        veHemi.forfeit(tokenId);

        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenId);
        assertEq(d.delegatee, address(0), "post-forfeit: delegatee MUST be cleared");
        assertEq(uint256(d.bias), 0, "post-forfeit: bias MUST be cleared");
        assertEq(uint256(d.amount), 0, "post-forfeit: amount MUST be cleared");
        assertEq(uint256(d.slope), 0, "post-forfeit: slope MUST be cleared");
        assertEq(uint256(d.end), 0, "post-forfeit: end MUST be cleared");
    }

    /// @notice SANITY companion: forfeit FAR from lock-end (the historically
    ///         working path) still clears the cache. Confirms the fix didn't
    ///         break the originally-correct case.
    function test_forfeit_farFromLockEnd_clearsDelegationCache() public {
        veHemi.updateForfeitAdmin(owner);

        hemi.mint(alice, LOCK_AMOUNT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, YEAR, alice, false, true);
        vm.stopPrank();

        // Warp only 1 day forward — months until lock-end. The pre-fix code
        // ALREADY worked here; this test pins that the fix preserves it.
        vm.warp(block.timestamp + 1 days);

        veHemi.forfeit(tokenId);

        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenId);
        assertEq(d.delegatee, address(0), "far-from-expiry: delegatee cleared");
        assertEq(uint256(d.bias), 0, "far-from-expiry: bias cleared");
    }

    /// @notice Parametric sweep across the boundary: forfeit at
    ///         `lock.end - {1, 60, 3599, 3600, 3601}` seconds. The exact
    ///         off-by-one matters for the guard rewrite: `_newDelegationStarts`
    ///         is `(now/1h)*1h + 1h`, so the boundary where the prior guard
    ///         flipped is `block.timestamp ∈ [lock.end - 1h, lock.end)`.
    ///         All five samples must clear the cache post-fix.
    function test_forfeit_nearLockEnd_boundarySweep_clearsCache() public {
        veHemi.updateForfeitAdmin(owner);

        uint256[5] memory offsets = [uint256(1), 60, 3599, 3600, 3601];
        for (uint256 i; i < offsets.length; ++i) {
            address user = address(uint160(uint256(0xBEEF0000) + i));
            hemi.mint(user, LOCK_AMOUNT);
            vm.startPrank(user);
            hemi.approve(address(veHemi), LOCK_AMOUNT);
            uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, YEAR, user, false, true);
            vm.stopPrank();

            uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;
            // Skip samples where the offset would not produce a valid pre-end
            // warp (block.timestamp must remain strictly less than lockEnd).
            if (offsets[i] >= lockEnd) continue;
            vm.warp(lockEnd - offsets[i]);

            veHemi.forfeit(tokenId);

            IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenId);
            assertEq(
                d.delegatee,
                address(0),
                string.concat("boundary sweep: cache not cleared at lock.end - ", vm.toString(offsets[i]), "s")
            );
        }
    }

    /// @notice POST-EXPIRY BOUND: forfeit is bounded by `transferableAfter`,
    ///         which equals `lock.end` at mint (see `_createLock`,
    ///         `transferableAfter[_tokenId] = unlockTime` in VeHemi.sol).
    ///         Forfeit MUST revert at and beyond `lock.end`, proving the
    ///         post-expiry forfeit path is UNREACHABLE. The `address(0)`
    ///         cleanup carve-out in `_delegate` is therefore purely
    ///         defense-in-depth for the `[lock.end - 1h, lock.end)` window.
    ///
    ///         At `block.timestamp == lock.end`: `LockExpired` checks
    ///         `lock.end < block.timestamp` (strict <), so it does NOT fire
    ///         at exact equality; `ForfeitWindowExpired` (`>=`) DOES fire.
    ///         At `block.timestamp > lock.end`: `LockExpired` fires first
    ///         (source-order earlier in `forfeit`).
    function test_forfeit_atAndAfterLockEnd_reverts() public {
        veHemi.updateForfeitAdmin(owner);

        uint256[3] memory offsets = [uint256(0), 1, 365 days];
        for (uint256 i; i < offsets.length; ++i) {
            address user = address(uint160(uint256(0xDEAD0000) + i));
            hemi.mint(user, LOCK_AMOUNT);
            vm.startPrank(user);
            hemi.approve(address(veHemi), LOCK_AMOUNT);
            uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, YEAR, user, false, true);
            vm.stopPrank();

            uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;
            vm.warp(lockEnd + offsets[i]);

            if (offsets[i] == 0) {
                vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
            } else {
                vm.expectRevert(VeHemi.LockExpired.selector);
            }
            veHemi.forfeit(tokenId);

            // No state mutation occurred — cache still reflects original delegation.
            IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenId);
            assertEq(d.delegatee, user, "post-expiry forfeit must not mutate cache");
        }
    }

    // -------------------------------------------------------------------------
    // setAutoDelegate / clearAutoDelegate
    // -------------------------------------------------------------------------

    function test_setAutoDelegate_writesStateAndEmits() public {
        assertEq(delegation.autoDelegate(alice), address(0), "default: no auto-delegate");

        vm.expectEmit(true, true, true, true, address(delegation));
        emit AutoDelegateSet(alice, address(0), bob);

        vm.prank(alice);
        delegation.setAutoDelegate(bob);

        assertEq(delegation.autoDelegate(alice), bob, "auto-delegate stored");
    }

    function test_setAutoDelegate_isIdempotent() public {
        vm.prank(alice);
        delegation.setAutoDelegate(bob);

        // Second identical call must NOT emit (and must not consume a sentinel SSTORE
        // if the implementation short-circuits — verified via vm.recordLogs).
        vm.recordLogs();
        vm.prank(alice);
        delegation.setAutoDelegate(bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 setSig = keccak256("AutoDelegateSet(address,address,address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                !(logs[i].emitter == address(delegation) && logs[i].topics[0] == setSig),
                "no AutoDelegateSet on idempotent call"
            );
        }
    }

    function test_setAutoDelegate_zeroIsEquivalentToClear() public {
        vm.prank(alice);
        delegation.setAutoDelegate(bob);

        vm.expectEmit(true, true, true, true, address(delegation));
        emit AutoDelegateSet(alice, bob, address(0));

        vm.prank(alice);
        delegation.setAutoDelegate(address(0));

        assertEq(delegation.autoDelegate(alice), address(0), "cleared via setAutoDelegate(0)");
    }

    /// @notice clearAutoDelegate emits AutoDelegateSet so indexers can
    ///         reconstruct (account → auto-delegate target) from events.
    function test_clearAutoDelegate_emitsEvent() public {
        vm.prank(alice);
        delegation.setAutoDelegate(bob);

        vm.expectEmit(true, true, true, true, address(delegation));
        emit AutoDelegateSet(alice, bob, address(0));

        vm.prank(alice);
        delegation.clearAutoDelegate();

        assertEq(delegation.autoDelegate(alice), address(0));
    }

    /// @notice clearAutoDelegate must short-circuit (no SSTORE, no event)
    ///         when the caller has no auto-delegate set.
    function test_clearAutoDelegate_isNoopWhenAlreadyZero() public {
        vm.recordLogs();
        vm.prank(alice);
        delegation.clearAutoDelegate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 setSig = keccak256("AutoDelegateSet(address,address,address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                !(logs[i].emitter == address(delegation) && logs[i].topics[0] == setSig),
                "no AutoDelegateSet on already-zero clear"
            );
        }
    }

    /// @notice setAutoDelegate must NOT touch existing positions'
    ///         delegations — the standalone setter only affects FUTURE
    ///         mints / transfers via `_resolveAutoDelegate`.
    function test_setAutoDelegate_doesNotRedelegateExisting() public {
        uint256 tokenId = _createLock(alice, LOCK_AMOUNT, YEAR);
        // Mint defaulted to self-delegation.
        assertEq(delegation.delegation(tokenId).delegatee, alice, "pre: self-delegated");

        vm.prank(alice);
        delegation.setAutoDelegate(bob);

        // Existing position still delegates to alice; only future mints would
        // pick up `bob` via _resolveAutoDelegate.
        assertEq(
            delegation.delegation(tokenId).delegatee, alice, "setAutoDelegate must NOT mutate existing delegations"
        );
    }

    /// @notice After a user calls setAutoDelegate(X), a fresh mint to that
    ///         user must auto-delegate to X (rather than self). This is the
    ///         entire point of the standalone setter — it lets users
    ///         configure their auto-delegate target without iterating
    ///         existing positions.
    function test_setAutoDelegate_freshMintPicksUpTarget() public {
        // Alice has no positions yet — setAutoDelegate is the cheap path.
        vm.prank(alice);
        delegation.setAutoDelegate(bob);
        assertEq(delegation.autoDelegate(alice), bob, "autoDelegate stored");

        // Now mint a position to alice. The mint flow runs
        // _resolveAutoDelegate(alice) which must read autoDelegate[alice]
        // == bob and delegate the new tokenId to bob.
        uint256 tokenId = _createLock(alice, LOCK_AMOUNT, YEAR);

        assertEq(
            delegation.delegation(tokenId).delegatee,
            bob,
            "fresh mint must auto-delegate to alice's chosen target (bob)"
        );

        // A second mint must pick the same target — the autoDelegate is
        // sticky across mints.
        uint256 tokenId2 = _createLock(alice, LOCK_AMOUNT, YEAR);
        assertEq(delegation.delegation(tokenId2).delegatee, bob, "second mint also picks up alice's autoDelegate");

        // After clearAutoDelegate, future mints fall back to self-delegation.
        vm.prank(alice);
        delegation.clearAutoDelegate();
        uint256 tokenId3 = _createLock(alice, LOCK_AMOUNT, YEAR);
        assertEq(delegation.delegation(tokenId3).delegatee, alice, "post-clear mint must self-delegate");
    }

    // -------------------------------------------------------------------------
    // FR2-B4: expiredDelegations slope-change bookkeeping under near-expiry
    //         forfeit. Verifies no double-apply / double-reverse occurs when
    //         a rollover checkpoint lands between delegation creation and
    //         the forfeit cleanup call.
    // -------------------------------------------------------------------------

    /// @notice After rollover materializes alice's expiration, a subsequent
    ///         forfeit MUST be a strict no-op on alice's voting power — the
    ///         expiration weight was already consumed by the rollover and
    ///         the cleanup path must NOT subtract it a second time.
    function test_forfeit_afterRollover_noDoubleSubtractOnAlice() public {
        veHemi.updateForfeitAdmin(owner);

        // Mint a forfeitable lock that ends ~12 days out (2 SIX_DAYS buckets).
        // Self-delegated by default → alice IS the delegatee.
        uint256 SIX_DAYS = YEAR / 60;
        hemi.mint(alice, LOCK_AMOUNT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, 2 * SIX_DAYS, alice, false, true);
        vm.stopPrank();

        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;

        // Warp to JUST BEFORE lockEnd, but past the prior hour boundary so
        // that the rollover's checkpoint timestamp (next hour) lands at or
        // after lockEnd. This makes the rollover walk fold the expiration
        // bucket into the checkpoint. forfeit() requires block.timestamp
        // <= lockEnd, so we stay strictly inside the window.
        vm.warp(lockEnd - 1);

        // Anyone can call. This pushes a new checkpoint whose timestamp
        // is the next hour boundary (>= lockEnd) and whose deltas fold in
        // alice's expiration. The expiredDelegations[alice][lockEnd]
        // bucket entries remain in storage but are now "consumed" by the
        // new checkpoint.
        delegation.writeNewCheckpointForExpiredDelegations(alice);

        // Snapshot alice's votes at block.timestamp = lockEnd - 1.
        // A small residual sliver of bias remains; the forfeit must leave
        // this value unchanged.
        uint256 votesPreForfeit = delegation.getVotes(alice);

        // Now forfeit. forfeit's _checkpointTimestamp is `next hour > now`
        // (>= lockEnd, same boundary the rollover just wrote at). The two
        // guards (`previousDelegation_.end > checkpointTimestamp_` at the
        // bucket subtraction and `previousDelegationEnd_ >
        // checkpointTimestamp_` inside _calculateCheckpoint) MUST both
        // gate-out — neither the expiredDelegations bucket nor the
        // checkpoint deltas should be touched a second time.
        veHemi.forfeit(tokenId);

        // Strict no-op invariant: votes at the current block are unchanged.
        // A double-subtract would underflow (revert) inside
        // _moveVotingPowerFromPreviousDelegate; a phantom add would skew
        // the number upward.
        assertEq(
            delegation.getVotes(alice),
            votesPreForfeit,
            "post-forfeit: votes unchanged - no double-apply on bookkeeping"
        );

        // Cache cleared (defense-in-depth — same property as the existing
        // near-expiry test, but specifically AFTER a rollover).
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenId);
        assertEq(d.delegatee, address(0), "post-forfeit: cache cleared after rollover path");
    }

    /// @notice Symmetric companion: forfeit BEFORE lock-end (so end >
    ///         checkpoint) MUST subtract from expiredDelegations exactly
    ///         once. A subsequent rollover walk that reaches the bucket
    ///         must see zeros (no residual phantom expiration).
    function test_forfeit_beforeRollover_bucketDrainedExactlyOnce() public {
        veHemi.updateForfeitAdmin(owner);

        uint256 SIX_DAYS = YEAR / 60;
        hemi.mint(alice, LOCK_AMOUNT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), LOCK_AMOUNT);
        uint256 tokenId = veHemi.createLockFor(LOCK_AMOUNT, 2 * SIX_DAYS, alice, false, true);
        vm.stopPrank();

        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;

        // Forfeit WHILE the lock is still live (end > now). The cleanup
        // path subtracts from expiredDelegations[alice][lockEnd] and from
        // the running checkpoint deltas.
        vm.warp(lockEnd - 30 minutes);
        veHemi.forfeit(tokenId);

        // Voting power already zero (the only delegated weight was alice's
        // own, which we just removed at the next epoch boundary).
        // Now warp PAST lockEnd. If the bucket retained ANY residual
        // entries, the rollover walk would either revert (underflow) or
        // produce a checkpoint with phantom negative deltas applied to a
        // new delegation arriving in the same bucket. We assert the
        // rollover is a strict no-op: writeNewCheckpointForExpiredDelegations
        // must revert with NoExpirations because the bucket is now empty
        // AND no live checkpoint deltas remain to flip.
        vm.warp(lockEnd + 1 hours);

        // Expect no-expirations revert (alice's bucket is fully drained).
        // If a residual entry leaked through, this call would either
        // succeed (writing a phantom-decrement checkpoint) or revert with
        // an arithmetic underflow — both detectable failures.
        vm.expectRevert(VeHemiVoteDelegation.NoExpirations.selector);
        delegation.writeNewCheckpointForExpiredDelegations(alice);

        assertEq(delegation.getVotes(alice), 0, "alice votes remain 0 after burn + post-end query");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createLock(address account_, uint256 amount_, uint256 duration_) internal returns (uint256 tokenId) {
        hemi.mint(account_, amount_);
        vm.startPrank(account_);
        hemi.approve(address(veHemi), amount_);
        tokenId = veHemi.createLock(amount_, duration_);
        vm.stopPrank();
    }
}

/// @notice Minimal ERC721 receiver used by the contract-recipient transfer test.
contract MinimalERC721Receiver {
    function onERC721Received(address, /* operator */ address, /* from */ uint256, /* tokenId */ bytes calldata /* data */ )
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}

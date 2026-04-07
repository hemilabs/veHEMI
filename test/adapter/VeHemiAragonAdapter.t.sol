// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {VeHemiAragonAdapter, IVotes} from "../../src/adapter/VeHemiAragonAdapter.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VeHemiAragonAdapterTest is Test {
    MockERC20 hemiToken;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;
    VeHemiAragonAdapter adapter;

    address constant ALICE = address(23_984_723_894_798);
    address constant BOB = address(987_654_321);
    address constant CAROL = address(12_345_678);

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MAX_TIME = 4 * YEAR;
    uint256 private constant CHECKPOINT_INTERVAL = 1 hours;
    uint256 private constant SIX_DAYS = YEAR / 60; // same as VeHemiVoteDelegation's SIX_DAYS

    function setUp() public {
        hemiToken = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemiToken));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);

        adapter = new VeHemiAragonAdapter(address(veHemi));
        delegation.setTrustedAdapter(address(adapter));
    }

    function _createLock(address account, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        hemiToken.mint(account, amount);
        vm.startPrank(account);
        hemiToken.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    function _delegateAndWarp(uint256 tokenId, address delegatee) internal {
        address owner_ = veHemi.ownerOf(tokenId);
        vm.prank(owner_);
        delegation.delegate(tokenId, delegatee);
        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor_storesVeHemi() public view {
        assertEq(adapter.veHemi(), address(veHemi));
    }

    function test_constructor_voteDelegationReadsDynamically() public view {
        // voteDelegation() reads from veHemi.voteDelegation() dynamically
        assertEq(adapter.voteDelegation(), address(delegation));
        assertEq(adapter.voteDelegation(), address(veHemi.voteDelegation()));
    }

    function test_constructor_revertsZeroVeHemi() public {
        vm.expectRevert("zero veHemi");
        new VeHemiAragonAdapter(address(0));
    }

    // ─── balanceOf ──────────────────────────────────────────────────────

    function test_balanceOf_zeroForUnknownAddress() public view {
        assertEq(adapter.balanceOf(ALICE), 0);
    }

    function test_balanceOf_returnsTotalLockedHemi() public {
        _createLock(ALICE, 10e18, YEAR);
        assertEq(adapter.balanceOf(ALICE), 10e18);

        _createLock(ALICE, 25e18, YEAR);
        assertEq(adapter.balanceOf(ALICE), 35e18);
    }

    function test_balanceOf_nonZeroAfterDelegation() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);
        assertEq(adapter.balanceOf(ALICE), 10e18, "locked HEMI persists after delegation");
    }

    function test_balanceOf_zeroAfterWithdraw() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        vm.warp(block.timestamp + YEAR + 1);
        vm.prank(ALICE);
        veHemi.withdraw(tokenId);
        assertEq(adapter.balanceOf(ALICE), 0);
    }

    function test_balanceOf_mixedExpiredAndActivePositions() public {
        _createLock(ALICE, 10e18, YEAR);
        _createLock(ALICE, 25e18, 2 * YEAR);

        // Warp past first lock's expiry — HEMI is still locked until withdraw
        vm.warp(block.timestamp + YEAR + 1);

        assertEq(adapter.balanceOf(ALICE), 35e18);
    }

    function test_balanceOf_afterIncreaseAmount() public {
        uint256 tokenId = _createLock(ALICE, 10e18, 2 * YEAR);
        assertEq(adapter.balanceOf(ALICE), 10e18);

        hemiToken.mint(ALICE, 5e18);
        vm.startPrank(ALICE);
        hemiToken.approve(address(veHemi), 5e18);
        veHemi.increaseAmount(tokenId, 5e18);
        vm.stopPrank();

        assertEq(adapter.balanceOf(ALICE), 15e18);
    }

    function test_balanceOf_afterPartialWithdraw() public {
        uint256 tokenId1 = _createLock(ALICE, 10e18, YEAR);
        _createLock(ALICE, 25e18, 2 * YEAR);
        assertEq(adapter.balanceOf(ALICE), 35e18);

        // Warp past first lock expiry and withdraw it
        vm.warp(block.timestamp + YEAR + 1);
        vm.prank(ALICE);
        veHemi.withdraw(tokenId1);

        assertEq(adapter.balanceOf(ALICE), 25e18);
    }

    function testFuzz_balanceOf_randomAmounts(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 10e18, 100_000_000e18);
        amount2 = bound(amount2, 10e18, 100_000_000e18);

        _createLock(ALICE, amount1, YEAR);
        _createLock(ALICE, amount2, 2 * YEAR);

        assertEq(adapter.balanceOf(ALICE), amount1 + amount2);
    }

    function test_balanceOf_matchesManualGetLockedBalanceSum() public {
        _createLock(ALICE, 10e18, YEAR);
        _createLock(ALICE, 25e18, 2 * YEAR);
        _createLock(ALICE, 5e18, YEAR);

        // Manually compute expected by iterating positions
        uint256 count = veHemi.balanceOf(ALICE);
        uint256 expected;
        for (uint256 i; i < count; i++) {
            uint256 tokenId = veHemi.tokenOfOwnerByIndex(ALICE, i);
            int128 amount = veHemi.getLockedBalance(tokenId).amount;
            if (amount > 0) expected += uint128(amount);
        }

        assertEq(adapter.balanceOf(ALICE), expected);
    }

    // ─── getVotes ───────────────────────────────────────────────────────

    function test_getVotes_zeroWithoutDelegation() public {
        _createLock(ALICE, 1e18, YEAR);
        assertEq(adapter.getVotes(ALICE), 0);
    }

    function test_getVotes_nonZeroAfterSelfDelegation() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);
        assertEq(adapter.getVotes(ALICE), delegation.getVotes(ALICE));
        assertGt(adapter.getVotes(ALICE), 0);
    }

    function test_getVotes_matchesDelegation() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, BOB);
        assertEq(adapter.getVotes(BOB), delegation.getVotes(BOB));
        assertEq(adapter.getVotes(ALICE), 0);
    }

    // ─── getPastVotes ───────────────────────────────────────────────────

    function test_getPastVotes_forwardsCorrectly() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        uint256 ts = block.timestamp;
        vm.warp(ts + 1);

        assertEq(adapter.getPastVotes(ALICE, ts), delegation.getPastVotes(ALICE, ts));
        assertGt(adapter.getPastVotes(ALICE, ts), 0);
    }

    function test_getPastVotes_zeroForUnknownAddress() public {
        uint256 ts = block.timestamp;
        vm.warp(ts + 1);
        assertEq(adapter.getPastVotes(ALICE, ts), 0);
    }

    function test_getPastVotes_revertsForFutureTimestamp() public {
        vm.expectRevert(VeHemiVoteDelegation.TimestampInFuture.selector);
        adapter.getPastVotes(ALICE, block.timestamp + 1);
    }

    function test_getPastVotes_snapshotAtTimestampMinusOne() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        // _delegateAndWarp puts us at exactly the epoch boundary where delegation
        // activates. Warp 1 more second so that block.timestamp - 1 = the
        // boundary itself, which includes the active delegation checkpoint.
        vm.warp(block.timestamp + 1);

        // Simulate Aragon's snapshot: block.timestamp - 1
        uint256 snapshot = block.timestamp - 1;
        uint256 power = adapter.getPastVotes(ALICE, snapshot);
        assertEq(power, delegation.getPastVotes(ALICE, snapshot), "adapter must match delegation at snapshot");
        assertGt(power, 0, "voting power at snapshot should be non-zero");
    }

    // ─── getPastTotalSupply ─────────────────────────────────────────────

    function test_getPastTotalSupply_forwardsCorrectly() public {
        _createLock(ALICE, 1e18, YEAR);

        uint256 ts = block.timestamp;
        vm.warp(ts + 1);

        assertEq(adapter.getPastTotalSupply(ts), delegation.getPastTotalSupply(ts));
        assertGt(adapter.getPastTotalSupply(ts), 0);
    }

    function test_getPastTotalSupply_zeroBeforeAnyLocks() public view {
        assertEq(adapter.getPastTotalSupply(0), 0);
    }

    function test_getPastTotalSupply_reflectsMultipleLocks() public {
        _createLock(ALICE, 10e18, YEAR);
        _createLock(BOB, 20e18, 2 * YEAR);

        uint256 ts = block.timestamp;
        vm.warp(ts + 1);

        uint256 totalSupply = adapter.getPastTotalSupply(ts);
        assertGt(totalSupply, 0);
        assertEq(totalSupply, delegation.getPastTotalSupply(ts));
    }

    // ─── clock / CLOCK_MODE ─────────────────────────────────────────────

    function test_clock_returnsBlockTimestamp() public view {
        assertEq(adapter.clock(), uint48(block.timestamp));
    }

    function test_CLOCK_MODE_returnsTimestamp() public view {
        assertEq(adapter.CLOCK_MODE(), "mode=timestamp");
    }

    function test_clockConsistency() public view {
        // Aragon's _detectTokenClock requires these to agree
        bool isTimestampMode = keccak256(bytes(adapter.CLOCK_MODE())) == keccak256(bytes("mode=timestamp"));
        bool clockMatchesTimestamp = adapter.clock() == uint48(block.timestamp);
        assertTrue(isTimestampMode && clockMatchesTimestamp, "clock and CLOCK_MODE must both indicate timestamp");
    }

    // ─── delegates ──────────────────────────────────────────────────────

    function test_delegates_zeroWithNoPositions() public view {
        assertEq(adapter.delegates(ALICE), address(0));
    }

    function test_delegates_returnsDelegateeWhenAllSame() public {
        uint256 tid1 = _createLock(ALICE, 1e18, YEAR);
        uint256 tid2 = _createLock(ALICE, 1e18, YEAR);

        // Both delegated to BOB
        vm.startPrank(ALICE);
        delegation.delegate(tid1, BOB);
        delegation.delegate(tid2, BOB);
        vm.stopPrank();

        assertEq(adapter.delegates(ALICE), BOB);
    }

    function test_delegates_returnsZeroWhenSplitDelegation() public {
        uint256 tid1 = _createLock(ALICE, 1e18, YEAR);
        uint256 tid2 = _createLock(ALICE, 1e18, YEAR);

        // Delegated to different addresses
        vm.startPrank(ALICE);
        delegation.delegate(tid1, BOB);
        delegation.delegate(tid2, CAROL);
        vm.stopPrank();

        assertEq(adapter.delegates(ALICE), address(0));
    }

    function test_delegates_returnsSelfWhenSelfDelegated() public {
        // createLock auto-delegates to the owner
        _createLock(ALICE, 1e18, YEAR);
        assertEq(adapter.delegates(ALICE), ALICE);
    }

    // ─── delegate ───────────────────────────────────────────────────────

    function test_delegate_delegatesAllPositions() public {
        uint256 tid1 = _createLock(ALICE, 5e18, YEAR);
        uint256 tid2 = _createLock(ALICE, 10e18, 2 * YEAR);

        // ALICE delegates all to BOB via the adapter
        vm.prank(ALICE);
        adapter.delegate(BOB);

        // Both positions should now be delegated to BOB
        assertEq(adapter.delegates(ALICE), BOB);
        assertEq(delegation.delegation(tid1).delegatee, BOB);
        assertEq(delegation.delegation(tid2).delegatee, BOB);

        // After epoch boundary, BOB should have voting power
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch);
        assertEq(adapter.getVotes(BOB), delegation.getVotes(BOB));
        assertGt(adapter.getVotes(BOB), 0);
    }

    function test_delegate_reDelegateAll() public {
        _createLock(ALICE, 5e18, YEAR);
        _createLock(ALICE, 10e18, 2 * YEAR);

        // Delegate all to BOB, then re-delegate all to CAROL
        vm.prank(ALICE);
        adapter.delegate(BOB);
        assertEq(adapter.delegates(ALICE), BOB);

        vm.prank(ALICE);
        adapter.delegate(CAROL);
        assertEq(adapter.delegates(ALICE), CAROL);
    }

    // ─── auto-delegate ───────────────────────────────────────────────────

    function test_autoDelegate_newLockUsesAutoDelegate() public {
        // ALICE delegates all to BOB via adapter
        _createLock(ALICE, 5e18, YEAR);
        vm.prank(ALICE);
        adapter.delegate(BOB);
        assertEq(adapter.delegates(ALICE), BOB);

        // ALICE creates a NEW lock — it should auto-delegate to BOB
        _createLock(ALICE, 10e18, 2 * YEAR);

        // Both old and new locks should be delegated to BOB
        assertEq(adapter.delegates(ALICE), BOB, "new lock should auto-delegate to BOB");
    }

    function test_autoDelegate_newLockSelfDelegatesWithoutAutoDelegate() public {
        // autoDelegate should default to address(0) for any account
        assertEq(delegation.autoDelegate(ALICE), address(0), "autoDelegate should default to zero");

        // ALICE creates a lock without ever calling adapter.delegate
        _createLock(ALICE, 5e18, YEAR);

        // Should self-delegate (no autoDelegate set)
        assertEq(adapter.delegates(ALICE), ALICE);

        // Create another lock — should also self-delegate
        _createLock(ALICE, 10e18, 2 * YEAR);
        assertEq(adapter.delegates(ALICE), ALICE);
    }

    function test_autoDelegate_transferUsesRecipientAutoDelegate() public {
        // BOB delegates all to CAROL via adapter
        uint256 tid1 = _createLock(BOB, 5e18, YEAR);
        vm.prank(BOB);
        adapter.delegate(CAROL);

        // ALICE creates a transferable lock and transfers it to BOB
        uint256 tid2 = _createLock(ALICE, 10e18, 2 * YEAR);
        vm.prank(ALICE);
        veHemi.transferFrom(ALICE, BOB, tid2);

        // The transferred NFT should auto-delegate to CAROL (BOB's autoDelegate)
        assertEq(delegation.delegation(tid2).delegatee, CAROL, "transferred NFT should use recipient's autoDelegate");
    }

    function test_autoDelegate_reDelegateUpdatesAutoDelegate() public {
        _createLock(ALICE, 5e18, YEAR);

        // Delegate all to BOB
        vm.prank(ALICE);
        adapter.delegate(BOB);
        assertEq(delegation.autoDelegate(ALICE), BOB);

        // Re-delegate all to CAROL
        vm.prank(ALICE);
        adapter.delegate(CAROL);
        assertEq(delegation.autoDelegate(ALICE), CAROL);

        // New lock should go to CAROL
        _createLock(ALICE, 10e18, 2 * YEAR);
        assertEq(adapter.delegates(ALICE), CAROL);
    }

    // ─── Event relay (Aragon subgraph compatibility) ──────────────────

    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    // --- DelegateVotesChanged relay ---

    function test_relay_delegateVotesChanged_viaAdapter() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        // Record logs to verify the actual event data (not just the indexed topic)
        vm.recordLogs();
        vm.prank(ALICE);
        adapter.delegate(BOB);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool foundBobOnAdapter;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == BOB) {
                    // BOB had 0 votes before, should have > 0 after
                    assertEq(prev, 0, "BOB previousVotes should be 0");
                    assertGt(newV, 0, "BOB newVotes should be > 0");
                    foundBobOnAdapter = true;
                }
            }
        }
        assertTrue(foundBobOnAdapter, "DelegateVotesChanged for BOB must be emitted from adapter");
    }

    function test_relay_delegateVotesChanged_perTokenDirect() public {
        // Per-token delegation bypassing the adapter should STILL relay
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        vm.recordLogs();
        vm.prank(ALICE);
        delegation.delegate(tokenId, BOB);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool foundBobOnAdapter;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == BOB) {
                    assertEq(prev, 0, "BOB previousVotes should be 0");
                    assertGt(newV, 0, "BOB newVotes should be > 0");
                    foundBobOnAdapter = true;
                }
            }
        }
        assertTrue(foundBobOnAdapter, "DelegateVotesChanged for BOB must be relayed from adapter");
    }

    function test_relay_delegateVotesChanged_onCreateLock() public {
        // createLock auto-delegates, which should relay DelegateVotesChanged from adapter
        vm.recordLogs();
        _createLock(ALICE, 10e18, YEAR);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        uint256 adapterEmitCount;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                adapterEmitCount++;
            }
        }
        assertGt(adapterEmitCount, 0, "createLock must relay DelegateVotesChanged through adapter");
    }

    function test_relay_noFireWhenAdapterNotSet() public {
        // Deploy a fresh delegation without setting trustedAdapter
        VeHemiVoteDelegation freshDelegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(freshDelegation);
        assertEq(freshDelegation.trustedAdapter(), address(0), "trustedAdapter should default to zero");

        // Record logs — no DelegateVotesChanged should come from the adapter
        vm.recordLogs();
        _createLock(ALICE, 10e18, YEAR);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        uint256 adapterEmitCount;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                adapterEmitCount++;
            }
        }
        assertEq(adapterEmitCount, 0, "no relay events should fire when trustedAdapter is address(0)");
    }

    function test_relay_survivesAdapterRevert() public {
        // Deploy a contract that always reverts on notifyVotesChanged
        RevertingAdapter bad = new RevertingAdapter();
        delegation.setTrustedAdapter(address(bad));

        // Delegation should still succeed despite relay reverting
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        vm.prank(ALICE);
        delegation.delegate(tokenId, BOB);
        // No revert — try/catch handled it
        // Verify the delegation actually took effect despite relay failure
        assertEq(delegation.delegation(tokenId).delegatee, BOB, "delegation must succeed despite relay revert");
    }

    function test_relay_notifyVotesChanged_revertsUnauthorized() public {
        vm.prank(ALICE);
        vm.expectRevert("unauthorized");
        adapter.notifyVotesChanged(BOB, 0, 100);
    }

    // --- DelegateChanged relay ---

    function test_relay_delegateChanged_viaAdapter() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        // DelegateChanged with address-based IVotes signature from adapter
        vm.expectEmit(true, true, true, false, address(adapter));
        emit DelegateChanged(ALICE, ALICE, BOB);

        vm.prank(ALICE);
        adapter.delegate(BOB);
    }

    function test_relay_delegateChanged_perTokenDirect() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        vm.expectEmit(true, true, true, false, address(adapter));
        emit DelegateChanged(ALICE, ALICE, BOB);

        vm.prank(ALICE);
        delegation.delegate(tokenId, BOB);
    }

    function test_relay_notifyDelegateChanged_revertsUnauthorized() public {
        vm.prank(ALICE);
        vm.expectRevert("unauthorized");
        adapter.notifyDelegateChanged(ALICE, address(0), BOB);
    }

    // --- writeNewCheckpointForExpiredDelegations relay ---

    function test_relay_writeExpiredCheckpointEmitsAndRelays() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);

        // Warp past lock expiry
        vm.warp(block.timestamp + YEAR + 1);

        // writeNewCheckpointForExpiredDelegations should emit + relay
        // DelegateVotesChanged for BOB with the correct (zero) power
        vm.recordLogs();
        delegation.writeNewCheckpointForExpiredDelegations(BOB);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool foundOnAdapter;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(delegate_, BOB, "event should be for BOB");
                assertEq(prev, newV, "previousVotes should equal newVotes");
                // Both should be 0 since the only delegation fully expired
                assertEq(newV, 0, "power should be 0 after full expiry");
                foundOnAdapter = true;
            }
        }
        assertTrue(foundOnAdapter, "DelegateVotesChanged must be relayed from adapter");
    }

    function test_relay_writeExpiredCheckpoint_emitsCorrectValues() public {
        // Two delegations to BOB: ALICE's expires after 1 year, CAROL's after 3 years.
        // writeNewCheckpointForExpiredDelegations is a gas optimization — it bakes
        // expired delegations into the checkpoint so future queries don't need to
        // re-compute them. The visible voting power doesn't change (since
        // _getDelegateVotesAt already calculates expirations on-the-fly), so
        // previousVotes == newVotes is expected.
        uint256 aliceToken = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(aliceToken, BOB);
        uint256 carolToken = _createLock(CAROL, 10e18, 3 * YEAR);
        _delegateAndWarp(carolToken, BOB);

        // Warp past ALICE's lock expiry but not CAROL's
        vm.warp(block.timestamp + YEAR + 30 days);

        // Record the events
        vm.recordLogs();
        delegation.writeNewCheckpointForExpiredDelegations(BOB);

        // Verify the DelegateVotesChanged event is emitted from both delegation and adapter
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        uint256 emitCount;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == dvcSig) {
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                // Both values should equal — the checkpoint write doesn't change visible power
                assertEq(prev, newV, "previousVotes should equal newVotes (gas optimization only)");
                // CAROL's delegation is still active, so power should be > 0
                assertGt(prev, 0, "BOB should still have voting power from CAROL");
                emitCount++;
            }
        }
        // One from delegation contract, one from adapter relay
        assertEq(emitCount, 2, "should emit from both delegation and adapter");
    }

    // ─── delegate with expired locks ───────────────────────────────────

    function test_delegate_skipsExpiredLocks() public {
        // Create two locks: one that expires soon, one that lasts long
        uint256 shortTid = _createLock(ALICE, 5e18, 2 * SIX_DAYS); // minimum duration (~12 days)
        uint256 longTid = _createLock(ALICE, 10e18, 2 * YEAR);

        // Warp past the short lock's expiry (but not the long one)
        vm.warp(block.timestamp + SIX_DAYS * 3); // ~18 days

        // ALICE should still be able to delegate via adapter even though
        // one lock has expired. Without the fix, this would revert with
        // CanNotDelegateExpiredLocks.
        vm.prank(ALICE);
        adapter.delegate(BOB);

        // The long lock should be delegated to BOB
        assertEq(delegation.delegation(longTid).delegatee, BOB, "active lock should be delegated");

        // autoDelegate should be set for future locks
        assertEq(delegation.autoDelegate(ALICE), BOB, "autoDelegate should be set");
    }

    function test_delegate_allExpiredLocks_setsAutoDelegate() public {
        // Create a short lock
        _createLock(ALICE, 5e18, 2 * SIX_DAYS);

        // Warp past expiry
        vm.warp(block.timestamp + SIX_DAYS * 3);

        // All locks expired — delegate should still succeed (no-op loop, but autoDelegate set)
        vm.prank(ALICE);
        adapter.delegate(BOB);

        assertEq(delegation.autoDelegate(ALICE), BOB, "autoDelegate should be set even with all expired locks");
    }

    // ─── delegateBySig ──────────────────────────────────────────────────

    function test_delegateBySig_reverts() public {
        vm.expectRevert("Use VeHemiVoteDelegation.delegateBySig");
        adapter.delegateBySig(ALICE, 0, 0, 0, bytes32(0), bytes32(0));
    }

    // ─── ERC-165 ────────────────────────────────────────────────────────

    function test_supportsInterface_IERC165() public view {
        assertTrue(adapter.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_IVotes() public view {
        bytes4 ivotesId = type(IVotes).interfaceId;
        assertTrue(adapter.supportsInterface(ivotesId));
    }

    function test_supportsInterface_IVotes_matchesManualComputation() public pure {
        bytes4 manual = bytes4(keccak256("getVotes(address)"))
            ^ bytes4(keccak256("getPastVotes(address,uint256)"))
            ^ bytes4(keccak256("getPastTotalSupply(uint256)"))
            ^ bytes4(keccak256("delegates(address)"))
            ^ bytes4(keccak256("delegate(address)"))
            ^ bytes4(keccak256("delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertEq(type(IVotes).interfaceId, manual);
    }

    function test_supportsInterface_falseForRandom() public view {
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    function test_supportsInterface_falseForZero() public view {
        assertFalse(adapter.supportsInterface(0xffffffff));
    }

    // ─── Metadata ───────────────────────────────────────────────────────

    function test_name() public view {
        assertEq(adapter.name(), "veHEMI Votes");
    }

    function test_symbol() public view {
        assertEq(adapter.symbol(), "veHEMI");
    }

    function test_decimals() public view {
        assertEq(adapter.decimals(), 18, "adapter.decimals() must return 18 for Aragon compatibility");
    }

    // ─── Integration: multiple users ────────────────────────────────────

    function test_multipleUsers_votingPower() public {
        uint256 tokenId1 = _createLock(ALICE, 1e18, YEAR);
        uint256 tokenId2 = _createLock(BOB, 2e18, 2 * YEAR);

        _delegateAndWarp(tokenId1, ALICE);

        vm.prank(BOB);
        delegation.delegate(tokenId2, BOB);
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch);

        assertEq(adapter.getVotes(ALICE), delegation.getVotes(ALICE));
        assertEq(adapter.getVotes(BOB), delegation.getVotes(BOB));
        assertGt(adapter.getVotes(ALICE), 0);
        assertGt(adapter.getVotes(BOB), 0);
        // BOB locked 2x amount for 2x duration → significantly more voting power
        assertGt(adapter.getVotes(BOB), adapter.getVotes(ALICE));
    }

    function test_delegateToThirdParty() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, CAROL);

        assertEq(adapter.getVotes(ALICE), 0);
        assertEq(adapter.getVotes(CAROL), delegation.getVotes(CAROL));
        assertGt(adapter.getVotes(CAROL), 0);
        // CAROL has voting power but no NFT
        assertEq(adapter.balanceOf(CAROL), 0);
    }

    function test_isMember_pattern() public {
        // Aragon's isMember: balanceOf > 0 || getVotes > 0
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);

        // Before delegation: ALICE is member via balanceOf, not getVotes
        assertTrue(adapter.balanceOf(ALICE) > 0);
        assertEq(adapter.getVotes(ALICE), 0);

        // After delegation to BOB: ALICE still member (owns NFT), BOB also member (has votes)
        _delegateAndWarp(tokenId, BOB);
        assertTrue(adapter.balanceOf(ALICE) > 0 || adapter.getVotes(ALICE) > 0);
        assertTrue(adapter.balanceOf(BOB) > 0 || adapter.getVotes(BOB) > 0);
    }

    function test_votingPowerDecaysOverTime() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        uint256 powerNow = adapter.getVotes(ALICE);

        // Warp 6 months forward
        vm.warp(block.timestamp + YEAR / 2);
        uint256 powerLater = adapter.getVotes(ALICE);

        assertGt(powerNow, powerLater, "voting power should decay over time");
        assertGt(powerLater, 0, "voting power should not be zero yet");
    }

    // ─── Hourly checkpoint boundary precision ───────────────────────────

    function test_hourlyCheckpointBoundaryPrecision() public {
        // 1. Create a lock for ALICE
        _createLock(ALICE, 10e18, 2 * YEAR);

        // 2. Delegate ALICE's token to BOB via the adapter
        vm.prank(ALICE);
        adapter.delegate(BOB);

        // 3. Compute the next epoch boundary
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;

        // 4. Warp to one second before the boundary
        vm.warp(nextEpoch - 1);

        // 5. Delegation not yet active: checkpoint timestamp (nextEpoch) > query timestamp (nextEpoch - 1)
        assertEq(adapter.getVotes(BOB), 0, "getVotes must be 0 one second before epoch boundary");
        // 6. getPastVotes also returns 0 before the boundary
        assertEq(adapter.getPastVotes(BOB, block.timestamp), 0, "getPastVotes must be 0 one second before epoch boundary");

        // 7. Warp to exactly the epoch boundary
        vm.warp(nextEpoch);

        // 8. Delegation now active: checkpoint timestamp (nextEpoch) == query timestamp (nextEpoch)
        assertGt(adapter.getVotes(BOB), 0, "getVotes must be > 0 at epoch boundary");
        // 9. getPastVotes also returns > 0 at the boundary
        assertGt(adapter.getPastVotes(BOB, block.timestamp), 0, "getPastVotes must be > 0 at epoch boundary");
    }

    // ─── CRITICAL: balanceOf with expired but unwithdrawn locks ─────────

    function test_balanceOf_nonZeroForExpiredButUnwithdrawnLock() public {
        // A user who created a lock that has expired but hasn't called withdraw()
        // still has HEMI locked. Aragon uses balanceOf > 0 for isMember, so this
        // user should still be considered a "member" even though their voting
        // power has decayed to zero.
        _createLock(ALICE, 10e18, YEAR);

        // Warp past lock expiry
        vm.warp(block.timestamp + YEAR + 1);

        // The lock is expired, but ALICE hasn't withdrawn — HEMI is still locked
        assertEq(adapter.balanceOf(ALICE), 10e18, "balanceOf should show locked HEMI for expired but unwithdrawn lock");

        // Voting power should be zero (lock expired, power fully decayed)
        assertEq(adapter.getVotes(ALICE), 0, "getVotes should be 0 for expired lock without delegation");

        // Aragon's isMember pattern: balanceOf > 0 || getVotes > 0
        // ALICE is still a member via balanceOf (locked HEMI > 0)
        assertTrue(
            adapter.balanceOf(ALICE) > 0 || adapter.getVotes(ALICE) > 0,
            "expired-but-unwithdrawn user should still be isMember"
        );
    }

    // ─── CRITICAL: getVotes/getPastVotes after delegation expiry ────────

    function test_getVotes_zeroAfterDelegationExpiry() public {
        // When a delegation expires (the delegator's lock ends), the delegatee's
        // voting power from that delegation must drop to zero. If it doesn't,
        // we have vote inflation.
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);

        // BOB should have votes now
        uint256 votesBefore = adapter.getVotes(BOB);
        assertGt(votesBefore, 0, "BOB should have delegated votes before expiry");

        // Warp past the lock expiry (delegation expires when the lock expires)
        vm.warp(block.timestamp + YEAR + 1);

        // BOB's delegated votes must be zero — the delegation has expired
        uint256 votesAfter = adapter.getVotes(BOB);
        assertEq(votesAfter, 0, "BOB should have zero votes after delegation expiry (vote inflation check)");
    }

    function test_getPastVotes_zeroAfterDelegationExpiry() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);

        uint256 tsBeforeExpiry = block.timestamp;

        // Warp past lock expiry
        vm.warp(block.timestamp + YEAR + 1);

        uint256 tsAfterExpiry = block.timestamp;
        vm.warp(tsAfterExpiry + 1); // move 1 second ahead so we can query tsAfterExpiry

        // getPastVotes before expiry should be non-zero
        uint256 pastVotesBeforeExpiry = adapter.getPastVotes(BOB, tsBeforeExpiry);
        assertGt(pastVotesBeforeExpiry, 0, "getPastVotes before expiry should be non-zero");

        // getPastVotes after expiry should be zero
        uint256 pastVotesAfterExpiry = adapter.getPastVotes(BOB, tsAfterExpiry);
        assertEq(pastVotesAfterExpiry, 0, "getPastVotes after expiry should be zero (vote inflation check)");
    }

    // ─── CRITICAL: getPastTotalSupply at block.timestamp - 1 ────────────

    function test_getPastTotalSupply_atTimestampMinusOne() public {
        // Aragon's TokenVoting snapshots voting power at block.timestamp - 1.
        // This test verifies that getPastTotalSupply works correctly at that
        // specific offset, which is the actual pattern used in production.
        _createLock(ALICE, 10e18, YEAR);
        _createLock(BOB, 20e18, 2 * YEAR);

        // Advance time so we have a valid past timestamp
        vm.warp(block.timestamp + 1);

        // Simulate Aragon's snapshot pattern: block.timestamp - 1
        uint256 snapshot = block.timestamp - 1;
        uint256 totalSupply = adapter.getPastTotalSupply(snapshot);
        assertGt(totalSupply, 0, "getPastTotalSupply at timestamp-1 should be non-zero");
        assertEq(
            totalSupply,
            delegation.getPastTotalSupply(snapshot),
            "getPastTotalSupply at timestamp-1 should match delegation contract"
        );
    }

    // ─── HIGH: getVotes with multiple delegated NFTs from different users ─

    function test_getVotes_withMultipleDelegationsFromDifferentUsers() public {
        // When multiple users delegate their NFTs to the same delegatee,
        // the delegatee's voting power should aggregate correctly.
        uint256 tokenId1 = _createLock(ALICE, 10e18, YEAR);
        uint256 tokenId2 = _createLock(BOB, 20e18, 2 * YEAR);

        // Both ALICE and BOB delegate to CAROL
        _delegateAndWarp(tokenId1, CAROL);

        vm.prank(BOB);
        delegation.delegate(tokenId2, CAROL);
        // Advance to next epoch boundary so BOB's delegation is active
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch);

        // CAROL should have votes from both delegations
        uint256 carolVotes = adapter.getVotes(CAROL);
        assertEq(carolVotes, delegation.getVotes(CAROL), "adapter must match delegation for CAROL");
        assertGt(carolVotes, 0, "CAROL should have aggregated votes from multiple delegators");

        // CAROL's votes should be more than what either delegation alone would provide.
        // We can verify by checking that CAROL has more than ALICE's individual contribution.
        // Create a separate lock for comparison: delegate only from a fresh user with same params as ALICE
        uint256 tokenId3 = _createLock(address(0xBEEF), 10e18, YEAR);
        vm.prank(address(0xBEEF));
        delegation.delegate(tokenId3, address(0xCAFE));
        uint256 nextEpoch2 = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch2);

        uint256 singleDelegationVotes = adapter.getVotes(address(0xCAFE));
        assertGt(carolVotes, singleDelegationVotes, "aggregated votes should exceed single delegation");

        // ALICE and BOB should have zero votes (they delegated away)
        assertEq(adapter.getVotes(ALICE), 0, "ALICE should have zero votes after delegating");
        assertEq(adapter.getVotes(BOB), 0, "BOB should have zero votes after delegating");

        // CAROL has no locked HEMI
        assertEq(adapter.balanceOf(CAROL), 0, "CAROL should have no locked HEMI");
    }

    // ─── HIGH: getPastTotalSupply reverts for future timestamp ──────────

    function test_getPastTotalSupply_revertsForFutureTimestamp() public {
        vm.expectRevert(VeHemiVoteDelegation.TimestampInFuture.selector);
        adapter.getPastTotalSupply(block.timestamp + 1);
    }

    // ─── HIGH: Constructor with non-contract addresses ──────────────────

    function test_constructor_withNonContractAddress() public {
        // The adapter constructor does not check for code at the provided address.
        // It only checks for address(0). A non-contract address (EOA) will be
        // accepted, but calls to it will revert at runtime.
        address fakeVeHemi = address(0xDEAD);

        VeHemiAragonAdapter badAdapter = new VeHemiAragonAdapter(fakeVeHemi);

        assertEq(badAdapter.veHemi(), fakeVeHemi, "should store non-contract veHemi address");

        // balanceOf reverts because fakeVeHemi is an EOA (no code)
        vm.expectRevert();
        badAdapter.balanceOf(ALICE);

        // voteDelegation() reverts because fakeVeHemi has no voteDelegation() function
        vm.expectRevert();
        badAdapter.voteDelegation();

        // getVotes reverts because voteDelegation() on the EOA reverts first
        vm.expectRevert();
        badAdapter.getVotes(ALICE);

        // clock() also reverts
        vm.expectRevert();
        badAdapter.clock();
    }

    // ─── HIGH: Fuzz test for getPastVotes with random timestamps ────────

    function testFuzz_getPastVotes_randomTimestamps(uint256 queryOffset) public {
        // Create a lock and delegate so there is actual voting power to query
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        uint256 delegationActiveTime = block.timestamp;

        // Warp forward a substantial amount so we have a wide range to query
        vm.warp(delegationActiveTime + YEAR / 2);

        // Bound the query offset to be within the valid range:
        // [delegationActiveTime, block.timestamp - 1]
        // We need block.timestamp > queryTs for getPastVotes to not revert
        uint256 rangeSize = block.timestamp - delegationActiveTime;
        queryOffset = bound(queryOffset, 0, rangeSize - 1);
        uint256 queryTs = delegationActiveTime + queryOffset;

        // Should not revert for any valid past timestamp
        uint256 power = adapter.getPastVotes(ALICE, queryTs);

        // Adapter result must match delegation contract
        assertEq(
            power,
            delegation.getPastVotes(ALICE, queryTs),
            "fuzz: getPastVotes must match delegation contract"
        );

        // veHemi voting power = amount * remaining_time / MAX_TIME
        // Maximum is at delegation activation: 10e18 * YEAR / MAX_TIME = ~2.5e18
        // Add 1e18 buffer for rounding
        uint256 maxExpectedPower = (10e18 * YEAR) / MAX_TIME + 1e18;
        assertLe(power, maxExpectedPower, "fuzz: voting power should not exceed theoretical max");
    }

    // ─── CRITICAL: Access Control ──────────────────────────────────────

    // 1. setTrustedAdapter called by non-owner must revert NotVeHemiOwner

    function test_setTrustedAdapter_revertsForNonOwner() public {
        // ALICE is not the veHemi owner (address(this) is the owner from setUp)
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        delegation.setTrustedAdapter(address(0xBAD));
    }

    function test_setTrustedAdapter_succeedsForOwner() public {
        // address(this) is the veHemi owner (set in setUp via initialize)
        address oldAdapter = delegation.trustedAdapter();
        address newAdapter = address(0xADA);

        vm.expectEmit(true, true, false, true);
        emit IVeHemiVoteDelegation.TrustedAdapterUpdated(oldAdapter, newAdapter);

        delegation.setTrustedAdapter(newAdapter);
        assertEq(delegation.trustedAdapter(), newAdapter, "owner should be able to set trusted adapter");
    }

    // 2. delegateAllFor called by non-trusted adapter must revert NotTrustedAdapter

    function test_delegateAllFor_revertsForNonTrustedAdapter() public {
        _createLock(ALICE, 1e18, YEAR);

        // BOB is not the trusted adapter
        vm.prank(BOB);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(ALICE, CAROL);
    }

    function test_delegateAllFor_revertsForEOA() public {
        _createLock(ALICE, 1e18, YEAR);

        // Even the veHemi owner cannot call delegateAllFor directly
        // (address(this) is the owner, but only the trustedAdapter may call it)
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(ALICE, BOB);
    }

    function test_delegateAllFor_revertsForPreviousTrustedAdapter() public {
        _createLock(ALICE, 1e18, YEAR);

        // Replace the trusted adapter with a new one
        address newAdapter = address(0xADA);
        delegation.setTrustedAdapter(newAdapter);

        // The old adapter should no longer be authorized
        vm.prank(address(adapter));
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(ALICE, BOB);
    }

    // 3. delegate(address(0)) through the adapter must revert InvalidDelegatee

    function test_delegate_zeroAddressViaAdapter_reverts() public {
        _createLock(ALICE, 1e18, YEAR);

        // Delegating to address(0) via the adapter calls delegateAllFor,
        // which calls _delegate with delegatee_=address(0).
        // _delegate reverts because msg.sender (the adapter) != address(veHemi).
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.InvalidDelegatee.selector);
        adapter.delegate(address(0));
    }

    // 4. setTrustedAdapter when veHemi.owner() is address(0) (ownership renounced)

    function test_setTrustedAdapter_revertsWhenOwnershipRenounced() public {
        // Renounce ownership: transfer to address(0) is not possible with
        // Ownable2Step, but we can simulate it by having the owner call
        // renounceOwnership(). After that, owner() == address(0), and
        // _veHemiOwner() returns address(0). No one can match msg.sender == address(0).
        veHemi.renounceOwnership();

        // Now even the previous owner (address(this)) cannot set the adapter
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        delegation.setTrustedAdapter(address(0xBAD));

        // And nobody else can either
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        delegation.setTrustedAdapter(address(0xBAD));
    }

    // 5. setTrustedAdapter to address(0) disables delegateAllFor

    function test_setTrustedAdapter_toZeroDisablesDelegateAllFor() public {
        // Start with a working adapter (from setUp)
        _createLock(ALICE, 1e18, YEAR);

        // Verify adapter works
        vm.prank(ALICE);
        adapter.delegate(BOB);
        assertEq(adapter.delegates(ALICE), BOB);

        // Disable the adapter by setting trustedAdapter to address(0)
        delegation.setTrustedAdapter(address(0));

        // Now the adapter cannot delegate
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        adapter.delegate(CAROL);
    }

    // 5b. Full lifecycle: create lock -> delegate -> disable adapter -> deploy new -> re-enable

    function test_setTrustedAdapter_fullLifecycle() public {
        // 1. Create a lock for ALICE
        _createLock(ALICE, 10e18, 2 * YEAR);

        // 2. Verify delegation works via the current adapter
        vm.prank(ALICE);
        adapter.delegate(BOB);
        assertEq(adapter.delegates(ALICE), BOB, "ALICE should be delegated to BOB via original adapter");

        // 3. Owner disables the adapter by setting trustedAdapter to address(0)
        delegation.setTrustedAdapter(address(0));

        // 4. Verify the old adapter can no longer delegate
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        adapter.delegate(CAROL);

        // 5. Deploy a NEW adapter
        VeHemiAragonAdapter newAdapter = new VeHemiAragonAdapter(address(veHemi));

        // 6. Owner sets the new adapter as trusted
        delegation.setTrustedAdapter(address(newAdapter));
        assertEq(delegation.trustedAdapter(), address(newAdapter), "trustedAdapter should be the new adapter");

        // 7. Verify delegation works via the new adapter
        vm.prank(ALICE);
        newAdapter.delegate(CAROL);
        assertEq(newAdapter.delegates(ALICE), CAROL, "ALICE should be delegated to CAROL via new adapter");

        // 8. Verify the OLD adapter can no longer delegate (it is no longer trusted)
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        adapter.delegate(BOB);
    }

    // 6. delegateAllFor with spoofed owner_ parameter

    function test_delegateAllFor_cannotSpoofOwner() public {
        // ALICE has a lock
        _createLock(ALICE, 1e18, YEAR);

        // The adapter correctly passes msg.sender as owner_ in delegate().
        // But what if a malicious contract calls delegateAllFor directly
        // with a spoofed owner? Only the trustedAdapter can call it.
        vm.prank(BOB);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(ALICE, BOB);
    }

    // 7. Fuzz: setTrustedAdapter reverts for any non-owner caller

    function testFuzz_setTrustedAdapter_revertsForNonOwner(address caller) public {
        // address(this) is the owner
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        delegation.setTrustedAdapter(address(0xBAD));
    }

    // 8. Fuzz: delegateAllFor reverts for any non-trusted-adapter caller

    function testFuzz_delegateAllFor_revertsForNonTrustedAdapter(address caller) public {
        vm.assume(caller != address(adapter));
        _createLock(ALICE, 1e18, YEAR);

        vm.prank(caller);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(ALICE, BOB);
    }

    // ─── totalSupply ────────────────────────────────────────────────────

    function test_totalSupply_returnsWeightedVeHemiSupply() public {
        _createLock(ALICE, 10e18, YEAR);
        _createLock(BOB, 20e18, 2 * YEAR);

        uint256 adapterSupply = adapter.totalSupply();

        // Must equal the veHEMI weighted supply, NOT the ERC721 NFT count
        assertEq(adapterSupply, veHemi.totalVeHemiSupply());
        assertGt(adapterSupply, 0);
        // The NFT count is 2, but the weighted supply should be much larger
        assertGt(adapterSupply, 2, "totalSupply must return weighted supply, not NFT count");
    }

    function test_totalSupply_zeroWithNoLocks() public view {
        assertEq(adapter.totalSupply(), 0);
    }

    // ─── NFT transfer relay event ───────────────────────────────────────

    function test_relay_firedOnNFTTransfer() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        vm.recordLogs();
        vm.prank(ALICE);
        veHemi.transferFrom(ALICE, BOB, tokenId);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bytes32 dcSig = keccak256("DelegateChanged(address,address,address)");

        uint256 adapterDvcCount;
        uint256 adapterDcCount;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter)) {
                if (entries[i].topics[0] == dvcSig) adapterDvcCount++;
                if (entries[i].topics[0] == dcSig) adapterDcCount++;
            }
        }
        assertGt(adapterDvcCount, 0, "transfer should relay DelegateVotesChanged through adapter");
        assertGt(adapterDcCount, 0, "transfer should relay DelegateChanged through adapter");
    }

    // ─── voteDelegation dynamic follow ──────────────────────────────────

    function test_voteDelegation_followsUpdate() public {
        // Create a lock and delegate on the initial delegation contract
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);
        assertEq(adapter.getVotes(ALICE), delegation.getVotes(ALICE));
        assertGt(adapter.getVotes(ALICE), 0);
        assertEq(adapter.voteDelegation(), address(delegation));

        // Deploy a NEW delegation contract and update veHemi to use it
        VeHemiVoteDelegation newDelegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(newDelegation);

        // The adapter should now read from the NEW delegation contract
        assertEq(adapter.voteDelegation(), address(newDelegation));

        // getVotes should reflect the new delegation (which has no checkpoints)
        assertEq(adapter.getVotes(ALICE), 0, "new delegation has no checkpoints");

        // Set up trustedAdapter on the new delegation and delegate
        newDelegation.setTrustedAdapter(address(adapter));
        vm.prank(ALICE);
        newDelegation.delegate(tokenId, ALICE);
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch);

        assertGt(adapter.getVotes(ALICE), 0, "adapter should read from the new delegation");
    }

    // ─── supportsInterface IERC6372 ─────────────────────────────────────

    function test_supportsInterface_IERC6372() public view {
        // IERC6372 = clock() ^ CLOCK_MODE() = 0xda287a1d
        assertTrue(adapter.supportsInterface(0xda287a1d));
    }

    // ─── refreshVotingPower ─────────────────────────────────────────────

    function test_refreshVotingPower_emitsCorrectEvent() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);

        vm.prank(ALICE);
        delegation.delegate(tokenId, ALICE);
        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);

        // refreshVotingPower uses the checkpoint timestamp (next-epoch boundary),
        // consistent with delegation events. Verify via log inspection since
        // the checkpoint timestamp is in the future and getPastVotes reverts.
        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == ALICE) {
                    assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                    assertGt(newV, 0, "ALICE should have voting power");
                    // The checkpoint timestamp is in the future, so MORE decay => value <= getVotes
                    // (voting power = normalizedBias - slope * timestamp)
                    assertLe(newV, delegation.getVotes(ALICE), "checkpoint votes <= current votes (more decay at future ts)");
                    found = true;
                }
            }
        }
        assertTrue(found, "DelegateVotesChanged must be emitted from adapter");
    }

    function test_refreshVotingPower_zeroForUnknownAddress() public {
        vm.expectEmit(true, false, false, true, address(adapter));
        emit DelegateVotesChanged(address(0xdead), 0, 0);
        adapter.refreshVotingPower(address(0xdead));
    }

    function test_refreshVotingPower_permissionless() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);

        vm.prank(ALICE);
        delegation.delegate(tokenId, ALICE);
        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);

        // BOB (a third party) calls refreshVotingPower for ALICE — should succeed
        vm.prank(BOB);
        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == ALICE) {
                    assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                    assertGt(newV, 0, "ALICE should have voting power");
                    found = true;
                }
            }
        }
        assertTrue(found, "DelegateVotesChanged must be emitted from adapter");
    }

    function test_refreshVotingPower_reflectsDecay() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);

        vm.prank(ALICE);
        delegation.delegate(tokenId, ALICE);
        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);

        // Record the initial refresh value at delegation start
        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);
        Vm.Log[] memory entries1 = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        uint256 votesAtStart;
        for (uint256 i; i < entries1.length; i++) {
            if (entries1[i].emitter == address(adapter) && entries1[i].topics[0] == dvcSig) {
                (, votesAtStart) = abi.decode(entries1[i].data, (uint256, uint256));
            }
        }
        assertGt(votesAtStart, 0, "should have votes at start");

        // Warp 1 year — voting power should decay
        vm.warp(block.timestamp + YEAR);

        // refreshVotingPower should emit a decayed value
        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);
        Vm.Log[] memory entries2 = vm.getRecordedLogs();
        uint256 votesAfterDecay;
        for (uint256 i; i < entries2.length; i++) {
            if (entries2[i].emitter == address(adapter) && entries2[i].topics[0] == dvcSig) {
                (uint256 prev, uint256 newV) = abi.decode(entries2[i].data, (uint256, uint256));
                assertEq(prev, newV, "prev must equal new for refresh");
                votesAfterDecay = newV;
            }
        }
        assertLt(votesAfterDecay, votesAtStart, "votes should have decayed after 1 year");
        assertGt(votesAfterDecay, 0, "votes should still be non-zero (max lock)");
    }

    function test_refreshVotingPower_afterExpiry_emitsZero() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        // Warp past full lock expiry
        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;
        vm.warp(lockEnd + 1);

        assertEq(adapter.getVotes(ALICE), 0, "votes should be zero after expiry");

        vm.expectEmit(true, false, false, true, address(adapter));
        emit DelegateVotesChanged(ALICE, 0, 0);
        adapter.refreshVotingPower(ALICE);
    }

    function test_refreshVotingPower_matchesCheckpointVotes() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);
        _delegateAndWarp(tokenId, ALICE);

        // Warp to mid-life to get a decayed, non-trivial value
        vm.warp(block.timestamp + YEAR);

        // refreshVotingPower uses the checkpoint timestamp (next-epoch boundary),
        // which is always in the future relative to block.timestamp. The emitted
        // value should be >= getVotes() (which uses block.timestamp with more decay).
        uint256 getVotesResult = delegation.getVotes(ALICE);
        assertGt(getVotesResult, 0, "should have non-zero votes at mid-life");

        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == sig && entries[i].emitter == address(adapter)) {
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                // Checkpoint timestamp is in the future, so MORE decay => value <= getVotes
                assertLe(newV, getVotesResult, "checkpoint votes <= getVotes (more decay at future ts)");
                found = true;
            }
        }
        assertTrue(found, "DelegateVotesChanged must be emitted from adapter");
    }

    // ─── refreshVotingPowerBatch ────────────────────────────────────────

    function test_refreshVotingPowerBatch_emitsForAll() public {
        uint256 tid1 = _createLock(ALICE, 10e18, MAX_TIME);
        uint256 tid2 = _createLock(BOB, 5e18, MAX_TIME);

        vm.prank(ALICE);
        delegation.delegate(tid1, ALICE);
        vm.prank(BOB);
        delegation.delegate(tid2, BOB);

        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);

        address[] memory delegatees = new address[](2);
        delegatees[0] = ALICE;
        delegatees[1] = BOB;

        vm.recordLogs();
        adapter.refreshVotingPowerBatch(delegatees);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool foundAlice;
        bool foundBob;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                if (delegate_ == ALICE) {
                    assertGt(newV, 0, "ALICE should have votes");
                    foundAlice = true;
                }
                if (delegate_ == BOB) {
                    assertGt(newV, 0, "BOB should have votes");
                    foundBob = true;
                }
            }
        }
        assertTrue(foundAlice, "DelegateVotesChanged for ALICE must be emitted from adapter");
        assertTrue(foundBob, "DelegateVotesChanged for BOB must be emitted from adapter");
    }

    function test_refreshVotingPowerBatch_emptyArrayNoOp() public {
        address[] memory empty = new address[](0);
        // Should not revert
        adapter.refreshVotingPowerBatch(empty);
    }

    function test_refreshVotingPowerBatch_duplicatesEmitTwice() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);

        vm.prank(ALICE);
        delegation.delegate(tokenId, ALICE);
        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);

        address[] memory delegatees = new address[](2);
        delegatees[0] = ALICE;
        delegatees[1] = ALICE;

        // Two events for the same address — both are valid, subgraph handles idempotently
        vm.recordLogs();
        adapter.refreshVotingPowerBatch(delegatees);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        uint256 adapterEmitCount;
        uint256 firstValue;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                assertGt(newV, 0, "ALICE should have voting power");
                if (adapterEmitCount == 0) {
                    firstValue = newV;
                } else {
                    assertEq(newV, firstValue, "duplicate refreshes must emit same value");
                }
                adapterEmitCount++;
            }
        }
        assertEq(adapterEmitCount, 2, "should emit DelegateVotesChanged twice for duplicate address");
    }

    // ─── NEW: 8 additional relay / refresh tests ─────────────────────

    function test_relay_onIncreaseAmount() public {
        uint256 tokenId = _createLock(ALICE, 10e18, 2 * YEAR);
        _delegateAndWarp(tokenId, ALICE);

        // Mint + approve 5e18 more for ALICE
        hemiToken.mint(ALICE, 5e18);
        vm.prank(ALICE);
        hemiToken.approve(address(veHemi), 5e18);

        vm.recordLogs();
        vm.prank(ALICE);
        veHemi.increaseAmount(tokenId, 5e18);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");

        bool foundIncreasedPower;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == ALICE && newV > prev) {
                    foundIncreasedPower = true;
                }
            }
        }
        assertTrue(foundIncreasedPower, "increaseAmount must relay DelegateVotesChanged showing increased power from adapter");
    }

    function test_relay_onIncreaseUnlockTime() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        vm.recordLogs();
        vm.prank(ALICE);
        veHemi.increaseUnlockTime(tokenId, 3 * YEAR);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");

        bool foundOnAdapter;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                if (delegate_ == ALICE) {
                    (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                    if (newV > prev) {
                        foundOnAdapter = true;
                    }
                }
            }
        }
        assertTrue(foundOnAdapter, "increaseUnlockTime must relay DelegateVotesChanged from adapter");
    }

    function test_relay_onForfeit() public {
        veHemi.updateForfeitAdmin(address(this));

        hemiToken.mint(address(this), 10e18);
        hemiToken.approve(address(veHemi), 10e18);
        uint256 tokenId = veHemi.createLockFor(10e18, 2 * YEAR, ALICE, false, true);

        vm.prank(ALICE);
        delegation.delegate(tokenId, BOB);
        uint256 delegationStarts = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(delegationStarts);

        assertGt(adapter.getVotes(BOB), 0, "BOB should have votes before forfeit");

        vm.recordLogs();
        veHemi.forfeit(tokenId);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bytes32 dcSig = keccak256("DelegateChanged(address,address,address)");

        bool foundDvcBob;
        bool foundDc;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter)) {
                if (entries[i].topics[0] == dvcSig) {
                    address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                    if (delegate_ == BOB) {
                        (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                        assertGt(prev, 0, "BOB should have had votes before forfeit");
                        assertEq(newV, 0, "BOB should have 0 votes after forfeit");
                        foundDvcBob = true;
                    }
                }
                if (entries[i].topics[0] == dcSig) {
                    foundDc = true;
                }
            }
        }
        assertTrue(foundDvcBob, "forfeit must relay DelegateVotesChanged for BOB from adapter");
        assertTrue(foundDc, "forfeit must relay DelegateChanged from adapter");
    }

    function test_relay_createLock_decodedValues() public {
        vm.recordLogs();
        _createLock(ALICE, 10e18, YEAR);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");

        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == ALICE) {
                    assertEq(prev, 0, "previousVotes should be 0 for first createLock");
                    assertGt(newV, 0, "newVotes should be > 0 after createLock");
                    found = true;
                }
            }
        }
        assertTrue(found, "createLock must relay DelegateVotesChanged for ALICE from adapter with prev==0 and newV>0");
    }

    function test_relay_transfer_decodedValues() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        vm.recordLogs();
        vm.prank(ALICE);
        veHemi.transferFrom(ALICE, BOB, tokenId);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bytes32 dcSig = keccak256("DelegateChanged(address,address,address)");

        bool foundBobGainsPower;
        bool foundDc;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter)) {
                if (entries[i].topics[0] == dvcSig) {
                    address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                    (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                    if (delegate_ == BOB && newV > 0) {
                        assertEq(prev, 0, "BOB had no prior votes before transfer");
                        foundBobGainsPower = true;
                    }
                }
                if (entries[i].topics[0] == dcSig) {
                    address delegator_ = address(uint160(uint256(entries[i].topics[1])));
                    address fromDelegate_ = address(uint160(uint256(entries[i].topics[2])));
                    address toDelegate_ = address(uint160(uint256(entries[i].topics[3])));
                    assertEq(delegator_, ALICE, "DelegateChanged delegator should be ALICE");
                    assertEq(fromDelegate_, ALICE, "DelegateChanged fromDelegate should be ALICE");
                    assertEq(toDelegate_, BOB, "DelegateChanged toDelegate should be BOB");
                    foundDc = true;
                }
            }
        }
        assertTrue(foundBobGainsPower, "transfer must relay DelegateVotesChanged for BOB with newV > 0");
        assertTrue(foundDc, "transfer must relay DelegateChanged from adapter with correct topics");
    }

    function test_delegation_refreshVotingPower_relaysToAdapter() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);
        _delegateAndWarp(tokenId, ALICE);

        vm.recordLogs();
        delegation.refreshVotingPower(ALICE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");

        bool foundOnDelegation;
        bool foundOnAdapter;
        uint256 delegationValue;
        uint256 adapterValue;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == dvcSig) {
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                assertGt(newV, 0, "ALICE should have voting power");
                if (entries[i].emitter == address(delegation)) {
                    delegationValue = newV;
                    foundOnDelegation = true;
                }
                if (entries[i].emitter == address(adapter)) {
                    adapterValue = newV;
                    foundOnAdapter = true;
                }
            }
        }
        assertTrue(foundOnDelegation, "delegation.refreshVotingPower must emit from delegation");
        assertTrue(foundOnAdapter, "delegation.refreshVotingPower must relay to adapter");
        assertEq(delegationValue, adapterValue, "delegation and adapter events must have same value");
    }

    function test_refreshVotingPower_multiDelegatorAggregate() public {
        uint256 aliceToken = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(aliceToken, BOB);

        uint256 carolToken = _createLock(CAROL, 20e18, 2 * YEAR);
        _delegateAndWarp(carolToken, BOB);

        // BOB should have aggregated votes from both ALICE and CAROL
        uint256 getVotesAggregate = adapter.getVotes(BOB);
        assertGt(getVotesAggregate, 0, "BOB should have aggregated votes");

        vm.recordLogs();
        adapter.refreshVotingPower(BOB);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");

        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(adapter) && entries[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries[i].topics[1])));
                (uint256 prev, uint256 newV) = abi.decode(entries[i].data, (uint256, uint256));
                if (delegate_ == BOB) {
                    assertEq(prev, newV, "previousVotes must equal newVotes for refresh");
                    // Checkpoint timestamp is further in future, so MORE decay => value <= getVotes
                    assertLe(newV, getVotesAggregate, "checkpoint aggregate <= getVotes aggregate (more decay)");
                    assertGt(newV, 0, "BOB should have aggregated voting power");
                    found = true;
                }
            }
        }
        assertTrue(found, "refreshVotingPower must emit the aggregate voting power for BOB");
    }

    function test_refreshVotingPower_idempotent() public {
        uint256 tokenId = _createLock(ALICE, 10e18, MAX_TIME);
        _delegateAndWarp(tokenId, ALICE);

        vm.warp(block.timestamp + 30 days);

        bytes32 dvcSig = keccak256("DelegateVotesChanged(address,uint256,uint256)");

        // First call
        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);
        Vm.Log[] memory entries1 = vm.getRecordedLogs();

        uint256 firstNewV;
        for (uint256 i; i < entries1.length; i++) {
            if (entries1[i].emitter == address(adapter) && entries1[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries1[i].topics[1])));
                if (delegate_ == ALICE) {
                    (, firstNewV) = abi.decode(entries1[i].data, (uint256, uint256));
                }
            }
        }
        assertGt(firstNewV, 0, "first refresh should emit non-zero votes");

        // Second call (same block, same checkpoint timestamp — must be identical)
        vm.recordLogs();
        adapter.refreshVotingPower(ALICE);
        Vm.Log[] memory entries2 = vm.getRecordedLogs();

        uint256 secondNewV;
        for (uint256 i; i < entries2.length; i++) {
            if (entries2[i].emitter == address(adapter) && entries2[i].topics[0] == dvcSig) {
                address delegate_ = address(uint160(uint256(entries2[i].topics[1])));
                if (delegate_ == ALICE) {
                    (, secondNewV) = abi.decode(entries2[i].data, (uint256, uint256));
                }
            }
        }

        // Both calls within the same block produce the same value (idempotent)
        assertEq(firstNewV, secondNewV, "idempotent: both refreshes must emit the same value");
    }

    // ─── Voting power after delegation expiry ───────────────────────────

    function test_votingPowerDropsToZeroAfterDelegationExpiry() public {
        // Simulates the Aragon scenario: delegatee had power, lock expires,
        // getPastVotes at a post-expiry snapshot must return 0.
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);

        // BOB has delegated power
        uint256 powerBefore = adapter.getVotes(BOB);
        assertGt(powerBefore, 0, "BOB should have power before expiry");

        // Record a timestamp while lock is active (for getPastVotes comparison)
        uint256 tsActive = block.timestamp;

        // Warp well past lock expiry
        vm.warp(block.timestamp + YEAR + 1 days);

        // getVotes returns 0
        assertEq(adapter.getVotes(BOB), 0, "getVotes must be 0 after lock expires");

        // getPastVotes at the active timestamp should still show historical power
        assertGt(adapter.getPastVotes(BOB, tsActive), 0, "historical power should be preserved");

        // getPastVotes at a post-expiry snapshot must be 0
        // (this is what Aragon uses when casting votes on a proposal created after expiry)
        uint256 tsPostExpiry = block.timestamp - 1;
        assertEq(adapter.getPastVotes(BOB, tsPostExpiry), 0, "getPastVotes at post-expiry snapshot must be 0");

        // isMember: ALICE still has locked HEMI (not withdrawn), BOB has nothing
        assertGt(adapter.balanceOf(ALICE), 0, "ALICE still has locked HEMI");
        assertEq(adapter.balanceOf(BOB), 0, "BOB has no locked HEMI");
    }

    // ─── Multiple proposals with different snapshots ──────────────────────

    function test_differentSnapshotsSeeDifferentDelegationState() public {
        // Simulates two Aragon proposals created at different times,
        // with a delegation change happening between them.
        uint256 tokenId = _createLock(ALICE, 10e18, 2 * YEAR);
        _delegateAndWarp(tokenId, ALICE); // self-delegate

        // "Proposal 1" snapshot: ALICE has self-delegated power
        uint256 snapshot1 = block.timestamp;
        uint256 alicePowerAtSnapshot1 = adapter.getPastVotes(ALICE, snapshot1);
        assertGt(alicePowerAtSnapshot1, 0, "ALICE should have power at snapshot 1");
        assertEq(adapter.getPastVotes(BOB, snapshot1), 0, "BOB should have 0 at snapshot 1");

        // ALICE re-delegates to BOB
        vm.prank(ALICE);
        adapter.delegate(BOB);

        // Warp past the next epoch boundary so the re-delegation activates
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch + 1);

        // "Proposal 2" snapshot: BOB now has ALICE's power, ALICE has 0
        uint256 snapshot2 = block.timestamp;
        assertEq(adapter.getPastVotes(ALICE, snapshot2), 0, "ALICE should have 0 at snapshot 2");
        assertGt(adapter.getPastVotes(BOB, snapshot2), 0, "BOB should have power at snapshot 2");

        // CRITICAL: Proposal 1's snapshot still shows the old state
        // (ALICE had power, BOB didn't) — each proposal uses its own snapshot
        assertGt(adapter.getPastVotes(ALICE, snapshot1), 0, "snapshot 1 still shows ALICE with power");
        assertEq(adapter.getPastVotes(BOB, snapshot1), 0, "snapshot 1 still shows BOB with 0");

        // Verify the two snapshots show different power distributions
        assertGt(adapter.getPastVotes(BOB, snapshot2), 0);
        assertEq(adapter.getPastVotes(ALICE, snapshot2), 0);
    }

    // ─── Abstain vote simulation (getPastVotes still counts) ──────────────

    function test_abstainVoterStillHasPowerAtSnapshot() public {
        // In Aragon's standard voting, abstain counts toward participation but not support.
        // This test verifies that a potential abstain voter's power is correctly
        // readable via getPastVotes at the proposal snapshot time.
        uint256 tokenId1 = _createLock(ALICE, 10e18, 2 * YEAR);
        uint256 tokenId2 = _createLock(BOB, 20e18, 2 * YEAR);
        _delegateAndWarp(tokenId1, ALICE);

        // Delegate BOB's token to self
        vm.prank(BOB);
        delegation.delegate(tokenId2, BOB);
        uint256 nextEpoch = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;
        vm.warp(nextEpoch);

        // Proposal snapshot
        uint256 snapshot = block.timestamp;

        // Both voters have power at the snapshot
        uint256 alicePower = adapter.getPastVotes(ALICE, snapshot);
        uint256 bobPower = adapter.getPastVotes(BOB, snapshot);
        assertGt(alicePower, 0, "ALICE should have power for yes/no/abstain");
        assertGt(bobPower, 0, "BOB should have power for yes/no/abstain");

        // Total supply at snapshot should cover both
        vm.warp(snapshot + 1); // move past snapshot so we can query it
        uint256 totalAtSnapshot = adapter.getPastTotalSupply(snapshot);
        assertGt(totalAtSnapshot, 0, "total supply at snapshot should be positive");

        // Each voter's power should be less than total (sanity check)
        assertLt(alicePower, totalAtSnapshot, "ALICE power should be < total");
        assertLt(bobPower, totalAtSnapshot, "BOB power should be < total");
    }
}

/// @dev Helper contract that always reverts on notify calls, for testing relay resilience.
contract RevertingAdapter {
    function notifyVotesChanged(address, uint256, uint256) external pure {
        revert("I always revert");
    }

    function notifyDelegateChanged(address, address, address) external pure {
        revert("I always revert");
    }
}

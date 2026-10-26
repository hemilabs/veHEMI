// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockUpgradeForkBase.sol";

interface IVeHemiAutoRelockOps {
    function createLockWithAutoRelock(uint256, uint256, bool, bool) external returns (uint256);
    function enableAutoRelock(uint256) external;
    function isTransferable(uint256) external view returns (bool);
    function autoRelockRemaining(uint256) external view returns (uint64);
    function transferFrom(address, address, uint256) external;
}

/**
 * The upgrade-hour window at the transition, on a Hemi mainnet fork: no
 * auto-relock enable while the window is open (the window probe), the
 * fail-safe plain-upgrade fallback, rollback inside the window,
 * re-forward after rollback (with the plain re-forward as the NEGATIVE
 * control), and the authentication of `armLegacyDatingWindow`. B and W are
 * as defined in AutoRelockUpgradeForkBase.
 */
contract UpgradeWindowTransitionForkTest is AutoRelockUpgradeForkBase {
    function _addr(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(s)))));
    }

    function _pickTransferableDelegated() internal view returns (uint256 id, address owner, address delegatee) {
        uint256 hi = vm.envOr("AUTORELOCK_FORK_SCAN_HI", uint256(29720));
        for (uint256 i = vm.envOr("AUTORELOCK_FORK_SCAN_LO", uint256(29400)); i < hi; ++i) {
            (address d,,,,) = vvd.delegations(i);
            if (d == address(0)) continue;
            if (uint256(veHemi.getLockedBalance(i).end) < block.timestamp + 60 days) continue;
            if (!IVeHemiAutoRelockOps(VEHEMI_PROXY).isTransferable(i)) continue;
            if (veHemi.balanceOfNFT(i) < 1e18) continue;
            return (i, veHemi.ownerOf(i), d);
        }
        revert("no transferable delegated position");
    }

    function _fund(address who) internal {
        deal(HEMI_TOKEN, who, 100e18);
        vm.prank(who);
        IForkERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, type(uint256).max);
    }

    // ------------------------------------- no auto-relock enable in the window

    function test_noAutoRelockEnableWhileWindowOpen() public {
        if (!forkReady) return;
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 1211);
        _upgradeBothAndArmWindow();
        (uint256 id, address owner, ) = _pickTransferableDelegated();
        address creator = _addr("transition-window-lock-creator");
        _fund(creator);
        _warpAndRollTo(block.timestamp + 12);
        vm.prank(owner);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        IVeHemiAutoRelockOps(VEHEMI_PROXY).enableAutoRelock(id);
        vm.prank(creator);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        IVeHemiAutoRelockOps(VEHEMI_PROXY).createLockWithAutoRelock(100e18, 3 * SIX_DAYS, true, false);

        uint256 snap = vm.snapshotState();
        _warpAndRollTo(hourStart + HOUR - 1); // B-1: deferred and immediate dating coincide
        assertFalse(vvd.legacyDatingActive(), "B-1: legacyDatingActive must be false");
        vm.prank(owner);
        IVeHemiAutoRelockOps(VEHEMI_PROXY).enableAutoRelock(id);
        assertTrue(IVeHemiAutoRelockOps(VEHEMI_PROXY).autoRelockRemaining(id) != 0, "B-1: auto-relock not enabled");
        vm.revertToState(snap);
        _warpAndRollTo(hourStart + HOUR + 11);
        vm.prank(owner);
        IVeHemiAutoRelockOps(VEHEMI_PROXY).enableAutoRelock(id);
        assertTrue(IVeHemiAutoRelockOps(VEHEMI_PROXY).autoRelockRemaining(id) != 0, "after B: auto-relock not enabled");
        vm.prank(creator);
        uint256 createdId = IVeHemiAutoRelockOps(VEHEMI_PROXY).createLockWithAutoRelock(100e18, 3 * SIX_DAYS, true, false);
        assertTrue(IVeHemiAutoRelockOps(VEHEMI_PROXY).autoRelockRemaining(createdId) != 0, "after B: createLockWithAutoRelock did not enable auto-relock");
    }

    /// An armed transfer on the forked mainnet state, with the window:
    /// `enableAutoRelock` is refused in the window and the armed transfer
    /// (move-or-remove) runs after B.
    function test_enableRefusedInWindow_armedTransferAfterBoundaryMovesRecordToBuyer() public {
        if (!forkReady) return;
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 11);
        _upgradeBothAndArmWindow();
        VeHemi veHemiProxy = VeHemi(VEHEMI_PROXY);
        (uint256 id, address owner, address sellerDelegatee) = _pickTransferableDelegated();
        address buyer = _addr("transition-buyer");
        _warpAndRollTo(block.timestamp + 12);
        vm.prank(owner);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        veHemiProxy.enableAutoRelock(id);
        _warpAndRollTo(hourStart + HOUR + 11);

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        veHemiProxy.transferFrom(owner, buyer, id);
        _warpAndRollTo(block.timestamp + 12);
        uint256 sellerDelegateeVotesAfterUnarmedTransfer = vvd.getVotes(sellerDelegatee);
        vm.revertToState(snap);

        vm.prank(owner);
        veHemiProxy.enableAutoRelock(id);
        assertTrue(veHemiProxy.autoRelockRemaining(id) != 0, "auto-relock not enabled");
        IVeHemiVoteDelegation.Delegation memory pre = vvd.delegation(id);
        assertTrue(pre.slope == 0 && pre.bias > 0 && pre.delegatee == sellerDelegatee, "auto-relock record not flat at the seller's delegatee");
        uint256 remaining = veHemiProxy.autoRelockRemaining(id);
        uint256 transferredAt = block.timestamp;
        vm.recordLogs();
        vm.prank(owner);
        veHemiProxy.transferFrom(owner, buyer, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("DelegationUpdateFailed(uint256)")), 0, "DelegationUpdateFailed emitted");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("AutoRelockRetirementUnverified(uint256)")), 0, "AutoRelockRetirementUnverified emitted");
        assertEq(veHemiProxy.autoRelockRemaining(id), 0, "flag survived the transfer");
        IVeHemiVoteDelegation.Delegation memory post = vvd.delegation(id);
        assertEq(post.delegatee, buyer, "record not at the buyer");
        assertGt(post.slope, 0, "record not decaying");
        assertEq(uint256(post.end), ((transferredAt / SIX_DAYS) + remaining / SIX_DAYS) * SIX_DAYS, "record end != grid(t) + remaining");
        assertEq(uint256(veHemiProxy.getLockedBalance(id).end), uint256(post.end), "lock end != record end");
        _warpAndRollTo(block.timestamp + 12);
        assertEq(
            vvd.getVotes(sellerDelegatee), sellerDelegateeVotesAfterUnarmedTransfer,
            "the seller's delegatee kept part of the position"
        );
        assertEq(vvd.getVotes(buyer), veHemiProxy.balanceOfNFT(id), "buyer votes != position weight");
    }

    // ---------------------------------------------------- plain-upgrade fallback

    /// A hand-built PLAIN VVD leg (no window arm): W == 0 reads as an open
    /// window, so the sequence -- a live in-hour move, the upgrade, then a move
    /// back in the same hour -- does not double count; the first `_delegate`
    /// closes the window at the next boundary, with event (B, false).
    function test_plainUpgradeFallback_noDoubleCount_firstDelegateClosesWindow() public {
        if (!forkReady) return;
        (uint256 id, address owner, address delegatee) = _pickDelegated();
        address retiredTo = _addr("transition-fallback-retired-to");
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 1799);
        uint256 positionWeight = veHemi.balanceOfNFT(id);
        uint256 snap = vm.snapshotState();
        _upgradeBothPlain();
        _warpAndRollTo(block.timestamp + 12);
        _warpAndRollTo(block.timestamp + 2);
        uint256 delegateeVotesInWindowWithoutWrites = vvd.getVotes(delegatee);
        _warpAndRollTo(hourStart + HOUR + 11);
        uint256 delegateeVotesAfterBWithoutWrites = vvd.getVotes(delegatee);
        vm.revertToState(snap);

        vm.prank(owner);
        vvd.delegate(id, retiredTo); // live, in-hour
        _upgradeBothPlain();
        assertEq(uint256(vvd.legacyDatingUntil()), 0, "fallback: W != 0 after a plain upgrade");
        assertTrue(vvd.legacyDatingActive(), "fallback: W == 0 must read as an open window");
        _warpAndRollTo(block.timestamp + 12);
        vm.recordLogs();
        vm.prank(owner);
        vvd.delegate(id, delegatee);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter == VVD_PROXY && logs[j].topics[0] == keccak256("LegacyDatingWindowArmed(uint256,bool)")) {
                (uint256 until, bool viaUpgradeCall) = abi.decode(logs[j].data, (uint256, bool));
                assertEq(until, hourStart + HOUR, "first-delegate close: until");
                assertFalse(viaUpgradeCall, "first-delegate close: viaUpgradeCall");
                seen = true;
            }
        }
        assertTrue(seen, "first-delegate close event missing");
        assertEq(uint256(vvd.legacyDatingUntil()), hourStart + HOUR, "first-delegate close: W");
        assertEq(uint256(vvd.delegationBookedAt(id)), hourStart + HOUR, "fallback: booking stamp != B");
        _warpAndRollTo(block.timestamp + 2);
        uint256 tol = positionWeight / 1e6 + 1e15;
        assertApproxEqAbs(vvd.getVotes(delegatee), delegateeVotesInWindowWithoutWrites, tol, "fallback: double count");
        assertEq(vvd.getVotes(retiredTo), 0, "fallback: retired-to delegatee in the window");
        _warpAndRollTo(hourStart + HOUR + 11);
        assertApproxEqAbs(vvd.getVotes(delegatee), delegateeVotesAfterBWithoutWrites, tol, "fallback: after B");
        assertEq(vvd.getVotes(retiredTo), 0, "fallback: retired-to delegatee after B");
        vm.prank(owner);
        vvd.delegate(id, retiredTo);
        assertEq(uint256(vvd.delegationBookedAt(id)), block.timestamp + 1, "fallback: post-B write not immediate");
    }

    /// Plain upgrade and NO `_delegate` for two hours: the amortiser and
    /// refresh write nothing to slot 101, the window probe refuses
    /// `enableAutoRelock` while W == 0, and the first `_delegate` closes the
    /// window at ITS OWN hour.
    function test_plainUpgradeFallback_windowStaysOpenUntilTheFirstDelegate() public {
        if (!forkReady) return;
        (uint256 id, address owner, address delegatee) = _pickDelegated();
        (uint256 autoRelockId, address autoRelockOwner, ) = _pickTransferableDelegated();
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 1799);
        _upgradeBothPlain();
        _warpAndRollTo(hourStart + 2 * HOUR + 599);
        vm.record();
        try vvd.writeNewCheckpointForExpiredDelegations(delegatee) {} catch {}
        vvd.refreshVotingPower(delegatee);
        (, bytes32[] memory writes) = vm.accesses(VVD_PROXY);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(writes[i] != bytes32(uint256(101)), "amortiser/refresh wrote slot 101");
        }
        assertEq(uint256(vvd.legacyDatingUntil()), 0, "W moved without a _delegate");
        vm.prank(autoRelockOwner);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        IVeHemiAutoRelockOps(VEHEMI_PROXY).enableAutoRelock(autoRelockId);
        vm.prank(owner);
        vvd.delegate(id, _addr("transition-fallback-late-move-target"));
        assertEq(uint256(vvd.legacyDatingUntil()), hourStart + 3 * HOUR, "first-delegate close not at the writing block's boundary");
        assertEq(uint256(vvd.delegationBookedAt(id)), hourStart + 3 * HOUR, "in-window booking stamp != boundary");
        _warpAndRollTo(hourStart + 3 * HOUR + 11);
        assertFalse(vvd.legacyDatingActive(), "window open after its boundary");
        vm.prank(autoRelockOwner);
        IVeHemiAutoRelockOps(VEHEMI_PROXY).enableAutoRelock(autoRelockId);
    }

    // --------------------------------------------------- rollback / re-forward

    /// The re-added position is booked live in-hour at `liveBookingDelegatee`, then
    /// re-added to its delegatee in the window; the moved position moves to a
    /// target in the window and back on the live writer after the rollback.
    struct RollbackCase {
        uint256 reAddedId; address reAddedOwner; address reAddedDelegatee;
        uint256 movedId; address movedOwner; address movedFromDelegatee;
        address liveBookingDelegatee; address moveTarget;
        uint256 hourStart;
    }

    function _rollbackSetup() internal returns (RollbackCase memory r) {
        (r.reAddedId, r.reAddedOwner, r.reAddedDelegatee) = _pickDelegated();
        (r.movedId, r.movedOwner, r.movedFromDelegatee) = _pickDelegatedFrom(r.reAddedId + 1, 1e18);
        r.liveBookingDelegatee = _addr("transition-rollback-live-booking-delegatee");
        r.moveTarget = _addr("transition-rollback-move-target");
        r.hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(r.hourStart + 611);
        vm.prank(r.reAddedOwner);
        vvd.delegate(r.reAddedId, r.liveBookingDelegatee); // live, in-hour
        _warpAndRollTo(r.hourStart + 1211);
    }

    function _rollbackScenarioOps(RollbackCase memory r, bool upgradeThenRollBack_) internal {
        if (upgradeThenRollBack_) _upgradeBothAndArmWindow();
        _warpAndRollTo(r.hourStart + 1223);
        vm.prank(r.reAddedOwner);
        vvd.delegate(r.reAddedId, r.reAddedDelegatee); // window re-add
        vm.prank(r.movedOwner);
        vvd.delegate(r.movedId, r.moveTarget); // window move
        _warpAndRollTo(r.hourStart + 1811);
        if (upgradeThenRollBack_) {
            vm.startPrank(SAFE);
            IForkProxyAdmin(PROXY_ADMIN).upgrade(VVD_PROXY, LIVE_VVD_IMPL); // VVD first
            IForkProxyAdmin(PROXY_ADMIN).upgrade(VEHEMI_PROXY, liveVeHemiImpl);
            vm.stopPrank();
        }
        _warpAndRollTo(r.hourStart + 1823);
        vm.prank(r.movedOwner);
        vvd.delegate(r.movedId, r.movedFromDelegatee); // live writer again
        vm.prank(r.reAddedOwner);
        vvd.delegate(r.reAddedId, r.moveTarget);
    }

    /// Rollback INSIDE the window, as ONE atomic batch (both plain legs in the
    /// same transaction) is state-clean: after B the VVD equals a twin that
    /// never upgraded and ran the same operations. A split rollback is NOT
    /// supported (the window probe fails open against the live VVD in the gap
    /// between the two transactions).
    function test_rollbackInWindow_matchesAWorldThatNeverUpgraded() public {
        if (!forkReady) return;
        RollbackCase memory r = _rollbackSetup();
        // short-history delegatees: `_observe` compares whole arrays
        address[] memory delegatees = new address[](4);
        delegatees[0] = r.reAddedDelegatee; delegatees[1] = r.liveBookingDelegatee;
        delegatees[2] = r.movedFromDelegatee; delegatees[3] = r.moveTarget;
        uint256[] memory ids = new uint256[](2);
        ids[0] = r.reAddedId; ids[1] = r.movedId;
        uint256[] memory keys = new uint256[](2);
        keys[0] = uint256(veHemi.getLockedBalance(r.reAddedId).end);
        keys[1] = uint256(veHemi.getLockedBalance(r.movedId).end);
        uint256 snap = vm.snapshotState();
        _rollbackScenarioOps(r, false);
        _warpAndRollTo(r.hourStart + 2 * HOUR + 11);
        bytes32[] memory observedWithoutUpgrade = _observe(delegatees, ids, keys);
        uint256 votesWithoutUpgrade =
            vvd.getVotes(r.reAddedDelegatee) + vvd.getVotes(r.moveTarget) + vvd.getVotes(r.movedFromDelegatee);
        vm.revertToState(snap);
        _rollbackScenarioOps(r, true);
        _warpAndRollTo(r.hourStart + 2 * HOUR + 11);
        bytes32[] memory observedWithUpgrade = _observe(delegatees, ids, keys);
        uint256 votesWithUpgrade =
            vvd.getVotes(r.reAddedDelegatee) + vvd.getVotes(r.moveTarget) + vvd.getVotes(r.movedFromDelegatee);
        _assertSameObservation(observedWithoutUpgrade, observedWithUpgrade, "rollback-in-window");
        assertEq(votesWithoutUpgrade, votesWithUpgrade, "rollback-in-window: votes");
    }

    function _reForward(bool armWindow_)
        internal
        returns (
            uint256 votesAtMovedFromDelegatee,
            uint256 votesAtMovedFromDelegateeWithoutWrites,
            uint256 retiredToVotesInWindow,
            uint256 positionWeight
        )
    {
        RollbackCase memory r = _rollbackSetup();
        _rollbackScenarioOps(r, true); // forward, window ops, rollback, live ops
        // A later hour: live in-hour retirement, then the re-forward mid-hour.
        uint256 laterHourStart = r.hourStart + 3 * HOUR;
        address retiredTo = _addr("transition-reforward-retired-to");
        _warpAndRollTo(laterHourStart + 611);
        positionWeight = veHemi.balanceOfNFT(r.movedId);
        uint256 snap = vm.snapshotState();
        _warpAndRollTo(laterHourStart + 1211);
        _reForwardBatch(armWindow_);
        _warpAndRollTo(laterHourStart + 1225);
        votesAtMovedFromDelegateeWithoutWrites = vvd.getVotes(r.movedFromDelegatee);
        vm.revertToState(snap);
        vm.prank(r.movedOwner);
        vvd.delegate(r.movedId, retiredTo); // live: retire from its delegatee in-hour
        _warpAndRollTo(laterHourStart + 1211);
        _reForwardBatch(armWindow_);
        _warpAndRollTo(laterHourStart + 1223);
        vm.prank(r.movedOwner);
        vvd.delegate(r.movedId, r.movedFromDelegatee); // re-add on the re-forwarded implementation
        _warpAndRollTo(laterHourStart + 1225);
        votesAtMovedFromDelegatee = vvd.getVotes(r.movedFromDelegatee);
        retiredToVotesInWindow = vvd.getVotes(retiredTo);
    }

    function _reForwardBatch(bool armWindow_) internal {
        vm.startPrank(SAFE);
        IForkProxyAdmin(PROXY_ADMIN).upgrade(VEHEMI_PROXY, newVeHemiImpl);
        if (armWindow_) IForkProxyAdmin(PROXY_ADMIN).upgradeAndCall(VVD_PROXY, newVvdImpl, _armWindowCalldata());
        else IForkProxyAdmin(PROXY_ADMIN).upgrade(VVD_PROXY, newVvdImpl);
        vm.stopPrank();
    }

    /// Re-forward after a rollback, WITH the window arm: anomaly-free (the
    /// window arm is not an initializer, so it arms the window again).
    function test_reForwardAfterRollback_withWindowArm_noDoubleCount() public {
        if (!forkReady) return;
        (
            uint256 votesAtMovedFromDelegatee,
            uint256 votesAtMovedFromDelegateeWithoutWrites,
            uint256 retiredToVotesInWindow,
            uint256 positionWeight
        ) = _reForward(true);
        assertApproxEqAbs(
            votesAtMovedFromDelegatee, votesAtMovedFromDelegateeWithoutWrites, positionWeight / 1e6 + 1e15,
            "re-forward with the window arm: double count"
        );
        assertEq(retiredToVotesInWindow, 0, "re-forward with the window arm: retired-to delegatee holds weight");
    }

    /// KNOWN HAZARD, asserted as a negative control: a PLAIN re-forward over a
    /// past non-zero W double-counts (the moved position, retired and re-added
    /// in a later hour, has its weight counted twice at `movedFromDelegatee`).
    /// (Any re-forward must use
    /// `upgradeAndCall(..., armLegacyDatingWindow())`, as above.)
    function test_reForwardAfterRollback_plainLegs_doubleCount_negativeControl() public {
        if (!forkReady) return;
        (uint256 votesAtMovedFromDelegatee, uint256 votesAtMovedFromDelegateeWithoutWrites, , uint256 positionWeight) =
            _reForward(false);
        assertApproxEqAbs(
            votesAtMovedFromDelegatee, votesAtMovedFromDelegateeWithoutWrites + positionWeight, positionWeight / 1000 + 1e15,
            "negative control: plain re-forward did not double count"
        );
    }

    // ----------------------------------------------- window arm authentication

    function test_armLegacyDatingWindowIsAuthenticated() public {
        if (!forkReady) return;
        _deployImplementationsOnce();
        // bare implementation: no admin
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        VeHemiVoteDelegation(newVvdImpl).armLegacyDatingWindow();
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 1211);
        _upgradeBothAndArmWindow();
        // stranger through the proxy
        vm.prank(_addr("transition-stranger"));
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        vvd.armLegacyDatingWindow();
        // the Safe itself (it is not the proxy's EIP-1967 admin; the ProxyAdmin is)
        vm.prank(SAFE);
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        vvd.armLegacyDatingWindow();
        // the ProxyAdmin cannot reach the implementation through the fallback
        vm.prank(PROXY_ADMIN);
        vm.expectRevert(bytes("TransparentUpgradeableProxy: admin cannot fallback to proxy target"));
        vvd.armLegacyDatingWindow();
        // non-payable: value through upgradeAndCall reverts
        vm.deal(SAFE, 1 ether);
        vm.prank(SAFE);
        vm.expectRevert();
        IForkProxyAdmin(PROXY_ADMIN).upgradeAndCall{value: 1}(VVD_PROXY, newVvdImpl, _armWindowCalldata());
        // arming the window again in a later hour assigns the next hour boundary
        _warpAndRollTo(hourStart + 5 * HOUR + 611);
        vm.prank(SAFE);
        IForkProxyAdmin(PROXY_ADMIN).upgradeAndCall(VVD_PROXY, newVvdImpl, _armWindowCalldata());
        assertEq(uint256(vvd.legacyDatingUntil()), hourStart + 6 * HOUR, "window re-arm value");
    }
}

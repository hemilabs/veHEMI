// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./R31Base.sol";

interface IVeHemiArmR31 {
    function createLockWithAutoRelock(uint256, uint256, bool, bool) external returns (uint256);
    function enableAutoRelock(uint256) external;
    function isTransferable(uint256) external view returns (bool);
    function autoRelockRemaining(uint256) external view returns (uint64);
    function transferFrom(address, address, uint256) external;
}

/**
 * The upgrade-hour window at the transition, on a Hemi mainnet fork: no
 * auto-relock arming while the window is open (the window probe), the
 * fail-safe plain-upgrade fallback, rollback inside the window,
 * re-forward after rollback (with the plain re-forward as the NEGATIVE
 * control), and the authentication of `armLegacyDatingWindow`. B is the
 * hour boundary that closes the window; W is the stored window end
 * (`legacyDatingUntil`).
 */
contract R31TransitionTest is R31Base {
    function _addr(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(s)))));
    }

    function _armable() internal view returns (uint256 id, address owner, address d) {
        uint256 hi = vm.envOr("R29_SCAN_HI", uint256(29720));
        for (uint256 i = vm.envOr("R29_SCAN_LO", uint256(29400)); i < hi; ++i) {
            (address dd,,,,) = vvd.delegations(i);
            if (dd == address(0)) continue;
            if (uint256(veHemi.getLockedBalance(i).end) < block.timestamp + 60 days) continue;
            if (!IVeHemiArmR31(VEHEMI_PROXY).isTransferable(i)) continue;
            if (veHemi.balanceOfNFT(i) < 1e18) continue;
            return (i, veHemi.ownerOf(i), dd);
        }
        revert("no armable position");
    }

    function _fund(address who) internal {
        deal(HEMI_TOKEN, who, 100e18);
        vm.prank(who);
        IERC20R31(HEMI_TOKEN).approve(VEHEMI_PROXY, type(uint256).max);
    }

    // ------------------------------------------------- no arming in the window

    function test_R31_G1_noArmingInWindow() public {
        if (!live) return;
        uint256 h = _nb(block.timestamp);
        _to(h + 1211);
        _upgradeBoth();
        (uint256 id, address owner, ) = _armable();
        address z = _addr("transition-window-z");
        _fund(z);
        _to(block.timestamp + 12);
        vm.prank(owner);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        IVeHemiArmR31(VEHEMI_PROXY).enableAutoRelock(id);
        vm.prank(z);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        IVeHemiArmR31(VEHEMI_PROXY).createLockWithAutoRelock(100e18, 3 * SIX_DAYS, true, false);

        uint256 snap = vm.snapshotState();
        _to(h + HOUR - 1); // B-1: deferred and immediate dating coincide
        assertFalse(vvd.legacyDatingActive(), "B-1 must not count as deferring");
        vm.prank(owner);
        IVeHemiArmR31(VEHEMI_PROXY).enableAutoRelock(id);
        assertTrue(IVeHemiArmR31(VEHEMI_PROXY).autoRelockRemaining(id) != 0, "B-1: not armed");
        vm.revertToState(snap);
        _to(h + HOUR + 11);
        vm.prank(owner);
        IVeHemiArmR31(VEHEMI_PROXY).enableAutoRelock(id);
        assertTrue(IVeHemiArmR31(VEHEMI_PROXY).autoRelockRemaining(id) != 0, "after B: not armed");
        vm.prank(z);
        uint256 zid = IVeHemiArmR31(VEHEMI_PROXY).createLockWithAutoRelock(100e18, 3 * SIX_DAYS, true, false);
        assertTrue(IVeHemiArmR31(VEHEMI_PROXY).autoRelockRemaining(zid) != 0, "after B: create-armed not armed");
    }

    /// An armed transfer on live state, with the window: the arm is refused
    /// in the window and the armed transfer (move-or-remove) runs after B.
    function test_R31_T11_armedTransferOnLiveState() public {
        if (!live) return;
        uint256 h = _nb(block.timestamp);
        _to(h + 11);
        _upgradeBoth();
        VeHemi v = VeHemi(VEHEMI_PROXY);
        (uint256 id, address owner, address dOld) = _armable();
        address buyer = _addr("transition-buyer");
        _to(block.timestamp + 12);
        vm.prank(owner);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        v.enableAutoRelock(id);
        _to(h + HOUR + 11);

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        v.transferFrom(owner, buyer, id);
        _to(block.timestamp + 12);
        uint256 dOldPlain = vvd.getVotes(dOld);
        vm.revertToState(snap);

        vm.prank(owner);
        v.enableAutoRelock(id);
        assertTrue(v.autoRelockRemaining(id) != 0, "not armed");
        IVeHemiVoteDelegation.Delegation memory pre = vvd.delegation(id);
        assertTrue(pre.slope == 0 && pre.bias > 0 && pre.delegatee == dOld, "armed record not flat at D_old");
        uint256 rem = v.autoRelockRemaining(id);
        uint256 tXfer = block.timestamp;
        vm.recordLogs();
        vm.prank(owner);
        v.transferFrom(owner, buyer, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("DelegationUpdateFailed(uint256)")), 0, "DelegationUpdateFailed emitted");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("AutoRelockRetirementUnverified(uint256)")), 0, "AutoRelockRetirementUnverified emitted");
        assertEq(v.autoRelockRemaining(id), 0, "flag survived the transfer");
        IVeHemiVoteDelegation.Delegation memory post = vvd.delegation(id);
        assertEq(post.delegatee, buyer, "record not at the buyer");
        assertGt(post.slope, 0, "record not decaying");
        assertEq(uint256(post.end), ((tXfer / SIX_DAYS) + rem / SIX_DAYS) * SIX_DAYS, "record end != grid(t) + R");
        assertEq(uint256(v.getLockedBalance(id).end), uint256(post.end), "lock end != record end");
        _to(block.timestamp + 12);
        assertEq(vvd.getVotes(dOld), dOldPlain, "D_old kept part of the position");
        assertEq(vvd.getVotes(buyer), v.balanceOfNFT(id), "buyer votes != position weight");
    }

    // ---------------------------------------------------- plain-upgrade fallback

    /// A hand-built PLAIN VVD leg (no arm): W == 0 reads as an open window,
    /// so the sequence -- a live in-hour move, the upgrade, then a move back
    /// in the same hour -- does not double count; the first `_delegate`
    /// closes the window at the next boundary, with event (B, false).
    function test_R31_plainUpgradeFallback_D2_clean_and_lazyClose() public {
        if (!live) return;
        (uint256 id, address owner, address a) = _pick();
        address fresh = _addr("transition-fb-fresh");
        uint256 h = _nb(block.timestamp);
        _to(h + 1799);
        uint256 w = veHemi.balanceOfNFT(id);
        uint256 snap = vm.snapshotState();
        _upgradeBothPlain();
        _to(block.timestamp + 12);
        _to(block.timestamp + 2);
        uint256 cfA = vvd.getVotes(a);
        _to(h + HOUR + 11);
        uint256 cfAfter = vvd.getVotes(a);
        vm.revertToState(snap);

        vm.prank(owner);
        vvd.delegate(id, fresh); // live, in-hour
        _upgradeBothPlain();
        assertEq(uint256(vvd.legacyDatingUntil()), 0, "fallback: W != 0 after a plain upgrade");
        assertTrue(vvd.legacyDatingActive(), "fallback: W == 0 must read as an open window");
        _to(block.timestamp + 12);
        vm.recordLogs();
        vm.prank(owner);
        vvd.delegate(id, a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter == VVD_PROXY && logs[j].topics[0] == keccak256("LegacyDatingWindowArmed(uint256,bool)")) {
                (uint256 until, bool via) = abi.decode(logs[j].data, (uint256, bool));
                assertEq(until, h + HOUR, "lazy close: until");
                assertFalse(via, "lazy close: viaUpgradeCall");
                seen = true;
            }
        }
        assertTrue(seen, "lazy close event missing");
        assertEq(uint256(vvd.legacyDatingUntil()), h + HOUR, "lazy close: W");
        assertEq(uint256(vvd.delegationBookedAt(id)), h + HOUR, "fallback: window stamp != B");
        _to(block.timestamp + 2);
        uint256 tol = w / 1e6 + 1e15;
        assertApproxEqAbs(vvd.getVotes(a), cfA, tol, "fallback: double count");
        assertEq(vvd.getVotes(fresh), 0, "fallback: fresh in the window");
        _to(h + HOUR + 11);
        assertApproxEqAbs(vvd.getVotes(a), cfAfter, tol, "fallback: after B");
        assertEq(vvd.getVotes(fresh), 0, "fallback: fresh after B");
        vm.prank(owner);
        vvd.delegate(id, fresh);
        assertEq(uint256(vvd.delegationBookedAt(id)), block.timestamp + 1, "fallback: post-B write not immediate");
    }

    /// Plain upgrade and NO `_delegate` for two hours: the amortiser and
    /// refresh write nothing to slot 101, the window probe refuses arming
    /// while W == 0, and the first `_delegate` closes the window at
    /// ITS OWN hour.
    function test_R31_plainUpgradeFallback_noDelegateForTwoHours() public {
        if (!live) return;
        (uint256 id, address owner, address a) = _pick();
        (uint256 aid, address aOwner, ) = _armable();
        uint256 h = _nb(block.timestamp);
        _to(h + 1799);
        _upgradeBothPlain();
        _to(h + 2 * HOUR + 599);
        vm.record();
        try vvd.writeNewCheckpointForExpiredDelegations(a) {} catch {}
        vvd.refreshVotingPower(a);
        (, bytes32[] memory writes) = vm.accesses(VVD_PROXY);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(writes[i] != bytes32(uint256(101)), "amortiser/refresh wrote slot 101");
        }
        assertEq(uint256(vvd.legacyDatingUntil()), 0, "W moved without a _delegate");
        vm.prank(aOwner);
        vm.expectRevert(VeHemi.VoteDelegationTransitionInProgress.selector);
        IVeHemiArmR31(VEHEMI_PROXY).enableAutoRelock(aid);
        vm.prank(owner);
        vvd.delegate(id, _addr("transition-fb2-g"));
        assertEq(uint256(vvd.legacyDatingUntil()), h + 3 * HOUR, "lazy close not at the writing block's boundary");
        assertEq(uint256(vvd.delegationBookedAt(id)), h + 3 * HOUR, "in-window stamp != boundary");
        _to(h + 3 * HOUR + 11);
        assertFalse(vvd.legacyDatingActive(), "window open after its boundary");
        vm.prank(aOwner);
        IVeHemiArmR31(VEHEMI_PROXY).enableAutoRelock(aid);
    }

    // --------------------------------------------------- rollback / re-forward

    struct RB {
        uint256 id1; address o1; address a1;
        uint256 id2; address o2; address a2;
        address f1; address g2;
        uint256 h;
    }

    function _rbSetup() internal returns (RB memory r) {
        (r.id1, r.o1, r.a1) = _pick();
        (r.id2, r.o2, r.a2) = _pickFrom(r.id1 + 1, 1e18);
        r.f1 = _addr("transition-rb-f1");
        r.g2 = _addr("transition-rb-g2");
        r.h = _nb(block.timestamp);
        _to(r.h + 611);
        vm.prank(r.o1);
        vvd.delegate(r.id1, r.f1); // live, in-hour
        _to(r.h + 1211);
    }

    function _rbOps(RB memory r, bool upgrade_) internal {
        if (upgrade_) _upgradeBoth();
        _to(r.h + 1223);
        vm.prank(r.o1);
        vvd.delegate(r.id1, r.a1); // window re-add
        vm.prank(r.o2);
        vvd.delegate(r.id2, r.g2); // window move
        _to(r.h + 1811);
        if (upgrade_) {
            vm.startPrank(SAFE);
            IProxyAdminR31(PROXY_ADMIN).upgrade(VVD_PROXY, LIVE_VVD_IMPL); // VVD first
            IProxyAdminR31(PROXY_ADMIN).upgrade(VEHEMI_PROXY, liveVeHemiImpl);
            vm.stopPrank();
        }
        _to(r.h + 1823);
        vm.prank(r.o2);
        vvd.delegate(r.id2, r.a2); // live writer again
        vm.prank(r.o1);
        vvd.delegate(r.id1, r.g2);
    }

    /// Rollback INSIDE the window, as ONE atomic batch (both plain legs in the
    /// same transaction) is state-clean: after B the VVD equals a twin that
    /// never upgraded and ran the same operations. A split rollback is NOT
    /// supported (the window probe fails open against the live VVD in the gap
    /// between the two transactions).
    function test_R31_rollbackInWindow_clean() public {
        if (!live) return;
        RB memory r = _rbSetup();
        address[] memory ds = new address[](4);
        ds[0] = r.a1; ds[1] = r.f1; ds[2] = r.a2; ds[3] = r.g2;
        uint256[] memory ids = new uint256[](2);
        ids[0] = r.id1; ids[1] = r.id2;
        uint256[] memory keys = new uint256[](2);
        keys[0] = uint256(veHemi.getLockedBalance(r.id1).end);
        keys[1] = uint256(veHemi.getLockedBalance(r.id2).end);
        uint256 snap = vm.snapshotState();
        _rbOps(r, false);
        _to(r.h + 2 * HOUR + 11);
        bytes32[] memory o0 = _observeSmall(ds, ids, keys);
        uint256 v0 = vvd.getVotes(r.a1) + vvd.getVotes(r.g2) + vvd.getVotes(r.a2);
        vm.revertToState(snap);
        _rbOps(r, true);
        _to(r.h + 2 * HOUR + 11);
        bytes32[] memory o1 = _observeSmall(ds, ids, keys);
        uint256 v1 = vvd.getVotes(r.a1) + vvd.getVotes(r.g2) + vvd.getVotes(r.a2);
        _assertSameObs(o0, o1, "rollback-in-window");
        assertEq(v0, v1, "rollback-in-window: votes");
    }

    /// The arrays here are short-history delegatees; compare whole arrays.
    function _observeSmall(address[] memory ds, uint256[] memory ids, uint256[] memory keys) internal view returns (bytes32[] memory) {
        return _observe(ds, ids, keys);
    }

    function _reForward(bool arm_) internal returns (uint256 votesA, uint256 cf, uint256 freshIn, uint256 w) {
        RB memory r = _rbSetup();
        _rbOps(r, true); // forward, window ops, rollback, live ops
        // A later hour: live in-hour retirement, then the re-forward mid-hour.
        uint256 h2 = r.h + 3 * HOUR;
        address fresh = _addr("transition-rf-fresh");
        _to(h2 + 611);
        w = veHemi.balanceOfNFT(r.id2);
        uint256 snap = vm.snapshotState();
        _to(h2 + 1211);
        _reForwardBatch(arm_);
        _to(h2 + 1225);
        cf = vvd.getVotes(r.a2);
        vm.revertToState(snap);
        vm.prank(r.o2);
        vvd.delegate(r.id2, fresh); // live: retire from a2 in-hour
        _to(h2 + 1211);
        _reForwardBatch(arm_);
        _to(h2 + 1223);
        vm.prank(r.o2);
        vvd.delegate(r.id2, r.a2); // re-add on the re-forwarded implementation
        _to(h2 + 1225);
        votesA = vvd.getVotes(r.a2);
        freshIn = vvd.getVotes(fresh);
    }

    function _reForwardBatch(bool arm_) internal {
        vm.startPrank(SAFE);
        IProxyAdminR31(PROXY_ADMIN).upgrade(VEHEMI_PROXY, newVeHemiImpl);
        if (arm_) IProxyAdminR31(PROXY_ADMIN).upgradeAndCall(VVD_PROXY, newVvdImpl, _armData());
        else IProxyAdminR31(PROXY_ADMIN).upgrade(VVD_PROXY, newVvdImpl);
        vm.stopPrank();
    }

    /// Re-forward after a rollback, WITH the arm: anomaly-free (the arm is
    /// not an initializer, so it re-arms).
    function test_R31_reForwardAfterRollback_armed_clean() public {
        if (!live) return;
        (uint256 votesA, uint256 cf, uint256 freshIn, uint256 w) = _reForward(true);
        assertApproxEqAbs(votesA, cf, w / 1e6 + 1e15, "re-forward (armed): double count");
        assertEq(freshIn, 0, "re-forward (armed): fresh");
    }

    /// KNOWN HAZARD, pinned as a negative control: a PLAIN re-forward over a
    /// past non-zero W reproduces the double count (the re-added position's
    /// weight counted twice at its delegatee). (Any re-forward must
    /// use `upgradeAndCall(..., armLegacyDatingWindow())`, as above.)
    function test_R31_reForwardAfterRollback_plain_doubleCounts_negativeControl() public {
        if (!live) return;
        (uint256 votesA, uint256 cf, , uint256 w) = _reForward(false);
        assertApproxEqAbs(votesA, cf + w, w / 1000 + 1e15, "negative control: plain re-forward did not double count");
    }

    // ---------------------------------------------------------------- arm auth

    function test_R31_armAuth() public {
        if (!live) return;
        _impls();
        // bare implementation: no admin
        vm.expectRevert(VeHemiVoteDelegation.NotUpgradeCall.selector);
        VeHemiVoteDelegation(newVvdImpl).armLegacyDatingWindow();
        uint256 h = _nb(block.timestamp);
        _to(h + 1211);
        _upgradeBoth();
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
        IProxyAdminR31(PROXY_ADMIN).upgradeAndCall{value: 1}(VVD_PROXY, newVvdImpl, _armData());
        // re-arm in a later hour assigns nb(now)
        _to(h + 5 * HOUR + 611);
        vm.prank(SAFE);
        IProxyAdminR31(PROXY_ADMIN).upgradeAndCall(VVD_PROXY, newVvdImpl, _armData());
        assertEq(uint256(vvd.legacyDatingUntil()), h + 6 * HOUR, "re-arm value");
    }
}

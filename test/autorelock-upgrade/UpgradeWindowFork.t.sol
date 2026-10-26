// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockUpgradeForkBase.sol";

/**
 * The upgrade hour, on a fork. A PLAIN mid-hour upgrade of the VVD mixes the
 * deployed implementation's hour-boundary dating with the new implementation's
 * `t+1` dating inside one hour, and the sequences below then double-count (the
 * re-add after a live in-hour retirement, and the same-block sandwich), panic
 * (retiring an in-hour booking from a delegatee with no weight) or
 * under-count (the same retirement from a delegatee with weight). Each is
 * re-run under the deploy/08 batch shape
 * (`upgradeAndCall(VVD, impl, armLegacyDatingWindow())`) and must be
 * anomaly-free: the re-add and both retirements at SEVEN execution instants of
 * the hour (`AutoRelockUpgradeForkBase._offsets`), the sandwich at three, with
 * a no-earlier-write control. The file also pins the window-arm value across
 * the hour, post-window equivalence with a fresh deployment, and the exact Safe
 * batch through `execTransaction`.
 */
contract UpgradeWindowForkTest is AutoRelockUpgradeForkBase {
    // "InWindow" readings are taken 2 s after the re-add; for the batch at B-1
    // (offset 3599) that is B+13, past the window.
    struct ReAddReadings {
        uint256 id;
        address delegatee;
        address retiredTo;
        uint256 positionWeight;
        uint256 boundary;
        uint256 upgradeAt;
        uint256 delegateeVotesInWindow;
        uint256 delegateeVotesInWindowWithoutWrites;
        uint256 delegateePastVotesInWindow;
        uint256 delegateePastVotesInWindowWithoutWrites;
        uint256 delegateePastVotesAfterB;
        uint256 delegateeVotesAfterB;
        uint256 delegateeVotesAfterBWithoutWrites;
        uint256 retiredToVotesInWindow;
        uint256 retiredToVotesAfterB;
    }

    /// @dev The re-add sequence: the deployed implementation retires the
    ///      record to `retiredTo` in-hour, the batch lands IN THE SAME BLOCK, and
    ///      the new implementation re-adds the record to A (12 s later, or
    ///      in the same block when `sameBlock_`, or at B+11 when the batch
    ///      landed at B-1).
    function _reAddAfterLiveRetirement(uint256 offset_, bool withLiveWrite_, bool sameBlock_)
        internal
        returns (ReAddReadings memory r)
    {
        address owner;
        (r.id, owner, r.delegatee) = _pickDelegated();
        r.retiredTo = address(uint160(uint256(keccak256("upgrade-hour-retired-to"))));
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + offset_);
        r.boundary = hourStart + HOUR;
        r.positionWeight = veHemi.balanceOfNFT(r.id);

        uint256 snap = vm.snapshotState();
        _upgradeBothAndArmWindow();
        if (!sameBlock_) _warpAndRollTo(block.timestamp + 12);
        _warpAndRollTo(block.timestamp + 2);
        r.delegateeVotesInWindowWithoutWrites = vvd.getVotes(r.delegatee);
        r.delegateePastVotesInWindowWithoutWrites = vvd.getPastVotes(r.delegatee, block.timestamp - 1);
        _toAfterBoundary(r.boundary);
        r.delegateeVotesAfterBWithoutWrites = vvd.getVotes(r.delegatee);
        vm.revertToState(snap);

        if (withLiveWrite_) {
            vm.prank(owner);
            vvd.delegate(r.id, r.retiredTo); // deployed implementation, in-hour
        }
        _upgradeBothAndArmWindow(); // same block
        r.upgradeAt = block.timestamp;
        if (!sameBlock_) _warpAndRollTo(block.timestamp + 12);
        vm.prank(owner);
        vvd.delegate(r.id, r.delegatee); // new implementation
        _warpAndRollTo(block.timestamp + 2);
        r.delegateeVotesInWindow = vvd.getVotes(r.delegatee);
        r.delegateePastVotesInWindow = vvd.getPastVotes(r.delegatee, block.timestamp - 1);
        r.retiredToVotesInWindow = vvd.getVotes(r.retiredTo);
        _toAfterBoundary(r.boundary);
        r.delegateeVotesAfterB = vvd.getVotes(r.delegatee);
        r.delegateePastVotesAfterB = vvd.getPastVotes(r.delegatee, sameBlock_ ? r.upgradeAt + 1 : r.upgradeAt + 13);
        r.retiredToVotesAfterB = vvd.getVotes(r.retiredTo);
        assertEq(vvd.delegation(r.id).delegatee, r.delegatee, "re-add: record not at A");
    }

    function _assertNoDoubleCount(ReAddReadings memory r, string memory tag) internal pure {
        uint256 tol = r.positionWeight / 1e6 + 1e15;
        assertApproxEqAbs(
            r.delegateeVotesInWindow,
            r.delegateeVotesInWindowWithoutWrites,
            tol,
            string.concat(tag, ": double count in the window")
        );
        assertApproxEqAbs(
            r.delegateePastVotesInWindow,
            r.delegateePastVotesInWindowWithoutWrites,
            tol,
            string.concat(tag, ": getPastVotes shows a double count")
        );
        assertEq(
            r.delegateePastVotesAfterB,
            r.delegateePastVotesInWindow,
            string.concat(tag, ": history restated (re-read after B)")
        );
        assertApproxEqAbs(r.delegateeVotesAfterB, r.delegateeVotesAfterBWithoutWrites, tol, string.concat(tag, ": after B"));
        assertEq(r.retiredToVotesInWindow, 0, string.concat(tag, ": retired-to delegatee holds weight in the window"));
        assertEq(r.retiredToVotesAfterB, 0, string.concat(tag, ": retired-to delegatee holds weight after B"));
    }

    /// Re-add after a live retirement (a plain mid-hour upgrade double-counts,
    /// frozen in history): no double count at any of the seven execution
    /// offsets (`_offsets`).
    function test_reAddAfterLiveRetirement_noDoubleCount_atSevenOffsets() public {
        if (!forkReady) return;
        uint256[7] memory o = _offsets();
        for (uint256 i; i < o.length; ++i) {
            uint256 snap = vm.snapshotState();
            ReAddReadings memory r = _reAddAfterLiveRetirement(o[i], true, false);
            emit log_named_uint("offset", o[i]);
            emit log_named_uint("  A votes (window)", r.delegateeVotesInWindow);
            emit log_named_uint("  A votes without the writes", r.delegateeVotesInWindowWithoutWrites);
            _assertNoDoubleCount(r, string.concat("re-add@", vm.toString(o[i])));
            vm.revertToState(snap);
        }
    }

    /// Same-block sandwich (a live write earlier in the SAME block as the
    /// batch): clean, including with the new implementation's re-add in that
    /// same block (the live-write / execTransaction / re-add sandwich).
    function test_sameBlockSandwich_noDoubleCount() public {
        if (!forkReady) return;
        uint256 snap = vm.snapshotState();
        _assertNoDoubleCount(_reAddAfterLiveRetirement(11, true, false), "same block, re-add in the next block");
        vm.revertToState(snap);
        _assertNoDoubleCount(_reAddAfterLiveRetirement(11, true, true), "sandwich");
        vm.revertToState(snap);
        _assertNoDoubleCount(_reAddAfterLiveRetirement(1799, true, true), "sandwich mid-hour");
        vm.revertToState(snap);
        _assertNoDoubleCount(_reAddAfterLiveRetirement(3587, true, true), "sandwich late hour");
    }

    /// CONTROL: no earlier write in the hour.
    function test_control_noEarlierWrite_noAnomaly() public {
        if (!forkReady) return;
        ReAddReadings memory r = _reAddAfterLiveRetirement(1799, false, false);
        uint256 tol = r.positionWeight / 1e6 + 1e15;
        assertApproxEqAbs(r.delegateeVotesInWindow, r.delegateeVotesInWindowWithoutWrites, tol, "control: in-window");
        assertApproxEqAbs(r.delegateeVotesAfterB, r.delegateeVotesAfterBWithoutWrites, tol, "control: after B");
    }

    /// Retiring a pre-upgrade in-hour booking from a delegatee with NO weight
    /// (after a plain upgrade: Panic(0x11), swallowed by VeHemi at every site)
    /// must succeed at every offset, with no weight at that booking delegatee
    /// ever and A whole.
    function _retireInHourBooking(uint256 offset_, bool withLiveWrite_)
        internal
        returns (
            uint256 delegateeVotesInWindow,
            uint256 delegateePastVotesAfterB,
            uint256 delegateeVotesAfterB,
            uint256 bookingDelegateeVotesInWindow,
            uint256 bookingDelegateeVotesAfterB,
            uint256 historyReadAt
        )
    {
        (uint256 id, address owner, address delegatee) = _pickDelegated();
        address bookingDelegatee = address(uint160(uint256(keccak256("upgrade-hour-booking-delegatee"))));
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 60);
        vm.prank(owner);
        vvd.delegate(id, bookingDelegatee);
        _warpAndRollTo(hourStart + HOUR + 60);
        vm.prank(owner);
        vvd.delegate(id, delegatee);
        uint256 boundary = hourStart + 3 * HOUR;
        _warpAndRollTo(hourStart + 2 * HOUR + offset_);
        if (withLiveWrite_) {
            vm.prank(owner);
            vvd.delegate(id, bookingDelegatee); // deployed writer, in the upgrade hour
            assertEq(vvd.getVotes(bookingDelegatee), 0, "premise: the booking delegatee holds no votes");
        }
        _upgradeBothAndArmWindow();
        _nextBlockOrSame(boundary);
        if (withLiveWrite_) {
            vm.prank(owner);
            vvd.delegate(id, delegatee); // Panic(0x11) after a plain upgrade
            assertEq(vvd.delegation(id).delegatee, delegatee, "retire: record not at A");
        }
        _warpAndRollTo(block.timestamp + 2);
        historyReadAt = block.timestamp - 1;
        delegateeVotesInWindow = vvd.getVotes(delegatee);
        bookingDelegateeVotesInWindow = vvd.getVotes(bookingDelegatee);
        _warpAndRollTo(boundary + 11);
        delegateeVotesAfterB = vvd.getVotes(delegatee);
        bookingDelegateeVotesAfterB = vvd.getVotes(bookingDelegatee);
        delegateePastVotesAfterB = vvd.getPastVotes(delegatee, historyReadAt);
    }

    function test_retireInHourBooking_noPanic_atSevenOffsets() public {
        if (!forkReady) return;
        uint256[7] memory o = _offsets();
        for (uint256 i; i < o.length; ++i) {
            uint256 snap = vm.snapshotState();
            (
                uint256 delegateeVotesInWindowWithoutWrites,
                uint256 delegateePastVotesAfterBWithoutWrites,
                uint256 delegateeVotesAfterBWithoutWrites,
                ,
                ,
            ) = _retireInHourBooking(o[i], false);
            vm.revertToState(snap);
            (
                uint256 delegateeVotesInWindow,
                uint256 delegateePastVotesAfterB,
                uint256 delegateeVotesAfterB,
                uint256 bookingDelegateeVotesInWindow,
                uint256 bookingDelegateeVotesAfterB,
            ) = _retireInHourBooking(o[i], true);
            vm.revertToState(snap);
            string memory tag = string.concat("retire@", vm.toString(o[i]));
            emit log_named_uint("offset", o[i]);
            emit log_named_uint("  A votes (window)", delegateeVotesInWindow);
            emit log_named_uint("  A votes without the writes", delegateeVotesInWindowWithoutWrites);
            uint256 tol = delegateeVotesInWindowWithoutWrites / 1e6 + 1e15;
            assertApproxEqAbs(
                delegateeVotesInWindow, delegateeVotesInWindowWithoutWrites, tol, string.concat(tag, ": A in the window")
            );
            assertApproxEqAbs(
                delegateePastVotesAfterB,
                delegateePastVotesAfterBWithoutWrites,
                tol,
                string.concat(tag, ": A history read after B")
            );
            assertApproxEqAbs(delegateeVotesAfterB, delegateeVotesAfterBWithoutWrites, tol, string.concat(tag, ": A after B"));
            assertEq(bookingDelegateeVotesInWindow, 0, string.concat(tag, ": booking delegatee in the window"));
            assertEq(bookingDelegateeVotesAfterB, 0, string.concat(tag, ": booking delegatee after B"));
        }
    }

    struct RetireRig {
        uint256 bookedId;
        address bookedOwner;
        address delegatee;
        uint256 bookedWeight;
        uint256 weightSourceId;
        address weightSourceOwner;
        address bookingDelegatee;
        uint256 boundary;
    }

    /// @dev Retires an in-hour booking from a delegatee with weight, at an
    ///      arbitrary booking-and-batch offset; returns the booking delegatee's
    ///      votes in the window and after B.
    function _retireInHourBookingAtWeightedDelegatee(RetireRig memory rig, bool withLiveWrite_)
        internal
        returns (uint256 bookingDelegateeVotesInWindow, uint256 bookingDelegateeVotesAfterB, bool reverted)
    {
        if (withLiveWrite_) {
            vm.prank(rig.bookedOwner);
            vvd.delegate(rig.bookedId, rig.bookingDelegatee); // deployed writer, in the upgrade hour
        }
        _upgradeBothAndArmWindow();
        _nextBlockOrSame(rig.boundary);
        if (withLiveWrite_) {
            vm.prank(rig.bookedOwner);
            try vvd.delegate(rig.bookedId, rig.delegatee) {} catch { reverted = true; }
        }
        _warpAndRollTo(block.timestamp + 2);
        bookingDelegateeVotesInWindow = vvd.getVotes(rig.bookingDelegatee);
        _warpAndRollTo(rig.boundary + 11);
        bookingDelegateeVotesAfterB = vvd.getVotes(rig.bookingDelegatee);
    }

    function test_retireInHourBookingAtWeightedDelegatee_noUnderCount_atSevenOffsets() public {
        if (!forkReady) return;
        uint256[7] memory o = _offsets();
        RetireRig memory rig;
        (rig.bookedId, rig.bookedOwner, rig.delegatee) = _pickDelegated();
        rig.bookedWeight = veHemi.balanceOfNFT(rig.bookedId);
        (rig.weightSourceId, rig.weightSourceOwner, ) = _pickDelegatedFrom(rig.bookedId + 1, 3 * rig.bookedWeight);
        rig.bookingDelegatee = address(uint160(uint256(keccak256("upgrade-hour-weighted-booking-delegatee"))));
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 60);
        vm.prank(rig.weightSourceOwner);
        vvd.delegate(rig.weightSourceId, rig.bookingDelegatee); // counted at the booking delegatee from hourStart + HOUR
        rig.boundary = hourStart + 2 * HOUR;
        for (uint256 i; i < o.length; ++i) {
            uint256 snap = vm.snapshotState();
            _warpAndRollTo(hourStart + HOUR + o[i]);
            uint256 offsetSnap = vm.snapshotState();
            (uint256 bookingDelegateeVotesInWindowWithoutWrites, uint256 bookingDelegateeVotesAfterBWithoutWrites, ) =
                _retireInHourBookingAtWeightedDelegatee(rig, false);
            vm.revertToState(offsetSnap);
            (uint256 bookingDelegateeVotesInWindow, uint256 bookingDelegateeVotesAfterB, bool reverted) =
                _retireInHourBookingAtWeightedDelegatee(rig, true);
            vm.revertToState(snap);
            string memory tag = string.concat("retire-weighted@", vm.toString(o[i]));
            uint256 tol = rig.bookedWeight / 1e6 + 1e15;
            assertFalse(reverted, string.concat(tag, ": retirement reverted"));
            assertApproxEqAbs(
                bookingDelegateeVotesInWindow,
                bookingDelegateeVotesInWindowWithoutWrites,
                tol,
                string.concat(tag, ": booking delegatee in the window")
            );
            assertApproxEqAbs(
                bookingDelegateeVotesAfterB,
                bookingDelegateeVotesAfterBWithoutWrites,
                tol,
                string.concat(tag, ": booking delegatee after B")
            );
        }
    }

    /// The window-arm value across the hour (block indexes k = 0, 1, 149, 298,
    /// 299): W == B for a batch at hourStart + 12k + 11, the event says
    /// (B, true), and at k = 299 (B-1) the first write after B is immediate.
    function test_windowArmSetsWindowEndToNextBoundary_atFiveBatchOffsets() public {
        if (!forkReady) return;
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        uint256[5] memory blockIndexes = [uint256(0), 1, 149, 298, 299];
        for (uint256 i; i < blockIndexes.length; ++i) {
            uint256 snap = vm.snapshotState();
            _warpAndRollTo(hourStart + 12 * blockIndexes[i] + 11);
            vm.recordLogs();
            _upgradeBothAndArmWindow();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 topic0 = keccak256("LegacyDatingWindowArmed(uint256,bool)");
            bool seen;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].emitter == VVD_PROXY && logs[j].topics[0] == topic0) {
                    (uint256 until, bool viaUpgradeCall) = abi.decode(logs[j].data, (uint256, bool));
                    assertEq(until, hourStart + HOUR, "window arm event: until");
                    assertTrue(viaUpgradeCall, "window arm event: viaUpgradeCall");
                    seen = true;
                }
            }
            assertTrue(seen, "window arm event missing");
            assertEq(uint256(vvd.legacyDatingUntil()), hourStart + HOUR, "window arm: W != B");
            assertEq(vvd.legacyDatingActive(), blockIndexes[i] != 299, "legacyDatingActive (false only at B-1)");
            if (blockIndexes[i] == 299) {
                (uint256 id, address owner, ) = _pickDelegated();
                _warpAndRollTo(hourStart + HOUR + 11);
                vm.prank(owner);
                vvd.delegate(id, address(uint160(uint256(keccak256("upgrade-hour-after-last-second-window-arm-target")))));
                assertEq(uint256(vvd.delegationBookedAt(id)), block.timestamp + 1, "post-B write not immediate");
            }
            vm.revertToState(snap);
        }
    }

    /// Post-window equivalence: after the window, writes are immediate (booking
    /// stamp now + 1, element at now + 1) and the result equals the same ops on
    /// a twin whose slot 101 was overwritten to the fresh-deployment sentinel 1.
    struct PostWindowCase {
        uint256 firstId;
        address firstOwner;
        address firstDelegatee;
        uint256 secondId;
        address secondOwner;
        address secondDelegatee;
        address sharedTarget;
    }

    function _postWindowOps(PostWindowCase memory p) internal returns (bytes32[] memory ev) {
        vm.recordLogs();
        vm.prank(p.firstOwner);
        vvd.delegate(p.firstId, p.sharedTarget);
        assertEq(uint256(vvd.delegationBookedAt(p.firstId)), block.timestamp + 1, "post-B booking stamp != now + 1");
        _warpAndRollTo(block.timestamp + 12);
        vm.prank(p.secondOwner);
        vvd.delegate(p.secondId, p.sharedTarget);
        vm.prank(p.firstOwner);
        vvd.delegate(p.firstId, p.secondDelegatee);
        try vvd.writeNewCheckpointForExpiredDelegations(p.firstDelegatee) {} catch {} // NoExpirations is fine
        vvd.refreshVotingPower(p.sharedTarget);
        ev = _delegateVotesChangedDigests(vm.getRecordedLogs());
    }

    function test_afterTheWindowCloses_writesMatchAFreshDeployment() public {
        if (!forkReady) return;
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 1211);
        _upgradeBothAndArmWindow();
        _warpAndRollTo(hourStart + HOUR + 11);
        assertFalse(vvd.legacyDatingActive(), "window still active after B");
        PostWindowCase memory p;
        (p.firstId, p.firstOwner, p.firstDelegatee) = _pickDelegated();
        (p.secondId, p.secondOwner, p.secondDelegatee) = _pickDelegatedFrom(p.firstId + 1, 1e18);
        p.sharedTarget = address(uint160(uint256(keccak256("upgrade-hour-post-window-target"))));
        address[] memory delegatees = new address[](3);
        delegatees[0] = p.firstDelegatee; delegatees[1] = p.secondDelegatee; delegatees[2] = p.sharedTarget;
        uint256[] memory ids = new uint256[](2);
        ids[0] = p.firstId; ids[1] = p.secondId;
        uint256[] memory keys = new uint256[](2);
        keys[0] = uint256(veHemi.getLockedBalance(p.firstId).end);
        keys[1] = uint256(veHemi.getLockedBalance(p.secondId).end);

        uint256 snap = vm.snapshotState();
        bytes32[] memory eventsAfterWindow = _postWindowOps(p);
        bytes32[] memory observedAfterWindow = _observe(delegatees, ids, keys);
        vm.revertToState(snap);
        vm.store(VVD_PROXY, bytes32(uint256(101)), bytes32(uint256(1)));
        bytes32[] memory eventsFreshDeployment = _postWindowOps(p);
        bytes32[] memory observedFreshDeployment = _observe(delegatees, ids, keys);
        _assertSameObservation(observedAfterWindow, observedFreshDeployment, "post-window");
        assertEq(
            keccak256(abi.encode(eventsAfterWindow)),
            keccak256(abi.encode(eventsFreshDeployment)),
            "post-window: events differ"
        );
    }

    /// Batch fidelity: the EXACT MultiSendCallOnly payload through
    /// Safe.execTransaction (owners' approveHash, v = 1), mid-hour, with a
    /// live write EARLIER in the same block and a new-implementation write
    /// LATER in it.
    function test_batchFidelity_execTransaction() public {
        if (!forkReady) return;
        assertGt(MULTISEND_CALL_ONLY.code.length, 0, "MultiSendCallOnly 1.4.1 absent at the fork block");
        _deployImplementationsOnce();
        (uint256 id, address owner, address delegatee) = _pickDelegated();
        address retiredTo = address(uint160(uint256(keccak256("upgrade-hour-batch-fidelity-retired-to"))));
        uint256 hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(hourStart + 1799);
        uint256 positionWeight = veHemi.balanceOfNFT(id);

        bytes memory leg0 = abi.encodeCall(IForkProxyAdmin.upgrade, (VEHEMI_PROXY, newVeHemiImpl));
        bytes memory leg1 = abi.encodeCall(IForkProxyAdmin.upgradeAndCall, (VVD_PROXY, newVvdImpl, _armWindowCalldata()));
        bytes memory txs = abi.encodePacked(
            uint8(0), PROXY_ADMIN, uint256(0), leg0.length, leg0,
            uint8(0), PROXY_ADMIN, uint256(0), leg1.length, leg1
        );
        bytes memory data = abi.encodeWithSignature("multiSend(bytes)", txs);

        // Counterfactual: the batch alone, same block.
        uint256 snap = vm.snapshotState();
        _execSafe(data);
        _warpAndRollTo(block.timestamp + 2);
        uint256 delegateeVotesInWindowWithoutWrites = vvd.getVotes(delegatee);
        _warpAndRollTo(hourStart + HOUR + 11);
        uint256 delegateeVotesAfterBWithoutWrites = vvd.getVotes(delegatee);
        vm.revertToState(snap);

        vm.prank(owner);
        vvd.delegate(id, retiredTo); // live write, same block, before the batch
        _execSafe(data);
        assertEq(uint256(vvd.legacyDatingUntil()), hourStart + HOUR, "fidelity: window not armed by the Safe batch");
        assertEq(address(uint160(uint256(vm.load(VVD_PROXY, IMPL_SLOT)))), newVvdImpl, "fidelity: VVD impl");
        assertEq(address(uint160(uint256(vm.load(VEHEMI_PROXY, IMPL_SLOT)))), newVeHemiImpl, "fidelity: VeHemi impl");
        vm.prank(owner);
        vvd.delegate(id, delegatee); // new-implementation write, same block, after the batch
        _warpAndRollTo(block.timestamp + 2);
        uint256 tol = positionWeight / 1e6 + 1e15;
        assertApproxEqAbs(vvd.getVotes(delegatee), delegateeVotesInWindowWithoutWrites, tol, "fidelity: A in the window");
        assertEq(vvd.getVotes(retiredTo), 0, "fidelity: retired-to delegatee in the window");
        _warpAndRollTo(hourStart + HOUR + 11);
        assertApproxEqAbs(vvd.getVotes(delegatee), delegateeVotesAfterBWithoutWrites, tol, "fidelity: A after B");
        assertEq(vvd.getVotes(retiredTo), 0, "fidelity: retired-to delegatee after B");
    }

    function _execSafe(bytes memory data) internal {
        (bool ok, bytes memory ret) = SAFE.staticcall(abi.encodeWithSignature("getOwners()"));
        require(ok, "getOwners");
        address[] memory owners = abi.decode(ret, (address[]));
        (ok, ret) = SAFE.staticcall(abi.encodeWithSignature("getThreshold()"));
        uint256 threshold = abi.decode(ret, (uint256));
        (ok, ret) = SAFE.staticcall(abi.encodeWithSignature("nonce()"));
        uint256 nonce = abi.decode(ret, (uint256));
        (ok, ret) = SAFE.staticcall(
            abi.encodeWithSignature(
                "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)",
                MULTISEND_CALL_ONLY, uint256(0), data, uint8(1), uint256(0), uint256(0), uint256(0), address(0), address(0), nonce
            )
        );
        bytes32 txHash = abi.decode(ret, (bytes32));
        // threshold owners, ascending
        address[] memory signers = new address[](threshold);
        for (uint256 i; i < threshold; ++i) signers[i] = owners[i];
        for (uint256 i; i < threshold; ++i) {
            for (uint256 j = i + 1; j < threshold; ++j) {
                if (signers[j] < signers[i]) (signers[i], signers[j]) = (signers[j], signers[i]);
            }
        }
        bytes memory sigs;
        for (uint256 i; i < threshold; ++i) {
            vm.prank(signers[i]);
            (ok, ) = SAFE.call(abi.encodeWithSignature("approveHash(bytes32)", txHash));
            require(ok, "approveHash");
            sigs = abi.encodePacked(sigs, bytes32(uint256(uint160(signers[i]))), bytes32(0), uint8(1));
        }
        vm.recordLogs();
        (ok, ret) = SAFE.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                MULTISEND_CALL_ONLY, uint256(0), data, uint8(1), uint256(0), uint256(0), uint256(0), address(0), payable(address(0)), sigs
            )
        );
        require(ok && abi.decode(ret, (bool)), "execTransaction");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, SAFE, keccak256("ExecutionSuccess(bytes32,uint256)")), 1, "Safe: no ExecutionSuccess");
    }
}

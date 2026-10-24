// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockUpgradeForkBase.sol";

interface IVoteDelegationOps {
    function delegateAllFor(address owner_, address delegatee_) external;
    function delegateBySig(uint256, address, uint256, uint256, uint8, bytes32, bytes32) external;
    function nonces(address) external view returns (uint256);
    function setAutoDelegate(address) external;
    function writeNewCheckpointForExpiredDelegations(address) external;
    function refreshVotingPower(address) external;
    function refreshVotingPowerBatch(address[] calldata) external;
    function getPastVotes(address, uint256) external view returns (uint256);
    function delegate(uint256, address) external;
}

interface IVeHemiOps {
    function createLock(uint256 amount, uint256 lockDuration) external returns (uint256);
    function increaseAmount(uint256 tokenId, uint256 amount) external;
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;
    function withdraw(uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function isTransferable(uint256 tokenId) external view returns (bool);
    function nextTokenId() external view returns (uint256);
}

/**
 * Live-writer parity for the upgrade-hour window. The same operation list
 * runs in two worlds from one forked state that already holds
 * deployed-implementation writes made earlier in the upgrade hour (moves, a
 * same-block burst):
 *   the live-writer world: VeHemi upgraded, VVD LEFT ON THE DEPLOYED
 *     IMPLEMENTATION (the live writer);
 *   the window world: the deploy/08 batch (VVD via
 *     upgradeAndCall(armLegacyDatingWindow())).
 * Every window write must leave the VVD in EXACTLY the raw state the live
 * writer leaves (checkpoint-array tails, expiration buckets, records), emit
 * the same DelegateVotesChanged stream, and serve the same getPastVotes on a
 * lattice spanning the hour and the next one (read after B + 1 h, through each
 * world's own reader). History at or before the upgrade instant (`upgradeAt`;
 * the window operations start 12 s later) never moves.
 */
contract UpgradeWindowLiveWriterParityForkTest is AutoRelockUpgradeForkBase {
    address constant ADAPTER = 0x3f41c138082b29fb1a6c91066e73480163f984e4;

    /// The window hour and the positions and delegatees the window operations
    /// touch, each named for its role in `_windowOps`.
    struct WindowScenario {
        uint256 hourStart; // the window hour's start
        uint256 upgradeAt; // the batch instant, hourStart + 1211
        uint256 boundary; // B, hourStart + HOUR
        uint256 recordEndInWindow; // a SIX_DAYS grid point inside the window hour
        uint256 expiredEnd; // a SIX_DAYS grid point before the window hour
        // booked in-hour at bookedTo by the live writer; moved to bookedTarget in the window
        uint256 bookedId; address bookedOwner; address bookedFrom;
        // retired in-hour from retiredFrom to retiredTo by the live writer; re-added in the window
        uint256 retiredId; address retiredOwner; address retiredFrom;
        uint256 soldId; address seller; address soldFrom; // transferred to buyer in the window
        uint256 toppedUpId; address toppedUpOwner; address toppedUpDelegatee; // topped up in the window
        uint256 extendedId; address extendedOwner; // ends at recordEndInWindow; extended in the window
        uint256 withdrawnId; address withdrawnOwner; // ends at expiredEnd; withdrawn in the window
        // amortiser: one expired + one unexpired decaying lock
        uint256 amortisedExpiredId; uint256 amortisedUnexpiredId; address amortisedOwner;
        // moved to signedTarget by signature, then to adapterTarget by the adapter
        uint256 signedId; address signer; uint256 signerKey;
        address creator; address autoDelegatee; // createLock auto-delegated to autoDelegatee
        address bookedTo; address retiredTo; address bookedTarget;
        address signedTarget; address adapterTarget; address buyer;
        // the live burst one block before the upgrade; ids 0-2 undone, id 3 moved in the window
        uint256[5] burstIds; address[5] burstOwners; address[5] burstFrom; address[5] burstTo;
        address burstMoveTarget; // burst id 3's target in the window
    }

    function _addr(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(s)))));
    }

    function _fund(address who, uint256 amt) internal {
        deal(HEMI_TOKEN, who, amt);
        vm.prank(who);
        IForkERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, type(uint256).max);
    }

    function _lockUntil(address who, uint256 end_) internal returns (uint256 id) {
        _fund(who, 100e18);
        vm.prank(who);
        id = IVeHemiOps(VEHEMI_PROXY).createLock(100e18, end_ - block.timestamp + 1);
        assertEq(uint256(veHemi.getLockedBalance(id).end), end_, "lock end not on the grid point");
    }

    function _pickTransferableDelegatedFrom(uint256 from_)
        internal
        view
        returns (uint256 id, address owner, address delegatee)
    {
        uint256 hi = vm.envOr("AUTORELOCK_FORK_SCAN_HI", uint256(29720));
        for (uint256 i = from_; i < hi; ++i) {
            (address d,,,,) = vvd.delegations(i);
            if (d == address(0)) continue;
            if (uint256(veHemi.getLockedBalance(i).end) < block.timestamp + 60 days) continue;
            if (!IVeHemiOps(VEHEMI_PROXY).isTransferable(i)) continue;
            if (veHemi.balanceOfNFT(i) < 1e18) continue;
            return (i, veHemi.ownerOf(i), d);
        }
        revert("no transferable delegated position");
    }

    /// @dev Shared pre-state: locks at t0, then deployed-implementation
    ///      writes in the window hour before the upgrade instant.
    function _scenarioWithInHourLiveWrites() internal returns (WindowScenario memory scenario) {
        uint256 t0 = block.timestamp;
        uint256 n = (t0 + 2 * SIX_DAYS + HOUR) / SIX_DAYS + 1;
        scenario.expiredEnd = n * SIX_DAYS;
        n = (scenario.expiredEnd + 2 * HOUR) / SIX_DAYS + 1;
        while ((n * SIX_DAYS) % HOUR < 1800) ++n;
        scenario.recordEndInWindow = n * SIX_DAYS;
        scenario.hourStart = scenario.recordEndInWindow - (scenario.recordEndInWindow % HOUR);
        scenario.upgradeAt = scenario.hourStart + 1211;
        scenario.boundary = scenario.hourStart + HOUR;
        scenario.extendedOwner = _addr("live-writer-extended-owner");
        scenario.withdrawnOwner = _addr("live-writer-withdrawn-owner");
        scenario.amortisedOwner = _addr("live-writer-amortised-owner");
        scenario.signerKey = uint256(keccak256("live-writer-signer-key"));
        scenario.signer = vm.addr(scenario.signerKey);
        scenario.creator = _addr("live-writer-creator");
        scenario.autoDelegatee = _addr("live-writer-auto-delegatee");
        scenario.bookedTo = _addr("live-writer-booked-to");
        scenario.retiredTo = _addr("live-writer-retired-to");
        scenario.bookedTarget = _addr("live-writer-booked-target");
        scenario.signedTarget = _addr("live-writer-signed-target");
        scenario.adapterTarget = _addr("live-writer-adapter-target");
        scenario.buyer = _addr("live-writer-buyer");
        scenario.burstMoveTarget = _addr("live-writer-burst-move-target");
        // t0: deployed VeHemi + VVD.
        scenario.withdrawnId = _lockUntil(scenario.withdrawnOwner, scenario.expiredEnd);
        scenario.extendedId = _lockUntil(scenario.extendedOwner, scenario.recordEndInWindow);
        scenario.amortisedExpiredId = _lockUntil(scenario.amortisedOwner, scenario.expiredEnd);
        scenario.amortisedUnexpiredId = _lockUntil(scenario.amortisedOwner, ((t0 + 300 days) / SIX_DAYS) * SIX_DAYS);
        scenario.signedId = _lockUntil(scenario.signer, ((t0 + 200 days) / SIX_DAYS) * SIX_DAYS);
        _fund(scenario.creator, 100e18);
        vm.prank(scenario.creator);
        IVoteDelegationOps(VVD_PROXY).setAutoDelegate(scenario.autoDelegatee);

        // The window hour.
        _warpAndRollTo(scenario.hourStart + 611);
        (scenario.bookedId, scenario.bookedOwner, scenario.bookedFrom) = _pickDelegated();
        (scenario.retiredId, scenario.retiredOwner, scenario.retiredFrom) = _pickDelegatedFrom(scenario.bookedId + 1, 1e18);
        (scenario.toppedUpId, scenario.toppedUpOwner, scenario.toppedUpDelegatee) = _pickDelegatedFrom(scenario.retiredId + 1, 1e18);
        (scenario.soldId, scenario.seller, scenario.soldFrom) = _pickTransferableDelegatedFrom(scenario.toppedUpId + 1);
        _fund(scenario.toppedUpOwner, 10e18);
        uint256 next = scenario.soldId + 1;
        for (uint256 i; i < 5; ++i) {
            (scenario.burstIds[i], scenario.burstOwners[i], scenario.burstFrom[i]) = _pickDelegatedFrom(next, 1e18);
            next = scenario.burstIds[i] + 1;
            scenario.burstTo[i] = _addr(string.concat("live-writer-burst-to-", vm.toString(i)));
        }
        // live: in-hour booking at bookedTo, an unused delegatee (len 1, pending only)
        vm.prank(scenario.bookedOwner);
        vvd.delegate(scenario.bookedId, scenario.bookedTo);
        vm.prank(scenario.retiredOwner);
        vvd.delegate(scenario.retiredId, scenario.retiredTo); // live: in-hour retirement from its delegatee
        _warpAndRollTo(scenario.upgradeAt - 12);
        for (uint256 i; i < 5; ++i) {
            vm.prank(scenario.burstOwners[i]);
            vvd.delegate(scenario.burstIds[i], scenario.burstTo[i]); // live burst, one block before the upgrade
        }
        _warpAndRollTo(scenario.upgradeAt);
    }

    function _observedDelegatees(WindowScenario memory scenario) internal pure returns (address[] memory delegatees) {
        delegatees = new address[](27);
        address[21] memory x = [
            scenario.bookedFrom, scenario.bookedTo, scenario.bookedTarget, scenario.retiredFrom,
            scenario.retiredTo, scenario.signedTarget, scenario.adapterTarget, scenario.signer,
            scenario.soldFrom, scenario.buyer, scenario.toppedUpDelegatee, scenario.extendedOwner,
            scenario.withdrawnOwner, scenario.autoDelegatee, scenario.creator, scenario.burstMoveTarget,
            scenario.seller, scenario.burstFrom[0], scenario.burstFrom[1], scenario.burstFrom[2],
            scenario.burstFrom[3]
        ];
        for (uint256 i; i < 21; ++i) delegatees[i] = x[i];
        delegatees[21] = scenario.burstFrom[4];
        for (uint256 i; i < 4; ++i) delegatees[22 + i] = scenario.burstTo[i];
        delegatees[26] = scenario.amortisedOwner;
    }

    function _observedIds(WindowScenario memory scenario) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](13);
        uint256[8] memory x = [
            scenario.bookedId, scenario.retiredId, scenario.soldId, scenario.toppedUpId, scenario.extendedId,
            scenario.withdrawnId, scenario.signedId, scenario.amortisedUnexpiredId
        ];
        for (uint256 i; i < 8; ++i) ids[i] = x[i];
        for (uint256 i; i < 5; ++i) ids[8 + i] = scenario.burstIds[i];
    }

    function _bucketKeys(WindowScenario memory scenario, uint256 autoDelegatedLockId) internal view returns (uint256[] memory keys) {
        uint256[] memory ids = _observedIds(scenario);
        keys = new uint256[](ids.length + 3);
        for (uint256 i; i < ids.length; ++i) keys[i] = uint256(veHemi.getLockedBalance(ids[i]).end);
        keys[ids.length] = scenario.recordEndInWindow;
        keys[ids.length + 1] = scenario.expiredEnd;
        keys[ids.length + 2] = autoDelegatedLockId == 0 ? 0 : uint256(veHemi.getLockedBalance(autoDelegatedLockId).end);
    }

    /// @dev The window operation list (upgradeAt + 12 .. upgradeAt + 84; all
    ///      before recordEndInWindow).
    function _windowOps(WindowScenario memory scenario) internal returns (uint256 autoDelegatedLockId) {
        _warpAndRollTo(scenario.upgradeAt + 12);
        vm.prank(scenario.bookedOwner);
        vvd.delegate(scenario.bookedId, scenario.bookedTarget); // retire a legacy in-hour booking
        vm.prank(scenario.retiredOwner);
        vvd.delegate(scenario.retiredId, scenario.retiredFrom); // re-add a legacy in-hour retirement
        _warpAndRollTo(scenario.upgradeAt + 24);
        {
            uint256 nonce = IVoteDelegationOps(VVD_PROXY).nonces(scenario.signer);
            uint256 expiry = block.timestamp + 1 days;
            bytes32 domainSeparator = keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("veHEMIDelegation")), keccak256(bytes("1.0.0")), block.chainid, VVD_PROXY));
            bytes32 structHash = keccak256(abi.encode(
                keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)"),
                scenario.signedId, scenario.signedTarget, nonce, expiry));
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(scenario.signerKey, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
            IVoteDelegationOps(VVD_PROXY).delegateBySig(scenario.signedId, scenario.signedTarget, nonce, expiry, v, r, s);
        }
        // window -> window move of the signed position
        vm.prank(ADAPTER);
        IVoteDelegationOps(VVD_PROXY).delegateAllFor(scenario.signer, scenario.adapterTarget);
        _warpAndRollTo(scenario.upgradeAt + 36);
        vm.prank(scenario.seller);
        IVeHemiOps(VEHEMI_PROXY).transferFrom(scenario.seller, scenario.buyer, scenario.soldId);
        vm.prank(scenario.creator);
        autoDelegatedLockId = IVeHemiOps(VEHEMI_PROXY).createLock(100e18, 3 * SIX_DAYS); // auto-delegated
        _warpAndRollTo(scenario.upgradeAt + 48);
        vm.prank(scenario.toppedUpOwner);
        IVeHemiOps(VEHEMI_PROXY).increaseAmount(scenario.toppedUpId, 10e18);
        // retire a record whose end (recordEndInWindow) is in (now+1, B]
        vm.prank(scenario.extendedOwner);
        IVeHemiOps(VEHEMI_PROXY).increaseUnlockTime(scenario.extendedId, 4 * SIX_DAYS);
        _warpAndRollTo(scenario.upgradeAt + 60);
        try IVoteDelegationOps(VVD_PROXY).writeNewCheckpointForExpiredDelegations(scenario.withdrawnOwner) {} catch {}
        // amortiser on a delegatee with a due bucket AND unexpired decaying weight:
        // its event values differ between `block.timestamp + 1` and B.
        IVoteDelegationOps(VVD_PROXY).writeNewCheckpointForExpiredDelegations(scenario.amortisedOwner);
        vm.prank(scenario.withdrawnOwner);
        IVeHemiOps(VEHEMI_PROXY).withdraw(scenario.withdrawnId); // retire an EXPIRED record (burn)
        _warpAndRollTo(scenario.upgradeAt + 72);
        for (uint256 i; i < 3; ++i) {
            vm.prank(scenario.burstOwners[i]);
            vvd.delegate(scenario.burstIds[i], scenario.burstFrom[i]); // undo the live burst
        }
        vm.prank(scenario.burstOwners[3]);
        vvd.delegate(scenario.burstIds[3], scenario.burstMoveTarget);
        _warpAndRollTo(scenario.upgradeAt + 84);
        IVoteDelegationOps(VVD_PROXY).refreshVotingPower(scenario.bookedFrom);
        address[] memory batch = new address[](3);
        batch[0] = scenario.bookedTarget; batch[1] = scenario.retiredFrom; batch[2] = scenario.bookedTo;
        IVoteDelegationOps(VVD_PROXY).refreshVotingPowerBatch(batch);
    }

    function _lattice(WindowScenario memory scenario) internal pure returns (uint256[12] memory latticeInstants) {
        latticeInstants = [
            scenario.hourStart + 1, scenario.hourStart + 612, scenario.upgradeAt - 1, scenario.upgradeAt, scenario.upgradeAt + 13,
            scenario.upgradeAt + 49, scenario.upgradeAt + 85, scenario.boundary - 1, scenario.boundary, scenario.boundary + 1,
            scenario.boundary + 1800, scenario.boundary + HOUR
        ];
    }

    struct WorldObservation {
        bytes32[] rawState;
        bytes32[] voteEvents;
        uint256[] pastVotes;
        uint256[] history;
    }

    function _historyInstants(WindowScenario memory scenario) internal pure returns (uint256[4] memory instants) {
        instants = [scenario.hourStart + 1, scenario.hourStart + 612, scenario.upgradeAt - 12, scenario.upgradeAt];
    }

    function _readHistory(WindowScenario memory scenario, address[] memory delegatees) internal view returns (uint256[] memory out) {
        uint256[4] memory instants = _historyInstants(scenario);
        out = new uint256[](delegatees.length * 4);
        for (uint256 i; i < delegatees.length; ++i) {
            for (uint256 j; j < 4; ++j) out[i * 4 + j] = IVoteDelegationOps(VVD_PROXY).getPastVotes(delegatees[i], instants[j]);
        }
    }

    function _world(WindowScenario memory scenario, bool window_) internal returns (WorldObservation memory observation) {
        if (window_) _upgradeBothAndArmWindow();
        else _upgradeVeHemiOnly();
        address[] memory delegatees = _observedDelegatees(scenario);
        uint256[] memory historyBefore = _readHistory(scenario, delegatees);
        vm.recordLogs();
        uint256 autoDelegatedLockId = _windowOps(scenario);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        observation.voteEvents = _delegateVotesChangedDigests(logs);
        // Non-vacuity: the ops really ran, and nothing was swallowed.
        assertGe(observation.voteEvents.length, 25, "parity: too few DelegateVotesChanged events -- ops did not run");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("DelegationUpdateFailed(uint256)")), 0, "parity: DelegationUpdateFailed emitted");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("DelegationUpdateFailedReason(uint256,bytes4)")), 0, "parity: DelegationUpdateFailedReason emitted");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("AutoRelockRetirementUnverified(uint256)")), 0, "parity: AutoRelockRetirementUnverified emitted");
        _postconditions(scenario, autoDelegatedLockId);
        if (window_) {
            assertEq(uint256(vvd.delegationBookedAt(scenario.bookedId)), scenario.boundary, "window world: booking stamp != B");
            assertEq(
                uint256(vvd.delegationBookedAt(autoDelegatedLockId)), scenario.boundary, "window world: booking stamp (createLock) != B"
            );
        }
        _toAfterBoundary(scenario.boundary + HOUR);
        observation.history = _readHistory(scenario, delegatees);
        for (uint256 i; i < historyBefore.length; ++i) {
            assertEq(observation.history[i], historyBefore[i], "history at or before the upgrade restated");
        }
        observation.rawState = _observeTails(delegatees, _observedIds(scenario), _bucketKeys(scenario, autoDelegatedLockId));
        uint256[12] memory latticeInstants = _lattice(scenario);
        observation.pastVotes = new uint256[](delegatees.length * 12);
        for (uint256 i; i < delegatees.length; ++i) {
            for (uint256 j; j < 12; ++j) observation.pastVotes[i * 12 + j] = IVoteDelegationOps(VVD_PROXY).getPastVotes(delegatees[i], latticeInstants[j]);
        }
        // truth after B (live semantics): the window moves have landed.
        (address bookedDelegatee,,,,) = vvd.delegations(scenario.bookedId);
        assertEq(bookedDelegatee, scenario.bookedTarget, "booked position not at its window target");
        assertEq(vvd.getVotes(scenario.bookedTo), 0, "bookedTo (the in-hour booking's delegatee) kept weight");
    }

    /// @dev Per-op record postconditions (same in both worlds).
    function _postconditions(WindowScenario memory scenario, uint256 autoDelegatedLockId) internal view {
        (address d,,,,) = vvd.delegations(scenario.retiredId);
        assertEq(d, scenario.retiredFrom, "post: retired position not back at its delegatee");
        (d,,,,) = vvd.delegations(scenario.signedId);
        assertEq(d, scenario.adapterTarget, "post: signed position not at the adapter target (bySig then delegateAllFor)");
        (d,,,,) = vvd.delegations(scenario.soldId);
        assertEq(d, scenario.buyer, "post: sold position not at the buyer");
        (d,,,,) = vvd.delegations(autoDelegatedLockId);
        assertEq(d, scenario.autoDelegatee, "post: createLock not auto-delegated to the auto-delegatee");
        uint48 recordEnd;
        (d, recordEnd,,,) = vvd.delegations(scenario.extendedId);
        assertEq(d, scenario.extendedOwner, "post: extended position's delegatee");
        assertGt(uint256(recordEnd), scenario.recordEndInWindow, "post: extended record end not past recordEndInWindow");
        (d,,,,) = vvd.delegations(scenario.withdrawnId);
        assertEq(d, address(0), "post: withdrawn record not deleted");
        for (uint256 i; i < 3; ++i) {
            (d,,,,) = vvd.delegations(scenario.burstIds[i]);
            assertEq(d, scenario.burstFrom[i], "post: burst not undone");
        }
        (d,,,,) = vvd.delegations(scenario.burstIds[3]);
        assertEq(d, scenario.burstMoveTarget, "post: burst id 3 not at the burst move target");
    }

    // tails: the elements a write can touch are the last two pre-existing and anything after.
    mapping(address => uint256) internal _tailFrom;

    function _recordTails(address[] memory delegatees) internal {
        for (uint256 i; i < delegatees.length; ++i) {
            uint256 len = uint256(vm.load(VVD_PROXY, _checkpointArraySlot(delegatees[i])));
            _tailFrom[delegatees[i]] = len >= 2 ? len - 2 : 0;
        }
    }

    function _observeTails(address[] memory delegatees, uint256[] memory ids, uint256[] memory keys)
        internal
        view
        returns (bytes32[] memory items)
    {
        items = new bytes32[](delegatees.length * (1 + keys.length) + ids.length);
        uint256 n;
        for (uint256 i; i < delegatees.length; ++i) {
            bytes32 arraySlot = _checkpointArraySlot(delegatees[i]);
            uint256 len = uint256(vm.load(VVD_PROXY, arraySlot));
            uint256 from = _tailFrom[delegatees[i]];
            bytes32[] memory words = new bytes32[](1 + 2 * (len - from));
            words[0] = bytes32(len);
            uint256 data = uint256(keccak256(abi.encode(arraySlot)));
            for (uint256 j = 2 * from; j < 2 * len; ++j) words[1 + j - 2 * from] = vm.load(VVD_PROXY, bytes32(data + j));
            items[n++] = keccak256(abi.encode(words));
            for (uint256 j; j < keys.length; ++j) items[n++] = _rawBucket(delegatees[i], keys[j]);
        }
        for (uint256 i; i < ids.length; ++i) {
            (bytes32 recordWord0, bytes32 recordWord1) = _rawRecord(ids[i]);
            items[n++] = keccak256(abi.encode(recordWord0, recordWord1));
        }
    }

    function test_windowWritesMatchTheLiveWriter() public {
        if (!forkReady) return;
        WindowScenario memory scenario = _scenarioWithInHourLiveWrites();
        _recordTails(_observedDelegatees(scenario));
        uint256 snap = vm.snapshotState();
        WorldObservation memory liveWorld = _world(scenario, false);
        vm.revertToState(snap);
        WorldObservation memory windowWorld = _world(scenario, true);
        emit log_named_uint("window hour start", scenario.hourStart);
        emit log_named_uint("record end inside the window", scenario.recordEndInWindow);
        emit log_named_uint("DelegateVotesChanged events (live-writer world)", liveWorld.voteEvents.length);
        emit log_named_uint("DelegateVotesChanged events (window world)", windowWorld.voteEvents.length);
        _assertSameObservation(liveWorld.rawState, windowWorld.rawState, "parity");
        assertEq(liveWorld.voteEvents.length, windowWorld.voteEvents.length, "parity: event count");
        for (uint256 i; i < liveWorld.voteEvents.length; ++i) {
            if (liveWorld.voteEvents[i] != windowWorld.voteEvents[i]) emit log_named_uint("parity: event mismatch at", i);
        }
        assertEq(
            keccak256(abi.encode(liveWorld.voteEvents)),
            keccak256(abi.encode(windowWorld.voteEvents)),
            "parity: DelegateVotesChanged stream differs"
        );
        for (uint256 i; i < liveWorld.pastVotes.length; ++i) {
            if (liveWorld.pastVotes[i] != windowWorld.pastVotes[i]) emit log_named_uint("parity: getPastVotes mismatch at", i);
        }
        assertEq(
            keccak256(abi.encode(liveWorld.pastVotes)),
            keccak256(abi.encode(windowWorld.pastVotes)),
            "parity: getPastVotes lattice differs"
        );
        assertEq(
            keccak256(abi.encode(liveWorld.history)),
            keccak256(abi.encode(windowWorld.history)),
            "parity: history differs"
        );
    }

    struct PendingOnlyCase {
        uint256 movedInId; address movedInOwner; address movedInFrom;
        uint256 movedOutId; address movedOutOwner; address movedOutOriginalDelegatee;
        address pendingOnlyDelegatee; address moveOutTarget; uint256 hourStart;
        address[] observedDelegatees; uint256[] observedIds; uint256[] bucketKeys;
    }

    function _pendingOnlyWorld(PendingOnlyCase memory c, bool window_)
        internal
        returns (bytes32[] memory rawState, bytes32[] memory voteEvents, uint256[16] memory pastVotes)
    {
        if (window_) _upgradeBothAndArmWindow();
        else _upgradeVeHemiOnly();
        vm.recordLogs();
        _warpAndRollTo(c.hourStart + 1223);
        vm.prank(c.movedInOwner);
        vvd.delegate(c.movedInId, c.pendingOnlyDelegatee);
        _warpAndRollTo(c.hourStart + 1235);
        vm.prank(c.movedOutOwner);
        vvd.delegate(c.movedOutId, c.moveOutTarget);
        voteEvents = _delegateVotesChangedDigests(vm.getRecordedLogs());
        _warpAndRollTo(c.hourStart + 2 * HOUR + 11);
        rawState = _observeTails(c.observedDelegatees, c.observedIds, c.bucketKeys);
        uint256[4] memory readAt =
            [c.hourStart + 1224, c.hourStart + 1236, c.hourStart + HOUR - 1, c.hourStart + HOUR + 1];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) pastVotes[i * 4 + j] = IVoteDelegationOps(VVD_PROXY).getPastVotes(c.observedDelegatees[i], readAt[j]);
        }
        assertApproxEqAbs(
            vvd.getVotes(c.pendingOnlyDelegatee), veHemi.balanceOfNFT(c.movedInId), 1e12,
            "pending-only delegatee after B != the moved-in position's weight"
        );
        assertApproxEqAbs(
            vvd.getVotes(c.moveOutTarget), veHemi.balanceOfNFT(c.movedOutId), 1e12,
            "move-out target after B != the moved-out position's weight"
        );
    }

    /// A pending-only delegatee (checkpoint array of length 1): the live writer
    /// books the moved-out position at it in the hour; in the window the
    /// moved-in position moves from A to it, then the moved-out position moves
    /// on to the move-out target. Equal to the live writer, and after B the
    /// truth.
    function test_pendingOnlyDelegatee_moveInMoveOut_matchesTheLiveWriter() public {
        if (!forkReady) return;
        PendingOnlyCase memory c;
        (c.movedInId, c.movedInOwner, c.movedInFrom) = _pickDelegated();
        (c.movedOutId, c.movedOutOwner, c.movedOutOriginalDelegatee) = _pickDelegatedFrom(c.movedInId + 1, 1e18);
        c.pendingOnlyDelegatee = _addr("live-writer-pending-only-delegatee");
        c.moveOutTarget = _addr("live-writer-pending-only-target");
        c.hourStart = _nextHourBoundary(block.timestamp);
        _warpAndRollTo(c.hourStart + 611);
        vm.prank(c.movedOutOwner);
        vvd.delegate(c.movedOutId, c.pendingOnlyDelegatee);
        assertEq(
            uint256(vm.load(VVD_PROXY, _checkpointArraySlot(c.pendingOnlyDelegatee))), 1,
            "premise: the pending-only delegatee has one checkpoint"
        );
        c.observedDelegatees = new address[](4);
        c.observedDelegatees[0] = c.movedInFrom; c.observedDelegatees[1] = c.pendingOnlyDelegatee;
        c.observedDelegatees[2] = c.moveOutTarget; c.observedDelegatees[3] = c.movedOutOriginalDelegatee;
        _recordTails(c.observedDelegatees);
        c.observedIds = new uint256[](2);
        c.observedIds[0] = c.movedInId; c.observedIds[1] = c.movedOutId;
        c.bucketKeys = new uint256[](2);
        c.bucketKeys[0] = uint256(veHemi.getLockedBalance(c.movedInId).end);
        c.bucketKeys[1] = uint256(veHemi.getLockedBalance(c.movedOutId).end);
        _warpAndRollTo(c.hourStart + 1211);
        uint256 snap = vm.snapshotState();
        (bytes32[] memory rawLive, bytes32[] memory eventsLive, uint256[16] memory pastLive) =
            _pendingOnlyWorld(c, false);
        vm.revertToState(snap);
        (bytes32[] memory rawWindow, bytes32[] memory eventsWindow, uint256[16] memory pastWindow) =
            _pendingOnlyWorld(c, true);
        _assertSameObservation(rawLive, rawWindow, "pending-only");
        assertEq(keccak256(abi.encode(eventsLive)), keccak256(abi.encode(eventsWindow)), "pending-only: events differ");
        for (uint256 i; i < 16; ++i) assertEq(pastLive[i], pastWindow[i], "pending-only: getPastVotes differs");
    }
}

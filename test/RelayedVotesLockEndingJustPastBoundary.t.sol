// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title RelayedVotesLockEndingJustPastBoundaryTest
/// @notice `DelegateVotesChanged.newVotes` (relayed to the adapter through
///         `IAdapterNotify.notifyVotesChanged`:
///         DelegateVotesChangedInstant E3) must equal the delegatee's votes
///         at the instant the change takes effect,
///         `block.timestamp + 1`, even when the delegator's lock ends 360 s
///         after the next hour boundary and the delegation is made at the
///         start of that hour.
contract RelayedVotesLockEndingJustPastBoundaryTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);
    address internal constant DEL_A   = address(0xA1);

    function _nextHourBoundary(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _lastEmittedNewVotes(address who) internal returns (uint256 nv) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == sig
                && logs[i].topics[1] == bytes32(uint256(uint160(who)))) {
                (, uint256 v) = abi.decode(logs[i].data, (uint256, uint256));
                nv = v;
            }
        }
    }

    function test_relayedNewVotesEqualsEffectiveVotes_lockEndingJustPastTheBoundary() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);

        // Find a lock duration whose `end` sits 360 s past an hour boundary:
        // then the hour starting at end-3960 has its boundary at end-360,
        // i.e. the lock survives the boundary by the smallest margin the
        // SIX_DAYS end grid allows.
        uint256 id;
        uint256 E;
        for (uint256 j = 20; j < 40; ++j) {
            uint256 snap = vm.snapshotState();
            hemi.mint(MALLORY, 1000 ether);
            vm.prank(MALLORY); hemi.approve(address(veHemi), type(uint256).max);
            vm.prank(MALLORY); uint256 trialId = veHemi.createLock(1000 ether, j * SIX_DAYS);
            uint256 trialEnd = veHemi.getLockedBalance(trialId).end;
            vm.revertToState(snap);
            if (trialEnd % 1 hours == 360) {
                hemi.mint(MALLORY, 1000 ether);
                vm.prank(MALLORY); hemi.approve(address(veHemi), type(uint256).max);
                vm.prank(MALLORY); id = veHemi.createLock(1000 ether, j * SIX_DAYS);
                E = veHemi.getLockedBalance(id).end;
                break;
            }
        }
        require(E != 0, "no duration with the wanted end offset");
        emit log_named_uint("lock end E                      ", E);
        emit log_named_uint("E mod 1 hour                    ", E % 1 hours);

        uint256 T = E - 3960;                 // the START of the hour whose boundary is E-360
        assertEq(_nextHourBoundary(T), E - 360, "premise: the next hour boundary is 360 s before the end");
        vm.warp(T);

        vm.recordLogs();
        vm.prank(MALLORY); delegation.delegate(id, DEL_A);
        uint256 emittedNewVotes = _lastEmittedNewVotes(DEL_A);

        // DEL_A was empty before, so any non-zero reading is the new booking.
        uint256 effective;
        for (uint256 t = T + 1; t <= E - 360; ++t) {
            vm.warp(t);
            if (delegation.getVotes(DEL_A) != 0) { effective = t; break; }
        }
        vm.warp(effective);
        uint256 actual = delegation.getVotes(DEL_A);
        vm.warp(E - 360);
        uint256 atBoundary = delegation.getVotes(DEL_A);

        emit log_named_uint("delegation made at T            ", T);
        emit log_named_uint("hour boundary                   ", E - 360);
        emit log_named_uint("FIRST effective instant         ", effective);
        emit log_named_uint("EMITTED newVotes                ", emittedNewVotes);
        emit log_named_uint("ACTUAL votes at that instant    ", actual);
        emit log_named_uint("getVotes at the boundary        ", atBoundary);
        emit log_named_uint("understatement (wei)            ",
            actual > emittedNewVotes ? actual - emittedNewVotes : 0);
        emit log_named_uint("emitted as % of actual          ", actual == 0 ? 0 : (emittedNewVotes * 100) / actual);

        assertEq(emittedNewVotes, actual,
            "the emitted newVotes must equal the votes at the instant the change becomes effective");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title O05RelayTest
/// @notice The relayed-event seam at its worst ratio. `DelegateVotesChanged.newVotes`
///         (the number relayed to the Aragon adapter through
///         `IAdapterNotify.notifyVotesChanged`) must equal the delegatee's votes
///         at the instant the change takes effect, `block.timestamp + 1`, even
///         when the delegator's lock ends 360 s after the next hour boundary
///         and the delegation is made at the start of that hour.
contract O05RelayTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);
    address internal constant DEL_A   = address(0xA1);

    function _b(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _relayed(address who) internal returns (uint256 nv) {
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

    function test_O05_C3_relaySeamWorstRatio() public {
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
            vm.prank(MALLORY); uint256 cand = veHemi.createLock(1000 ether, j * SIX_DAYS);
            uint256 candEnd = veHemi.getLockedBalance(cand).end;
            vm.revertToState(snap);
            if (candEnd % 1 hours == 360) {
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
        assertEq(_b(T), E - 360, "construction");
        vm.warp(T);

        vm.recordLogs();
        vm.prank(MALLORY); delegation.delegate(id, DEL_A);
        uint256 relayed = _relayed(DEL_A);

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
        emit log_named_uint("RELAYED newVotes                ", relayed);
        emit log_named_uint("ACTUAL votes at that instant    ", actual);
        emit log_named_uint("getVotes at the boundary        ", atBoundary);
        emit log_named_uint("understatement (wei)            ", actual > relayed ? actual - relayed : 0);
        emit log_named_uint("relayed as % of actual          ", actual == 0 ? 0 : (relayed * 100) / actual);

        assertEq(relayed, actual,
            "the relayed newVotes must equal the votes at the instant the change becomes effective");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title RelayExpiringThisHourTest
/// @notice The emitted `DelegateVotesChanged.newVotes` (the adapter relays
///         this value: DelegateVotesChangedInstant E3) counts a position that
///         expires later in the same hour: it equals the delegatee's votes at
///         the instant the change takes effect.
contract RelayExpiringThisHourTest is LockedCurveTestBase {
    address internal constant MALLORY  = address(0xBAD0);
    address internal constant DEL_A    = address(0xA1);
    address internal constant VICTIM   = address(0x1C70);

    function _nextHourBoundary(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    // =====================================================================
    // THE RELAY WHEN A DELEGATED POSITION EXPIRES IN THE SAME HOUR. The
    // victim's lock ends 60 s after the relay is triggered and before the next
    // hour boundary; the attacker triggers the relay by delegating her own
    // token into the victim's delegatee (free and ungated). The emitted
    // `newVotes` must still include the victim, who is live at the effective
    // instant.
    // =====================================================================
    function test_relayCountsAPositionExpiringThisHour() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 victimId = _mk(VICTIM, 500 ether, 20 * SIX_DAYS);
        vm.prank(VICTIM); delegation.delegate(victimId, DEL_A);
        uint256 malloryId = _mk(MALLORY, 10 ether, 200 * SIX_DAYS);

        uint256 E = veHemi.getLockedBalance(victimId).end;
        uint256 offset = E % 1 hours;
        emit log_named_uint("victim lock end E               ", E);
        emit log_named_uint("E mod 1 hour                    ", offset);
        require(offset >= 120, "need the expiry away from the hour edge");

        uint256 T = E - 60;                       // same hour as E, 60 s before expiry
        vm.warp(T);
        uint256 delAbefore = delegation.getVotes(DEL_A);

        vm.recordLogs();
        vm.prank(MALLORY); delegation.delegate(malloryId, DEL_A);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 emittedNewVotes;
        uint256 emittedEventCount;
        bytes32 sig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == sig
                && logs[i].topics[1] == bytes32(uint256(uint160(DEL_A)))) {
                (, uint256 nv) = abi.decode(logs[i].data, (uint256, uint256));
                emittedNewVotes = nv;
                ++emittedEventCount;
            }
        }
        assertGt(emittedEventCount, 0, "NON-VACUOUS: the delegate emitted no DelegateVotesChanged for DEL_A");

        uint256 effective;
        for (uint256 t = T + 1; t <= _nextHourBoundary(T); ++t) {
            vm.warp(t);
            if (delegation.getVotes(DEL_A) != delAbefore) { effective = t; break; }
        }
        // Without these the comparison below could run at time 0, where both
        // sides read 0, or after the victim's expiry, where it tests nothing.
        assertGt(effective, 0,
            "NON-VACUOUS: DEL_A's votes never changed between the trigger and the next hour boundary");
        assertLt(effective, E, "NON-VACUOUS: the victim is not live at the effective instant");
        vm.warp(effective);
        uint256 actual = delegation.getVotes(DEL_A);

        emit log_named_uint("DEL_A votes before the relay    ", delAbefore);
        emit log_named_uint("relay trigger instant T         ", T);
        emit log_named_uint("first effective instant         ", effective);
        emit log_named_uint("EMITTED newVotes                ", emittedNewVotes);
        emit log_named_uint("ACTUAL votes then               ", actual);
        emit log_named_uint("understatement (wei)            ",
            actual > emittedNewVotes ? actual - emittedNewVotes : 0);

        assertEq(emittedNewVotes, actual,
            "the emitted newVotes omits weight that is live at the effective instant");
    }
}

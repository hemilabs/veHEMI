// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

/// @title The holder's cures for a flat term stranded by an unverified
///        retirement.
/// @notice A lying module accepts the disable's re-delegation and does
///         nothing, so the REAL module keeps the flat term booked at the old
///         delegatee (a phantom; VeHemi announces it). Once the module is
///         repaired, the holder clears the phantom with an ordinary action:
///         re-delegating (to the same or another delegatee) re-books the
///         position at its live weight, and withdrawing removes it.
contract StrandedFlatTermCureTest is AutoRelockTestBase {
    function _strandFlatTerm(address who_)
        internal
        returns (uint256 id, uint256 wFlat, IVeHemiVoteDelegation realDelegation)
    {
        realDelegation = IVeHemiVoteDelegation(address(delegation));
        (id, , ) = createLock(who_, 1_000 ether, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        wFlat = delegation.getVotes(delegateeA);
        require(wFlat > 0, "premise: no flat term booked");
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        disable(who_, id);
        require(veHemi.autoRelockRemaining(id) == 0, "premise: not disarmed");
        require(delegation.getVotes(delegateeA) == wFlat, "premise: not stranded");
        veHemi.updateVoteDelegation(realDelegation); // the module is repaired
    }

    function _warpPastNextHourBoundary() internal { vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours); }

    function test_cure_redelegateToSameDelegatee() public {
        (uint256 id, uint256 wFlat, ) = _strandFlatTerm(attacker);
        delegateTo(attacker, id, delegateeA);
        _warpPastNextHourBoundary();
        assertTrue(veHemi.balanceOfNFT(id) != wFlat, "premise: live weight equals the stranded flat level");
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id), "re-delegating to the same delegatee left the phantom");
    }

    function test_cure_redelegateToAnotherDelegatee() public {
        (uint256 id, , ) = _strandFlatTerm(attacker);
        delegateTo(attacker, id, delegateeB);
        _warpPastNextHourBoundary();
        assertEq(delegation.getVotes(delegateeA), 0, "moving away left the phantom at the old delegatee");
        assertEq(delegation.getVotes(delegateeB), veHemi.balanceOfNFT(id), "the move did not land at the live weight");
    }

    function test_cure_withdraw() public {
        (uint256 id, , ) = _strandFlatTerm(attacker);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether, "principal not returned");
        _warpPastNextHourBoundary();
        assertEq(delegation.getVotes(delegateeA), 0, "withdraw left the phantom");
    }
}

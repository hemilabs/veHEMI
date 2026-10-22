// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

/// @title K08 — the holder's cures for a flat term stranded by an unverified
///        retirement.
/// @notice A lying module accepts the disable's re-delegation and does
///         nothing, so the REAL module keeps the flat term booked at the old
///         delegatee (a phantom; VeHemi announces it). Once the module is
///         repaired, the holder clears the phantom with an ordinary action:
///         re-delegating (to the same or another delegatee) re-books the
///         position at its live weight, and withdrawing removes it.
contract K08Cure is J11Base {
    function _stranded(address who_) internal returns (uint256 id, uint256 wFlat, IVeHemiVoteDelegation good) {
        good = IVeHemiVoteDelegation(address(delegation));
        (id, , ) = createLock(who_, 1_000 ether, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, dele);
        vm.warp(block.timestamp + 7200);
        wFlat = delegation.getVotes(dele);
        require(wFlat > 0, "probe");
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        disable(who_, id);
        require(veHemi.autoRelockRemaining(id) == 0, "probe: not disarmed");
        require(delegation.getVotes(dele) == wFlat, "probe: not stranded");
        veHemi.updateVoteDelegation(good);      // the module is repaired
    }

    function _boundary() internal { vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours); }

    function test_K08_cure_1_holderCallsVvdDelegateDirectly() public {
        (uint256 id, uint256 w, ) = _stranded(attacker);
        delegateTo(attacker, id, dele);
        _boundary();
        assertTrue(veHemi.balanceOfNFT(id) != w, "probe: live weight equals the stranded flat level");
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "re-delegating to the same delegatee left the phantom");
    }

    function test_K08_cure_2_holderCallsVvdDelegateToSomeoneElse() public {
        (uint256 id, , ) = _stranded(attacker);
        delegateTo(attacker, id, dele2);
        _boundary();
        assertEq(delegation.getVotes(dele), 0, "moving away left the phantom at the old delegatee");
        assertEq(delegation.getVotes(dele2), veHemi.balanceOfNFT(id), "the move did not land at the live weight");
    }

    function test_K08_cure_4_withdraw() public {
        (uint256 id, , ) = _stranded(attacker);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether, "principal not returned");
        _boundary();
        assertEq(delegation.getVotes(dele), 0, "withdraw left the phantom");
    }
}

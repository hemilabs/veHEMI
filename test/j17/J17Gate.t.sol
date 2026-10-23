// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./J17Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import {RevertingVoteDelegation} from "../mocks/RevertingVoteDelegation.sol";
import {RevertingRewardDistributor} from "../mocks/RevertingRewardDistributor.sol";
import {
    J17MuteModule,
    LyingUnreadableVoteDelegation,
    StarvableRewardDistributor,
    GasEatingAutoDelegate
} from "../mocks/J17Modules.sol";

/// @title  Starved and unreadable modules.
///
/// @dev    `VeHemi` never commits an outer call whose inner module call was
///         GAS-STARVED (H2: the auto-delegate read), a retirement it cannot
///         VERIFY is ANNOUNCED with `AutoRelockRetirementUnverified` (H3, H4),
///         and a broken or gas-eating delegation module or reward distributor
///         still cannot lock principal (H5, H6, H9); the honest paths are
///         unaffected (H7). H8 checks that the test modules really starve.
contract J17Gate is J17Base {
    event AutoRelockRetirementUnverified(uint256 indexed tokenId);

    function _flat(address who_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, 1_000 ether, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, dele);
        vm.warp(block.timestamp + 7200);
    }

    // ------------------------------------------------------------------
    // H2 — `_resolveAutoDelegate`. Its catch falls back to the caller's own
    //      address, so a starved read must REVERT rather than silently
    //      redirect the delegation away from the configured auto-delegate.
    //      The call is an UNARMED `createLock`, so `REMOVAL_GAS_FLOOR` is not
    //      on its path: what refuses the low limits is `_requireNotStarved`
    //      (or, at the lowest, the outer frame running out of gas).
    // ------------------------------------------------------------------
    function test_J17_H2_starvedAutoDelegateCannotRedirect() public {
        GasEatingAutoDelegate ga = new GasEatingAutoDelegate(attacker, dele);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(ga)));

        // NON-VACUITY: with the READ healthy these limits DO commit, and the
        // configured auto-delegate IS the one that gets booked.
        ga.setEat(false);
        uint256 healthy;
        for (uint256 g = 150_000; g <= 4_000_000; g += 50_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            (bool ok, bytes memory ret) = address(veHemi).call{gas: g}(
                abi.encodeWithSignature("createLock(uint256,uint256)", uint256(1_000 ether), uint256(4 * 365 days)));
            if (ok && ret.length == 32 && ga.booked(abi.decode(ret, (uint256))) == dele) healthy++;
            vm.revertToState(snap);
        }
        assertGt(healthy, 0, "probe: the auto-delegate is never booked even when the read is healthy");

        // EATING READ. Below the 8,000,000 ceiling the read is starved at every
        // limit, so NOTHING may commit: every point is refused, by the
        // starvation tripwire (`DelegationCallStarved`) or by running out of
        // gas outright -- never by committing a self-delegation.
        ga.setEat(true);
        uint256 points;
        uint256 committed;
        uint256 refusedStarved;
        for (uint256 g = 150_000; g <= 4_000_000; g += 50_000) {
            ++points;
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            (bool ok, bytes memory ret) = address(veHemi).call{gas: g}(
                abi.encodeWithSignature("createLock(uint256,uint256)", uint256(1_000 ether), uint256(4 * 365 days)));
            if (ok) {
                ++committed;
                if (ret.length == 32) {
                    emit log_named_uint("  committed at gas limit", g);
                    assertEq(ga.booked(abi.decode(ret, (uint256))), dele,
                        "STARVED _resolveAutoDelegate REDIRECTED the delegation to the caller");
                }
            } else {
                assertTrue(
                    ret.length == 0 || bytes4(ret) == VeHemi.DelegationCallStarved.selector,
                    "starved createLock refused for a reason other than starvation"
                );
                if (ret.length >= 4 && bytes4(ret) == VeHemi.DelegationCallStarved.selector) ++refusedStarved;
            }
            vm.revertToState(snap);
        }
        assertEq(committed, 0, "a createLock with a STARVED auto-delegate read committed");
        assertGt(refusedStarved, 0, "the starvation tripwire never fired -- every refusal was a bare out-of-gas");
        emit log_named_uint("points", points);
        emit log_named_uint("refused with DelegationCallStarved", refusedStarved);
    }

    // ------------------------------------------------------------------
    // H3 — AN UNVERIFIABLE RETIREMENT IS ACCEPTED, BUT IT IS NOT SILENT.
    //      A module `VeHemi` cannot read still commits the retirement
    //      (refusing would trap the holder) — but it MUST announce it.
    // ------------------------------------------------------------------
    function test_J17_H3_unverifiableRetirementIsAnnounced() public {
        uint256 id = _flat(attacker);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new J17MuteModule())));
        vm.expectEmit(true, false, false, false, address(veHemi));
        emit AutoRelockRetirementUnverified(id);
        disable(attacker, id);
    }

    // ------------------------------------------------------------------
    // H4 — THE SILENT VARIANT, ANNOUNCED TOO. A module that ANSWERS the
    //      first read, LIES on `delegate` and is UNREADABLE by the time the
    //      post-condition asks gets past the starvation tripwire (the call
    //      succeeded) and the read-back (the record cannot be read), and emits
    //      no `DelegationUpdateFailed`; the retirement must still be announced.
    // ------------------------------------------------------------------
    function test_J17_H4_silentBypassIsAnnounced() public {
        uint256 id = _flat(attacker);
        IVeHemiVoteDelegation good = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(
            IVeHemiVoteDelegation(address(new LyingUnreadableVoteDelegation(good, id, dele))));
        vm.expectEmit(true, false, false, false, address(veHemi));
        emit AutoRelockRetirementUnverified(id);
        disable(attacker, id);
    }

    // ------------------------------------------------------------------
    // H5 — THE COUNTERWEIGHT. The griefing suite's broken-module test uses
    //      a position that was ENABLED but never delegated away from its
    //      owner (it keeps its mint-time self-delegation). The wider
    //      guarantee: a position DELEGATED to another account and
    //      auto-relocked, under a module that reverts on EVERYTHING, must
    //      still return its principal. This is why an unverifiable
    //      retirement is announced (H3) rather than refused.
    // ------------------------------------------------------------------
    function test_J17_H5_brokenModuleCannotLockADELEGATEDPosition() public {
        uint256 id = _flat(attacker);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new RevertingVoteDelegation())));
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        disable(attacker, id); // must not revert
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether,
            "principal trapped behind a broken delegation module (DELEGATED position)");
    }

    // ------------------------------------------------------------------
    // H6 — A distributor that reverts CHEAPLY is the ordinary broken-module
    //      shape and it must STILL be swallowed on disable and withdraw: a
    //      broken reward distributor must not turn into locked funds.
    // ------------------------------------------------------------------
    function test_J17_H6_brokenDistributorStillCannotLockFunds() public {
        uint256 id = _flat(attacker);
        veHemi.updateRewardDistributor(IRewardDistributor(address(new RevertingRewardDistributor())));
        disable(attacker, id); // must not revert
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether,
            "principal trapped behind a broken REWARD DISTRIBUTOR");
    }

    // ------------------------------------------------------------------
    // H9 — WHY `_updateReward` HAS NO STARVATION TRIPWIRE. It is the FIRST
    //      statement of `_withdraw`; with a tripwire there, a distributor that
    //      EATS its allowance (rather than reverting cheaply, which is H6)
    //      would lock principal. The swallowed harm at this site (a stale
    //      reward anchor) is curable by the next notify; locked principal is
    //      not.
    // ------------------------------------------------------------------
    function test_J17_H9_gasEatingDistributorStillCannotLockFunds() public {
        StarvableRewardDistributor rd = new StarvableRewardDistributor();
        veHemi.updateRewardDistributor(IRewardDistributor(address(rd)));
        uint256 id = _flat(attacker);
        rd.setEat(true);
        disable(attacker, id); // must not revert
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether,
            "principal trapped behind a GAS-EATING reward distributor");
    }

    // ------------------------------------------------------------------
    // H7 — LIVENESS. The starvation and announcement rules must not make the
    //      honest paths refusable. A healthy distributor is notified, a healthy
    //      auto-delegate is honoured, and an ordinary retirement emits NO
    //      `AutoRelockRetirementUnverified` at all.
    // ------------------------------------------------------------------
    function test_J17_H7_honestPathsUnaffected() public {
        StarvableRewardDistributor rd = new StarvableRewardDistributor();
        veHemi.updateRewardDistributor(IRewardDistributor(address(rd)));

        vm.prank(victim);
        delegation.setAutoDelegate(dele2);
        (uint256 auto_, , ) = createLock(victim, 500 ether, 4 * 365 days);
        assertEq(delegation.delegation(auto_).delegatee, dele2, "healthy autoDelegate not honoured");

        uint256 id = _flat(attacker);
        uint256 callsBefore = rd.callsForToken(id);
        vm.recordLogs();
        disable(attacker, id);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; ++i) {
            assertTrue(entries[i].topics[0] != keccak256("AutoRelockRetirementUnverified(uint256)"),
                "an HONEST retirement was announced as unverified");
        }
        assertGt(rd.callsForToken(id), callsBefore, "healthy distributor not notified on retire");
        assertEq(veHemi.autoRelockRemaining(id), 0, "flag survived disable");
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "disable mis-booked");
    }

    // ------------------------------------------------------------------
    // H8 — VACUITY. If the gas eaters did not actually starve, H2/H9 would
    //      pass for the wrong reason; and if the mute module were readable,
    //      H3 would. Each premise is asserted here directly.
    // ------------------------------------------------------------------
    function test_J17_H8_vacuity_theEatersReallyStarve() public {
        StarvableRewardDistributor rd = new StarvableRewardDistributor();
        rd.setEat(true);
        (bool ok1, ) = address(rd).call{gas: 500_000}(
            abi.encodeWithSignature("updateRewards(uint256)", uint256(1)));
        assertFalse(ok1, "probe: the starvable distributor did not starve");
        rd.setEat(false);
        (bool ok2, ) = address(rd).call{gas: 500_000}(
            abi.encodeWithSignature("updateRewards(uint256)", uint256(1)));
        assertTrue(ok2, "probe: the starvable distributor never works");
        assertEq(rd.callsForToken(1), 1, "probe: the healthy leg records nothing");

        GasEatingAutoDelegate ga = new GasEatingAutoDelegate(attacker, dele);
        (bool ok3, ) = address(ga).call{gas: 500_000}(
            abi.encodeWithSignature("autoDelegate(address)", attacker));
        assertFalse(ok3, "probe: the gas-eating autoDelegate did not starve");

        J17MuteModule mute = new J17MuteModule();
        (bool ok4, ) = address(mute).call{gas: 500_000}(
            abi.encodeWithSignature("delegation(uint256)", uint256(1)));
        assertFalse(ok4, "probe: the mute module answered");
    }
}

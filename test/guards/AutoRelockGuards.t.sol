// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import {K08Garbage} from "../k08/K08Modules.sol";

/// @notice An adapter whose relays burn all the gas they are given.
contract GasBurningAdapter {
    function notifyVotesChanged(address, uint256, uint256) external pure {
        while (true) {}
    }

    function notifyDelegateChanged(address, address, address) external pure {
        while (true) {}
    }
}

/// @notice A module whose window probe REVERTS with 32 bytes of non-zero data.
contract RevertingWindowProbeModule is LyingVoteDelegation {
    constructor(IVeHemiVoteDelegation real_) LyingVoteDelegation(real_) {}

    function legacyDatingActive() external pure returns (bool) {
        assembly {
            mstore(0, 1)
            revert(0, 32)
        }
    }
}

/// @title  Auto-relock guards, one body per guard.
/// @notice The relay gas cap, `retireStrandedFlatTerm`'s refusals,
///         `enableAutoRelock`'s refusal of an armed position, the fail-open
///         window probe, delegation of an armed position past its stored end,
///         and the undecodable-module risk. Each body fails if the guard it
///         names is removed or inverted.
contract AutoRelockGuards is J11Base {
    /// @notice The vote-delegation module caps each `notifyVotesChanged` relay at
    ///         `RELAY_GAS_BUDGET`, so an adapter that burns its gas cannot make a
    ///         delegation write run out of gas. (The account-wide
    ///         `notifyDelegateChanged` relay is uncapped by design and is the
    ///         module's last statement; this adapter burns there too, which the
    ///         try/catch absorbs with 1/64 of the frame left.)
    function test_relayGasBudget_bindsAGasBurningAdapter() public {
        delegation.setTrustedAdapter(address(new GasBurningAdapter()));
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        vm.prank(attacker);
        (bool ok, ) = address(delegation).call{gas: 3_000_000}(abi.encodeCall(delegation.delegate, (id, dele)));
        assertTrue(ok, "a gas-burning adapter made a delegation write run out of gas");
        vm.warp(block.timestamp + 2);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "the write did not book the votes");
    }

    /// @notice `retireStrandedFlatTerm` refuses a record that is not flat: a live
    ///         DECAYING record cannot be re-booked by a stranger.
    function test_retireStrandedFlatTerm_refusesALiveDecayingRecord() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        delegateTo(attacker, id, dele);
        vm.warp(block.timestamp + 2);
        uint256 before = delegation.getVotes(dele);
        vm.prank(stranger);
        vm.expectRevert(VeHemiVoteDelegation.FlatTermNotRetryable.selector);
        delegation.retireStrandedFlatTerm(id);
        assertEq(delegation.getVotes(dele), before, "votes moved");
    }

    /// @notice ... and an ARMED position's flat record (it is not stranded).
    function test_retireStrandedFlatTerm_refusesAnArmedPosition() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        vm.prank(stranger);
        vm.expectRevert(VeHemiVoteDelegation.FlatTermNotRetryable.selector);
        delegation.retireStrandedFlatTerm(id);
    }

    /// @notice `enableAutoRelock` refuses a position that is already armed, with
    ///         `AutoRelockAlreadyEnabled`.
    function test_enableAutoRelock_refusesAnArmedPosition() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        vm.prank(attacker);
        vm.expectRevert(VeHemi.AutoRelockAlreadyEnabled.selector);
        veHemi.enableAutoRelock(id);
    }

    /// @notice The upgrade-window probe in `enableAutoRelock` reads the module's
    ///         answer only when the call SUCCEEDED: a module whose
    ///         `legacyDatingActive` reverts with non-zero return data does not
    ///         block arming (the probe fails open).
    function test_windowProbe_failsOpenOnARevertWithData() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new RevertingWindowProbeModule(delegation))));
        enable(attacker, id);
        assertTrue(veHemi.isAutoRelockEnabled(id), "a reverting probe was read as an open window");
    }

    /// @notice An armed position stays delegatable after its stored `end`: an
    ///         owner's self-transfer re-applies the owner's auto-delegate even when
    ///         `getLockedBalance(id).end` is in the past (the near-expiry skip
    ///         applies only to unarmed positions).
    function test_armedSelfTransferAfterStoredEnd_reachesTheAutoDelegate() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 3 * SIX_DAYS);
        enable(attacker, id);
        _ageAndRefresh(attacker, id, 6);
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "probe: the stored end is not in the past");
        assertTrue(veHemi.isAutoRelockEnabled(id), "probe: not armed");
        vm.prank(attacker);
        delegation.setAutoDelegate(dele2);
        vm.prank(attacker);
        veHemi.transferFrom(attacker, attacker, id);
        assertTrue(veHemi.isAutoRelockEnabled(id), "a self-transfer disarmed the position");
        assertEq(delegation.delegation(id).delegatee, dele2, "the self-transfer did not reach the auto-delegate");
        vm.warp(block.timestamp + 2);
        assertEq(delegation.getVotes(dele2), veHemi.balanceOfNFT(id), "the auto-delegate does not hold the weight");
    }

    /// @notice KNOWN LIMITATION (documented on `VeHemi.updateVoteDelegation`): a
    ///         module whose `delegation(uint256)` return data does not decode
    ///         reverts the caller at the `try ... returns` site, so an armed
    ///         position can neither be disarmed, retired nor withdrawn while that
    ///         module is installed. Replacing the module (an owner action) cures
    ///         it, and the principal comes back in full.
    function test_undecodableModule_locksArmedPrincipalUntilTheOwnerReplacesIt() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        IVeHemiVoteDelegation good = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new K08Garbage())));

        // Undecodable return data reverts at the `try ... returns` decode
        // with EMPTY revert data, not with a VeHemi error.
        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(veHemi).call(abi.encodeCall(veHemi.disableAutoRelock, (id)));
        assertTrue(!ok && ret.length == 0, "disable did not revert at the decode");
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(stranger);
        (ok, ret) = address(veHemi).call(abi.encodeCall(veHemi.retireStaleAutoRelock, (id)));
        assertTrue(!ok && ret.length == 0, "retire did not revert at the decode");
        vm.prank(attacker);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);
        assertTrue(veHemi.isAutoRelockEnabled(id), "probe: the position is no longer armed");

        veHemi.updateVoteDelegation(good);
        disable(attacker, id);
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether, "principal not returned after the module was replaced");
    }

    function _ageAndRefresh(address owner_, uint256 id_, uint256 buckets_) internal {
        for (uint256 b = 0; b < buckets_; ++b) {
            vm.warp(block.timestamp + SIX_DAYS);
            vm.prank(owner_);
            veHemi.refreshAutoRelock(id_);
        }
    }
}

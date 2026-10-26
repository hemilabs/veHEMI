// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// THE bias == 0 MOVE.
// ----------------------------------------------------------------------------
// A stranded flat term whose restored end has passed takes the tolerated-expiry
// branch of `VeHemiVoteDelegation._getNormalizedLockedInfo` (`tolerateExpired_`),
// so the holder's `delegate()` arrives at `_moveVotingPowerToNewDelegate`
// with `bias == 0`. That function runs the addition unconditionally (no
// `if (bias != 0)` gate), which keeps the record and the checkpoint array
// consistent:
//
//   A1  the owner's NEXT `delegate` is the ordinary refusal, never a panic;
//   A2  the record is cleared when the NFT burns;
//   A3  a successful `delegate(id, X)` is recorded (gating BOTH writes would
//       avoid the panic and silently discard the request);
//   A4  a non-zero record implies a non-empty checkpoint array, and the move
//       books no weight, now or years later;
//   A5  a third party sharing the delegatee is undisturbed.
// ============================================================================

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

contract ZeroBiasMoveTest is AutoRelockTestBase {
    uint256 private _observations;

    address internal freshDelegatee1 = address(0x2C7B41);
    address internal freshDelegatee2 = address(0x2C7B42);
    address internal freshDelegatee3 = address(0x2C7B43);
    address internal movedOntoDelegatee = address(0x2C7B51);
    address internal controlDelegatee = address(0x2C7B52);

    bytes4 internal constant CANNOT_DELEGATE_EXPIRED = 0xac29a81f; // CanNotDelegateExpiredLocks()

    function _requireObserved(string memory tag) internal view {
        require(_observations > 0, string.concat("VACUOUS: ", tag, " observed nothing"));
    }

    function _isPanic11(bool ok_, bytes memory r_) internal pure returns (bool) {
        if (ok_) return false;
        if (r_.length < 36) return false;
        bytes4 sel;
        uint256 code;
        assembly {
            sel := mload(add(r_, 0x20))
            code := mload(add(r_, 0x24))
        }
        return sel == bytes4(0x4e487b71) && code == 17;
    }

    function _revertSelector(bytes memory r_) internal pure returns (bytes4 selector) {
        if (r_.length < 4) return bytes4(0);
        assembly { selector := mload(add(r_, 0x20)) }
    }

    /// @dev A FLAT position whose retirement was SWALLOWED, aged past its
    ///      restored end, so the next `delegate` takes the tolerated-expiry
    ///      branch and arrives at `_moveVotingPowerToNewDelegate` with
    ///      `bias == 0`.
    function _strandExpiredFlatTerm(address owner_, uint256 amount_) internal returns (uint256 id) {
        IVeHemiVoteDelegation realDelegation = IVeHemiVoteDelegation(address(delegation));
        (id, , ) = createLock(owner_, amount_, 4 * 365 days);
        enable(owner_, id);
        delegateTo(owner_, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        veHemi.updateVoteDelegation(
            IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation)))
        );
        disable(owner_, id);
        veHemi.updateVoteDelegation(realDelegation);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1 hours);
    }

    /// @dev NON-VACUITY: the fixture really is on the tolerated branch --
    ///      the record it carries into `_delegate` is FLAT (slope==0, bias>0)
    ///      and the lock's end is at or before the checkpoint.
    function _assertOnToleratedBranch(uint256 id_) internal {
        IVeHemiVoteDelegation.Delegation memory previousRecord = delegation.delegation(id_);
        assertEq(previousRecord.slope, 0, "NON-VACUOUS: previous record is not flat (slope != 0)");
        assertGt(previousRecord.bias, 0, "NON-VACUOUS: previous record is not flat (bias == 0)");
        assertLe(
            uint256(veHemi.getLockedBalance(id_).end),
            block.timestamp,
            "NON-VACUOUS: the lock has not passed its end"
        );
        _observations++;
    }

    // =====================================================================
    // A1 -- NO PANIC ON THE NEXT `delegate`.
    // The owner's NEXT `delegate` must be an ordinary refusal, never an
    // unwrapped `panic 0x11` on an external entry point.
    // =====================================================================
    function test_A1_nextDelegateIsARefusalNotAPanic() public {
        _observations = 0;
        uint256 id = _strandExpiredFlatTerm(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        delegateTo(attacker, id, freshDelegatee1);
        _observations++;

        vm.prank(attacker);
        (bool ok, bytes memory r) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, freshDelegatee2)
        );
        emit log_named_bytes32("A1 next delegate revert selector", bytes32(_revertSelector(r)));
        _observations++;

        assertFalse(
            _isPanic11(ok, r),
            "A1: the owner's next delegate() PANICS 0x11 -- an unwrapped panic on an external entry point"
        );
        assertFalse(ok, "A1: the expired position must still be refused");
        assertEq(
            _revertSelector(r),
            CANNOT_DELEGATE_EXPIRED,
            "A1: the refusal must be the ORDINARY CanNotDelegateExpiredLocks"
        );
        _requireObserved("A1");
    }

    // =====================================================================
    // A2 -- NO RECORD LEAK.  `delegations[id]` must be EMPTY once the
    // NFT is burned.  A leftover record is what `VeHemiVoteDelegation`'s own
    // "CRITICAL: DO NOT REMOVE the address(0) branch" note exists to prevent.
    // =====================================================================
    function test_A2_theRecordIsClearedWhenTheNFTBurns() public {
        _observations = 0;
        uint256 id = _strandExpiredFlatTerm(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        delegateTo(attacker, id, freshDelegatee1);
        assertEq(delegation.delegation(id).delegatee, freshDelegatee1, "A2 premise: the move was not recorded");
        _observations++;

        vm.prank(attacker);
        veHemi.withdraw(id);
        _observations++;

        // the NFT really is gone
        vm.expectRevert();
        veHemi.ownerOf(id);

        assertEq(
            delegation.delegation(id).delegatee,
            address(0),
            "A2: `delegations[id].delegatee` survives the burn -- the record LEAKED"
        );
        _requireObserved("A2");
    }

    // =====================================================================
    // A3 *** THE NEGATIVE CONTROL IN THE OTHER DIRECTION ***
    // Gating BOTH writes on `bias != 0` would also avoid A1's panic, but it
    // SILENTLY DISCARDS the caller's request.  A `delegate(id, X)` that
    // returns successfully must be visible in `delegation(id)`.
    // =====================================================================
    function test_A3_aSuccessfulDelegateIsRecorded() public {
        _observations = 0;
        uint256 id = _strandExpiredFlatTerm(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        address before_ = delegation.delegation(id).delegatee;
        assertEq(before_, delegateeA, "A3 premise: the record does not start at `delegateeA`");
        _observations++;

        delegateTo(attacker, id, freshDelegatee3); // returns successfully
        _observations++;

        assertEq(
            delegation.delegation(id).delegatee,
            freshDelegatee3,
            "A3: `delegate(id, freshDelegatee3)` SUCCEEDED and the record still points somewhere else"
        );
        _requireObserved("A3");
    }

    // =====================================================================
    // A4 -- a non-zero `delegations[id].delegatee` implies a NON-EMPTY
    //   `delegateCheckpoints[that delegatee]`, and the bias == 0 move books
    //   NO weight on the fresh delegatee: zero now, 365 days later, 4 * 365
    //   days later, and past `MAX_LOCK_DURATION` (4 * 365.25 days) after the
    //   delegatee's last checkpoint. Only that last read takes
    //   `_calculateExpirations`' beyond-`MAX_LOCK_DURATION` branch, which
    //   retires the checkpoint's whole decaying aggregate; 4 * 365 days is
    //   one day short of it.
    // =====================================================================
    function test_A4_aNonZeroRecordImpliesANonEmptyCheckpointArray() public {
        _observations = 0;
        uint256 id = _strandExpiredFlatTerm(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        delegateTo(attacker, id, freshDelegatee1);
        _observations++;

        address recordedDelegatee = delegation.delegation(id).delegatee;
        uint256 len = delegation.getDelegationCheckpointsLength(recordedDelegatee);
        emit log_named_address("A4 recorded delegatee", recordedDelegatee);
        emit log_named_uint("A4 checkpoints[recorded].length", len);
        _observations++;

        if (recordedDelegatee != address(0)) {
            assertGt(
                len,
                0,
                "A4: `delegations[id].delegatee` is non-zero and its checkpoint array is EMPTY"
            );
        }

        assertEq(delegation.getVotes(freshDelegatee1), 0, "A4: the bias==0 move BOOKED WEIGHT on a fresh delegatee");
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 365 days);
        assertEq(delegation.getVotes(freshDelegatee1), 0, "A4: the fresh delegatee carries weight one year later");
        vm.warp(t0 + 4 * 365 days);
        assertEq(delegation.getVotes(freshDelegatee1), 0, "A4: the fresh delegatee carries weight four years later");

        // The read must find a checkpoint: on an empty array `_getDelegateVotesAt`
        // returns 0 before the expiration walk. `MAX_TIME` is the contract's
        // `MAX_LOCK_DURATION`.
        uint256 fresh1CheckpointCount = delegation.getDelegationCheckpointsLength(freshDelegatee1);
        assertGt(
            fresh1CheckpointCount,
            0,
            "NON-VACUOUS: freshDelegatee1 has no checkpoint, so the read returns before the expiration walk"
        );
        uint256 fresh1LastCheckpoint =
            delegation.getDelegationCheckpointsPage(freshDelegatee1, fresh1CheckpointCount - 1, 1)[0].timestamp;
        vm.warp(fresh1LastCheckpoint + MAX_TIME + 1 hours);
        assertEq(
            delegation.getVotes(freshDelegatee1),
            0,
            "A4: the fresh delegatee carries weight past MAX_LOCK_DURATION"
        );
        _observations++;
        _requireObserved("A4");
    }

    // =====================================================================
    // A5 -- THE SAFETY PROPERTY THE UNCONDITIONAL ADDITION RESTS ON: a
    // bias == 0 move onto a delegatee that carries a third party's weight
    // leaves that weight exactly equal to an identical control delegatee's,
    // for years.
    // =====================================================================
    function test_A5_theBiasZeroMoveDisturbsNoThirdParty() public {
        _observations = 0;

        // two identical third parties on movedOntoDelegatee and controlDelegatee
        (uint256 movedOntoThirdPartyId, , ) = createLock(victim, 400 ether, 3 * 365 days);
        delegateTo(victim, movedOntoThirdPartyId, movedOntoDelegatee);
        (uint256 controlThirdPartyId, , ) = createLock(stranger, 400 ether, 3 * 365 days);
        delegateTo(stranger, controlThirdPartyId, controlDelegatee);

        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours + 1);
        uint256 baseline = delegation.getVotes(movedOntoDelegatee);
        emit log_named_uint("A5 baseline getVotes(movedOntoDelegatee)", baseline);
        assertGt(baseline, 0, "NON-VACUOUS: the third parties carry no weight");
        assertEq(
            baseline,
            delegation.getVotes(controlDelegatee),
            "A5 premise: movedOntoDelegatee and controlDelegatee are not identical"
        );
        _observations++;

        uint256 id = _strandExpiredFlatTerm(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);
        // movedOntoDelegatee receives the bias==0 move; controlDelegatee does not
        delegateTo(attacker, id, movedOntoDelegatee);
        _observations++;

        uint256 mismatches;
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(t0 + (i * 220 days));
            if (delegation.getVotes(movedOntoDelegatee) != delegation.getVotes(controlDelegatee)) ++mismatches;
            _observations++;
        }
        emit log_named_uint("A5 samples", 8);
        emit log_named_uint("A5 value-mismatches", mismatches);
        assertEq(mismatches, 0, "A5: the bias==0 move DISTURBED a third party's weight");
        _requireObserved("A5");
    }
}

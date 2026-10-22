// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// S24/A0A -- THE bias == 0 MOVE (A0A).
// ----------------------------------------------------------------------------
// A stranded flat term whose restored end has passed takes the tolerated-expiry
// branch of `VeHemiVoteDelegation._getNormalizedLockedInfo` (`tolerateExpired_`),
// so the holder's `delegate()` arrives at `_moveVotingPowerToNewDelegate`
// with `bias == 0`. A0A runs that addition unconditionally (no
// `if (bias != 0)` gate), which keeps the record and the checkpoint array
// consistent:
//
//   A1  the owner's NEXT `delegate` is the ordinary refusal, never a panic;
//   A2  the record is cleared when the NFT burns;
//   A3  a successful `delegate(id, X)` is recorded (gating BOTH writes would
//       close the panic and silently discard the request);
//   A4  a non-zero record implies a non-empty checkpoint array, and the move
//       books no weight, now or years later;
//   A5  a third party sharing the delegatee is undisturbed.
// ============================================================================

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";

contract S24A0A is J11Base {
    uint256 private _obs;

    address internal F1 = address(0x524001);
    address internal F2 = address(0x524002);
    address internal F3 = address(0x524003);
    address internal X1 = address(0x524011);
    address internal X2 = address(0x524012);

    bytes4 internal constant CANNOT_DELEGATE_EXPIRED = 0xac29a81f; // CanNotDelegateExpiredLocks()

    function _ok(string memory tag) internal view {
        require(_obs > 0, string.concat("VACUOUS: ", tag, " observed nothing"));
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

    function _sel(bytes memory r_) internal pure returns (bytes4 s4) {
        if (r_.length < 4) return bytes4(0);
        assembly { s4 := mload(add(r_, 0x20)) }
    }

    /// @dev A FLAT position whose retirement was SWALLOWED, aged past its
    ///      restored end, so the next `delegate` takes the tolerated-expiry
    ///      branch and arrives at the A0A site with `bias == 0`.
    function _armFlatExpired(address owner_, uint256 amount_) internal returns (uint256 id) {
        IVeHemiVoteDelegation good = IVeHemiVoteDelegation(address(delegation));
        (id, , ) = createLock(owner_, amount_, 4 * 365 days);
        enable(owner_, id);
        delegateTo(owner_, id, dele);
        vm.warp(block.timestamp + 7200);
        veHemi.updateVoteDelegation(
            IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation)))
        );
        disable(owner_, id);
        veHemi.updateVoteDelegation(good);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1 hours);
    }

    /// @dev NON-VACUITY: the fixture really is on the tolerated branch --
    ///      the record it carries into `_delegate` is FLAT (slope==0, bias>0)
    ///      and the lock's end is at or before the checkpoint.
    function _assertOnToleratedBranch(uint256 id_) internal {
        IVeHemiVoteDelegation.Delegation memory p = delegation.delegation(id_);
        assertEq(p.slope, 0, "NON-VACUOUS: previous record is not flat (slope != 0)");
        assertGt(p.bias, 0, "NON-VACUOUS: previous record is not flat (bias == 0)");
        assertLe(
            uint256(veHemi.getLockedBalance(id_).end),
            block.timestamp,
            "NON-VACUOUS: the lock has not passed its end"
        );
        _obs++;
    }

    // =====================================================================
    // S24/A1 -- THE PANIC A0A CLOSES.
    // The owner's NEXT `delegate` must be an ordinary refusal, never an
    // unwrapped `panic 0x11` on an external entry point.
    // =====================================================================
    function test_S24_A1_nextDelegateIsARefusalNotAPanic() public {
        _obs = 0;
        uint256 id = _armFlatExpired(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        delegateTo(attacker, id, F1);
        _obs++;

        vm.prank(attacker);
        (bool ok, bytes memory r) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, F2)
        );
        emit log_named_bytes32("S24/A1 next delegate revert selector", bytes32(_sel(r)));
        _obs++;

        assertFalse(
            _isPanic11(ok, r),
            "S24/A1 KILLED: the owner's next delegate() PANICS 0x11 -- an unwrapped panic on an external entry point"
        );
        assertFalse(ok, "S24/A1: the expired position must still be refused");
        assertEq(
            _sel(r),
            CANNOT_DELEGATE_EXPIRED,
            "S24/A1: the refusal must be the ORDINARY CanNotDelegateExpiredLocks"
        );
        _ok("S24/A1");
    }

    // =====================================================================
    // S24/A2 -- THE RECORD LEAK.  `delegations[id]` must be EMPTY once the
    // NFT is burned.  This is the outcome `VeHemiVoteDelegation`'s own
    // "CRITICAL: DO NOT REMOVE the address(0) branch" note exists to prevent.
    // =====================================================================
    function test_S24_A2_theRecordIsClearedWhenTheNFTBurns() public {
        _obs = 0;
        uint256 id = _armFlatExpired(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        delegateTo(attacker, id, F1);
        assertEq(delegation.delegation(id).delegatee, F1, "S24/A2 setup: the move was not recorded");
        _obs++;

        vm.prank(attacker);
        veHemi.withdraw(id);
        _obs++;

        // the NFT really is gone
        vm.expectRevert();
        veHemi.ownerOf(id);

        assertEq(
            delegation.delegation(id).delegatee,
            address(0),
            "S24/A2 KILLED: `delegations[id].delegatee` survives the burn -- the record LEAKED"
        );
        _ok("S24/A2");
    }

    // =====================================================================
    // S24/A3 *** THE NEGATIVE CONTROL IN THE OTHER DIRECTION ***
    // The naive repair of A1's panic is "the record and the checkpoint array
    // disagree, so gate BOTH".  That closes the panic and SILENTLY DISCARDS
    // the caller's request.  A `delegate(id, X)` that returns successfully
    // must be visible in `delegation(id)`.
    // =====================================================================
    function test_S24_A3_aSuccessfulDelegateIsRecorded() public {
        _obs = 0;
        uint256 id = _armFlatExpired(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        address before_ = delegation.delegation(id).delegatee;
        assertEq(before_, dele, "S24/A3 setup: the record does not start at `dele`");
        _obs++;

        delegateTo(attacker, id, F3); // returns successfully
        _obs++;

        assertEq(
            delegation.delegation(id).delegatee,
            F3,
            "S24/A3 KILLED: `delegate(id, F3)` SUCCEEDED and the record still points somewhere else"
        );
        _ok("S24/A3");
    }

    // =====================================================================
    // S24/A4 -- a non-zero `delegations[id].delegatee` implies a NON-EMPTY
    //   `delegateCheckpoints[that delegatee]`, and the bias == 0 move books
    //   NO weight on the fresh delegatee: zero now, 365 days later, 4 * 365
    //   days later, and past `MAX_LOCK_DURATION` (4 * 365.25 days) after the
    //   delegatee's last checkpoint. Only that last read takes
    //   `_calculateExpirations`' beyond-`MAX_LOCK_DURATION` branch, which
    //   retires the checkpoint's whole decaying aggregate; 4 * 365 days is
    //   one day short of it.
    // =====================================================================
    function test_S24_A4_aNonZeroRecordImpliesANonEmptyCheckpointArray() public {
        _obs = 0;
        uint256 id = _armFlatExpired(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);

        delegateTo(attacker, id, F1);
        _obs++;

        address rec = delegation.delegation(id).delegatee;
        uint256 len = delegation.getDelegationCheckpointsLength(rec);
        emit log_named_address("S24/A4 recorded delegatee", rec);
        emit log_named_uint("S24/A4 checkpoints[recorded].length", len);
        _obs++;

        if (rec != address(0)) {
            assertGt(
                len,
                0,
                "S24/A4 KILLED: `delegations[id].delegatee` is non-zero and its checkpoint array is EMPTY"
            );
        }

        assertEq(delegation.getVotes(F1), 0, "S24/A4: the bias==0 move BOOKED WEIGHT on a fresh delegatee");
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 365 days);
        assertEq(delegation.getVotes(F1), 0, "S24/A4: the fresh delegatee carries weight one year later");
        vm.warp(t0 + 4 * 365 days);
        assertEq(delegation.getVotes(F1), 0, "S24/A4: the fresh delegatee carries weight four years later");

        // The read must find a checkpoint: on an empty array `_getDelegateVotesAt`
        // returns 0 before the expiration walk. `MAX_TIME` is the contract's
        // `MAX_LOCK_DURATION`.
        uint256 nF1 = delegation.getDelegationCheckpointsLength(F1);
        assertGt(nF1, 0, "NON-VACUOUS: F1 has no checkpoint, so the read returns before the expiration walk");
        uint256 lastF1 = delegation.getDelegationCheckpointsPage(F1, nF1 - 1, 1)[0].timestamp;
        vm.warp(lastF1 + MAX_TIME + 1 hours);
        assertEq(
            delegation.getVotes(F1),
            0,
            "S24/A4: the fresh delegatee carries weight past MAX_LOCK_DURATION"
        );
        _obs++;
        _ok("S24/A4");
    }

    // =====================================================================
    // S24/A5 -- THE SAFETY PROPERTY A0A RESTS ON: a bias == 0 move onto a
    // delegatee that carries a third party's weight leaves that weight
    // exactly equal to an identical control delegatee's, for years.
    // =====================================================================
    function test_S24_A5_theBiasZeroMoveDisturbsNoThirdParty() public {
        _obs = 0;

        // two identical third parties on X1 and X2
        (uint256 d1, , ) = createLock(victim, 400 ether, 3 * 365 days);
        delegateTo(victim, d1, X1);
        (uint256 d2, , ) = createLock(stranger, 400 ether, 3 * 365 days);
        delegateTo(stranger, d2, X2);

        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours + 1);
        uint256 baseline = delegation.getVotes(X1);
        emit log_named_uint("S24/A5 baseline getVotes(X1)", baseline);
        assertGt(baseline, 0, "NON-VACUOUS: the third parties carry no weight");
        assertEq(baseline, delegation.getVotes(X2), "S24/A5 setup: X1 and X2 are not identical");
        _obs++;

        uint256 id = _armFlatExpired(attacker, 1_000 ether);
        _assertOnToleratedBranch(id);
        delegateTo(attacker, id, X1); // X1 receives the bias==0 move; X2 does not
        _obs++;

        uint256 mismatches;
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(t0 + (i * 220 days));
            if (delegation.getVotes(X1) != delegation.getVotes(X2)) ++mismatches;
            _obs++;
        }
        emit log_named_uint("S24/A5 samples", 8);
        emit log_named_uint("S24/A5 value-mismatches", mismatches);
        assertEq(mismatches, 0, "S24/A5 KILLED: the bias==0 move DISTURBED a third party's weight");
        _ok("S24/A5");
    }
}

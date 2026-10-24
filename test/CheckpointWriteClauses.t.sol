// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";

/**
 * @title CheckpointWriteClausesTest
 * @notice Checkpoint-layout clauses (4) and (5) of `_applyToCheckpoints`'s docblock
 *         (L4, L5 here). They are properties of the WRITE, not of the array, so
 *         `CheckpointLayoutViolated` cannot check them and no `vm.store` can install a
 *         violation; these two bodies defend them.
 *         L4: no write mutates an element dated at or before `now` (a sealed reading
 *             never moves).
 *         L5: a delta applied to the live element is also applied to the pending one
 *             (the two-leg `_pendingNew` path). The body reaches that state through
 *             honest code only: the permissionless `writeNewCheckpointForExpiredDelegations`
 *             is the writer that leaves a pending element mid-hour.
 */
contract CheckpointWriteClausesTest is LockedCurveTestBase {

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }
    function _cps(address d) internal view returns (VeHemiVoteDelegation.DelegateCheckpoint[] memory) {
        return delegation.getDelegationCheckpoints(d);
    }
    function _nb(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    // ===================================================================== L4
    /// *** L4 APPEND-ONLY AT OR BELOW `now`: a sealed reading must not move. ***
    /// PREMISE FIRST (an empty position would make the claim a `0 == 0`
    /// tautology), then the claim.
    function test_L4_appendOnly_sealedReadingIsFrozen() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);

        uint256 S = block.timestamp + 1;
        vm.warp(block.timestamp + 900);
        uint256 v1 = delegation.getPastVotes(bob, S);
        assertGt(v1, 0, "L4 premise: the sealed reading must be non-zero");
        uint256 lenBefore = _cps(bob).length;

        vm.prank(charlie); delegation.delegate(idC, bob);

        assertEq(delegation.getPastVotes(bob, S), v1, "L4: a SEALED reading was rewritten");
        assertEq(_cps(bob).length, lenBefore + 1, "L4: the write must APPEND, not overwrite");
        emit log_named_uint("L4 sealed reading", v1);
    }

    // ===================================================================== L5
    /// *** L5 THE PENDING ELEMENT CARRIES THE LIVE ONE FORWARD -- REACHED BY
    ///     HONEST CODE. ***
    ///
    /// The two-leg path needs a mid-hour PENDING element. Outside the
    /// upgrade-hour window the delegation writer cannot make one (a write
    /// dated at `B` is only taken when
    /// `now + 1 >= B`, and in that second `B` is not future). The honest
    /// producer is the PERMISSIONLESS `writeNewCheckpointForExpiredDelegations`,
    /// which pushes the materialized expirations at `B`. This body uses exactly
    /// that, asserts on storage that every precondition of the `_pendingNew`
    /// leg holds, then retires bob's only remaining delegator mid-hour. If the
    /// retirement is not carried into the pending element, bob keeps the whole
    /// weight across the boundary -- a PHANTOM.
    function test_L5_pendingCarriesTheDelta_viaPermissionlessWriter() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idShort = _mk(alice, 500 ether, 2 * SIX_DAYS);
        uint256 idLong = _mk(charlie, 300 ether, 20 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idShort, bob);
        vm.prank(charlie); delegation.delegate(idLong, bob);

        // Past the short lock's expiry, mid-hour.
        vm.warp(veHemi.getLockedBalance(idShort).end + 3 * SIX_DAYS + 900);

        // HONEST CODE, permissionless, anyone: push the materialized
        // expirations at `B`, leaving a pending element mid-hour.
        delegation.writeNewCheckpointForExpiredDelegations(bob);

        // The two-leg path is entered iff the tail is dated strictly after
        // `now + 1` at the write AND a live element exists below it AND
        // `imm < B` (no early deferred-only return). All asserted on storage.
        VeHemiVoteDelegation.DelegateCheckpoint[] memory a = _cps(bob);
        assertEq(a.length, 2, "L5 premise: the array must be [live, pending]");
        uint256 B = _nb(block.timestamp);
        assertGt(uint256(a[1].timestamp), block.timestamp + 1, "L5 premise: the tail really is PENDING");
        assertEq(uint256(a[1].timestamp), B, "L5 premise: the pending element sits at B");
        assertLe(uint256(a[0].timestamp), block.timestamp + 1,
            "L5 premise: the element below it is LIVE, so `len > 1` and the guard branch is entered");
        assertLt(block.timestamp + 1, B,
            "L5 premise: `imm < B`, so the write does not take the early deferred return");

        uint256 votesBefore = delegation.getVotes(bob);
        assertGt(votesBefore, 0, "L5 premise: bob must actually hold weight to lose");

        // bob's only remaining delegator leaves, mid-hour. THIS IS THE WRITE
        // THAT TAKES THE TWO-LEG PATH.
        vm.prank(charlie); delegation.delegate(idLong, address(0xC0DE));

        // The array must still be legal after it.
        VeHemiVoteDelegation.DelegateCheckpoint[] memory b = _cps(bob);
        assertEq(uint256(b[b.length - 1].timestamp), B, "L5: the tail is still the pending element at B");

        vm.warp(B + 1);
        assertGt(veHemi.balanceOfNFTAt(idLong, B + 1), 0,
            "L5 premise: the position is still alive, only the delegation moved");
        assertEq(delegation.getVotes(bob), 0,
            "L5: the retirement was not carried into the pending element - PHANTOM across the boundary");
        assertGt(delegation.getVotes(address(0xC0DE)), 0,
            "L5: and the weight must have arrived at the new delegatee");
    }
}

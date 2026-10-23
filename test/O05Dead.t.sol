// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title O05DeadTest
/// @notice The vote-blackout attacks are closed. Delegation writes are dated
///         `block.timestamp + 1`, so after an owner's own weight write, a
///         permissionless stale retire, or a write on an attacker's own
///         position delegated to the victim's delegatee, the delegatee never
///         reads zero, and a snapshot at the publicly computable instant
///         `boundary - 1` seals real weight. `increaseAmount` and `delegate`
///         are strict-owner (R0).
///
/// Read surface: `getVotes`, `getPastVotes`, `balanceOfNFTAt`. No private
/// state.
contract O05DeadTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);
    address internal constant DEL_A   = address(0xA1);
    address internal constant DEL_B   = address(0xB1);
    address internal constant DEL_C   = address(0xC1);
    address internal constant OWNER1  = address(0xD1);
    address internal constant OWNER2  = address(0xD2);
    address internal constant OWNER3  = address(0xD3);

    function _b(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    function _topUpSelf(address o, uint256 id, uint256 amt) internal {
        hemi.mint(o, amt);
        vm.prank(o); veHemi.increaseAmount(id, amt);
    }

    /// sweep [from, to) and return (zeroSeconds, minVotes)
    function _sweep(address d, uint256 from, uint256 to)
        internal
        returns (uint256 zeroSeconds, uint256 minVotes)
    {
        minVotes = type(uint256).max;
        for (uint256 t = from; t < to; ++t) {
            vm.warp(t);
            uint256 v = delegation.getVotes(d);
            if (v == 0) { unchecked { ++zeroSeconds; } }
            if (v < minVotes) minVotes = v;
        }
    }

    // =====================================================================
    // R1 -- AN OWNER'S TOP-UP LEAVES NO SNAPSHOT TO PICK.
    //   Alice tops up her OWN position. An attacker sweeps the whole
    //   remainder of the hour looking for ANY second at which DEL_A reads
    //   zero, and then seals `boundary - 1`.
    // =====================================================================
    function test_O05_R1_honestTopUpLeavesNoSnapshotToPick() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, DEL_A);

        vm.warp(_b(block.timestamp) + 600);
        uint256 full = delegation.getVotes(DEL_A);
        assertGt(full, 0, "precondition");

        uint256 T = block.timestamp;
        _topUpSelf(alice, id, 10 ether);

        (uint256 zeroSeconds, uint256 minVotes) = _sweep(DEL_A, T + 1, _b(T));

        uint256 S = _b(T) - 1;                       // the harvest instant
        vm.warp(S + 400 days);
        uint256 sealedVotes = delegation.getPastVotes(DEL_A, S);
        uint256 escrowAtS   = veHemi.balanceOfNFTAt(id, S);

        emit log_named_uint("R1 votes before the top-up      ", full);
        emit log_named_uint("R1 attacker slack (sec at zero) ", zeroSeconds);
        emit log_named_uint("R1 MIN votes over the window    ", minVotes);
        emit log_named_uint("R1 SEALED getPastVotes at bnd-1 ", sealedVotes);
        emit log_named_uint("R1 escrow balanceOfNFTAt bnd-1  ", escrowAtS);

        assertEq(zeroSeconds, 0, "R1: there is no second at which DEL_A reads zero");
        assertGt(sealedVotes, 0, "R1: boundary-1 seals REAL weight, not zero");
        assertGt(escrowAtS, 0, "R1: escrow exists at the sealed instant");
        assertGe(sealedVotes, full, "R1: a top-up may only RAISE the sealed weight");
    }

    // =====================================================================
    // R2 -- ONE SNAPSHOT HARVESTS NOTHING. Three unrelated owners, three
    //       action types (top-up, enable, extend) in one hour, three
    //       delegatees, ONE snapshot at `boundary - 1`.
    // =====================================================================
    function test_O05_R2_oneSnapshotHarvestsNothing() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 i1 = _mk(OWNER1, 500 ether, 40 * SIX_DAYS);
        uint256 i2 = _mk(OWNER2, 300 ether, 40 * SIX_DAYS);
        uint256 i3 = _mk(OWNER3, 100 ether, 40 * SIX_DAYS);
        vm.prank(OWNER1); delegation.delegate(i1, DEL_A);
        vm.prank(OWNER2); delegation.delegate(i2, DEL_B);
        vm.prank(OWNER3); delegation.delegate(i3, DEL_C);

        vm.warp(_b(block.timestamp) + 1 hours);
        uint256 B0 = block.timestamp;
        uint256 BE = B0 + 1 hours;

        uint256 fA = delegation.getVotes(DEL_A);
        uint256 fB = delegation.getVotes(DEL_B);
        uint256 fC = delegation.getVotes(DEL_C);
        assertGt(fA, 0); assertGt(fB, 0); assertGt(fC, 0);

        vm.warp(B0 + 5);    _topUpSelf(OWNER1, i1, 1 ether);
        vm.warp(B0 + 1200); vm.prank(OWNER2); veHemi.enableAutoRelock(i2);
        vm.warp(B0 + 3300); vm.prank(OWNER3); veHemi.increaseUnlockTime(i3, 60 * SIX_DAYS);

        uint256 S = BE - 1;
        vm.warp(S + 400 days);
        uint256 pA = delegation.getPastVotes(DEL_A, S);
        uint256 pB = delegation.getPastVotes(DEL_B, S);
        uint256 pC = delegation.getPastVotes(DEL_C, S);

        emit log_named_uint("R2 DEL_A full / sealed          ", fA);
        emit log_named_uint("   DEL_A sealed at boundary-1   ", pA);
        emit log_named_uint("R2 DEL_B full                   ", fB);
        emit log_named_uint("   DEL_B sealed at boundary-1   ", pB);
        emit log_named_uint("R2 DEL_C full                   ", fC);
        emit log_named_uint("   DEL_C sealed at boundary-1   ", pC);

        assertGt(pA, 0, "R2: DEL_A not erased");
        assertGt(pB, 0, "R2: DEL_B not erased");
        assertGt(pC, 0, "R2: DEL_C not erased");
    }

    // =====================================================================
    // R3 -- A PERMISSIONLESS STALE RETIRE, FIRED AT AN ATTACKER-CHOSEN
    //       HOUR BOUNDARY, OPENS NO ZERO-SECOND. The snapshot instant is
    //       fixed (`boundary - 1`, not data-dependent) and the pin is
    //       explicit: `getPastVotes > 0` AND `balanceOfNFTAt > 0`.
    // =====================================================================
    function test_O05_R3_permissionlessRetireSealsRealWeight() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, DEL_A);
        vm.prank(alice); veHemi.enableAutoRelock(id);

        uint256 staleAt = veHemi.autoRelockStaleAt(id);
        uint256 fireT = _b(staleAt + 1 hours);     // exactly an hour boundary: widest window
        vm.warp(fireT);
        uint256 full = delegation.getVotes(DEL_A);
        assertGt(full, 0, "precondition: DEL_A carries the flat term");

        vm.prank(MALLORY);
        veHemi.retireStaleAutoRelock(id);

        (uint256 zeroSeconds, uint256 minVotes) = _sweep(DEL_A, fireT + 1, fireT + 1 hours);

        uint256 S = fireT + 1 hours - 1;           // FIXED instant, not data-dependent
        vm.warp(S + 400 days);
        uint256 sealedVotes = delegation.getPastVotes(DEL_A, S);
        uint256 escrowAtS   = veHemi.balanceOfNFTAt(id, S);

        emit log_named_uint("R3 fire instant (a boundary)    ", fireT);
        emit log_named_uint("R3 seconds at zero in the hour  ", zeroSeconds);
        emit log_named_uint("R3 MIN votes over the hour      ", minVotes);
        emit log_named_uint("R3 votes before the retire      ", full);
        emit log_named_uint("R3 SEALED getPastVotes at S     ", sealedVotes);
        emit log_named_uint("R3 escrow balanceOfNFTAt at S   ", escrowAtS);

        assertEq(zeroSeconds, 0, "R3: the permissionless retire opens no zero-second");
        assertGt(sealedVotes, 0, "R3 PIN: boundary-1 seals REAL weight");
        assertGt(escrowAtS, 0, "R3 PIN: escrow exists at that instant");
    }

    // =====================================================================
    // R4 -- BATCHED STALE RETIRES. Three stale positions retired in ONE
    //       block by a stranger, one snapshot at the far edge of the hour.
    // =====================================================================
    function test_O05_R4_batchedStaleRetireSealsRealWeight() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 i1 = _mk(OWNER1, 500 ether, 40 * SIX_DAYS);
        uint256 i2 = _mk(OWNER2, 300 ether, 40 * SIX_DAYS);
        uint256 i3 = _mk(OWNER3, 100 ether, 40 * SIX_DAYS);
        vm.prank(OWNER1); delegation.delegate(i1, DEL_A);
        vm.prank(OWNER2); delegation.delegate(i2, DEL_B);
        vm.prank(OWNER3); delegation.delegate(i3, DEL_C);
        vm.prank(OWNER1); veHemi.enableAutoRelock(i1);
        vm.prank(OWNER2); veHemi.enableAutoRelock(i2);
        vm.prank(OWNER3); veHemi.enableAutoRelock(i3);

        uint256 fireT = _b(veHemi.autoRelockStaleAt(i1) + 1 hours);
        vm.warp(fireT);
        uint256 fA = delegation.getVotes(DEL_A);
        uint256 fB = delegation.getVotes(DEL_B);
        uint256 fC = delegation.getVotes(DEL_C);

        vm.startPrank(MALLORY);
        veHemi.retireStaleAutoRelock(i1);
        veHemi.retireStaleAutoRelock(i2);
        veHemi.retireStaleAutoRelock(i3);
        vm.stopPrank();

        uint256 S = fireT + 1 hours - 1;
        vm.warp(S + 400 days);
        uint256 pA = delegation.getPastVotes(DEL_A, S);
        uint256 pB = delegation.getPastVotes(DEL_B, S);
        uint256 pC = delegation.getPastVotes(DEL_C, S);

        emit log_named_uint("R4 DEL_A before / sealed        ", fA);
        emit log_named_uint("   DEL_A sealed                 ", pA);
        emit log_named_uint("R4 DEL_B before                 ", fB);
        emit log_named_uint("   DEL_B sealed                 ", pB);
        emit log_named_uint("R4 DEL_C before                 ", fC);
        emit log_named_uint("   DEL_C sealed                 ", pC);

        assertGt(pA, 0, "R4: DEL_A not erased");
        assertGt(pB, 0, "R4: DEL_B not erased");
        assertGt(pC, 0, "R4: DEL_C not erased");
    }

    // =====================================================================
    // R0 -- THE OWNER GATE IS STRICT. A bare stranger, an `approve(tokenId)`
    //       holder and an operator-for-all are all refused by
    //       `increaseAmount`, and `delegate` refuses the operator too.
    // =====================================================================
    function test_O05_R0_ownerGateRefusesStrangerApprovedAndOperator() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 20 * SIX_DAYS);

        hemi.mint(MALLORY, 1000);
        vm.prank(MALLORY); hemi.approve(address(veHemi), type(uint256).max);

        // (1) bare stranger
        vm.prank(MALLORY);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(id, 1);

        // (2) ERC-721 per-token approval
        vm.prank(alice); veHemi.approve(MALLORY, id);
        assertEq(veHemi.getApproved(id), MALLORY, "precondition: mallory is approved for the token");
        vm.prank(MALLORY);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(id, 1);

        // (3) operator-for-all (the marketplace case)
        vm.prank(alice); veHemi.setApprovalForAll(MALLORY, true);
        assertTrue(veHemi.isApprovedForAll(alice, MALLORY), "precondition: mallory is operator-for-all");
        vm.prank(MALLORY);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(id, 1);

        // and the delegation entry point refuses the operator as well
        vm.prank(MALLORY);
        vm.expectRevert(VeHemiVoteDelegation.CallerIsNotAuthorized.selector);
        delegation.delegate(id, DEL_A);
    }

    // =====================================================================
    // R6 -- NO ACTION SECOND IN THE HOUR IS CAUGHT BY `boundary - 1`.
    //   For action seconds sampled every 60 s across a whole hour bucket,
    //   plus both edges (3598, 3599): the owner tops up by 1 wei, and the
    //   delegatee's votes at `boundary - 1` are at least what they would be
    //   had nobody acted (a `vm.snapshotState` counterfactual).
    // =====================================================================
    function test_O05_R6_noActionSecondInTheHourIsHarvested() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, DEL_A);
        vm.warp(_b(block.timestamp) + 1 hours);
        uint256 B0 = block.timestamp;               // an hour boundary
        uint256 S = B0 + 3599;                      // the harvest instant

        uint256 snap0 = vm.snapshotState();
        vm.warp(S);
        uint256 untouched = delegation.getVotes(DEL_A);
        vm.revertToState(snap0);
        assertGt(untouched, 0, "precondition: DEL_A carries alice's weight at S");

        for (uint256 k = 0; k < 3600; k += 60) {
            _assertActionAtOffsetNotHarvested(id, B0, k, S, untouched);
        }
        _assertActionAtOffsetNotHarvested(id, B0, 3598, S, untouched);
        _assertActionAtOffsetNotHarvested(id, B0, 3599, S, untouched);
    }

    function _assertActionAtOffsetNotHarvested(
        uint256 id_, uint256 b0_, uint256 offset_, uint256 s_, uint256 untouched_
    ) internal {
        uint256 snap = vm.snapshotState();
        vm.warp(b0_ + offset_);
        _topUpSelf(alice, id_, 1);
        vm.warp(s_);
        uint256 v = delegation.getVotes(DEL_A);
        vm.revertToState(snap);
        assertGe(v, untouched_, string.concat("R6: a top-up at offset ", vm.toString(offset_), " lowered DEL_A at boundary-1"));
    }

    // =====================================================================
    // R7 -- THE BUCKET-EDGE INSTANT IS NOT A BLACKOUT INSTANT.
    //   The last `hourBoundary - 1` before a SIX_DAYS boundary is public
    //   (both grids are anchored at unix 0). With an attacker's flat
    //   position in play, the victim's owner tops up inside that hour; the
    //   victim's delegatee must still seal exactly the victim's escrow at
    //   that instant.
    // =====================================================================
    function test_O05_R7_bucketEdgeInstantSealsVictimEscrow() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);

        uint256 idA = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, DEL_A);

        // the attacker's own FLAT (auto-relock) position, self-delegated
        uint256 idM = _mk(MALLORY, 500 ether, 40 * SIX_DAYS);
        vm.prank(MALLORY); delegation.delegate(idM, MALLORY);
        vm.prank(MALLORY); veHemi.enableAutoRelock(idM);

        // the next SIX_DAYS boundary, and the last hour edge at or below it
        uint256 SB = ((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS;
        uint256 hb = (SB / 1 hours) * 1 hours;
        uint256 S  = hb - 1;

        // the victim's owner acts inside that hour
        vm.warp(hb - 1800);
        _topUpSelf(alice, idA, 10 ether);

        vm.warp(S + 400 days);
        uint256 sealedVictim = delegation.getPastVotes(DEL_A, S);
        uint256 escrowAtS    = veHemi.balanceOfNFTAt(idA, S);

        assertGt(escrowAtS, 0, "precondition: the victim holds escrow at S");
        assertEq(sealedVictim, escrowAtS, "R7: the victim's delegatee does not seal the victim's escrow at S");
        assertGt(delegation.getPastVotes(MALLORY, S), 0, "precondition: the attacker's flat position counts at S");
    }

    // =====================================================================
    // R8 -- AN ATTACKER'S OWN DUST POSITION, DELEGATED TO THE VICTIM'S
    //       DELEGATEE. Every call is gate-legal (MALLORY touches only her own
    //       token); retiring her contribution must not zero DEL_A.
    // =====================================================================
    function test_O05_R8_ownPositionOnSharedDelegateeCannotZeroIt() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);

        uint256 idA = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, DEL_A);

        uint256 idM = _mk(MALLORY, 10 ether, 40 * SIX_DAYS);
        vm.prank(MALLORY); delegation.delegate(idM, DEL_A);

        vm.warp(_b(block.timestamp) + 600);
        assertGt(delegation.getVotes(DEL_A), 0, "precondition");

        uint256 T = block.timestamp;
        _topUpSelf(MALLORY, idM, 1);

        (uint256 zeroSeconds, ) = _sweep(DEL_A, T + 1, _b(T));
        assertEq(zeroSeconds, 0, "R8: an attacker's own dust position zeroed the victim's delegatee");
    }

    // =====================================================================
    // R9 -- THE TWO PERMISSIONLESS PATHS INTO A VICTIM'S DELEGATEE:
    //       `createLockFor` (mint FOR the victim) and an unsolicited
    //       `transferFrom` INTO the victim. Neither opens a zero-second.
    // =====================================================================
    function test_O05_R9_createLockForAndUnsolicitedGiftOpenNoZeroSecond() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, DEL_A);
        // alice routes all future positions to DEL_A
        vm.prank(alice); delegation.setAutoDelegate(DEL_A);

        vm.warp(_b(block.timestamp) + 600);

        // (1) permissionless mint FOR alice
        uint256 T = block.timestamp;
        hemi.mint(MALLORY, 1000 ether);
        vm.prank(MALLORY); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(MALLORY); veHemi.createLockFor(10 ether, 40 * SIX_DAYS, alice, true, false);
        (uint256 zeros1, ) = _sweep(DEL_A, T + 1, _b(T));

        // (2) an unsolicited gift: MALLORY's own token, already delegated to
        //     DEL_A, transferred to alice whose autoDelegate is DEL_A.
        vm.warp(_b(T) + 600);
        uint256 T2 = block.timestamp;
        uint256 idM = _mk(MALLORY, 10 ether, 40 * SIX_DAYS);
        vm.prank(MALLORY); delegation.delegate(idM, DEL_A);
        vm.warp(_b(T2) + 600);
        uint256 T3 = block.timestamp;
        vm.prank(MALLORY); veHemi.transferFrom(MALLORY, alice, idM);
        (uint256 zeros2, ) = _sweep(DEL_A, T3 + 1, _b(T3));

        assertEq(zeros1, 0, "R9: permissionless createLockFor zeroed a third party's delegatee");
        assertEq(zeros2, 0, "R9: an unsolicited NFT gift zeroed the recipient's delegatee");
    }
}

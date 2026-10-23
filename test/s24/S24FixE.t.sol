// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// `DelegationUpdateSkipped`: THE NEAR-EXPIRY TRANSFER SKIP.
// ----------------------------------------------------------------------------
// A transfer of an UNARMED position in the last `((end - 1) mod 3600) + 1`
// seconds of its lock is not forwarded to the delegation module: the NFT
// moves, the delegation record stays with the previous delegatee, and VeHemi
// emits `DelegationUpdateSkipped(tokenId)` (IVeHemi NatSpec).
//
//   E1  the skip is attributable from the log stream alone, against a control
//       one second before the window;
//   E2  the receipt is sound and complete: events == skips measured from state;
//   E3  DOCUMENTED BEHAVIOUR: after such a transfer, the new
//       owner's `increaseUnlockTime` re-books the weight at the PREVIOUS
//       delegatee, and the new owner's own `delegate()` then takes it back.
//   E4  the same with auto-relock: the new owner's `enableAutoRelock` after
//       the extension books the FLAT weight at the previous delegatee, and a
//       stranger's `retireStaleAutoRelock` leaves the record there, decaying.
// ============================================================================

import "../j11/J11Base.sol";
import {Vm} from "forge-std/Test.sol";

contract S24FixE is J11Base {
    uint256 private _obs;

    bytes32 internal constant T_SKIPPED = keccak256("DelegationUpdateSkipped(uint256)");
    bytes32 internal constant T_DELEGCHANGED = keccak256("DelegateChanged(uint256,address,address)");

    address internal buyer = address(0x524101);
    address internal seller = address(0x524102);

    function _ok(string memory tag) internal view {
        require(_obs > 0, string.concat("VACUOUS: ", tag, " observed nothing"));
    }

    function _count(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }

    /// @dev the window IVeHemi's NatSpec names: `((end - 1) mod 3600) + 1`.
    function _windowStart(uint256 end_) internal pure returns (uint256) {
        return end_ - (((end_ - 1) % 1 hours) + 1);
    }

    function _mkPosition(address owner_, uint256 amount_, uint256 dur_) internal returns (uint256 id) {
        (id, , ) = createLock(owner_, amount_, dur_);
        delegateTo(owner_, id, dele);
    }

    // =====================================================================
    // E1 -- THE SKIP IS ATTRIBUTABLE FROM THE LOG STREAM ALONE.
    // With a matched control ONE SECOND before the window, which must emit
    // NO skip event and MUST move the delegation.  Both halves asserted, so
    // neither can pass vacuously.
    // =====================================================================
    function test_S24_E1_theSkipIsAttributableAndTheControlIsNot() public {
        _obs = 0;
        uint256 idSkip = _mkPosition(seller, 100 ether, 365 days);
        uint256 idCtl = _mkPosition(victim, 100 ether, 365 days);
        uint256 end = veHemi.getLockedBalance(idSkip).end;
        assertEq(end, veHemi.getLockedBalance(idCtl).end, "E1 setup: the two ends differ");

        // ---- CONTROL: one second BEFORE the window opens ----
        vm.warp(_windowStart(end) - 1);
        vm.recordLogs();
        vm.prank(victim);
        veHemi.transferFrom(victim, buyer, idCtl);
        Vm.Log[] memory ctlLogs = vm.getRecordedLogs();
        uint256 ctlSkips = _count(ctlLogs, T_SKIPPED);
        emit log_named_uint("E1 control DelegationUpdateSkipped", ctlSkips);
        _obs++;
        assertEq(
            delegation.delegation(idCtl).delegatee,
            buyer,
            "NON-VACUOUS: the control transfer did NOT move the delegation -- it is not a control"
        );
        assertEq(ctlSkips, 0, "E1: the control emitted a skip event");

        // ---- THE SKIP: the first second of the window ----
        vm.warp(_windowStart(end));
        vm.recordLogs();
        vm.prank(seller);
        veHemi.transferFrom(seller, buyer, idSkip);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 skips = _count(logs, T_SKIPPED);
        emit log_named_uint("E1 skipping-transfer DelegationUpdateSkipped", skips);
        _obs++;

        // NON-VACUITY: the transfer really did skip.
        assertEq(veHemi.ownerOf(idSkip), buyer, "NON-VACUOUS: the NFT did not move");
        assertEq(
            delegation.delegation(idSkip).delegatee,
            dele,
            "NON-VACUOUS: the delegation FOLLOWED the NFT -- this is not the skip branch"
        );

        assertEq(
            skips,
            1,
            "E1: an escrow-changing call left the delegation behind with NO event to attribute it"
        );
        // the payload must identify the position, or it attributes nothing.
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == T_SKIPPED && logs[i].topics.length > 1) {
                if (uint256(logs[i].topics[1]) == idSkip) found = true;
            }
        }
        assertTrue(found, "E1: the event does not carry the tokenId it is about");
        _ok("E1");
    }

    // =====================================================================
    // E2 -- THE RECEIPT IS SOUND AND COMPLETE.
    // Seven independent positions sharing one `end`, transferred at seven
    // instants spanning the window boundary.  The number of events must equal
    // the number of transfers that actually skipped, measured from STATE --
    // and both must be strictly between 0 and 7, or the grid is degenerate.
    // =====================================================================
    function test_S24_E2_theReceiptIsSoundAndComplete() public {
        _obs = 0;
        uint256[7] memory ids;
        address[7] memory owners;
        for (uint256 i; i < 7; ++i) {
            owners[i] = address(uint160(0x524200 + i));
            ids[i] = _mkPosition(owners[i], 100 ether, 365 days);
        }
        uint256 end = veHemi.getLockedBalance(ids[0]).end;
        uint256 ws = _windowStart(end);
        uint256 w = end - ws; // the shipped window length
        emit log_named_uint("E2 window length (shipped formula)", w);
        assertGt(w, 4, "E2 setup: the window is too short to subdivide");

        uint256[7] memory ts;
        ts[0] = ws - 1800;
        ts[1] = ws - 1200;
        ts[2] = ws - 600;
        ts[3] = ws;
        ts[4] = ws + w / 4;
        ts[5] = ws + w / 2;
        ts[6] = ws + (3 * w) / 4;

        uint256 events;
        uint256 stateSkips;
        for (uint256 i; i < 7; ++i) {
            vm.warp(ts[i]);
            vm.recordLogs();
            vm.prank(owners[i]);
            veHemi.transferFrom(owners[i], buyer, ids[i]);
            events += _count(vm.getRecordedLogs(), T_SKIPPED);
            if (delegation.delegation(ids[i]).delegatee == dele) ++stateSkips;
            _obs++;
        }
        emit log_named_uint("E2 transfers", 7);
        emit log_named_uint("E2 skips measured from STATE", stateSkips);
        emit log_named_uint("E2 DelegationUpdateSkipped events", events);

        assertGt(stateSkips, 0, "NON-VACUOUS: no transfer in the grid skipped");
        assertLt(stateSkips, 7, "NON-VACUOUS: every transfer in the grid skipped -- no negative side");
        assertEq(
            events,
            stateSkips,
            "E2: the receipt is not sound-and-complete -- event count != skip count"
        );
        _ok("E2");
    }

    // =====================================================================
    // E3 -- DOCUMENTED BEHAVIOUR: THE LATE-TRANSFER RE-BOOKING.
    // A transfer in the window leaves the record on the seller's delegatee.
    // The buyer cannot `delegate()` while the lock ends at or before the next
    // hour boundary (`CanNotDelegateExpiredLocks`); extending the lock with
    // `increaseUnlockTime` re-books the restored weight at the PREVIOUS
    // delegatee, and the buyer's own `delegate()` then takes it back, live
    // from the next second. (IVeHemi's `DelegationUpdateSkipped` NatSpec.)
    // =====================================================================
    function test_S24_E3_lateTransfer_extensionRebooksPreviousDelegatee_newOwnerDelegateTakesItBack() public {
        _obs = 0;
        uint256 id = _mkPosition(seller, 100 ether, 365 days);
        uint256 end = veHemi.getLockedBalance(id).end;
        vm.warp(_windowStart(end));

        vm.prank(seller);
        veHemi.transferFrom(seller, buyer, id);
        assertEq(veHemi.ownerOf(id), buyer, "NON-VACUOUS: the NFT did not move");
        assertEq(delegation.delegation(id).delegatee, dele, "NON-VACUOUS: the transfer did not skip");
        _obs++;

        // (1) The buyer cannot delegate yet: the lock ends at or before the
        //     next hour boundary.
        vm.prank(buyer);
        vm.expectRevert(VeHemiVoteDelegation.CanNotDelegateExpiredLocks.selector);
        delegation.delegate(id, buyer);

        // (2) The buyer extends: the weight is re-booked at the PREVIOUS
        //     delegatee.
        vm.prank(buyer);
        veHemi.increaseUnlockTime(id, 365 days);
        vm.warp(block.timestamp + 1);
        uint256 w = veHemi.balanceOfNFT(id);
        assertGt(w, 0, "NON-VACUOUS: the extended position has no weight");
        assertEq(delegation.delegation(id).delegatee, dele, "E3: the extension did not re-book at the previous delegatee");
        assertEq(delegation.getVotes(dele), w, "E3: the previous delegatee does not hold the extended weight");
        assertEq(delegation.getVotes(buyer), 0, "E3: the new owner already holds weight");
        _obs++;

        // (3) The buyer's own `delegate()` takes it back.
        vm.prank(buyer);
        delegation.delegate(id, buyer);
        uint256 tMove = block.timestamp;
        vm.warp(tMove + 1);
        assertEq(delegation.delegation(id).delegatee, buyer, "E3: the new owner's delegate() was not recorded");
        assertEq(delegation.getVotes(dele), 0, "E3: the previous delegatee kept the weight after the new owner's delegate()");
        assertEq(delegation.getVotes(buyer), veHemi.balanceOfNFT(id), "E3: the new owner does not hold the position's weight");
        _obs++;
        _ok("E3");
    }

    // =====================================================================
    // E4 -- DOCUMENTED BEHAVIOUR, ARMED: THE LATE-TRANSFER RE-BOOKING
    // UNDER AUTO-RELOCK. As E3, but the new owner arms the position after the
    // extension instead of delegating. The arm re-books the record FLAT at
    // the PREVIOUS delegatee; if nobody refreshes it, the permissionless
    // stale retirement re-books it there again, decaying (transferFrom's
    // NatSpec: "a later ... `enableAutoRelock` (and a later
    // `retireStaleAutoRelock`) re-books the position's weight to that
    // delegatee").
    // =====================================================================
    function test_S24_E4_lateTransfer_armRebooksPreviousDelegateeFlat_staleRetireLeavesItThereDecaying() public {
        _obs = 0;
        uint256 id = _mkPosition(seller, 100 ether, 365 days);
        uint256 end = veHemi.getLockedBalance(id).end;
        vm.warp(_windowStart(end));

        vm.prank(seller);
        veHemi.transferFrom(seller, buyer, id);
        assertEq(veHemi.ownerOf(id), buyer, "NON-VACUOUS: the NFT did not move");
        assertEq(delegation.delegation(id).delegatee, dele, "NON-VACUOUS: the transfer did not skip");
        _obs++;

        // (1) The buyer extends, then arms: the arm re-books the record as a
        //     flat term at the PREVIOUS delegatee.
        vm.prank(buyer);
        veHemi.increaseUnlockTime(id, 365 days);
        enable(buyer, id);
        assertTrue(veHemi.isAutoRelockEnabled(id), "NON-VACUOUS: the arm did not commit");
        vm.warp(block.timestamp + 1);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, dele, "E4: the arm did not re-book at the previous delegatee");
        assertTrue(d.slope == 0 && d.bias > 0, "E4: the armed record is not flat");
        uint256 w = veHemi.balanceOfNFT(id);
        assertGt(w, 0, "NON-VACUOUS: the armed position has no weight");
        assertEq(delegation.getVotes(dele), w, "E4: the previous delegatee does not hold the flat weight");
        assertEq(delegation.getVotes(buyer), 0, "E4: the new owner already holds weight");
        _obs++;

        // (2) Nobody refreshes; a stranger retires the stale position. The
        //     record stays at the previous delegatee and decays again.
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id);
        assertFalse(veHemi.isAutoRelockEnabled(id), "NON-VACUOUS: the retirement did not commit");
        d = delegation.delegation(id);
        assertEq(d.delegatee, dele, "E4: the retirement moved the record off the previous delegatee");
        assertGt(d.slope, 0, "E4: the retired record is not decaying");
        vm.warp(block.timestamp + 1);
        uint256 w1 = delegation.getVotes(dele);
        assertEq(w1, veHemi.balanceOfNFT(id), "E4: the previous delegatee does not hold the retired weight");
        assertGt(w1, 0, "NON-VACUOUS: the retired position has no weight");
        vm.warp(block.timestamp + SIX_DAYS);
        assertLt(delegation.getVotes(dele), w1, "E4: the weight at the previous delegatee does not decay");
        assertEq(delegation.getVotes(buyer), 0, "E4: the new owner holds weight it never delegated");
        _obs++;
        _ok("E4");
    }
}

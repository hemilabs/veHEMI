// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";

/**
 * @title P205GuardTest
 * @notice `CheckpointLayoutViolated` fires on every checkpoint-array shape that breaks
 *         layout clause (1) (the tail pair is sorted) or (2) (at most one element dated
 *         after `imm`; it is the last and is dated exactly `B`), and never on an
 *         honestly-written array or on the pending-only (`len == 1`, dated `B`) shape of
 *         the upgrade-hour window.
 *
 *         The broken shapes are written straight into storage with `vm.store`: they model what
 *         the guard exists to catch -- a NEW writer of `delegateCheckpoints` that broke a
 *         clause -- without requiring that writer to exist. That is not a demonstration
 *         that any plausible code change produces these states. Clauses (4) and (5) are
 *         properties of the WRITE and live in `P205Clause45.t.sol`.
 */
contract P205GuardTest is LockedCurveTestBase {
    // delegateCheckpoints is slot 1 of VeHemiVoteDelegation (golden layout).
    uint256 internal constant CP_SLOT = 1;

    error CheckpointLayoutViolated();

    // ------------------------------------------------------------- helpers --
    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }
    function _cps(address d) internal view returns (VeHemiVoteDelegation.DelegateCheckpoint[] memory) {
        return delegation.getDelegationCheckpoints(d);
    }
    function _nb(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _arrSlot(address d) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(d, CP_SLOT)));
    }
    function _dataSlot(address d) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(bytes32(_arrSlot(d)))));
    }
    function _len(address d) internal view returns (uint256) {
        return uint256(vm.load(address(delegation), bytes32(_arrSlot(d))));
    }
    function _setLen(address d, uint256 n) internal {
        vm.store(address(delegation), bytes32(_arrSlot(d)), bytes32(n));
    }
    /// element i, packed slot 1: totalAmount[0:128] | normalizedSlope[128:192] | timestamp[192:256]
    function _setTs(address d, uint256 i, uint256 ts) internal {
        bytes32 s = bytes32(_dataSlot(d) + 2 * i + 1);
        uint256 w = uint256(vm.load(address(delegation), s));
        w = (w & ((uint256(1) << 192) - 1)) | (ts << 192);
        vm.store(address(delegation), s, bytes32(w));
    }
    function _copyEl(address d, uint256 from, uint256 to) internal {
        for (uint256 k; k < 2; ++k) {
            vm.store(
                address(delegation),
                bytes32(_dataSlot(d) + 2 * to + k),
                vm.load(address(delegation), bytes32(_dataSlot(d) + 2 * from + k))
            );
        }
    }
    function _dumpCps(address d, string memory where) internal {
        VeHemiVoteDelegation.DelegateCheckpoint[] memory a = _cps(d);
        emit log_named_string("--- checkpoints", where);
        emit log_named_uint("    now", block.timestamp);
        emit log_named_uint("    imm (now+1)", block.timestamp + 1);
        emit log_named_uint("    B (boundary)", _nb(block.timestamp));
        for (uint256 i; i < a.length; ++i) emit log_named_uint("    ts", uint256(a[i].timestamp));
    }

    /// Base state: `[ ...history, live(t_live), pending(B) ]` -- compliant with
    /// every layout clause.
    function _liveAndPending() internal returns (uint256 idA, uint256 B) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nb(block.timestamp) + 120);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(block.timestamp + 600);

        uint256 n = _len(bob);
        B = _nb(block.timestamp);
        _copyEl(bob, n - 1, n);
        _setLen(bob, n + 1);
        _setTs(bob, n, B);
        _dumpCps(bob, "base: live + pending (CP-LAYOUT compliant)");
    }

    // ============================================== CLAUSE (2): FUTURE ELEMENTS ===
    /// L2a -- a SECOND future element.
    function test_P205_M_L2a_secondFutureElement_GUARD_FIRES() public {
        (uint256 idA, uint256 B) = _liveAndPending();
        uint256 n = _len(bob);
        assertGe(n, 2, "need live + pending");
        assertEq(uint256(_cps(bob)[n - 1].timestamp), B, "last must be the pending element");
        _setTs(bob, n - 2, B - 1);
        assertGt(B - 1, block.timestamp + 1, "the mutant element must be future");
        _dumpCps(bob, "L2a mutant: two future elements");

        vm.expectRevert(CheckpointLayoutViolated.selector);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
    }

    /// L2b -- the pending element is not dated at `B` (judged above the
    /// live/pending branch).
    function test_P205_M_L2b_pendingNotAtBoundary_GUARD_FIRES() public {
        (uint256 idA, uint256 B) = _liveAndPending();
        uint256 n = _len(bob);
        _setTs(bob, n - 1, B + 1 hours);
        _dumpCps(bob, "L2b mutant: pending off-boundary");

        vm.expectRevert(CheckpointLayoutViolated.selector);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
    }

    // ======================================================= CLAUSE (1): ORDER ===
    /// L1 -- two PAST-dated elements out of order. Zero future elements, so
    /// clause (2) is intact; the tail-order test must catch it.
    function test_P205_M_L1_unsorted_GUARD_FIRES() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nb(block.timestamp) + 120);
        vm.prank(charlie); delegation.delegate(idC, bob);
        vm.warp(block.timestamp + 600);
        uint256 n = _len(bob);
        assertGe(n, 2, "need two matured elements");
        uint256 t0 = uint256(_cps(bob)[n - 2].timestamp);
        _setTs(bob, n - 1, t0 - 1);
        _dumpCps(bob, "L1 mutant: unsorted, both past");

        // PREMISE FIRST: the corrupted array really is unsorted, and it really has NO
        // future element -- otherwise this body would be re-testing L2a.
        assertGt(
            uint256(_cps(bob)[n - 2].timestamp), uint256(_cps(bob)[n - 1].timestamp),
            "L1 premise: the mutant array must be unsorted"
        );
        assertLe(
            uint256(_cps(bob)[n - 2].timestamp), block.timestamp + 1,
            "L1 premise: NO element may be future, or this is L2a not L1"
        );

        vm.expectRevert(CheckpointLayoutViolated.selector);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
    }

    // ============================================ CLAUSE (2): FUTURE, NOT LAST ===
    /// L2c -- one future element, NOT the tail. `_hasPending` reads the LAST
    /// element only, so it is false. A future element that is not last
    /// necessarily inverts the tail pair, which the tail-order test catches.
    function test_P205_M_L2c_futureElementNotLast_GUARD_FIRES() public {
        (uint256 idA, uint256 B) = _liveAndPending();
        uint256 n = _len(bob);
        uint256 tPrev = uint256(_cps(bob)[n - 2].timestamp);
        _setTs(bob, n - 2, B);
        _setTs(bob, n - 1, tPrev);
        _dumpCps(bob, "L2c mutant: future element NOT last");

        assertGt(uint256(_cps(bob)[n - 2].timestamp), block.timestamp + 1, "L2c premise: it is future");
        assertLe(uint256(_cps(bob)[n - 1].timestamp), block.timestamp + 1, "L2c premise: the tail is past");

        vm.expectRevert(CheckpointLayoutViolated.selector);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
    }

    // ================================= CLAUSE (2): SOLE ELEMENT OFF-BOUNDARY ===
    /// L3b -- a SOLE element, future-dated and NOT at `B`. The
    /// `!_hasPending || len > 1` branch skips the tail checks here, so the
    /// pending-date check above that branch must refuse it; otherwise it would
    /// reach `_calculateCheckpoint` with
    /// `previousCheckpoint_.timestamp != checkpointTimestamp_` and be silently
    /// re-dated to `B`.
    function test_P205_M_L3b_soleElementOffBoundary_GUARD_FIRES() public {
        (uint256 idA, uint256 B) = _liveAndPending();
        uint256 n = _len(bob);
        _copyEl(bob, n - 1, 0);
        _setLen(bob, 1);
        _setTs(bob, 0, B + 1 hours);
        _dumpCps(bob, "L3b mutant: sole element, future, off-boundary");

        assertEq(_len(bob), 1, "L3b premise: len == 1 -- the branch that skipped the guard");
        assertGt(uint256(_cps(bob)[0].timestamp), block.timestamp + 1, "L3b premise: it is future");

        vm.expectRevert(CheckpointLayoutViolated.selector);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
    }

    // ======================================= PENDING-ONLY SHAPE STAYS SERVED ===
    /// *** THE LIMIT OF THE SOLE-ELEMENT CHECK, PINNED. ***
    /// `len == 1` with that element PENDING and dated EXACTLY at `B` is the
    /// upgrade-hour-window shape. It must NOT be refused: the writer takes the
    /// `else if (_hasPending)` tail and updates the pending element in place.
    function test_P205_M_L3_pendingOnly_STILL_SERVED() public {
        (uint256 idA, uint256 B) = _liveAndPending();
        uint256 n = _len(bob);
        bytes32 a0 = vm.load(address(delegation), bytes32(_dataSlot(bob) + 2 * (n - 1)));
        bytes32 a1 = vm.load(address(delegation), bytes32(_dataSlot(bob) + 2 * (n - 1) + 1));
        vm.store(address(delegation), bytes32(_dataSlot(bob)), a0);
        vm.store(address(delegation), bytes32(_dataSlot(bob) + 1), a1);
        _setLen(bob, 1);
        assertEq(uint256(_cps(bob)[0].timestamp), B, "premise: the single element is pending, AT B");
        _dumpCps(bob, "L3 residual: pending-only, len == 1, dated at B");

        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
        VeHemiVoteDelegation.DelegateCheckpoint[] memory a = _cps(bob);
        assertEq(a.length, 1, "L3 residual: the writer must still take the pending-only tail");
        assertEq(uint256(a[0].timestamp), B, "L3 residual: the element is still dated at B");
    }

    // ========================================================== NO MISFIRE ===
    /// The compliant live+pending base must accept every ordinary write --
    /// the tail-order test included.
    function test_P205_NOMISFIRE_ordinaryTraffic() public {
        (uint256 idA, ) = _liveAndPending();
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
        vm.warp(block.timestamp + 300);
        vm.prank(alice); delegation.delegate(idA, bob);
        vm.warp(_nb(block.timestamp) + 60);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
    }

    /// The tail-order test must not fire on a ONE-ELEMENT array, where there
    /// is no predecessor (the `len > 1` half of that test).
    function test_P205_NOMISFIRE_singleElementArray() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(idA, bob);
        assertEq(_len(bob), 1, "premise: exactly one element");
        vm.warp(block.timestamp + 300);
        vm.prank(alice); delegation.delegate(idA, address(0xC0DE));
        assertEq(_len(bob), 2, "the write appended through a one-element array");
    }

    /// A long, honestly-grown array: many writes through the same delegatee,
    /// across boundaries, must never trip the layout checks.
    function test_P205_NOMISFIRE_longHonestArray() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 idA = _mk(alice, 500 ether, 20 * SIX_DAYS);
        uint256 idC = _mk(charlie, 300 ether, 20 * SIX_DAYS);
        for (uint256 i; i < 12; ++i) {
            vm.prank(alice); delegation.delegate(idA, i % 2 == 0 ? bob : address(0xC0DE));
            vm.prank(charlie); delegation.delegate(idC, bob);
            vm.warp(block.timestamp + 1200);
        }
        assertGt(_len(bob), 4, "premise: the array really grew");
        emit log_named_uint("honest array length", _len(bob));
    }
}

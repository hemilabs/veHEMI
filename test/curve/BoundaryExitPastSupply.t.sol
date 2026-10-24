// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @title Past supply is immutable across a bucket-boundary exit.
/// @notice Forces `block.timestamp % SIX_DAYS == 0` AND
///         `oldEnd_ == block.timestamp` at `VeHemiCurveLib._adjustSlopeChange`
///         (a withdraw or transfer at exactly `lock.end`, on the grid) and
///         asserts that every historical supply view (total, non-transferable,
///         forfeitable) at the sample instants at or before the boundary is
///         unchanged afterwards, read at the boundary and buckets later. The
///         sample instants after the boundary are still in the future when the
///         reference snapshot is taken; each is checked against the closed form
///         instead, once it has passed (`_assertAfterBoundary`).
contract BoundaryExitPastSupplyTest is LockedCurveTestBase {
    uint256 constant LONG_LIVED_AMOUNT = 500 ether; // long-lived position, keeps the curve alive
    uint256 constant EXITING_AMOUNT = 300 ether;    // the position that expires ON the boundary

    uint256[] internal sampleInstants;
    uint256[] internal pastTotal;
    uint256[] internal pastLocked;
    uint256[] internal pastForfeitable;

    function _mk(address who, uint256 amt, uint256 dur, bool transferable_, bool forfeitable_)
        internal
        returns (uint256 id)
    {
        hemi.mint(address(this), amt);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLockFor(amt, dur, who, transferable_, forfeitable_);
    }

    function _buildSampleInstants(uint256 boundary) internal {
        delete sampleInstants;
        sampleInstants.push(boundary - 3 * SIX_DAYS);
        sampleInstants.push(boundary - 2 * SIX_DAYS);
        sampleInstants.push(boundary - SIX_DAYS);
        sampleInstants.push(boundary - SIX_DAYS / 2);
        sampleInstants.push(boundary - 1);
        sampleInstants.push(boundary);
        sampleInstants.push(boundary + 1);
        sampleInstants.push(boundary + SIX_DAYS / 2);
        sampleInstants.push(boundary + SIX_DAYS);
        sampleInstants.push(boundary + 2 * SIX_DAYS);
        sampleInstants.push(boundary + 3 * SIX_DAYS);
        sampleInstants.push(boundary + 10 * SIX_DAYS);
    }

    function _readPastSupplies(string memory)
        internal
        view
        returns (uint256[] memory total, uint256[] memory locked, uint256[] memory forfeitable)
    {
        total = new uint256[](sampleInstants.length);
        locked = new uint256[](sampleInstants.length);
        forfeitable = new uint256[](sampleInstants.length);
        for (uint256 i; i < sampleInstants.length; ++i) {
            uint256 sampleAt = sampleInstants[i];
            if (sampleAt > block.timestamp) continue;
            total[i] = veHemi.totalVeHemiSupplyAt(sampleAt);
            locked[i] = veHemi.nonTransferableTotalVeHemiSupplyAt(sampleAt);
            forfeitable[i] = veHemi.forfeitableTotalVeHemiSupplyAt(sampleAt);
        }
    }

    function _storeReferenceSupplies(
        uint256[] memory total,
        uint256[] memory locked,
        uint256[] memory forfeitable
    ) internal {
        delete pastTotal; delete pastLocked; delete pastForfeitable;
        for (uint256 i; i < total.length; ++i) {
            pastTotal.push(total[i]);
            pastLocked.push(locked[i]);
            pastForfeitable.push(forfeitable[i]);
        }
    }

    function _assertImmutable(string memory tag) internal {
        for (uint256 i; i < sampleInstants.length; ++i) {
            uint256 sampleAt = sampleInstants[i];
            if (sampleAt > block.timestamp) continue;
            if (pastTotal[i] == 0 && pastLocked[i] == 0 && pastForfeitable[i] == 0) continue;
            assertEq(veHemi.totalVeHemiSupplyAt(sampleAt), pastTotal[i],
                string.concat(tag, ": PAST TOTAL SUPPLY MOVED"));
            assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(sampleAt), pastLocked[i],
                string.concat(tag, ": PAST LOCKED SUPPLY MOVED"));
            assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(sampleAt), pastForfeitable[i],
                string.concat(tag, ": PAST FORFEITABLE SUPPLY MOVED"));
        }
    }

    /// @dev The sample instants after `boundary_` that have passed, checked
    ///      against the closed form. Seeding ran on an empty state and every other
    ///      position ends at `boundary_`, so after it the long-lived position is
    ///      the only unexpired one. The global curve is integer-exact (each
    ///      position adds `slope * (end - t)` and its slope is retired at `end`),
    ///      so the total supply at `sampleAt` is
    ///      `(LONG_LIVED_AMOUNT / MAX_TIME) * (longLivedEnd_ - sampleAt)`.
    ///      The long-lived position is transferable, so both subcurves read 0.
    ///      A retirement at the boundary that the exit loses or books twice
    ///      changes only these instants.
    ///      Returns how many instants were checked.
    function _assertAfterBoundary(string memory tag, uint256 boundary_, uint256 longLivedEnd_)
        internal
        view
        returns (uint256 checked)
    {
        uint256 longLivedSlope = LONG_LIVED_AMOUNT / MAX_TIME;
        for (uint256 i; i < sampleInstants.length; ++i) {
            uint256 sampleAt = sampleInstants[i];
            if (sampleAt <= boundary_ || sampleAt > block.timestamp) continue;
            assertGt(longLivedEnd_, sampleAt,
                string.concat(tag, ": premise: the long-lived position must outlive the sample"));
            assertEq(veHemi.totalVeHemiSupplyAt(sampleAt), longLivedSlope * (longLivedEnd_ - sampleAt),
                string.concat(tag, ": TOTAL SUPPLY AFTER THE BOUNDARY WRONG"));
            assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(sampleAt), 0,
                string.concat(tag, ": LOCKED SUPPLY AFTER THE BOUNDARY NOT ZERO"));
            assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(sampleAt), 0,
                string.concat(tag, ": FORFEITABLE SUPPLY AFTER THE BOUNDARY NOT ZERO"));
            ++checked;
        }
    }

    // =================================================================
    // A/B/C: withdraw at EXACTLY lock.end, which is a SIX_DAYS boundary.
    // =================================================================
    function _runBoundaryWithdraw(bool transferable_, bool forfeitable_, string memory tag) internal {
        vm.warp(2_000 * SIX_DAYS);
        assertEq(block.timestamp % SIX_DAYS, 0, "premise: not on a boundary");
        runSeedingFlow();

        uint256 longLived = _mk(alice, LONG_LIVED_AMOUNT, 3 * 365 days, true, false);
        uint256 exiting = _mk(bob, EXITING_AMOUNT, 4 * SIX_DAYS, transferable_, forfeitable_);

        uint256 boundary = veHemi.getLockedBalance(exiting).end;
        uint256 longLivedEnd = veHemi.getLockedBalance(longLived).end;
        assertGt(longLivedEnd, boundary + 40 * SIX_DAYS, "premise: the long-lived position must outlive the walk");
        _buildSampleInstants(boundary);

        vm.warp(boundary);
        assertEq(block.timestamp % SIX_DAYS, 0, "not phase 0");
        assertEq(block.timestamp, veHemi.getLockedBalance(exiting).end, "not at lock.end");

        (uint256[] memory referenceTotal, uint256[] memory referenceLocked, uint256[] memory referenceForfeitable) =
            _readPastSupplies(string.concat(tag, " PRE "));
        _storeReferenceSupplies(referenceTotal, referenceLocked, referenceForfeitable);

        vm.prank(bob);
        veHemi.withdraw(exiting);             // <- the phase-0 _adjustSlopeChange call

        _readPastSupplies(string.concat(tag, " POST"));
        _assertImmutable(string.concat(tag, " POST"));

        vm.warp(boundary + 3 * SIX_DAYS);
        veHemi.checkpoint();
        _readPastSupplies(string.concat(tag, " LATE"));
        _assertImmutable(string.concat(tag, " LATE"));
        _assertAfterBoundary(string.concat(tag, " LATE"), boundary, longLivedEnd);

        vm.warp(boundary + 40 * SIX_DAYS);
        veHemi.checkpoint();
        _readPastSupplies(string.concat(tag, " FAR "));
        _assertImmutable(string.concat(tag, " FAR "));
        assertEq(_assertAfterBoundary(string.concat(tag, " FAR "), boundary, longLivedEnd), 6,
            "NON-VACUOUS: not every sample instant after the boundary was checked");
    }

    function test_A_transferable_withdraw_at_boundary() public { _runBoundaryWithdraw(true, false, "A"); }
    function test_B_nontransferable_withdraw_at_boundary() public { _runBoundaryWithdraw(false, false, "B"); }
    function test_C_forfeitable_withdraw_at_boundary() public { _runBoundaryWithdraw(false, true, "C"); }

    // =================================================================
    // D: transferFrom at exactly lock.end (oldEnd_ == newEnd_ == now).
    // =================================================================
    function test_D_transfer_at_boundary() public {
        vm.warp(2_000 * SIX_DAYS);
        runSeedingFlow();
        uint256 longLived = _mk(alice, LONG_LIVED_AMOUNT, 3 * 365 days, true, false);
        uint256 exiting = _mk(bob, EXITING_AMOUNT, 4 * SIX_DAYS, true, false);
        uint256 boundary = veHemi.getLockedBalance(exiting).end;
        uint256 longLivedEnd = veHemi.getLockedBalance(longLived).end;
        _buildSampleInstants(boundary);
        vm.warp(boundary);
        (uint256[] memory referenceTotal, uint256[] memory referenceLocked, uint256[] memory referenceForfeitable) =
            _readPastSupplies("D PRE ");
        _storeReferenceSupplies(referenceTotal, referenceLocked, referenceForfeitable);
        vm.prank(bob);
        veHemi.transferFrom(bob, charlie, exiting);
        _readPastSupplies("D POST");
        _assertImmutable("D POST");
        vm.warp(boundary + 5 * SIX_DAYS);
        veHemi.checkpoint();
        _readPastSupplies("D LATE");
        _assertImmutable("D LATE");
        _assertAfterBoundary("D LATE", boundary, longLivedEnd);
        vm.warp(boundary + 40 * SIX_DAYS);
        veHemi.checkpoint();
        _assertImmutable("D FAR ");
        assertEq(_assertAfterBoundary("D FAR ", boundary, longLivedEnd), 6,
            "NON-VACUOUS: not every sample instant after the boundary was checked");
    }

    // =================================================================
    // E: two positions share the boundary bucket; only one withdraws at
    //    exactly the boundary, so a corrupted slopeChanges[boundary] is a
    //    PARTIAL corruption of a bucket that still has live weight behind it.
    // =================================================================
    function test_E_shared_bucket_partial_withdraw() public {
        vm.warp(2_000 * SIX_DAYS);
        runSeedingFlow();
        uint256 longLived = _mk(alice, LONG_LIVED_AMOUNT, 3 * 365 days, true, false);
        uint256 firstExiting = _mk(bob, EXITING_AMOUNT, 4 * SIX_DAYS, true, false);
        uint256 secondExiting = _mk(charlie, EXITING_AMOUNT * 2, 4 * SIX_DAYS, true, false);
        uint256 boundary = veHemi.getLockedBalance(firstExiting).end;
        assertEq(boundary, veHemi.getLockedBalance(secondExiting).end, "E: not the same bucket");
        uint256 longLivedEnd = veHemi.getLockedBalance(longLived).end;
        _buildSampleInstants(boundary);
        vm.warp(boundary);
        (uint256[] memory referenceTotal, uint256[] memory referenceLocked, uint256[] memory referenceForfeitable) =
            _readPastSupplies("E PRE ");
        _storeReferenceSupplies(referenceTotal, referenceLocked, referenceForfeitable);
        vm.prank(bob);
        veHemi.withdraw(firstExiting);
        _readPastSupplies("E POST");
        _assertImmutable("E POST");
        vm.warp(boundary + 2 * SIX_DAYS);
        veHemi.checkpoint();
        _readPastSupplies("E LATE");
        _assertImmutable("E LATE");
        vm.prank(charlie);
        veHemi.withdraw(secondExiting);
        _readPastSupplies("E LAST");
        _assertImmutable("E LAST");
        _assertAfterBoundary("E LAST", boundary, longLivedEnd);
        vm.warp(boundary + 40 * SIX_DAYS);
        veHemi.checkpoint();
        _assertImmutable("E FAR ");
        assertEq(_assertAfterBoundary("E FAR ", boundary, longLivedEnd), 6,
            "NON-VACUOUS: not every sample instant after the boundary was checked");
    }
}

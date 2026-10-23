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
contract J14BoundaryTest is LockedCurveTestBase {
    uint256 constant KEEP = 500 ether;   // long-lived position, keeps the curve alive
    uint256 constant VICT = 300 ether;   // the position that expires ON the boundary

    uint256[] internal grid;
    uint256[] internal preTot;
    uint256[] internal preLk;
    uint256[] internal preFo;

    function _mk(address who, uint256 amt, uint256 dur, bool transferable_, bool forf_)
        internal
        returns (uint256 id)
    {
        hemi.mint(address(this), amt);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLockFor(amt, dur, who, transferable_, forf_);
    }

    function _buildGrid(uint256 B) internal {
        delete grid;
        grid.push(B - 3 * SIX_DAYS);
        grid.push(B - 2 * SIX_DAYS);
        grid.push(B - SIX_DAYS);
        grid.push(B - SIX_DAYS / 2);
        grid.push(B - 1);
        grid.push(B);
        grid.push(B + 1);
        grid.push(B + SIX_DAYS / 2);
        grid.push(B + SIX_DAYS);
        grid.push(B + 2 * SIX_DAYS);
        grid.push(B + 3 * SIX_DAYS);
        grid.push(B + 10 * SIX_DAYS);
    }

    function _snap(string memory)
        internal
        view
        returns (uint256[] memory t, uint256[] memory l, uint256[] memory f)
    {
        t = new uint256[](grid.length);
        l = new uint256[](grid.length);
        f = new uint256[](grid.length);
        for (uint256 i; i < grid.length; ++i) {
            uint256 q = grid[i];
            if (q > block.timestamp) continue;
            t[i] = veHemi.totalVeHemiSupplyAt(q);
            l[i] = veHemi.nonTransferableTotalVeHemiSupplyAt(q);
            f[i] = veHemi.forfeitableTotalVeHemiSupplyAt(q);
        }
    }

    function _record(uint256[] memory t, uint256[] memory l, uint256[] memory f) internal {
        delete preTot; delete preLk; delete preFo;
        for (uint256 i; i < t.length; ++i) { preTot.push(t[i]); preLk.push(l[i]); preFo.push(f[i]); }
    }

    function _assertImmutable(string memory tag) internal {
        for (uint256 i; i < grid.length; ++i) {
            uint256 q = grid[i];
            if (q > block.timestamp) continue;
            if (preTot[i] == 0 && preLk[i] == 0 && preFo[i] == 0) continue;
            assertEq(veHemi.totalVeHemiSupplyAt(q), preTot[i],
                string.concat(tag, ": PAST TOTAL SUPPLY MOVED"));
            assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(q), preLk[i],
                string.concat(tag, ": PAST LOCKED SUPPLY MOVED"));
            assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(q), preFo[i],
                string.concat(tag, ": PAST FORFEITABLE SUPPLY MOVED"));
        }
    }

    /// @dev The sample instants after `boundary_` that have passed, checked
    ///      against the closed form. Seeding ran on an empty state and every other
    ///      position ends at `boundary_`, so after it the keeper is the only live
    ///      position. The global curve is integer-exact (each position adds
    ///      `slope * (end - t)` and its slope is retired at `end`), so the total
    ///      supply at `q` is `(KEEP / MAX_TIME) * (keeperEnd_ - q)`. The keeper is
    ///      transferable, so both subcurves read 0. A retirement at the boundary
    ///      that the exit loses or books twice changes only these instants.
    ///      Returns how many instants were checked.
    function _assertAfterBoundary(string memory tag, uint256 boundary_, uint256 keeperEnd_)
        internal
        view
        returns (uint256 n)
    {
        uint256 slopeK = KEEP / MAX_TIME;
        for (uint256 i; i < grid.length; ++i) {
            uint256 q = grid[i];
            if (q <= boundary_ || q > block.timestamp) continue;
            assertGt(keeperEnd_, q, string.concat(tag, ": setup: the keeper must outlive the sample"));
            assertEq(veHemi.totalVeHemiSupplyAt(q), slopeK * (keeperEnd_ - q),
                string.concat(tag, ": TOTAL SUPPLY AFTER THE BOUNDARY WRONG"));
            assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(q), 0,
                string.concat(tag, ": LOCKED SUPPLY AFTER THE BOUNDARY NOT ZERO"));
            assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(q), 0,
                string.concat(tag, ": FORFEITABLE SUPPLY AFTER THE BOUNDARY NOT ZERO"));
            ++n;
        }
    }

    // =================================================================
    // A/B/C: withdraw at EXACTLY lock.end, which is a SIX_DAYS boundary.
    // =================================================================
    function _run(bool transferable_, bool forf_, string memory tag) internal {
        vm.warp(2_000 * SIX_DAYS);
        assertEq(block.timestamp % SIX_DAYS, 0, "setup: not on a boundary");
        runSeedingFlow();

        uint256 keeper = _mk(alice, KEEP, 3 * 365 days, true, false);
        uint256 victim = _mk(bob, VICT, 4 * SIX_DAYS, transferable_, forf_);

        uint256 B = veHemi.getLockedBalance(victim).end;
        uint256 keeperEnd = veHemi.getLockedBalance(keeper).end;
        assertGt(keeperEnd, B + 40 * SIX_DAYS, "setup: keeper must outlive the walk");
        _buildGrid(B);

        vm.warp(B);
        assertEq(block.timestamp % SIX_DAYS, 0, "not phase 0");
        assertEq(block.timestamp, veHemi.getLockedBalance(victim).end, "not at lock.end");

        (uint256[] memory t0, uint256[] memory l0, uint256[] memory f0) = _snap(string.concat(tag, " PRE "));
        _record(t0, l0, f0);

        vm.prank(bob);
        veHemi.withdraw(victim);              // <- the phase-0 _adjustSlopeChange call

        _snap(string.concat(tag, " POST"));
        _assertImmutable(string.concat(tag, " POST"));

        vm.warp(B + 3 * SIX_DAYS);
        veHemi.checkpoint();
        _snap(string.concat(tag, " LATE"));
        _assertImmutable(string.concat(tag, " LATE"));
        _assertAfterBoundary(string.concat(tag, " LATE"), B, keeperEnd);

        vm.warp(B + 40 * SIX_DAYS);
        veHemi.checkpoint();
        _snap(string.concat(tag, " FAR "));
        _assertImmutable(string.concat(tag, " FAR "));
        assertEq(_assertAfterBoundary(string.concat(tag, " FAR "), B, keeperEnd), 6,
            "NON-VACUOUS: not every sample instant after the boundary was checked");
    }

    function test_J14_A_transferable_withdraw_at_boundary() public { _run(true, false, "A"); }
    function test_J14_B_nontransferable_withdraw_at_boundary() public { _run(false, false, "B"); }
    function test_J14_C_forfeitable_withdraw_at_boundary() public { _run(false, true, "C"); }

    // =================================================================
    // D: transferFrom at exactly lock.end (oldEnd_ == newEnd_ == now).
    // =================================================================
    function test_J14_D_transfer_at_boundary() public {
        vm.warp(2_000 * SIX_DAYS);
        runSeedingFlow();
        uint256 keeper = _mk(alice, KEEP, 3 * 365 days, true, false);
        uint256 victim = _mk(bob, VICT, 4 * SIX_DAYS, true, false);
        uint256 B = veHemi.getLockedBalance(victim).end;
        uint256 keeperEnd = veHemi.getLockedBalance(keeper).end;
        _buildGrid(B);
        vm.warp(B);
        (uint256[] memory t0, uint256[] memory l0, uint256[] memory f0) = _snap("D PRE ");
        _record(t0, l0, f0);
        vm.prank(bob);
        veHemi.transferFrom(bob, charlie, victim);
        _snap("D POST");
        _assertImmutable("D POST");
        vm.warp(B + 5 * SIX_DAYS);
        veHemi.checkpoint();
        _snap("D LATE");
        _assertImmutable("D LATE");
        _assertAfterBoundary("D LATE", B, keeperEnd);
        vm.warp(B + 40 * SIX_DAYS);
        veHemi.checkpoint();
        _assertImmutable("D FAR ");
        assertEq(_assertAfterBoundary("D FAR ", B, keeperEnd), 6,
            "NON-VACUOUS: not every sample instant after the boundary was checked");
    }

    // =================================================================
    // E: two positions share the boundary bucket; only one withdraws at
    //    exactly B, so a corrupted slopeChanges[B] is a PARTIAL corruption
    //    of a bucket that still has live weight behind it.
    // =================================================================
    function test_J14_E_shared_bucket_partial_withdraw() public {
        vm.warp(2_000 * SIX_DAYS);
        runSeedingFlow();
        uint256 keeper = _mk(alice, KEEP, 3 * 365 days, true, false);
        uint256 v1 = _mk(bob, VICT, 4 * SIX_DAYS, true, false);
        uint256 v2 = _mk(charlie, VICT * 2, 4 * SIX_DAYS, true, false);
        uint256 B = veHemi.getLockedBalance(v1).end;
        assertEq(B, veHemi.getLockedBalance(v2).end, "E: not the same bucket");
        uint256 keeperEnd = veHemi.getLockedBalance(keeper).end;
        _buildGrid(B);
        vm.warp(B);
        (uint256[] memory t0, uint256[] memory l0, uint256[] memory f0) = _snap("E PRE ");
        _record(t0, l0, f0);
        vm.prank(bob);
        veHemi.withdraw(v1);
        _snap("E POST");
        _assertImmutable("E POST");
        vm.warp(B + 2 * SIX_DAYS);
        veHemi.checkpoint();
        _snap("E LATE");
        _assertImmutable("E LATE");
        vm.prank(charlie);
        veHemi.withdraw(v2);
        _snap("E LAST");
        _assertImmutable("E LAST");
        _assertAfterBoundary("E LAST", B, keeperEnd);
        vm.warp(B + 40 * SIX_DAYS);
        veHemi.checkpoint();
        _assertImmutable("E FAR ");
        assertEq(_assertAfterBoundary("E FAR ", B, keeperEnd), 6,
            "NON-VACUOUS: not every sample instant after the boundary was checked");
    }
}

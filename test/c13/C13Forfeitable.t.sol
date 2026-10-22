// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice A flat FORFEITABLE position in the subcurves. Auto-relock is
///         invisible to the subcurves: while the global weight is the flat
///         level `slope * (R - SIX_DAYS/2)`, the position's subcurve
///         contribution stays a plain decay to `transferableAfter`,
///         `slope * (ta - now)`, exactly the manual twin's. Both subcurves
///         retire it at `ta`.
contract C13Forfeitable is LockedCurveTestBase {
    function _mkForfeitable(uint256 amt, uint256 dur) internal returns (uint256 id) {
        vm.prank(alice);
        id = veHemi.createLockFor(amt, dur, alice, false, true);
    }

    function _slope(uint256 amt) internal pure returns (uint256) {
        return amt / MAX_TIME;
    }

    /// @dev The V-MEAN flat level of `id`, from the closed form: R is the whole
    ///      buckets from grid(now) to the lock end.
    function _flatLevel(uint256 id, uint256 amt) internal view returns (uint256) {
        uint256 gridNow = (block.timestamp / SIX_DAYS) * SIX_DAYS;
        uint256 r = ((uint256(veHemi.getLockedBalance(id).end) - gridNow) / SIX_DAYS) * SIX_DAYS;
        return _slope(amt) * (r - SIX_DAYS / 2);
    }

    /// @dev At enable, at six phases of the bucket (both edges and both sides
    ///      of the midpoint): both subcurves carry
    ///      `slope * (ta - now)` and the global weight is the V-MEAN level, so
    ///      `subcurve - total == slope * (SIX_DAYS/2 - now mod SIX_DAYS)`
    ///      (`ta` is the grid-aligned lock end).
    function test_F1_flatForfeitableIsInBothSubcurves() public {
        uint256 amt = 100 ether;
        uint256 id = _mkForfeitable(amt, 2 * 365 days);
        runSeedingFlow();
        uint256 ta = veHemi.transferableAfter(id);
        assertEq(ta, veHemi.getLockedBalance(id).end, "precondition: forfeitable ta == end");
        assertEq(ta % SIX_DAYS, 0, "precondition: grid-aligned end");

        uint256 grid0 = (block.timestamp / SIX_DAYS) * SIX_DAYS + SIX_DAYS;
        uint256[6] memory phases =
            [uint256(0), 1, SIX_DAYS / 2 - 1, SIX_DAYS / 2, SIX_DAYS / 2 + 1, SIX_DAYS - 1];
        for (uint256 k; k < phases.length; ++k) {
            uint256 snap = vm.snapshotState();
            vm.warp(grid0 + phases[k]);
            vm.prank(alice);
            veHemi.enableAutoRelock(id);

            uint256 sub = _slope(amt) * (ta - block.timestamp);
            uint256 total = veHemi.totalVeHemiSupply();
            assertEq(veHemi.balanceOfNFT(id), _flatLevel(id, amt), "flat level is not V-MEAN");
            assertEq(total, veHemi.balanceOfNFT(id), "total != the only position");
            assertEq(veHemi.nonTransferableTotalVeHemiSupply(), sub, "locked subcurve != slope * (ta - now)");
            assertEq(veHemi.forfeitableTotalVeHemiSupply(), sub, "forfeitable subcurve != slope * (ta - now)");
            assertEq(
                int256(sub) - int256(total),
                int256(_slope(amt) * (SIX_DAYS / 2)) - int256(_slope(amt) * (block.timestamp % SIX_DAYS)),
                "subcurve - total != slope * (S/2 - now mod S)"
            );
            vm.revertToState(snap);
        }
    }

    /// @dev ...and across a long catch-up walk the global weight stays flat
    ///      while both subcurves keep decaying to `ta`.
    function test_F2_flatForfeitableSurvivesWalk() public {
        uint256 amt = 100 ether;
        uint256 id = _mkForfeitable(amt, 2 * 365 days);
        runSeedingFlow();
        uint256 ta = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 w0 = veHemi.balanceOfNFT(id);

        for (uint256 k = 1; k <= 20; ++k) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();
            uint256 sub = _slope(amt) * (ta - block.timestamp);
            assertEq(veHemi.balanceOfNFT(id), w0, "droop");
            assertEq(veHemi.totalVeHemiSupply(), w0, "global droop");
            assertEq(veHemi.nonTransferableTotalVeHemiSupply(), sub, "locked subcurve != slope * (ta - now)");
            assertEq(veHemi.forfeitableTotalVeHemiSupply(), sub, "forfeitable subcurve != slope * (ta - now)");
        }
    }

    /// @dev The forfeitable subcurve must retire the flat term at
    ///      `transferableAfter`, exactly like the locked one. A flat position
    ///      whose `transferableAfter` has passed is neither non-transferable
    ///      nor forfeitable any more.
    function test_F3_flatForfeitableRetiresAtTransferableAfter() public {
        uint256 id = _mkForfeitable(100 ether, 2 * 365 days);
        runSeedingFlow();
        uint256 ta = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        vm.warp(ta + 1);
        veHemi.checkpoint();
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve did not retire");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve did not retire");
    }

    /// @dev MIXED POPULATION. One forfeitable + one merely non-transferable,
    ///      both flat. Each position contributes `slope * (ta - now)` to the
    ///      subcurves it belongs to, and the forfeitable sum is ONLY the
    ///      forfeitable position's.
    function test_F4_mixedPopulation() public {
        uint256 f = _mkForfeitable(100 ether, 2 * 365 days);
        vm.prank(bob);
        uint256 nf = veHemi.createLockFor(300 ether, 3 * 365 days, bob, false, false);
        runSeedingFlow();
        vm.prank(alice);
        veHemi.enableAutoRelock(f);
        vm.prank(bob);
        veHemi.enableAutoRelock(nf);

        uint256 subF = _slope(100 ether) * (veHemi.transferableAfter(f) - block.timestamp);
        uint256 subNf = _slope(300 ether) * (veHemi.transferableAfter(nf) - block.timestamp);
        uint256 wf = veHemi.balanceOfNFT(f);
        uint256 wnf = veHemi.balanceOfNFT(nf);
        assertEq(wf, _flatLevel(f, 100 ether), "forfeitable flat level");
        assertEq(wnf, _flatLevel(nf, 300 ether), "non-forfeitable flat level");
        assertEq(veHemi.totalVeHemiSupply(), wf + wnf, "total != both flat levels");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), subF, "forfeitable != the forfeitable position");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), subF + subNf, "nonTransferable != both");

        // Per bucket, both subcurves decay while the flat weights stay put.
        for (uint256 k = 1; k <= 10; ++k) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();
            subF = _slope(100 ether) * (veHemi.transferableAfter(f) - block.timestamp);
            subNf = _slope(300 ether) * (veHemi.transferableAfter(nf) - block.timestamp);
            assertEq(veHemi.totalVeHemiSupply(), wf + wnf, "global droop");
            assertEq(veHemi.forfeitableTotalVeHemiSupply(), subF, "forfeitable drift");
            assertEq(veHemi.nonTransferableTotalVeHemiSupply(), subF + subNf, "nonTransferable drift");
        }
    }

    /// @dev CONTROL: the same population WITHOUT auto-relock.
    function test_F5_control_noAutoRelock() public {
        uint256 f = _mkForfeitable(100 ether, 2 * 365 days);
        vm.prank(bob);
        uint256 nf = veHemi.createLockFor(300 ether, 3 * 365 days, bob, false, false);
        runSeedingFlow();
        uint256 wf = veHemi.balanceOfNFT(f);
        uint256 wnf = veHemi.balanceOfNFT(nf);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), wf, "CONTROL forfeitable");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), wf + wnf, "CONTROL nonTransferable");
    }
}

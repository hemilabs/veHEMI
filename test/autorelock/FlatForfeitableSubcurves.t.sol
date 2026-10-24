// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice A flat FORFEITABLE position in the subcurves. Auto-relock is
///         invisible to the subcurves: while the global weight is the flat
///         level `slope * (R - SIX_DAYS/2)` (R = `autoRelockRemaining(id)`,
///         the frozen remaining term), the position's subcurve contribution
///         stays a plain decay to `transferableAfter`,
///         `slope * (transferableAfter - now)`, exactly the manual twin's.
///         Both subcurves retire it at `transferableAfter`.
contract FlatForfeitableSubcurvesTest is LockedCurveTestBase {
    function _mkForfeitable(uint256 amt, uint256 dur) internal returns (uint256 id) {
        vm.prank(alice);
        id = veHemi.createLockFor(amt, dur, alice, false, true);
    }

    function _slope(uint256 amt) internal pure returns (uint256) {
        return amt / MAX_TIME;
    }

    /// @dev The bucket-mean flat level of `id`, from the closed form: R is
    ///      the whole buckets from grid(now) to the lock end.
    function _flatLevel(uint256 id, uint256 amt) internal view returns (uint256) {
        uint256 gridNow = (block.timestamp / SIX_DAYS) * SIX_DAYS;
        uint256 r = ((uint256(veHemi.getLockedBalance(id).end) - gridNow) / SIX_DAYS) * SIX_DAYS;
        return _slope(amt) * (r - SIX_DAYS / 2);
    }

    /// @dev At enable, at six phases of the bucket (both edges and both sides
    ///      of the midpoint): both subcurves carry
    ///      `slope * (transferableAfter - now)` and the global weight is the
    ///      bucket-mean level, so
    ///      `subcurve - total == slope * (SIX_DAYS/2 - now mod SIX_DAYS)`
    ///      (`transferableAfter` is the grid-aligned lock end).
    function test_flatForfeitableIsInBothSubcurves() public {
        uint256 amt = 100 ether;
        uint256 id = _mkForfeitable(amt, 2 * 365 days);
        runSeedingFlow();
        uint256 transferableAfter = veHemi.transferableAfter(id);
        assertEq(transferableAfter, veHemi.getLockedBalance(id).end, "premise: forfeitable transferableAfter == end");
        assertEq(transferableAfter % SIX_DAYS, 0, "premise: grid-aligned end");

        uint256 nextGridBoundary = (block.timestamp / SIX_DAYS) * SIX_DAYS + SIX_DAYS;
        uint256[6] memory phases =
            [uint256(0), 1, SIX_DAYS / 2 - 1, SIX_DAYS / 2, SIX_DAYS / 2 + 1, SIX_DAYS - 1];
        for (uint256 k; k < phases.length; ++k) {
            uint256 snap = vm.snapshotState();
            vm.warp(nextGridBoundary + phases[k]);
            vm.prank(alice);
            veHemi.enableAutoRelock(id);

            uint256 subcurveWeight = _slope(amt) * (transferableAfter - block.timestamp);
            uint256 total = veHemi.totalVeHemiSupply();
            assertEq(veHemi.balanceOfNFT(id), _flatLevel(id, amt), "flat level is not the bucket mean");
            assertEq(total, veHemi.balanceOfNFT(id), "total != the only position");
            assertEq(
                veHemi.nonTransferableTotalVeHemiSupply(),
                subcurveWeight,
                "locked subcurve != slope * (transferableAfter - now)"
            );
            assertEq(
                veHemi.forfeitableTotalVeHemiSupply(),
                subcurveWeight,
                "forfeitable subcurve != slope * (transferableAfter - now)"
            );
            assertEq(
                int256(subcurveWeight) - int256(total),
                int256(_slope(amt) * (SIX_DAYS / 2)) - int256(_slope(amt) * (block.timestamp % SIX_DAYS)),
                "subcurve - total != slope * (SIX_DAYS/2 - now mod SIX_DAYS)"
            );
            vm.revertToState(snap);
        }
    }

    /// @dev ...and across a long catch-up walk the global weight stays flat
    ///      while both subcurves keep decaying to `transferableAfter`.
    function test_flatForfeitableSurvivesWalk() public {
        uint256 amt = 100 ether;
        uint256 id = _mkForfeitable(amt, 2 * 365 days);
        runSeedingFlow();
        uint256 transferableAfter = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 flatWeight = veHemi.balanceOfNFT(id);

        for (uint256 k = 1; k <= 20; ++k) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();
            uint256 subcurveWeight = _slope(amt) * (transferableAfter - block.timestamp);
            assertEq(veHemi.balanceOfNFT(id), flatWeight, "droop");
            assertEq(veHemi.totalVeHemiSupply(), flatWeight, "global droop");
            assertEq(
                veHemi.nonTransferableTotalVeHemiSupply(),
                subcurveWeight,
                "locked subcurve != slope * (transferableAfter - now)"
            );
            assertEq(
                veHemi.forfeitableTotalVeHemiSupply(),
                subcurveWeight,
                "forfeitable subcurve != slope * (transferableAfter - now)"
            );
        }
    }

    /// @dev The forfeitable subcurve must retire the flat term at
    ///      `transferableAfter`, exactly like the locked one. A flat position
    ///      whose `transferableAfter` has passed is neither non-transferable
    ///      nor forfeitable any more.
    function test_flatForfeitableRetiresAtTransferableAfter() public {
        uint256 id = _mkForfeitable(100 ether, 2 * 365 days);
        runSeedingFlow();
        uint256 transferableAfter = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        vm.warp(transferableAfter + 1);
        veHemi.checkpoint();
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve did not retire");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve did not retire");
    }

    /// @dev MIXED POPULATION. One forfeitable + one merely non-transferable,
    ///      both flat. Each position contributes
    ///      `slope * (transferableAfter - now)` to the subcurves it belongs to,
    ///      and the forfeitable sum is ONLY the forfeitable position's.
    function test_mixedFlatPopulation_eachSubcurveCarriesOnlyItsMembers() public {
        uint256 forfeitableId = _mkForfeitable(100 ether, 2 * 365 days);
        vm.prank(bob);
        uint256 nonForfeitableId = veHemi.createLockFor(300 ether, 3 * 365 days, bob, false, false);
        runSeedingFlow();
        vm.prank(alice);
        veHemi.enableAutoRelock(forfeitableId);
        vm.prank(bob);
        veHemi.enableAutoRelock(nonForfeitableId);

        uint256 forfeitableSubcurveShare =
            _slope(100 ether) * (veHemi.transferableAfter(forfeitableId) - block.timestamp);
        uint256 nonForfeitableSubcurveShare =
            _slope(300 ether) * (veHemi.transferableAfter(nonForfeitableId) - block.timestamp);
        uint256 forfeitableWeight = veHemi.balanceOfNFT(forfeitableId);
        uint256 nonForfeitableWeight = veHemi.balanceOfNFT(nonForfeitableId);
        assertEq(forfeitableWeight, _flatLevel(forfeitableId, 100 ether), "forfeitable flat level");
        assertEq(nonForfeitableWeight, _flatLevel(nonForfeitableId, 300 ether), "non-forfeitable flat level");
        assertEq(veHemi.totalVeHemiSupply(), forfeitableWeight + nonForfeitableWeight, "total != both flat levels");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableSubcurveShare, "forfeitable != the forfeitable position");
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            forfeitableSubcurveShare + nonForfeitableSubcurveShare,
            "nonTransferable != both"
        );

        // Per bucket, both subcurves decay while the flat weights stay put.
        for (uint256 k = 1; k <= 10; ++k) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();
            forfeitableSubcurveShare = _slope(100 ether) * (veHemi.transferableAfter(forfeitableId) - block.timestamp);
            nonForfeitableSubcurveShare =
                _slope(300 ether) * (veHemi.transferableAfter(nonForfeitableId) - block.timestamp);
            assertEq(veHemi.totalVeHemiSupply(), forfeitableWeight + nonForfeitableWeight, "global droop");
            assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableSubcurveShare, "forfeitable drift");
            assertEq(
                veHemi.nonTransferableTotalVeHemiSupply(),
                forfeitableSubcurveShare + nonForfeitableSubcurveShare,
                "nonTransferable drift"
            );
        }
    }

    /// @dev CONTROL: the same population WITHOUT auto-relock.
    function test_control_noAutoRelock() public {
        uint256 forfeitableId = _mkForfeitable(100 ether, 2 * 365 days);
        vm.prank(bob);
        uint256 nonForfeitableId = veHemi.createLockFor(300 ether, 3 * 365 days, bob, false, false);
        runSeedingFlow();
        uint256 forfeitableWeight = veHemi.balanceOfNFT(forfeitableId);
        uint256 nonForfeitableWeight = veHemi.balanceOfNFT(nonForfeitableId);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableWeight, "CONTROL forfeitable");
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(), forfeitableWeight + nonForfeitableWeight, "CONTROL nonTransferable"
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import "../LockedCurveTestBase.sol";

/// @notice A flat (auto-relocking) position must leave both subcurves at its
///         `transferableAfter`, on the write path and on the read path, and a flat
///         position is never withdrawable until it is disabled and the restored
///         term has been served.
contract C10Blocker is LockedCurveTestBase {
    function test_BLOCKER_subcurveFixedBiasNeverRetiresAtTransferableAfter() public {
        vm.prank(alice);
        uint256 id = veHemi.createLockFor(100 ether, 2 * 365 days, alice, false, false);
        runSeedingFlow();
        uint256 ta = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 w = veHemi.balanceOfNFT(id);
        emit log_named_uint("weight", w);
        emit log_named_uint("transferableAfter", ta);

        // Walk PAST transferableAfter while still flat. The position becomes
        // TRANSFERABLE (isTransferable == true) and must therefore leave the
        // locked subcurve -- for a decaying position lockedSlopeChanges[ta]
        // does that automatically.
        vm.warp(ta + 1);
        veHemi.checkpoint();

        emit log_named_uint("isTransferable", veHemi.isTransferable(id) ? 1 : 0);
        emit log_named_uint("total", veHemi.totalVeHemiSupply());
        emit log_named_uint("nonTransferable", veHemi.nonTransferableTotalVeHemiSupply());

        assertTrue(veHemi.isTransferable(id), "precondition: position is now transferable");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0,
            "P8 HOLE: a transferable flat position is still counted in the non-transferable subcurve");
    }

    /// @dev Flat past `transferableAfter`, then disabled and served out: the
    ///      non-transferable subcurve must not exceed the total
    ///      (invariant_subcurveOrdering). A flat term stranded in the subcurve
    ///      would be "equal to total" at first, which that invariant tolerates,
    ///      and would EXCEED total once the global curve decays it out.
    function test_BLOCKER_strandedFixedBiasEventuallyExceedsTotal() public {
        vm.prank(alice);
        uint256 id = veHemi.createLockFor(100 ether, 2 * 365 days, alice, false, false);
        runSeedingFlow();
        uint256 ta = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        vm.warp(ta + 1);
        veHemi.checkpoint();
        // Owner disables; the position now decays out normally in the GLOBAL
        // curve. It must already have left the subcurves at transferableAfter.
        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        uint256 end = veHemi.getLockedBalance(id).end;
        vm.warp(end + 1);
        veHemi.checkpoint();

        uint256 total = veHemi.totalVeHemiSupply();
        uint256 nt = veHemi.nonTransferableTotalVeHemiSupply();
        emit log_named_uint("total", total);
        emit log_named_uint("nonTransferable", nt);
        assertLe(nt, total, "invariant_subcurveOrdering VIOLATED: nonTransferable > total");
    }

    /// @dev The READ path must retire the flat position too, when the LAST
    ///      written checkpoint predates `transferableAfter`. The subcurves carry
    ///      a flat member's real slope and decaying bias, so the view's
    ///      slope-change walk alone must bring both subcurves and
    ///      `supplyBreakdown().locked` to 0 there.
    function test_BLOCKER_readPathRetiresFlatWithoutACheckpoint() public {
        vm.prank(alice);
        uint256 id = veHemi.createLockFor(100 ether, 2 * 365 days, alice, false, false);
        runSeedingFlow();
        uint256 ta = veHemi.transferableAfter(id);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        // NO checkpoint after this point -- pure view-path query.
        vm.warp(ta + 1);
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0,
            "READ PATH: stale fixedBias reported for a now-transferable flat position");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable read path");
        (, uint256 locked_, , ) = veHemi.supplyBreakdown();
        assertEq(locked_, 0, "supplyBreakdown read path");
    }

    /// @dev A FLAT position's stored `end` is frozen and falls into the past
    ///      while it keeps its full, non-decaying weight. `VeHemi::withdraw`
    ///      must therefore refuse a flat position (`LockNotExpired`) even after
    ///      that stale end: otherwise it would carry its full flat voting power
    ///      with zero remaining lock-up.
    function test_BLOCKER_flatPositionIsFullyLiquidAtMaxWeight() public {
        // `enableAutoRelock` refuses a still-non-transferable position until
        // `lockedSeedingFinalized`; finalize seeding first.
        runSeedingFlow();
        (uint256 id, , uint256 end) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 maxWeight = veHemi.balanceOfNFT(id);

        // One second after the ORIGINAL unlock time. Weight is untouched...
        vm.warp(end + 1);
        assertEq(veHemi.balanceOfNFT(id), maxWeight, "weight decayed");

        // ...so the position must NOT be withdrawable. The property: a
        // position carrying non-zero veHEMI weight is never liquid.
        vm.prank(alice);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);

        // It becomes withdrawable only after the owner disables and the
        // restored duration is actually served out.
        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        uint256 balBefore = hemi.balanceOf(alice);
        vm.prank(alice);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(alice) - balBefore, 100 ether, "principal not returned");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice The disable floor-snap, priced exactly. `lock.end` is always on the
///         SIX_DAYS grid and R is whole buckets from `grid(now)`, so a disable
///         restores the end `grid(now) + R`: a position that is enabled and
///         disabled on the grid gets exactly R back (and steps UP from the
///         V-MEAN flat level by `slope * S/2`), while a disable one second short
///         of a bucket loses the most, `slope * (S/2 - 1)` against the flat level.
contract C13O1Conflict is LockedCurveTestBase {
    uint256 constant AMT = 1_000 ether;

    function _mk(uint256 nBuckets) internal returns (uint256 id) {
        vm.prank(alice);
        id = veHemi.createLockFor(AMT, (nBuckets + 1) * SIX_DAYS, alice, false, false);
        runSeedingFlow();
        // Land on a grid boundary so R is exactly `nBuckets` buckets.
        vm.warp((block.timestamp / SIX_DAYS) * SIX_DAYS + SIX_DAYS);
        veHemi.checkpoint();
    }

    /// @dev Enable on the grid, disable on the grid three buckets later: the
    ///      restored term is exactly R = 6 buckets, so the decaying weight is
    ///      `slope * 6S`, a rise of exactly `slope * S/2` over the flat level.
    function test_O1_alignedDisableIsExact() public {
        uint256 slope = AMT / MAX_TIME;
        uint256 a = _mk(6);
        vm.prank(alice);
        veHemi.enableAutoRelock(a);
        assertEq(uint256(veHemi.autoRelockRemaining(a)), 6 * SIX_DAYS, "precondition: R == 6 buckets");
        uint256 wFlat = veHemi.balanceOfNFT(a);
        assertEq(wFlat, slope * (6 * SIX_DAYS - SIX_DAYS / 2), "flat level is not V-MEAN");

        vm.warp(block.timestamp + 3 * SIX_DAYS);
        vm.prank(alice);
        veHemi.disableAutoRelock(a);
        assertEq(veHemi.getLockedBalance(a).end, block.timestamp + 6 * SIX_DAYS, "restored end != now + R");
        assertEq(veHemi.balanceOfNFT(a), slope * 6 * SIX_DAYS, "grid-aligned disable must restore exactly R");
        assertEq(veHemi.balanceOfNFT(a) - wFlat, slope * (SIX_DAYS / 2), "rise != slope * S/2");
    }

    /// @dev R = 2 buckets (the minimum), enabled on the grid, disabled one
    ///      second short of the next bucket: the restored end is still
    ///      `grid(enable) + 2S`, so the decaying weight is `slope * (S + 1)` and
    ///      the step-down from the flat level is exactly `slope * (S/2 - 1)`.
    function test_O1_worstCaseIsOneSecondShortOfABucket() public {
        uint256 slope = AMT / MAX_TIME;
        uint256 id = _mk(2);
        uint256 g = block.timestamp;
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        assertEq(uint256(veHemi.autoRelockRemaining(id)), 2 * SIX_DAYS, "precondition: R == 2 buckets");
        uint256 w0 = veHemi.balanceOfNFT(id);
        assertEq(w0, slope * (3 * SIX_DAYS / 2), "flat level is not V-MEAN");

        vm.warp(block.timestamp + SIX_DAYS - 1);
        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        uint256 w1 = veHemi.balanceOfNFT(id);
        assertEq(veHemi.getLockedBalance(id).end, g + 2 * SIX_DAYS, "restored end != grid(now) + R");
        assertEq(w1, slope * (SIX_DAYS + 1), "decaying weight after disable");
        assertEq(w0 - w1, slope * (SIX_DAYS / 2 - 1), "step-down != slope * (S/2 - 1)");
    }
}

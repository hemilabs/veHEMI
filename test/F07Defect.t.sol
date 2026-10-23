// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// AN ABANDONED ARMED POSITION STAYS FLAT
// ----------------------------------------------------------------------------
// A manual twin whose owner walks away decays to zero N buckets after its last
// extension. An armed (flat) position whose owner walks away keeps its
// bucket-mean level for ever: nothing in the curve retires it. This is why the
// permissionless `retireStaleAutoRelock` exists (covered in F07Retire.t.sol).
// ============================================================================

import "./TwinOracle.sol";

contract F07DefectTest is TwinOracle {
    address internal constant ALICE = address(0xA11CE); // manual twin, abandoned
    address internal constant BOB   = address(0xB0B);   // flat, abandoned

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;

    uint256 internal mi; // manual twin  (universe M)
    uint256 internal xi; // flat         (universe X)

    function setUp() public {
        setUpTwinOracle();
        mi = spawn(false, ALICE, AMT, N, Cadence.MANUAL, false, false);
        xi = spawn(true,  BOB,   AMT, N, Cadence.NEVER,  false, false);
        vm.prank(BOB);
        // R is derived from the lock end, which spawn() put exactly N buckets out.
        X.ve.enableAutoRelock(positions[xi].tokenId);
    }

    function _driveCandidate(uint256) internal override {}

    // ===================================================================
    /// @notice Both owners vanish at bucket 3. The twin is dead at bucket 9
    ///         (3 + N). The flat position still holds its bucket-mean level
    ///         at bucket 400, and it is the whole supply of its universe.
    function test_G1_abandonment_gap() public {
        // 3 buckets of normal life, both extending / flat.
        for (uint256 k = 1; k <= 3; ++k) step(t0 + k * SIX_DAYS);
        // BOTH owners now lose their keys.
        stopExtending(mi);

        uint256 twinDeadAt = M.ve.getLockedBalance(positions[mi].tokenId).end;
        assertEq(twinDeadAt, (t0 + 3 * SIX_DAYS) + N * SIX_DAYS, "twin end");

        uint256 W = meanLevelOf(AMT, N);
        uint256 firstTwinZero;
        uint256 firstFlatZero;
        for (uint256 k = 4; k <= 400; ++k) {
            vm.warp(t0 + k * SIX_DAYS);
            vm.roll(block.number + 43830);
            uint256 wm = M.ve.balanceOfNFT(positions[mi].tokenId);
            uint256 wx = X.ve.balanceOfNFT(positions[xi].tokenId);
            if (wm == 0 && firstTwinZero == 0) firstTwinZero = k;
            if (wx == 0 && firstFlatZero == 0) firstFlatZero = k;
        }
        assertEq(firstTwinZero, 9, "twin must die at 3+N");
        assertEq(firstFlatZero, 0, "abandoned flat position decayed to zero");
        assertEq(X.ve.balanceOfNFT(positions[xi].tokenId), W, "flat not at the bucket-mean level at +400");
        assertEq(X.ve.totalVeHemiSupply(), W, "supply != the one flat position");
        assertEq(M.ve.totalVeHemiSupply(), 0, "twin universe supply must be 0");
    }
}

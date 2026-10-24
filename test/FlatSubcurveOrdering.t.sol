// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// The subcurve-ordering law for a flat (armed) non-transferable position.
// ----------------------------------------------------------------------------
//   S    = SIX_DAYS = 525,960     H = S/2 = 262,980 (exact; S is even)
//   g    = grid(now),  off = now - g in [0, S)
//   slope= amount / MAX_TIME  (int128 truncation)
//   R    = lock.end - g, in WHOLE BUCKETS
//   ta   = transferableAfter[id], set once at mint to the rounded unlockTime.
//          For a position minted non-transferable, ta == lock.end at mint.
//
//   GLOBAL book of a flat position (bucket mean):  V   = slope * (R - H)
//   SUBCURVE book of the SAME position:            sub = slope * (ta - now)
//   (auto-relock is invisible to the subcurves: they keep the manual ramp).
//
//   With ta == g + R:   sub - V = slope * (H - off),  > 0 FOR off < H.
//
// So `nonTransferableTotalVeHemiSupply() > totalVeHemiSupply()` by EXACTLY
// `slope * (H - off)` when off < H and by zero when off >= H: the excess is
// bounded by `slope * H` and lives only in the first half-bucket after the flat
// position's last checkpoint. S1, S2 and S4 pin that closed form to the wei;
// S5 and S7 check its bound.
// ============================================================================

import "./TwinOracle.sol";

contract FlatSubcurveOrderingTest is TwinOracle {
    address internal constant NONTRANSFERABLE_HOLDER = address(0x17A1);
    address internal constant FORFEITABLE_HOLDER     = address(0x50FF);
    address internal constant PLAIN_HOLDER           = address(0x9141);  // an ordinary transferable lock

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;

    function setUp() public { setUpTwinOracle(); }
    function _driveCandidate(uint256) internal override {}
    function _id(uint256 i) internal view returns (uint256) { return positions[i].tokenId; }

    function _grid(uint256 t) internal pure returns (uint256) { return (t / SIX_DAYS) * SIX_DAYS; }
    function _off() internal view returns (uint256) { return block.timestamp - _grid(block.timestamp); }

    /// @dev The flat level right after an enable at a bucket-aligned lock end
    ///      must be the bucket-mean flat level, `slope * (R - SIX_DAYS/2)`.
    function _assertMean(uint256 id, uint256 amount, uint256 n) internal view {
        assertEq(X.ve.balanceOfNFT(id), meanLevelOf(amount, n), "flat level is not the bucket-mean level");
    }

    /// @dev The excess the design predicts, from the test's own clock and the
    ///      position's own slope: slope * (SIX_DAYS/2 - off)^+.
    function _predictedExcess(uint256 amount, uint256 off) internal pure returns (uint256) {
        uint256 H = SIX_DAYS / 2;
        return off >= H ? 0 : slopeOf(amount) * (H - off);
    }

    // ==================================================================== S1
    /// @notice THE MINIMAL CASE. One non-transferable position, flat, enabled
    ///         on a bucket boundary: `locked > total` by EXACTLY
    ///         `slope * SIX_DAYS/2`.
    function test_S1_minimal_subcurve_ordering_break() public {
        uint256 i = spawn(true, NONTRANSFERABLE_HOLDER, AMT, N, Cadence.NEVER, true, false);
        vm.prank(NONTRANSFERABLE_HOLDER);
        X.ve.enableAutoRelock(_id(i));
        _assertMean(_id(i), AMT, N);

        uint256 total  = X.ve.totalVeHemiSupply();
        uint256 locked = X.ve.nonTransferableTotalVeHemiSupply();

        // the subcurve is the manual twin's ramp (ta == lock.end at mint)
        assertEq(locked, peakOf(AMT, N), "S1 subcurve != the twin ramp");
        assertEq(total, meanLevelOf(AMT, N), "S1 total != mean level");
        assertEq(locked - total, slopeOf(AMT) * (SIX_DAYS / 2), "S1 excess != slope * SIX_DAYS/2");
        assertEq(locked - total, _predictedExcess(AMT, _off()), "S1 excess != the closed form");
    }

    // ==================================================================== S2
    /// @notice THE TWELVE-PHASE SWEEP. The excess is the closed form at every
    ///         phase, to the wei -- and zero from the half-bucket onward.
    function test_S2_twelve_phases_excess_is_the_closed_form() public {
        uint256 worst;
        uint256 excessPhases;
        for (uint256 p; p < 12; ++p) {
            uint256 snap = vm.snapshotState();
            uint256 off = (p * SIX_DAYS) / 12;
            vm.warp(t0 + off);
            vm.roll(block.number + 1 + p);
            uint256 i = spawn(true, NONTRANSFERABLE_HOLDER, AMT, N, Cadence.NEVER, true, false);
            vm.prank(NONTRANSFERABLE_HOLDER);
            X.ve.enableAutoRelock(_id(i));
            _assertMean(_id(i), AMT, N);

            uint256 total  = X.ve.totalVeHemiSupply();
            uint256 locked = X.ve.nonTransferableTotalVeHemiSupply();
            uint256 excess = locked > total ? locked - total : 0;
            assertEq(excess, _predictedExcess(AMT, off), "S2 excess != the closed form");
            if (excess > 0) { excessPhases += 1; if (excess > worst) worst = excess; }
            vm.revertToState(snap);
        }
        assertEq(excessPhases, 6, "S2 excess outside the first half-bucket");
        assertLe(worst, slopeOf(AMT) * (SIX_DAYS / 2), "S2 excess exceeded slope * SIX_DAYS/2");
    }

    // ==================================================================== S4
    /// @notice FORFEITABLE. The same law on the outer ordering; the INNER
    ///         ordering (forfeitable <= locked) is exact.
    function test_S4_forfeitable_flat_position_excess_is_the_closed_form() public {
        uint256 i = spawn(true, FORFEITABLE_HOLDER, AMT, N, Cadence.NEVER, true, true);
        vm.prank(FORFEITABLE_HOLDER);
        X.ve.enableAutoRelock(_id(i));
        _assertMean(_id(i), AMT, N);
        uint256 total       = X.ve.totalVeHemiSupply();
        uint256 locked      = X.ve.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable = X.ve.forfeitableTotalVeHemiSupply();
        assertEq(forfeitable, locked, "S4 a lone forfeitable position: forfeitable != locked");
        uint256 predictedExcess = _predictedExcess(AMT, _off());
        assertLe(locked, total + predictedExcess, "S4 locked > total + slack");
        assertEq(locked > total ? locked - total : 0, predictedExcess, "S4 forfeitable excess != the closed form");
    }

    // ==================================================================== S5
    /// @notice MIXED UNIVERSE. A transferable lock carries supply the flat
    ///         non-transferable one does not, so the law can only break by the
    ///         flat position's own half-bucket slack.
    function test_S5_mixed_universe_orders() public {
        spawn(true, PLAIN_HOLDER, AMT * 3, N + 4, Cadence.NEVER, false, false);
        uint256 i = spawn(true, NONTRANSFERABLE_HOLDER, AMT, N, Cadence.NEVER, true, false);
        vm.prank(NONTRANSFERABLE_HOLDER);
        X.ve.enableAutoRelock(_id(i));
        _assertMean(_id(i), AMT, N);
        assertLe(X.ve.nonTransferableTotalVeHemiSupply(),
            X.ve.totalVeHemiSupply() + _predictedExcess(AMT, _off()),
            "S5 locked > total + slack");
    }

    // ==================================================================== S7
    /// @notice THE EXCESS LASTS AT MOST HALF A BUCKET AND HEALS. Sample every
    ///         3 hours for two full buckets after the enable: the ordering is
    ///         violated only within SIX_DAYS/2 of the enable, by at most half a
    ///         bucket of the position's own slope.
    function test_S7_excess_lasts_at_most_half_a_bucket() public {
        uint256 i = spawn(true, NONTRANSFERABLE_HOLDER, AMT, N, Cadence.NEVER, true, false);
        vm.prank(NONTRANSFERABLE_HOLDER);
        X.ve.enableAutoRelock(_id(i));
        _assertMean(_id(i), AMT, N);
        uint256 enableAt = block.timestamp;
        uint256 lastExcessAt;
        bool sawExcess;
        uint256 worstWei;
        for (uint256 t = enableAt; t <= enableAt + 2 * SIX_DAYS; t += 10_800) {
            vm.warp(t);
            uint256 locked = X.ve.nonTransferableTotalVeHemiSupply();
            uint256 total = X.ve.totalVeHemiSupply();
            if (locked > total) {
                sawExcess = true;
                lastExcessAt = t;
                if (locked - total > worstWei) worstWei = locked - total;
            }
        }
        assertTrue(sawExcess, "S7 no excess observed: the sweep is blind");
        assertLe(lastExcessAt - enableAt, SIX_DAYS / 2, "S7 the excess outlived the first half-bucket");
        assertLe(worstWei, slopeOf(AMT) * (SIX_DAYS / 2), "S7 excess exceeded slope * SIX_DAYS/2");
    }
}

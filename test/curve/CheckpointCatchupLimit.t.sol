// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice Catch-up clamp. The checkpoint catch-up loop
///         (`VeHemiCurveLib::checkpoint`) walks at most CATCHUP_LIMIT = 300
///         SIX_DAYS buckets. Unclamped, a longer silent gap leaves the head Point
///         stamped in the past, and every later read re-decays a correct bias
///         across the phantom gap. The clamp stamps the head at `block.timestamp`.
///
///         Checked here for gaps below, at and above the limit: the head
///         timestamp, the global curve against the sum of `balanceOfNFT`, both
///         subcurves against an independent reconstruction, the
///         `forfeitable <= locked <= total` ordering, and historical
///         `totalVeHemiSupplyAt` inside the gap (the source of the VVD's
///         `getPastTotalSupply`, Aragon's quorum denominator).
contract CheckpointCatchupLimitTest is LockedCurveTestBase {
    uint256[] internal ids;

    function _sumBalances() internal view returns (uint256 s) {
        for (uint256 i; i < ids.length; ++i) s += veHemi.balanceOfNFT(ids[i]);
    }

    function _sumBalancesWhere(bool wantForfeitable) internal view returns (uint256 s) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 ta = veHemi.transferableAfter(id);
            if (ta == 0 || block.timestamp >= ta) continue; // outside the subcurve window
            if (wantForfeitable && !veHemi.forfeitable(id)) continue;
            // subcurve weight is bounded by min(lock.end, transferableAfter)
            IVeHemi.LockedBalance memory L = veHemi.getLockedBalance(id);
            uint256 eff = L.end < ta ? L.end : ta;
            if (eff <= block.timestamp) continue;
            s += uint256(uint128(L.amount / int128(int256(MAX_TIME)))) * (eff - block.timestamp);
        }
    }

    function _mkCohort() internal {
        runSeedingFlow();
        vm.startPrank(address(this));
        hemi.mint(address(this), 10_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        ids.push(veHemi.createLockFor(100 ether, 2 * 365 days, alice, true, false));
        ids.push(veHemi.createLockFor(150 ether, 3 * 365 days, bob, false, false));
        ids.push(veHemi.createLockFor(200 ether, 3 * 365 days, charlie, false, true));
        vm.stopPrank();
    }

    function _assertConsistentAtGap(uint256 buckets) internal {
        uint256 snap = vm.snapshotState();
        _mkCohort();
        // silence: no state-mutating call for `buckets` SIX_DAYS periods
        vm.warp(block.timestamp + buckets * SIX_DAYS);
        // the first lifecycle call after the silence performs the catch-up.
        // Mint into ALL THREE curves so the subcurve assertions below can bite:
        // the same catch-up loop advances the locked/forfeitable points, not
        // just the global one.
        hemi.mint(address(this), 10_000 ether);
        vm.startPrank(address(this));
        ids.push(veHemi.createLockFor(100 ether, 4 * 365 days - 1 days, alice, true, false));
        ids.push(veHemi.createLockFor(120 ether, 3 * 365 days, bob, false, false));
        ids.push(veHemi.createLockFor(140 ether, 3 * 365 days, charlie, false, true));
        vm.stopPrank();

        assertEq(
            veHemi.getGlobalPoint(veHemi.epoch()).timestamp,
            uint64(block.timestamp),
            string.concat("head timestamp stale at gap ", vm.toString(buckets))
        );
        assertEq(
            veHemi.totalVeHemiSupply(),
            _sumBalances(),
            string.concat("global supply != sum(balanceOfNFT) at gap ", vm.toString(buckets))
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            _sumBalancesWhere(false),
            string.concat("locked subcurve != reconstruction at gap ", vm.toString(buckets))
        );
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            _sumBalancesWhere(true),
            string.concat("forfeitable subcurve != reconstruction at gap ", vm.toString(buckets))
        );
        (uint256 tot, uint256 lk, uint256 fo, ) = veHemi.supplyBreakdown();
        assertLe(fo, lk, "ordering forfeitable <= locked");
        assertLe(lk, tot, "ordering locked <= total");

        delete ids;
        vm.revertToState(snap);
    }

    function test_gap_250_belowCap() public { _assertConsistentAtGap(250); }
    function test_gap_299() public { _assertConsistentAtGap(299); }
    function test_gap_300() public { _assertConsistentAtGap(300); }
    function test_gap_305() public { _assertConsistentAtGap(305); }
    function test_gap_400() public { _assertConsistentAtGap(400); }
    function test_gap_480() public { _assertConsistentAtGap(480); }
    function test_gap_700() public { _assertConsistentAtGap(700); }

    /// @notice Extreme gap — proves the single clamped jump does not overflow int128.
    function test_gap_30_000_000() public { _assertConsistentAtGap(30_000_000); }

    /// @notice A NON-TRANSFERABLE + FORFEITABLE cohort minted immediately after a
    ///         catch-up longer than the limit. Both subcurve heads are advanced by
    ///         the same loop, so an unclamped loop would leave them stale too.
    function test_subcurvesAfterTruncatingCatchup() public {
        _mkCohort();
        vm.warp(block.timestamp + 480 * SIX_DAYS);
        hemi.mint(address(this), 10_000 ether);
        vm.startPrank(address(this));
        ids.push(veHemi.createLockFor(200 ether, 3 * 365 days, bob, false, true));
        ids.push(veHemi.createLockFor(300 ether, 3 * 365 days, charlie, false, false));
        vm.stopPrank();

        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), _sumBalancesWhere(false), "locked subcurve");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), _sumBalancesWhere(true), "forfeitable subcurve");

        // and it stays exact as the curve decays forward
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 20 * SIX_DAYS);
            veHemi.checkpoint();
            assertEq(veHemi.totalVeHemiSupply(), _sumBalances(), "global drift after catch-up");
            assertEq(veHemi.nonTransferableTotalVeHemiSupply(), _sumBalancesWhere(false), "locked drift");
        }
    }

    /// @notice Ordering after three lifecycle calls in the same second following a
    ///         700-bucket gap: unclamped, the first two would truncate and leave
    ///         `locked > total`.
    function test_doubleTruncation_orderingHolds() public {
        _mkCohort();
        vm.warp(block.timestamp + 700 * SIX_DAYS);
        hemi.mint(address(this), 10_000 ether);
        for (uint256 i; i < 3; ++i) {
            ids.push(veHemi.createLockFor(100 ether, 2 * 365 days, alice, true, false));
        }
        (uint256 tot, uint256 lk, uint256 fo, ) = veHemi.supplyBreakdown();
        assertLe(fo, lk, "forfeitable <= locked");
        assertLe(lk, tot, "locked <= total");
        assertEq(veHemi.totalVeHemiSupply(), _sumBalances(), "supply != sum after double truncation");
    }

    /// @notice No historical over-report: `totalVeHemiSupplyAt(t)` for t inside
    ///         the gap. The VVD's `getPastTotalSupply` (Aragon's quorum
    ///         denominator, frozen into a proposal for its whole life) reads it.
    function test_historicalQueryInsideGap_isNotPhantom() public {
        _mkCohort();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 600 * SIX_DAYS);
        hemi.mint(address(this), 10_000 ether);
        veHemi.createLockFor(100 ether, 2 * 365 days, alice, true, false);

        // every original position expired long ago; true supply at these instants is 0
        for (uint256 b = 350; b <= 599; b += 50) {
            uint256 t = t0 + b * SIX_DAYS;
            assertEq(
                veHemi.totalVeHemiSupplyAt(t),
                0,
                string.concat("phantom supply reported at bucket ", vm.toString(b))
            );
        }
    }

    /// @notice Repeated checkpoints after a long gap stay exact and keep the head current.
    function test_repeatedCheckpointsStayExact() public {
        _mkCohort();
        vm.warp(block.timestamp + 480 * SIX_DAYS);
        veHemi.checkpoint();
        for (uint256 i; i < 4; ++i) {
            veHemi.checkpoint();
            assertEq(veHemi.totalVeHemiSupply(), _sumBalances(), "supply drifted");
            assertEq(veHemi.getGlobalPoint(veHemi.epoch()).timestamp, uint64(block.timestamp));
        }
    }

    /// @notice A 299-bucket catch-up (below the limit) leaves the head current. The
    ///         fingerprint of every global Point is logged for comparison only.
    function test_fingerprintBelowThreshold() public {
        _mkCohort();
        vm.warp(block.timestamp + 299 * SIX_DAYS);
        veHemi.checkpoint();
        uint256 e = veHemi.epoch();
        bytes32 fp;
        for (uint256 i; i <= e; ++i) {
            IVeHemi.Point memory p = veHemi.getGlobalPoint(i);
            fp = keccak256(abi.encodePacked(fp, p.bias, p.slope, p.timestamp, p.blockNumber));
        }
        emit log_named_uint("epochs", e);
        emit log_named_bytes32("fingerprint", fp);
        // the head must be current; the epoch count depends on CATCHUP_LIMIT and is logged only
        assertEq(veHemi.getGlobalPoint(e).timestamp, uint64(block.timestamp), "head not current");
    }

    /// @notice Randomised gaps and sub-bucket phases.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_anyGapAndPhase(uint16 gapRaw, uint32 phaseRaw) public {
        uint256 gap = 250 + (uint256(gapRaw) % 600);
        uint256 phase = uint256(phaseRaw) % SIX_DAYS;
        _mkCohort();
        vm.warp(block.timestamp + gap * SIX_DAYS + phase);
        hemi.mint(address(this), 10_000 ether);
        ids.push(veHemi.createLockFor(100 ether, 3 * 365 days, alice, true, false));

        assertEq(veHemi.getGlobalPoint(veHemi.epoch()).timestamp, uint64(block.timestamp), "stale head");
        assertEq(veHemi.totalVeHemiSupply(), _sumBalances(), "supply != sum");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), _sumBalancesWhere(false), "locked subcurve");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), _sumBalancesWhere(true), "forfeitable subcurve");
    }
}

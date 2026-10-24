// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// The heartbeat (`refreshAutoRelock`) and the permissionless stale
// retire (`retireStaleAutoRelock`), checked against a live manual twin and the
// closed-form bucket-mean level.
//
// Labels (one banner each below): R1 the heartbeat costs the curve nothing,
// R2 the stale-retire guard, R3 the retired position decays like a stopped
// twin, R4 the retire takes no principal, R5 a top-up does not postpone the
// retire, R10 a retired forfeitable non-transferable position closes out both
// subcurves, R7 a position that is not flat is refused. R6, R8 and R9 are not
// used.
//
// Notation: grid(t) = floor(t / SIX_DAYS) * SIX_DAYS, the start of t's six-day
// bucket.
// ============================================================================

import "./TwinOracle.sol";

contract HeartbeatAndStaleRetireTest is TwinOracle {
    address internal constant ALICE  = address(0xA11CE); // manual twin, never stops
    address internal constant BOB    = address(0xB0B);   // flat candidate
    address internal constant DAVE   = address(0xDA4E);  // manual twin, stops at retire
    address internal constant KEEPER = address(0xCAFE);  // a stranger

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;

    uint256 internal mi;
    uint256 internal xi;
    uint256 internal di;

    uint256 internal staleBuckets; // STALE_FLAT_BUCKETS

    function setUp() public {
        setUpTwinOracle();
        staleBuckets = X.ve.STALE_FLAT_BUCKETS();
        mi = spawn(false, ALICE, AMT, N, Cadence.MANUAL, false, false);
        xi = spawn(true,  BOB,   AMT, N, Cadence.NEVER,  false, false);
        vm.prank(BOB);
        // autoRelockRemaining is derived from the lock end, which spawn() put
        // exactly N buckets out.
        X.ve.enableAutoRelock(positions[xi].tokenId);
    }

    function _driveCandidate(uint256) internal override {}

    function _id(uint256 i) internal view returns (uint256) { return positions[i].tokenId; }

    // =================================================================== R1
    /// @notice THE HEARTBEAT COSTS THE CURVE NOTHING. A flat position refreshed
    ///         every 6 buckets sits at the closed-form bucket-mean level at
    ///         every sample (weight and supply), and its time-integral matches
    ///         the live manual twin's to within 1 bps.
    function test_R1_heartbeat_is_curve_invisible() public {
        assertEq(X.ve.autoRelockStaleAt(_id(xi)), t0 + staleBuckets * SIX_DAYS, "staleAt");
        // heartbeat every 6 buckets during the sweep
        for (uint256 b; b < 12; ++b) {
            uint256 base = t0 + b * SIX_DAYS;
            step(base);
            if (b % 6 == 0) {
                vm.prank(BOB);
                X.ve.refreshAutoRelock(_id(xi));
                assertEq(X.ve.autoRelockStaleAt(_id(xi)), base + staleBuckets * SIX_DAYS,
                    "autoRelockStaleAt after the heartbeat");
            }
            step(base + 3600);
            step(base + SIX_DAYS / 2);
            step(base + SIX_DAYS - 1);
        }
        uint256 flatLevel = meanLevelOf(AMT, N);
        Sample[] storage flatSamples = series[xi];
        for (uint256 k; k < flatSamples.length; ++k) {
            assertEq(flatSamples[k].weight, flatLevel, "not flat at the bucket-mean level");
            assertEq(flatSamples[k].totalSupply, flatLevel, "supply not flat at the bucket-mean level");
        }
        assertEq(_deviationBps(integral(xi, Field.WEIGHT), integral(mi, Field.WEIGHT)), int256(0), "integral != the twin's");
    }

    // =================================================================== R2
    /// @notice THE GUARD. Not stale -> anyone reverts. Stale -> anyone succeeds.
    function test_R2_guard_opens_exactly_at_staleAt() public {
        uint256 staleAt = X.ve.autoRelockStaleAt(_id(xi));
        vm.warp(staleAt - 1);
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
        X.ve.retireStaleAutoRelock(_id(xi));

        vm.warp(staleAt);
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(xi));
        assertEq(X.ve.autoRelockRemaining(_id(xi)), 0, "flag not cleared");
        assertEq(X.ve.autoRelockRefreshedAt(_id(xi)), 0, "refresh stamp not cleared");
        assertEq(
            X.ve.getLockedBalance(_id(xi)).end,
            ((staleAt / SIX_DAYS) + N) * SIX_DAYS,
            "restored end != grid(staleAt) + N buckets"
        );
        // a second retire is refused
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        X.ve.retireStaleAutoRelock(_id(xi));
    }

    // =================================================================== R3
    /// @notice THE REMEDY. After the retire the position decays out
    ///         bucket-for-bucket IDENTICALLY to a manual twin that stopped
    ///         extending in the same block, and reaches zero exactly N buckets
    ///         later, taking the delegated votes and the quorum denominator
    ///         with it.
    function test_R3_retired_position_decays_like_a_stopped_manual_twin() public {
        // a second manual twin in universe M, to be stopped at the retire instant
        di = spawn(false, DAVE, AMT, N, Cadence.MANUAL, false, false);
        for (uint256 k = 1; k <= staleBuckets; ++k) step(t0 + k * SIX_DAYS);

        uint256 staleAt = t0 + staleBuckets * SIX_DAYS;
        assertEq(block.timestamp, staleAt, "clock");
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(xi));
        stopExtending(di);
        assertEq(
            M.ve.getLockedBalance(_id(di)).end,
            X.ve.getLockedBalance(_id(xi)).end,
            "restored end != stopped twin end"
        );

        uint256 firstZero;
        for (uint256 k = 1; k <= N + 4; ++k) {
            step(staleAt + k * SIX_DAYS);
            uint256 retiredWeight = X.ve.balanceOfNFT(_id(xi));
            uint256 stoppedTwinWeight = M.ve.balanceOfNFT(_id(di));
            assertEq(retiredWeight, stoppedTwinWeight, "retired position's decay diverged from the stopped twin");
            assertEq(X.ve.totalVeHemiSupply(), retiredWeight, "global supply != the only position");
            if (retiredWeight == 0 && firstZero == 0) firstZero = k;
        }
        assertEq(firstZero, N, "did not reach zero at retire + N");
        // ... and the votes went with it.
        assertEq(X.del.getVotes(BOB), 0, "PHANTOM VOTES SURVIVED THE RETIRE");
        assertEq(X.del.getPastTotalSupply(block.timestamp - 1), 0, "quorum denominator not repaired");
    }

    // =================================================================== R4
    /// @notice IT TAKES NOTHING. Principal intact; the owner may withdraw at
    ///         the restored end; an owner who comes back BEFORE that end simply
    ///         re-enables and is flat again.
    function test_R4_retire_is_not_confiscation() public {
        uint256 staleAt = X.ve.autoRelockStaleAt(_id(xi));
        vm.warp(staleAt);
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(xi));
        assertEq(uint256(uint128(X.ve.getLockedBalance(_id(xi)).amount)), AMT, "principal moved");

        // the owner returns two buckets later and re-enables
        vm.warp(staleAt + 2 * SIX_DAYS);
        vm.roll(block.number + 1);
        vm.prank(BOB);
        // autoRelockRemaining is derived from the lock end the retire restored
        // (`grid(retire) + N*SIX_DAYS`), and the owner has used two of those
        // buckets by coming back late, so the re-enable flattens at N-2: the
        // level the REMAINING lock buys.
        X.ve.enableAutoRelock(_id(xi));
        assertEq(uint256(X.ve.autoRelockRemaining(_id(xi))), (N - 2) * SIX_DAYS,
            "autoRelockRemaining not the remaining lock");
        assertEq(X.ve.balanceOfNFT(_id(xi)), meanLevelOf(AMT, N - 2), "re-enable did not restore the bucket-mean level of the remaining lock");
        assertEq(X.ve.autoRelockStaleAt(_id(xi)), block.timestamp + staleBuckets * SIX_DAYS, "clock did not restart");

        // ... or, had they not, they withdraw at the restored end
        vm.prank(BOB);
        X.ve.disableAutoRelock(_id(xi));
        uint256 end = X.ve.getLockedBalance(_id(xi)).end;
        vm.warp(end - 1);
        vm.prank(BOB);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        X.ve.withdraw(_id(xi));
        vm.warp(end);
        uint256 bal = X.hemi.balanceOf(BOB);
        vm.prank(BOB);
        X.ve.withdraw(_id(xi));
        assertEq(X.hemi.balanceOf(BOB) - bal, AMT, "principal not returned in full");
        positions[xi].withdrawn = true;
    }

    // =================================================================== R5
    /// @notice A top-up does not postpone the retire. `increaseAmount`
    ///         re-materialises the stored end, but the abandonment clock is keyed
    ///         on the refresh stamp, which only `refreshAutoRelock` moves.
    function test_R5_dust_cannot_postpone_the_retire() public {
        uint256 staleAt = X.ve.autoRelockStaleAt(_id(xi));
        vm.warp(t0 + (staleBuckets - 1) * SIX_DAYS);
        vm.roll(block.number + 1);
        // `increaseAmount` is owner-only, so the top-up comes from the owner.
        address owner_ = X.ve.ownerOf(_id(xi));
        X.hemi.mint(owner_, 1 ether);
        vm.startPrank(owner_);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(_id(xi), 1); // 1 wei of dust
        vm.stopPrank();
        assertEq(X.ve.autoRelockStaleAt(_id(xi)), staleAt, "top-up moved the abandonment clock");
        // and the stored end DID move, which is exactly why the clock is not keyed on it
        assertEq(
            X.ve.getLockedBalance(_id(xi)).end,
            ((block.timestamp / SIX_DAYS) + N) * SIX_DAYS,
            "stored end not re-materialised"
        );
        vm.warp(staleAt);
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(xi)); // still opens on time
    }

    // =================================================================== R10
    /// @notice COMPOSITION. Retire a forfeitable non-transferable flat
    ///         position and check both subcurves close out with the global curve.
    function test_R10_retired_forfeitable_nontransferable_position_closes_out_both_subcurves() public {
        // > staleBuckets, so the subcurve is STILL ACTIVE at the retire instant
        uint256 forfeitableTermBuckets = 70;
        uint256 fi = spawn(true, DAVE, AMT, forfeitableTermBuckets, Cadence.NEVER, true, true);
        vm.prank(DAVE);
        X.ve.enableAutoRelock(_id(fi));
        uint256 staleAt = X.ve.autoRelockStaleAt(_id(fi));
        for (uint256 k = 1; k <= staleBuckets; ++k) { vm.warp(t0 + k * SIX_DAYS); vm.roll(block.number + 43830); }
        assertEq(block.timestamp, staleAt, "clock");
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(fi));
        assertGt(X.ve.nonTransferableTotalVeHemiSupply(), 0, "subcurve already empty - test is blind");
        assertGt(X.ve.forfeitableTotalVeHemiSupply(), 0, "subcurve already empty - test is blind");
        // BOB's flat position is still flat and still counted; only DAVE's retired.
        for (uint256 k = 1; k <= forfeitableTermBuckets + 2; ++k) {
            vm.warp(staleAt + k * SIX_DAYS);
            vm.roll(block.number + 43830);
            uint256 forfeitableWeight = X.ve.balanceOfNFT(_id(fi));
            uint256 bobWeight = X.ve.balanceOfNFT(_id(xi));
            assertEq(X.ve.totalVeHemiSupply(), forfeitableWeight + bobWeight, "global supply != sum of parts");
        }
        assertEq(X.ve.balanceOfNFT(_id(fi)), 0, "retired position not dead");
        assertEq(X.ve.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve leaked");
        assertEq(X.ve.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve leaked");
        positions[fi].withdrawn = true;
    }

    // =================================================================== R7
    /// @notice The view and the guard agree, and a non-flat position is refused.
    function test_R7_not_enabled_is_refused() public {
        uint256 pi = spawn(true, KEEPER, AMT, N, Cadence.NEVER, false, false);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        X.ve.autoRelockStaleAt(_id(pi));
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        X.ve.retireStaleAutoRelock(_id(pi));
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        X.ve.refreshAutoRelock(_id(pi));
        vm.prank(BOB);
        vm.expectRevert(VeHemi.NotOwner.selector);
        X.ve.refreshAutoRelock(_id(pi));
        positions[pi].withdrawn = true;
    }
}

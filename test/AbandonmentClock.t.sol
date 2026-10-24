// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// The abandonment clock of an armed position.
// ----------------------------------------------------------------------------
// `autoRelockRefreshedAt` is written only when a position is armed
// (`enableAutoRelock`, or `createLockWithAutoRelock` at mint) and by
// `refreshAutoRelock`. `increaseUnlockTime` on an armed position enlarges
// R (the frozen remaining term, `autoRelockRemaining`) but does NOT restart
// the clock, so an owner who only extends is still retired on time (L1); the
// heartbeat does restart it (L2).
// An armed non-self transfer disarms the position, so there is no refresh
// stamp for the buyer to inherit and nothing for a keeper to retire (L4).
// ============================================================================

import "./TwinOracle.sol";

contract AbandonmentClockTest is TwinOracle {
    address internal constant BOB    = address(0xB0B);
    address internal constant CAROL  = address(0xCA401);
    address internal constant KEEPER = address(0xCAFE);

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;

    uint256 internal staleBuckets;
    uint256 internal bi;

    function setUp() public {
        setUpTwinOracle();
        staleBuckets = X.ve.STALE_FLAT_BUCKETS();
        bi = spawn(true, BOB, AMT, N, Cadence.NEVER, false, false);
        vm.prank(BOB);
        X.del.delegate(_id(bi), CAROL);
        vm.prank(BOB);
        X.ve.enableAutoRelock(_id(bi));
    }

    function _driveCandidate(uint256) internal override {}
    function _id(uint256 i) internal view returns (uint256) { return positions[i].tokenId; }

    // =================================================================== L4
    /// @notice A transfer disarms the position, so the buyer inherits no
    ///         abandonment clock
    ///         and there is no stale position for a keeper to retire.
    function test_L4_transfer_disarms_so_nothing_is_left_to_retire() public {
        uint256 id = _id(bi);
        _warpToBucket(staleBuckets - 1);
        vm.prank(BOB);
        X.ve.transferFrom(BOB, CAROL, id);
        assertEq(X.ve.ownerOf(id), CAROL, "transfer refused");
        assertEq(uint256(X.ve.autoRelockRemaining(id)), 0, "flag survived the transfer");
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        X.ve.autoRelockStaleAt(id);
        _warpToBucket(staleBuckets);
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        X.ve.retireStaleAutoRelock(id);
    }

    function _warpToBucket(uint256 k) internal {
        vm.warp(t0 + k * SIX_DAYS);
        vm.roll(block.number + 43_830 * k);
    }

    // =================================================================== L1
    /// @notice AN OWNER WHO ENLARGES R IS STILL RETIRED ON TIME.
    function test_L1_increaseUnlockTime_does_not_restart_the_clock() public {
        uint256 id = _id(bi);
        uint256 staleAtAfterEnable = X.ve.autoRelockStaleAt(id);

        // bucket 30: the OWNER enlarges R from 6 to 10 buckets.
        _warpToBucket(30);
        vm.prank(BOB);
        X.ve.increaseUnlockTime(id, 10 * SIX_DAYS);
        assertEq(uint256(X.ve.autoRelockRemaining(id)), 10 * SIX_DAYS, "R was not enlarged");

        uint256 staleAtAfterExtend = X.ve.autoRelockStaleAt(id);
        assertEq(staleAtAfterExtend, staleAtAfterEnable, "increaseUnlockTime moved the abandonment clock");

        // bucket 60: a STRANGER retires a position whose owner signed 30
        // buckets ago -- half the abandonment horizon.
        _warpToBucket(staleBuckets);
        assertEq(block.timestamp, staleAtAfterExtend, "did not land on staleAt");
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(id);
        assertEq(uint256(X.ve.autoRelockRemaining(id)), 0, "not retired");
    }

    // =================================================================== L2
    /// @notice CONTROL: the heartbeat DOES move the clock.
    function test_L2_refresh_defers_the_retire() public {
        uint256 id = _id(bi);
        _warpToBucket(30);
        vm.prank(BOB);
        X.ve.refreshAutoRelock(id);
        assertEq(X.ve.autoRelockStaleAt(id), t0 + (30 + staleBuckets) * SIX_DAYS, "heartbeat did not defer");

        _warpToBucket(staleBuckets);
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
        X.ve.retireStaleAutoRelock(id);
    }
}

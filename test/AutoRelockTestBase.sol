// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title  Shared fixture for many of the auto-relock suites.
/// @notice A seeded `LockedCurveTestBase` with funded, approved actors
///         (attacker, victim, stranger) and two delegatees, plus small helpers:
///         `grid()`, `slopeOf`, `residualLockup` (`effectiveLockEnd - now`),
///         `warpToPhase`, and enable / disable / delegate wrappers. Green means
///         "this attack did not succeed on this build"; it never means the
///         attack is impossible. R = `autoRelockRemaining(id)`, the frozen
///         remaining term in seconds (whole SIX_DAYS buckets).
contract AutoRelockTestBase is LockedCurveTestBase {
    /// @dev The bucket-mean flat level is `slope * (R - SIX_DAYS/2)`.
    uint256 internal constant HALF_BUCKET = 262_980; // SIX_DAYS / 2

    address internal attacker = address(0xA11CE0);
    address internal victim = address(0x71C71);
    address internal stranger = address(0x57AA9E);
    address internal delegateeA = address(0xDE1E6A);
    address internal delegateeB = address(0xDE1E62);

    function setUp() public virtual override {
        super.setUp();
        hemi.mint(attacker, 10_000 ether);
        hemi.mint(victim, 10_000 ether);
        hemi.mint(stranger, 10_000 ether);
        vm.prank(attacker);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(victim);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(stranger);
        hemi.approve(address(veHemi), type(uint256).max);
        runSeedingFlow();
    }

    /// @dev grid(now)
    function grid() internal view returns (uint256) {
        return (block.timestamp / SIX_DAYS) * SIX_DAYS;
    }

    function slopeOf(uint256 amount_) internal pure returns (uint256) {
        return amount_ / MAX_TIME;
    }

    /// @dev The residual lock-up a flat position is STILL SERVING: the end
    ///      `disableAutoRelock` would restore, minus now. This is the
    ///      denominator of the vote-escrow law `weight == slope * lockup`.
    function residualLockup(uint256 id_) internal view returns (uint256) {
        return veHemi.effectiveLockEnd(id_) - block.timestamp;
    }

    /// @dev warp to an exact phase inside the NEXT bucket.
    function warpToPhase(uint256 phase_) internal {
        uint256 target = grid() + SIX_DAYS + phase_;
        vm.warp(target);
    }

    function enable(address who_, uint256 id_) internal {
        vm.prank(who_);
        veHemi.enableAutoRelock(id_);
    }

    function disable(address who_, uint256 id_) internal {
        vm.prank(who_);
        veHemi.disableAutoRelock(id_);
    }

    function delegateTo(address who_, uint256 id_, address to_) internal {
        vm.prank(who_);
        delegation.delegate(id_, to_);
    }
}

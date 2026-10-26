// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title AutoRelockViewsTest
/// @notice `effectiveLockEnd` against closed forms computed in the test:
///         an unarmed position reports its stored end; an armed one reports
///         `grid(now) + R`, where `R = end - grid(armTime)`; a position
///         disarmed by `disableAutoRelock` or by a transfer to another
///         account reports the end written at the disarm, `grid(disarmTime) + R`,
///         and stops moving.
contract AutoRelockViewsTest is LockedCurveTestBase {
    uint256 internal constant DURATION = 40 * SIX_DAYS;

    function _grid(uint256 t_) internal pure returns (uint256) {
        return (t_ / SIX_DAYS) * SIX_DAYS;
    }

    function _start() internal returns (uint256 id_, uint256 end_) {
        vm.warp(_grid(block.timestamp) + 3 * SIX_DAYS + 12_345);   // mid-bucket
        end_ = _grid(block.timestamp + DURATION);
        (id_, , ) = createLock(alice, 100 ether, DURATION);
        assertEq(veHemi.getLockedBalance(id_).end, end_, "premise: end is floor-snapped to the grid");
    }

    function test_effectiveLockEnd_unarmedIsStoredEnd() public {
        (uint256 id, uint256 end) = _start();
        assertFalse(veHemi.isAutoRelockEnabled(id), "premise: unarmed");
        assertEq(veHemi.effectiveLockEnd(id), end, "unarmed: effectiveLockEnd != stored end");

        vm.warp(block.timestamp + 7 * SIX_DAYS + 999);
        assertEq(veHemi.effectiveLockEnd(id), end, "unarmed: effectiveLockEnd moved with the clock");

        vm.warp(end + 1);
        assertEq(veHemi.effectiveLockEnd(id), end, "unarmed: effectiveLockEnd changed after expiry");
    }

    function test_effectiveLockEnd_armedTracksGridPlusRemaining() public {
        (uint256 id, uint256 end) = _start();
        vm.warp(block.timestamp + 2 * SIX_DAYS + 100);
        uint256 r = end - _grid(block.timestamp);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        assertEq(veHemi.effectiveLockEnd(id), end, "armed in this block: effectiveLockEnd != stored end");

        vm.warp(block.timestamp + 5 * SIX_DAYS + 77);
        assertEq(veHemi.effectiveLockEnd(id), _grid(block.timestamp) + r, "armed: effectiveLockEnd != grid(now) + R");
        assertGt(veHemi.effectiveLockEnd(id), end, "armed: effectiveLockEnd did not move forward");
    }

    function test_effectiveLockEnd_createLockWithAutoRelockIsArmedAtCreation() public {
        vm.warp(_grid(block.timestamp) + 3 * SIX_DAYS + 12_345);
        uint256 end = _grid(block.timestamp + DURATION);
        uint256 r = end - _grid(block.timestamp);
        hemi.mint(alice, 100 ether);
        vm.prank(alice);
        uint256 id = veHemi.createLockWithAutoRelock(100 ether, DURATION, true, false);
        assertTrue(veHemi.isAutoRelockEnabled(id), "armed at creation");
        assertEq(veHemi.effectiveLockEnd(id), end, "at creation: effectiveLockEnd != floor-snapped end");

        vm.warp(block.timestamp + 9 * SIX_DAYS);
        assertEq(veHemi.effectiveLockEnd(id), _grid(block.timestamp) + r, "armed: effectiveLockEnd != grid(now) + R");
    }

    function test_effectiveLockEnd_disarmedByDisableIsTheRestoredEnd() public {
        (uint256 id, uint256 end) = _start();
        vm.warp(block.timestamp + SIX_DAYS + 500);
        uint256 r = end - _grid(block.timestamp);
        vm.prank(alice); veHemi.enableAutoRelock(id);

        vm.warp(block.timestamp + 4 * SIX_DAYS + 31);
        uint256 restored = _grid(block.timestamp) + r;
        vm.prank(alice); veHemi.disableAutoRelock(id);

        assertFalse(veHemi.isAutoRelockEnabled(id), "disarmed");
        assertEq(veHemi.getLockedBalance(id).end, restored, "disable: stored end != grid(disable) + R");
        assertEq(veHemi.effectiveLockEnd(id), restored, "disabled: effectiveLockEnd != restored end");

        vm.warp(block.timestamp + 6 * SIX_DAYS);
        assertEq(veHemi.effectiveLockEnd(id), restored, "disabled: effectiveLockEnd still moves with the clock");
    }

    function test_effectiveLockEnd_disarmedByTransferIsTheEndAtTransfer() public {
        (uint256 id, uint256 end) = _start();
        vm.warp(block.timestamp + SIX_DAYS + 500);
        uint256 r = end - _grid(block.timestamp);
        vm.prank(alice); veHemi.enableAutoRelock(id);

        vm.warp(block.timestamp + 3 * SIX_DAYS + 4_000);
        uint256 atTransfer = _grid(block.timestamp) + r;
        assertEq(veHemi.effectiveLockEnd(id), atTransfer, "armed: effectiveLockEnd != grid(now) + R");
        vm.prank(alice); veHemi.transferFrom(alice, bob, id);

        assertEq(veHemi.ownerOf(id), bob, "transferred");
        assertFalse(veHemi.isAutoRelockEnabled(id), "a transfer to another account disarms");
        assertEq(veHemi.getLockedBalance(id).end, atTransfer, "transfer: stored end != effectiveLockEnd at the transfer");
        assertEq(veHemi.effectiveLockEnd(id), atTransfer, "transferred: effectiveLockEnd != end at the transfer");

        vm.warp(block.timestamp + 6 * SIX_DAYS);
        assertEq(veHemi.effectiveLockEnd(id), atTransfer, "transferred: effectiveLockEnd still moves with the clock");
    }
}

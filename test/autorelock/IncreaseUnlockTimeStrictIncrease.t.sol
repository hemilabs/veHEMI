// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice The strict-increase refusal of `increaseUnlockTime`
///         (`NewLockDurationNotGreater`), on both branches. On a FLAT position a
///         request for exactly R asks for the term the position already has
///         and must be refused without touching anything; one bucket more must
///         be accepted and move R. The bodies make the boundary call directly
///         and assert the contract's answer, not a recomputation of its rule.
contract IncreaseUnlockTimeStrictIncreaseTest is LockedCurveTestBase {
    /// THE ACCEPTANCE CONTROL. Without this the refusals below could pass
    /// because `increaseUnlockTime` refuses EVERYTHING. One whole bucket beyond
    /// `R` must be ACCEPTED, and must actually move `R`.
    function test_oneBucketBeyondIsAccepted_notVacuous() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 R = veHemi.autoRelockRemaining(id);
        vm.prank(alice);
        veHemi.increaseUnlockTime(id, R + SIX_DAYS);
        assertEq(
            uint256(veHemi.autoRelockRemaining(id)),
            R + SIX_DAYS,
            "a genuine one-bucket extension must be accepted and must move R"
        );
    }

    /// Requests BELOW the current term are refused too, with the SAME error
    /// (a short duration must not panic 0x11).
    function test_shortExtensionIsRefusedNotPanic() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        vm.prank(alice);
        vm.expectRevert(VeHemi.NewLockDurationNotGreater.selector);
        veHemi.increaseUnlockTime(id, 0);
    }

    /// THE DECAYING BRANCH of the same guard: a request for the current end is
    /// refused.
    function test_decayingNoopExtensionIsRefused() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        uint256 end = veHemi.getLockedBalance(id).end;
        assertGt(end, block.timestamp, "precondition: still decaying");

        vm.prank(alice);
        vm.expectRevert(VeHemi.NewLockDurationNotGreater.selector);
        veHemi.increaseUnlockTime(id, end - block.timestamp);
    }

    /// The no-op extension on a FLAT position. `R` is whole SIX_DAYS buckets,
    /// so `duration == R` yields `grid(now + R) == grid(now) + R`: the term the
    /// position already has. It is refused with `NewLockDurationNotGreater`
    /// and moves nothing (no R, weight or end change).
    function test_refusedNoopTouchesNothing() public {
        runSeedingFlow();
        (uint256 id, , ) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 R = veHemi.autoRelockRemaining(id);
        assertGt(R, 0, "precondition: position is flat");
        assertEq(R % SIX_DAYS, 0, "precondition: R is whole buckets");
        uint256 wBefore = veHemi.balanceOfNFT(id);
        uint256 endBefore = veHemi.getLockedBalance(id).end;

        vm.prank(alice);
        try veHemi.increaseUnlockTime(id, R) {
            fail();
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason),
                VeHemi.NewLockDurationNotGreater.selector,
                "the no-op must be refused with NewLockDurationNotGreater"
            );
        }

        assertEq(uint256(veHemi.autoRelockRemaining(id)), R, "R unmoved by a refused call");
        assertEq(veHemi.balanceOfNFT(id), wBefore, "weight unmoved by a refused call");
        assertEq(veHemi.getLockedBalance(id).end, endBefore, "end unmoved by a refused call");
    }
}

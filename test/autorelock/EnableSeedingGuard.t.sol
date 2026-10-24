// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// @notice The seeding guard. `enableAutoRelock` on a subcurve position
///         is refused (`SeedingNotFinalized`) until
///         `lockedSeedingFinalized`: before the latch, `_checkpoint` skips the
///         subcurves and `seedBatch` would enrol a flat position as a decaying
///         one. After the latch, enabling keeps the subcurve on its plain decay
///         to `transferableAfter`.
contract EnableSeedingGuardTest is LockedCurveTestBase {
    /// @dev Refused for the whole seeding window, accepted the instant the
    ///      latch flips.
    function test_enableIsRefusedUntilSeedingIsFinalized() public {
        vm.prank(alice);
        uint256 id = veHemi.createLockFor(100 ether, 2 * 365 days, alice, false, false);
        assertFalse(veHemi.lockedSeedingFinalized(), "premise: not yet finalized");
        vm.prank(alice);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        veHemi.enableAutoRelock(id);

        // ...and it is refused for the whole window, not just before
        // markSeedingStarted.
        veHemi.markSeedingStarted();
        vm.prank(alice);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        veHemi.enableAutoRelock(id);

        veHemi.seedBatch(type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        veHemi.enableAutoRelock(id);

        // The instant the latch flips, it is accepted.
        veHemi.finalizeSeeding();
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        assertGt(veHemi.autoRelockRemaining(id), 0, "enable must succeed once seeding is finalized");
    }

    /// @dev CONTROL. Enable AFTER `finalizeSeeding`: the non-transferable
    ///      subcurve carries `slope * (transferableAfter - now)` at enable and
    ///      180 days later, while the global weight stays at the flat level.
    function test_control_enableAfterSeedingIsSound() public {
        vm.prank(alice);
        uint256 id = veHemi.createLockFor(100 ether, 2 * 365 days, alice, false, false);
        runSeedingFlow();
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 slope = 100 ether / MAX_TIME;
        uint256 transferableAfter = veHemi.transferableAfter(id);
        uint256 flatWeight = veHemi.balanceOfNFT(id);
        uint256 remaining = veHemi.autoRelockRemaining(id);
        assertEq(flatWeight, slope * (remaining - SIX_DAYS / 2), "flat level is not the bucket mean");
        assertEq(veHemi.totalVeHemiSupply(), flatWeight, "total != the only position");
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            slope * (transferableAfter - block.timestamp),
            "subcurve at enable"
        );
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "non-forfeitable position in the forfeitable subcurve");

        vm.warp(block.timestamp + 180 days);
        veHemi.checkpoint();
        assertEq(veHemi.totalVeHemiSupply(), flatWeight, "global droop at +180 days");
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            slope * (transferableAfter - block.timestamp),
            "subcurve at +180 days"
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockSeamsBase.sol";

/// @notice The seams between auto-relock and the rest of the position life
///         cycle: a transfer disarms, a forfeit of a flat position clears every
///         curve and the votes, the forfeit window closes at
///         `transferableAfter` and is not dodged by staying flat, seeding is
///         one-way, an approved operator cannot disarm or heartbeat a position,
///         and `supplyBreakdown` agrees with the dedicated views.
contract LifecycleSeamsTest is AutoRelockSeamsBase {
    function setUp() public { _deploy(); }

    // ---------------------------------------------------------------- T1
    // Transfer of a FLAT position: the auto-relock state does NOT follow the
    // token, so the buyer inherits no abandonment clock one second from
    // lapsing that a stranger could then fire.
    function test_T1_transfer_disarms_the_position() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);

        uint256 staleAtBefore = ve.autoRelockStaleAt(id);

        // warp to 1 second before the heartbeat lapses, then transfer
        vm.warp(staleAtBefore - 1);
        vm.prank(alice);
        ve.transferFrom(alice, bob, id);

        // The transfer auto-disabled it: bob holds a plain decaying lock.
        assertEq(ve.autoRelockRemaining(id), 0, "state followed the token");
        // No abandonment clock exists for anyone to read or fire on bob.
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        ve.autoRelockStaleAt(id);

        vm.warp(staleAtBefore);
        vm.prank(carol);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        ve.retireStaleAutoRelock(id);

        // the delivered lock is live and still carries weight
        assertGt(ve.balanceOfNFT(id), 0, "disarmed lock has no weight");
        assertGt(ve.getLockedBalance(id).end, block.timestamp, "disarmed lock must be live");
    }

    // ---------------------------------------------------------------- T2
    // FORFEIT of a FLAT forfeitable position: all curves and votes clear.
    function test_T2_forfeitOfFlatPositionClearsEveryCurveAndTheVotes() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, false, true);
        vm.prank(alice);
        ve.enableAutoRelock(id);

        vm.warp(block.timestamp + 10 * SIX_DAYS);
        assertGt(del.getVotes(alice), 0, "premise: no votes before the forfeit");

        vm.prank(admin);
        ve.forfeit(id);

        // the vote change takes effect from the next second; read two hours later
        vm.warp(block.timestamp + 2 hours);
        assertEq(ve.totalVeHemiSupply(), 0, "global flat aggregate survived forfeit");
        assertEq(ve.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve survived forfeit");
        assertEq(ve.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve survived forfeit");
        assertEq(del.getVotes(alice), 0, "phantom votes after forfeit");
    }

    // ---------------------------------------------------------------- T3
    // A FLAT forfeitable position is still forfeitable at the last second of
    // its window, and the forfeit clears it completely.
    function test_T3_flatPositionIsForfeitableAtTheLastSecondOfTheWindow() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, false, true);
        uint256 transferableAfter = ve.transferableAfter(id);
        vm.prank(alice);
        ve.enableAutoRelock(id);

        vm.warp(transferableAfter - 1);
        uint256 adminBalanceBefore = hemi.balanceOf(admin);
        vm.prank(admin);
        ve.forfeit(id);
        assertEq(hemi.balanceOf(admin) - adminBalanceBefore, 1000e18, "forfeit did not seize the principal");
        assertEq(ve.autoRelockRemaining(id), 0, "forfeit left the flag");
        assertEq(ve.totalVeHemiSupply(), 0, "forfeit at transferableAfter - 1 left supply");
    }

    // T3b -- At and after `transferableAfter` the forfeit is refused even
    // though the position is still flat at full weight, and the position
    // becomes transferable. (At `transferableAfter` itself the window check
    // refuses; one second later the stored `lock.end`, which equals
    // `transferableAfter`, is in the past and the expiry check refuses
    // first.)
    function test_T3b_flat_survives_past_transferableAfter_and_forfeit_closes() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, false, true);
        uint256 transferableAfter = ve.transferableAfter(id);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        uint256 flatWeight = ve.balanceOfNFT(id);

        vm.warp(transferableAfter);
        vm.prank(admin);
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        ve.forfeit(id);

        vm.warp(transferableAfter + 1);
        assertEq(ve.balanceOfNFT(id), flatWeight, "flat weight lost past transferableAfter");
        assertEq(ve.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve not retired at transferableAfter");
        assertEq(ve.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve not retired at transferableAfter");
        vm.prank(admin);
        vm.expectRevert(VeHemi.LockExpired.selector);
        ve.forfeit(id);

        // the position is now transferable, and the transfer disarms it
        assertTrue(ve.isTransferable(id), "not transferable past transferableAfter");
        vm.prank(alice);
        ve.transferFrom(alice, bob, id);
        assertEq(ve.autoRelockRemaining(id), 0, "transfer did not disarm");
    }

    // ---------------------------------------------------------------- T4
    // The seeding state machine is one-way.
    function test_T4_seeding_is_one_way() public {
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        ve.markSeedingStarted();
        assertTrue(ve.lockedSeedingFinalized());
    }

    // ---------------------------------------------------------------- T5
    // An approved operator can move the position but cannot disarm or
    // heartbeat it, and the move itself disarms it.
    function test_T5_operatorCannotDisableOrRefresh_andItsTransferDisarms() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        vm.prank(alice);
        ve.approve(bob, id);

        vm.prank(bob);
        vm.expectRevert(VeHemi.NotOwner.selector);
        ve.disableAutoRelock(id);

        vm.prank(bob);
        vm.expectRevert(VeHemi.NotOwner.selector);
        ve.refreshAutoRelock(id);

        vm.prank(bob);
        ve.transferFrom(alice, bob, id);
        assertEq(ve.autoRelockRemaining(id), 0, "operator seize left it armed");
        // so a follow-up disable reverts: there is nothing left to disable.
        vm.prank(bob);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        ve.disableAutoRelock(id);
    }

    // ---------------------------------------------------------------- T6
    // supplyBreakdown vs dedicated views with a flat non-transferable position
    function test_T6_supplyBreakdownMatchesTheDedicatedViews_withAFlatPosition() public {
        _mint(alice, 1000e18, 100 * SIX_DAYS, false, true);
        uint256 bobId = _mint(bob, 500e18, 100 * SIX_DAYS, false, false);
        vm.prank(bob);
        ve.enableAutoRelock(bobId);

        for (uint256 k = 0; k < 6; ++k) {
            vm.warp(block.timestamp + SIX_DAYS / 3);
            (uint256 total, uint256 locked_, uint256 forfeitable_, ) = ve.supplyBreakdown();
            assertEq(locked_, ve.nonTransferableTotalVeHemiSupply(), "locked mismatch");
            assertEq(forfeitable_, ve.forfeitableTotalVeHemiSupply(), "forfeitable mismatch");
            assertEq(total, ve.totalVeHemiSupply(), "total mismatch");
        }
    }
}

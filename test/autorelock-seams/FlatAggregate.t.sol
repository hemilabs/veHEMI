// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockSeamsBase.sol";

/// @notice The global flat aggregate (`Point.amount`) is the exact sum of the
///         flat levels across forfeit, top-up, stale retire and disable of
///         neighbouring positions, drains to zero, and historical supply read
///         after a flat episode equals the live reading taken during it.
contract FlatAggregateTest is AutoRelockSeamsBase {
    function setUp() public { _deploy(); }

    /// Three flat positions; burn/forfeit/disable one at a time and check the
    /// global flat aggregate (Point.amount, clamped at 0 in VeHemiCurveLib's
    /// Phase C) never eats a neighbour's weight.
    function test_flat_aggregate_no_cross_contamination() public {
        uint256 aliceId = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        uint256 bobId = _mint(bob,    700e18,  80 * SIX_DAYS, false, true);
        uint256 carolId = _mint(carol, 300e18, 60 * SIX_DAYS, false, false);
        vm.prank(alice); ve.enableAutoRelock(aliceId);
        vm.prank(bob);   ve.enableAutoRelock(bobId);
        vm.prank(carol); ve.enableAutoRelock(carolId);

        uint256 aliceWeight = ve.balanceOfNFT(aliceId);
        uint256 bobWeight = ve.balanceOfNFT(bobId);
        uint256 carolWeight = ve.balanceOfNFT(carolId);
        emit log_named_uint("alice flat weight", aliceWeight);
        emit log_named_uint("bob flat weight", bobWeight);
        emit log_named_uint("carol flat weight", carolWeight);
        assertEq(ve.totalVeHemiSupply(), aliceWeight + bobWeight + carolWeight, "aggregate != sum of flat levels");

        // 1) forfeit bob's position (flat + forfeitable)
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        vm.prank(admin); ve.forfeit(bobId);
        assertEq(
            ve.totalVeHemiSupply(), aliceWeight + carolWeight, "forfeit of bob's position disturbed alice's or carol's position"
        );
        assertEq(ve.balanceOfNFT(aliceId), aliceWeight, "alice's position moved");
        assertEq(ve.balanceOfNFT(carolId), carolWeight, "carol's position moved");

        // 2) the owner's increaseAmount on alice's position -> flat level steps up
        address aliceOwner = ve.ownerOf(aliceId);
        hemi.mint(aliceOwner, 100e18);
        vm.startPrank(aliceOwner);
        hemi.approve(address(ve), type(uint256).max);
        ve.increaseAmount(aliceId, 100e18);
        vm.stopPrank();
        uint256 aliceWeightAfterTopUp = ve.balanceOfNFT(aliceId);
        emit log_named_uint("alice flat weight after owner top-up +100e18", aliceWeightAfterTopUp);
        assertEq(ve.totalVeHemiSupply(), aliceWeightAfterTopUp + carolWeight, "aggregate wrong after increaseAmount");

        // 3) permissionless stale retire of carol's position
        vm.warp(ve.autoRelockStaleAt(carolId));
        vm.prank(address(0xDEAD)); ve.retireStaleAutoRelock(carolId);
        assertEq(ve.balanceOfNFT(aliceId), aliceWeightAfterTopUp, "alice's position disturbed by the retire of carol's position");
        assertEq(ve.totalVeHemiSupply(), aliceWeightAfterTopUp + ve.balanceOfNFT(carolId), "aggregate wrong after retire");

        // 4) owner disable of alice's position
        vm.prank(alice); ve.disableAutoRelock(aliceId);
        assertEq(ve.totalVeHemiSupply(), ve.balanceOfNFT(aliceId) + ve.balanceOfNFT(carolId), "aggregate wrong after disable");
        emit log_named_uint("final total", ve.totalVeHemiSupply());

        // 5) everything must drain to zero eventually
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(ve.totalVeHemiSupply(), 0, "supply never drained");
        assertEq(ve.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve never drained");
        assertEq(ve.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve never drained");
    }

    /// Historical supply at a timestamp inside a flat episode must equal the
    /// live reading taken at that timestamp.
    function test_historical_supply_matches_live() public {
        uint256 aliceId = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice); ve.enableAutoRelock(aliceId);
        uint256[] memory ts = new uint256[](5);
        uint256[] memory live = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 7 * SIX_DAYS + 1234);
            ts[i] = block.timestamp;
            live[i] = ve.totalVeHemiSupply();
        }
        vm.warp(block.timestamp + 1); // sample instants are strictly in the past
        vm.prank(alice); ve.disableAutoRelock(aliceId);
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        for (uint256 i; i < 5; ++i) {
            emit log_named_uint("ts", ts[i]);
            emit log_named_uint("  live then", live[i]);
            emit log_named_uint("  historical now", ve.totalVeHemiSupplyAt(ts[i]));
            assertEq(ve.totalVeHemiSupplyAt(ts[i]), live[i], "history rewritten");
        }
    }
}

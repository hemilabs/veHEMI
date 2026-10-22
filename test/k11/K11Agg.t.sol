// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./K11Base.sol";

/// @notice The global flat aggregate (`Point.amount`) is the exact sum of the
///         flat levels across forfeit, top-up, stale retire and disable of
///         neighbouring positions, drains to zero, and historical supply read
///         after a flat episode equals the live reading taken during it.
contract K11Agg is K11Base {
    function setUp() public { _deploy(); }

    /// Three flat positions; burn/forfeit/disable one at a time and check the
    /// global flat aggregate (Point.amount, clamped at 0 in Phase C) never
    /// eats a neighbour's weight.
    function test_A1_flat_aggregate_no_cross_contamination() public {
        uint256 a = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        uint256 b = _mint(bob,    700e18,  80 * SIX_DAYS, false, true);
        uint256 cId = _mint(carol, 300e18, 60 * SIX_DAYS, false, false);
        vm.prank(alice); ve.enableAutoRelock(a);
        vm.prank(bob);   ve.enableAutoRelock(b);
        vm.prank(carol); ve.enableAutoRelock(cId);

        uint256 wa = ve.balanceOfNFT(a);
        uint256 wb = ve.balanceOfNFT(b);
        uint256 wc = ve.balanceOfNFT(cId);
        emit log_named_uint("wa", wa); emit log_named_uint("wb", wb); emit log_named_uint("wc", wc);
        assertEq(ve.totalVeHemiSupply(), wa + wb + wc, "aggregate != sum of flat levels");

        // 1) forfeit b (flat + forfeitable)
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        vm.prank(admin); ve.forfeit(b);
        assertEq(ve.totalVeHemiSupply(), wa + wc, "forfeit of b disturbed a/c");
        assertEq(ve.balanceOfNFT(a), wa, "a moved"); assertEq(ve.balanceOfNFT(cId), wc, "c moved");

        // 2) the owner's increaseAmount on a -> flat level steps up
        address ownerA = ve.ownerOf(a);
        hemi.mint(ownerA, 100e18);
        vm.startPrank(ownerA);
        hemi.approve(address(ve), type(uint256).max);
        ve.increaseAmount(a, 100e18);
        vm.stopPrank();
        uint256 wa2 = ve.balanceOfNFT(a);
        emit log_named_uint("wa after owner top-up +100e18", wa2);
        assertEq(ve.totalVeHemiSupply(), wa2 + wc, "aggregate wrong after increaseAmount");

        // 3) permissionless stale retire of c
        vm.warp(ve.autoRelockStaleAt(cId));
        vm.prank(address(0xDEAD)); ve.retireStaleAutoRelock(cId);
        assertEq(ve.balanceOfNFT(a), wa2, "a disturbed by c's retire");
        assertEq(ve.totalVeHemiSupply(), wa2 + ve.balanceOfNFT(cId), "aggregate wrong after retire");

        // 4) owner disable of a
        vm.prank(alice); ve.disableAutoRelock(a);
        assertEq(ve.totalVeHemiSupply(), ve.balanceOfNFT(a) + ve.balanceOfNFT(cId), "aggregate wrong after disable");
        emit log_named_uint("final total", ve.totalVeHemiSupply());

        // 5) everything must drain to zero eventually
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(ve.totalVeHemiSupply(), 0, "supply never drained");
        assertEq(ve.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve never drained");
        assertEq(ve.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve never drained");
    }

    /// Historical supply at a timestamp inside a flat episode must equal the
    /// live reading taken at that timestamp.
    function test_A2_historical_supply_matches_live() public {
        uint256 a = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice); ve.enableAutoRelock(a);
        uint256[] memory ts = new uint256[](5);
        uint256[] memory live = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 7 * SIX_DAYS + 1234);
            ts[i] = block.timestamp;
            live[i] = ve.totalVeHemiSupply();
        }
        vm.warp(block.timestamp + 1); // sample instants are strictly in the past
        vm.prank(alice); ve.disableAutoRelock(a);
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        for (uint256 i; i < 5; ++i) {
            emit log_named_uint("ts", ts[i]);
            emit log_named_uint("  live then", live[i]);
            emit log_named_uint("  historical now", ve.totalVeHemiSupplyAt(ts[i]));
            assertEq(ve.totalVeHemiSupplyAt(ts[i]), live[i], "history rewritten");
        }
    }
}

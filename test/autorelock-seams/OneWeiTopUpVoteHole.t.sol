// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockSeamsBase.sol";

/// A 1-wei `increaseAmount` must not open a vote hole: the delegatee's live
/// and past votes stay non-zero across the re-booking, on decaying and flat
/// positions. `increaseAmount` is owner-gated, so the owner makes the top-up;
/// the hole this guards against is a dating defect, not an access-control one.
contract OneWeiTopUpVoteHoleTest is AutoRelockSeamsBase {
    function setUp() public { _deploy(); }

    function _v(string memory tag) internal {
        emit log_named_uint(tag, del.getVotes(alice));
    }

    // 1 wei top-up -> does the delegatee lose votes?
    function test_oneWeiTopUpOpensNoVoteHole() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.warp(block.timestamp + 2 hours);
        uint256 before = del.getVotes(alice);
        emit log_named_uint("votes before", before);
        assertGt(before, 0);

        hemi.mint(alice, 1);
        vm.startPrank(alice);
        hemi.approve(address(ve), type(uint256).max);
        ve.increaseAmount(id, 1);
        vm.stopPrank();

        _v("votes same block");
        vm.warp(block.timestamp + 1);
        _v("votes +1s");
        vm.warp(block.timestamp + 30 minutes);
        _v("votes +30m");
        uint256 mid = del.getVotes(alice);
        vm.warp(block.timestamp + 1 hours);
        _v("votes +1h30m");
        emit log_named_uint("weight", ve.balanceOfNFT(id));
        emit log_named_uint("supply", ve.totalVeHemiSupply());

        assertGt(mid, 0, "VOTE HOLE: delegatee lost all votes after a 1-wei owner top-up");
    }

    // same, on a FLAT position
    function test_oneWeiTopUpOnFlatPositionOpensNoVoteHole() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        vm.warp(block.timestamp + 2 hours);
        emit log_named_uint("votes before", del.getVotes(alice));
        hemi.mint(alice, 1);
        vm.startPrank(alice);
        hemi.approve(address(ve), type(uint256).max);
        ve.increaseAmount(id, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 minutes);
        uint256 mid = del.getVotes(alice);
        _v("votes +30m");
        vm.warp(block.timestamp + 2 hours);
        _v("votes +2h30m");
        assertGt(mid, 0, "VOTE HOLE on flat position");
    }

    // getPastVotes inside the hole (this is what a governance snapshot reads)
    function test_pastVotesAfterOneWeiTopUpStayNonZero() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.warp(block.timestamp + 2 hours);
        hemi.mint(alice, 1);
        vm.startPrank(alice);
        hemi.approve(address(ve), type(uint256).max);
        ve.increaseAmount(id, 1);
        vm.stopPrank();
        uint256 holeTs = block.timestamp + 600;
        vm.warp(block.timestamp + 3 hours);
        emit log_named_uint("getPastVotes(alice, holeTs)", del.getPastVotes(alice, holeTs));
        emit log_named_uint("getPastTotalSupply(holeTs)", del.getPastTotalSupply(holeTs));
        assertGt(del.getPastVotes(alice, holeTs), 0, "historical snapshot inside the hole reads zero");
    }
}

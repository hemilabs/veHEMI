// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockSeamsBase.sol";

/// @notice Vote conservation across a transfer: the seller holds no votes and
///         the buyer holds exactly the (disarmed) position's weight, for a flat
///         position, two transfers in the same hour, and a flat position whose
///         stored end is already in the past. A decaying control checks the
///         seller side only.
contract TransferVoteConservationTest is AutoRelockSeamsBase {
    function setUp() public { _deploy(); }

    function _logVotesAndSupply(string memory tag, uint256 id) internal {
        emit log_named_string("--", tag);
        emit log_named_uint("  ts", block.timestamp);
        emit log_named_uint("  alice votes", del.getVotes(alice));
        emit log_named_uint("  bob   votes", del.getVotes(bob));
        emit log_named_uint("  carol votes", del.getVotes(carol));
        emit log_named_uint("  weight", ve.balanceOfNFT(id));
        emit log_named_uint("  supply", ve.totalVeHemiSupply());
    }

    // Flat position transferred: are the votes conserved across the transfer?
    function test_flat_transfer_vote_conservation() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        vm.warp(block.timestamp + 5 * SIX_DAYS);
        _logVotesAndSupply("before transfer", id);

        vm.prank(alice);
        ve.transferFrom(alice, bob, id);
        _logVotesAndSupply("same block as transfer", id);
        vm.warp(block.timestamp + 1);
        _logVotesAndSupply("+1s", id);
        vm.warp(block.timestamp + 1 hours);
        _logVotesAndSupply("+1h", id);
        vm.warp(block.timestamp + 1 hours);
        _logVotesAndSupply("+2h", id);

        assertEq(del.getVotes(alice), 0, "seller retains votes");
        assertEq(del.getVotes(bob), ve.balanceOfNFT(id), "buyer votes != weight");
    }

    // Control: decaying position transferred
    function test_decayingTransfer_sellerKeepsNoVotes() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.warp(block.timestamp + 5 * SIX_DAYS);
        _logVotesAndSupply("before transfer", id);
        vm.prank(alice);
        ve.transferFrom(alice, bob, id);
        _logVotesAndSupply("same block", id);
        vm.warp(block.timestamp + 2 hours);
        _logVotesAndSupply("+2h", id);
        assertEq(del.getVotes(alice), 0, "seller retains votes");
    }

    // Two transfers inside the SAME hour
    function test_twoTransfersInOneHour_onlyTheLastBuyerHoldsVotes() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        vm.warp(block.timestamp + 5 * SIX_DAYS);
        vm.prank(alice);
        ve.transferFrom(alice, bob, id);
        vm.warp(block.timestamp + 60); // same hour
        vm.prank(bob);
        ve.transferFrom(bob, carol, id);
        _logVotesAndSupply("after A->B->C same hour", id);
        vm.warp(block.timestamp + 2 hours);
        _logVotesAndSupply("+2h", id);
        assertEq(del.getVotes(alice), 0, "alice phantom");
        assertEq(del.getVotes(bob), 0, "bob phantom");
        assertEq(del.getVotes(carol), ve.balanceOfNFT(id), "carol short");
    }

    // Transfer a flat position whose stored lock.end is already in the PAST.
    function test_flatPositionWithPastStoredEnd_transferMovesAllVotesToTheBuyer() public {
        uint256 id = _mint(alice, 1000e18, 100 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        uint256 end = ve.getLockedBalance(id).end;
        vm.warp(end + SIX_DAYS);
        emit log_named_uint("lock.end", end);
        emit log_named_uint("now", block.timestamp);
        _logVotesAndSupply("flat past stored end, pre transfer", id);
        vm.prank(alice);
        ve.transferFrom(alice, bob, id);
        vm.warp(block.timestamp + 2 hours);
        _logVotesAndSupply("post transfer +2h", id);
        assertEq(del.getVotes(alice), 0, "alice phantom");
        assertEq(del.getVotes(bob), ve.balanceOfNFT(id), "bob short");
    }
}

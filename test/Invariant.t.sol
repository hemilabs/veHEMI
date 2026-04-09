// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {VeHemi} from "src/VeHemi.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {InvariantHandler} from "./InvariantHandler.sol";

contract InvariantTest is Test {
    using SafeCast for int128;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carl = makeAddr("carl");
    address dan = makeAddr("dan");
    address earl = makeAddr("earl");

    InvariantHandler handler;
    VeHemi veHemi;
    VeHemiVoteDelegation public delegation;
    MockERC20 public hemi;

    function setUp() public {
        handler = new InvariantHandler(admin, [alice, bob, carl, dan, earl]);
        veHemi = handler.veHemi();
        hemi = handler.hemi();
        delegation = handler.delegation();

        targetContract(address(handler));

        for (uint i = 0; i < 5; i++) {
            targetSender(handler.users(i));
        }
    }

    function invariant_veHemiSupply() public view {
        uint256 sumOfBalances;

        for (uint i; i < 5; i++) {
            address user = handler.users(i);

            uint256 nfts = veHemi.balanceOf(user);
            for (uint256 j; j < nfts; j++) {
                uint256 tokenId = veHemi.tokenOfOwnerByIndex(user, j);
                sumOfBalances += veHemi.balanceOfNFT(tokenId);
            }
        }

        assertEq(sumOfBalances, veHemi.totalVeHemiSupply(), "sum of balances != total supply");
    }

    function invariant_votingPower() public {
        // Warp to next day boundary (delegation takes effect at day boundaries),
        // then restore timestamp so we don't pollute handler state.
        uint256 savedTimestamp = block.timestamp;
        vm.warp(((block.timestamp / 1 days) + 1) * 1 days);

        uint256 sumOfBalances;
        uint256 sumOfVotes;

        for (uint i; i < 5; i++) {
            address user = handler.users(i);

            sumOfVotes += delegation.getVotes(user);

            uint256 nfts = veHemi.balanceOf(user);
            for (uint256 j; j < nfts; j++) {
                uint256 tokenId = veHemi.tokenOfOwnerByIndex(user, j);
                sumOfBalances += veHemi.balanceOfNFT(tokenId);
            }
        }

        assertEq(sumOfBalances, sumOfVotes, "sum of balances != sum of votes");

        vm.warp(savedTimestamp);
    }

    /// @dev V2: After seeding, forfeitable <= locked <= total must always hold.
    function invariant_subcurveOrdering() public view {
        if (!handler.seeded()) return; // Subcurves not active yet

        uint256 total = veHemi.totalVeHemiSupply();
        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable_ = veHemi.forfeitableTotalVeHemiSupply();

        assertLe(forfeitable_, locked, "forfeitable > locked");
        assertLe(locked, total, "locked > total");
    }

    /// @dev V2: supplyBreakdown must be internally consistent AND match individual functions.
    function invariant_supplyBreakdownConsistency() public view {
        if (!handler.seeded()) return;

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        // Internal consistency
        assertLe(forfeitable_, locked_, "breakdown: forfeitable > locked");
        assertLe(locked_, total, "breakdown: locked > total");
        assertEq(transferable, total - locked_, "breakdown: transferable != total - locked");

        // Cross-check against individual supply functions
        assertApproxEqRel(total, veHemi.totalVeHemiSupply(), 0.001e18, "breakdown total != totalVeHemiSupply");
        assertApproxEqRel(locked_, veHemi.nonTransferableTotalVeHemiSupply(), 0.001e18, "breakdown locked != nonTransferableTotalVeHemiSupply");
        assertApproxEqRel(forfeitable_, veHemi.forfeitableTotalVeHemiSupply(), 0.001e18, "breakdown forfeitable != forfeitableTotalVeHemiSupply");
    }
}

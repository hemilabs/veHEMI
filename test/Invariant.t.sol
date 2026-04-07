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
        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours); // warp to the next checkpoint

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
    }
}

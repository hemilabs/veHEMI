// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VeHemi} from "src/VeHemi.sol";
import {IVeHemiVoteDelegation} from "src/interfaces/IVeHemiVoteDelegation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";

contract FuzzTest is Test {
    using SafeCast for int128;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carl = makeAddr("carl");

    MockERC20 hemi;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MAX_TIME = 4 * YEAR; // 4 years
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;

    uint256 private constant MIN_AMOUNT = 11e18; // must be >= VeHemi.MIN_LOCK_AMOUNT (10e18)
    uint256 private constant MAX_AMOUNT = 1_000e18;

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);

        // Deploy logic contract
        VeHemi logic = new VeHemi(address(hemi));

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));

        vm.prank(address(this));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(delegation)));

        vm.prank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(bob);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(carl);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    function _getExpectedBalanceOf(uint tokenId) private view returns (uint256) {
        uint end = veHemi.getLockedBalance(tokenId).end;
        uint amount = veHemi.getLockedBalance(tokenId).amount.toUint256();
        uint unlockTime = (end / SIX_DAYS) * SIX_DAYS;
        return (amount * (unlockTime - block.timestamp)) / MAX_TIME;
    }

    function _getNextCheckpoint() private view returns (uint256) {
        return ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
    }

    function testFuzz_createLock(uint amount, uint duration, uint t_1, uint t_2) public {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, 2 * SIX_DAYS, MAX_TIME / 2);

        uint t_0 = block.timestamp;

        vm.startPrank(alice);
        hemi.mint(alice, amount);
        uint tokenId = veHemi.createLock(amount, duration); // create lock
        hemi.mint(alice, amount);
        duration = bound(duration, duration + 1, MAX_TIME); // increase duration
        veHemi.increaseUnlockTime(tokenId, duration);
        hemi.mint(alice, amount);
        veHemi.increaseAmount(tokenId, amount); // increase amount
        vm.stopPrank();

        amount *= 2;
        uint end = veHemi.getLockedBalance(tokenId).end;

        uint expected_0 = _getExpectedBalanceOf(tokenId);
        uint balance_0 = veHemi.balanceOfNFT(tokenId);
        assertEq(veHemi.getLockedBalance(tokenId).amount.toUint256(), amount, "locked @ t0");
        assertApproxEqRel(balance_0, expected_0, 0.0005e18, "balance @ t0");

        t_1 = bound(t_1, _getNextCheckpoint(), t_0 + duration / 2);
        vm.warp(t_1);

        uint expected_1 = _getExpectedBalanceOf(tokenId);
        uint balance_1 = veHemi.balanceOfNFT(tokenId);
        assertApproxEqRel(balance_1, expected_1, 0.0005e18, "balance @ t1");
        assertEq(delegation.getVotes(alice), balance_1, "votes @ t1");
        assertEq(veHemi.totalVeHemiSupply(), balance_1, "supply @ t1");
        assertEq(veHemi.balanceOfNFTAt(tokenId, t_0), balance_0, "past balance @ t1");
        assertEq(veHemi.totalVeHemiSupplyAt(t_0), balance_0, " past supply @ t1");

        t_2 = bound(t_2, _getNextCheckpoint(), end - 1);
        vm.warp(t_2);

        assertEq(veHemi.balanceOfNFTAt(tokenId, t_1), balance_1, "past balance @ t2");
        assertEq(veHemi.totalVeHemiSupplyAt(t_1), balance_1, "past supply @ t2");
        assertEq(delegation.getPastVotes(alice, t_1), balance_1, "past votes @ t2");

        vm.warp(end + 1);

        assertEq(veHemi.balanceOfNFT(tokenId), 0, "balance not 0 after ending");
        assertEq(veHemi.totalVeHemiSupply(), 0, "supply not 0 after ending");
        assertEq(delegation.getVotes(alice), 0, "votes not 0 after ending");
    }
}

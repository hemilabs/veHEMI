// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StakedHemi.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("HEMI", "HEMI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakedHemiTest is Test {
    ERC20Mock hemi;
    StakedHemi stakedHemi;
    address user = address(0xBEEF);

    function setUp() public {
        hemi = new ERC20Mock();
        hemi.mint(user, 1_000 ether);

        // Deploy logic contract
        StakedHemi logic = new StakedHemi(address(hemi));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(StakedHemi.initialize.selector, address(this))
        );
        stakedHemi = StakedHemi(address(proxy));

        vm.prank(user);
        hemi.approve(address(stakedHemi), type(uint256).max);
    }

    function testCreateLock() public {
        uint256 amount = 100 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 * 365 days;

        vm.prank(user);
        stakedHemi.createLock(amount, unlockTime);

        // Check locked balance
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(user);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockedEnd, (unlockTime / stakedHemi.WEEK()) * stakedHemi.WEEK(), "Unlock time mismatch");

        // Check supply
        assertEq(stakedHemi.supply(), amount, "Supply mismatch");

        // Check event emission (optional, for advanced Foundry usage)
        // vm.expectEmit(true, true, true, true);
        // emit Deposit(user, amount, unlockTime, int128(1), block.timestamp);
    }

    function testCreateLockZeroAmountReverts() public {
        uint256 unlockTime = block.timestamp + 365 days;
        vm.prank(user);
        vm.expectRevert(StakedHemi.AmountIsZero.selector);
        stakedHemi.createLock(0, unlockTime);
    }

    function testCreateLockTwiceReverts() public {
        uint256 amount = 1 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        vm.prank(user);
        stakedHemi.createLock(amount, unlockTime);

        vm.prank(user);
        vm.expectRevert(StakedHemi.LockNotExpired.selector);
        stakedHemi.createLock(amount, unlockTime + 1 weeks);
    }

    function testCreateLockShortDurationReverts() public {
        uint256 amount = 1 ether;
        uint256 unlockTime = block.timestamp; // Not in future
        vm.prank(user);
        vm.expectRevert(StakedHemi.LockDurationTooShort.selector);
        stakedHemi.createLock(amount, unlockTime);
    }

    function testCreateLockTooLongReverts() public {
        uint256 amount = 1 ether;
        uint256 unlockTime = block.timestamp + (4 * 365 days) + 1 days;
        vm.prank(user);
        vm.expectRevert(StakedHemi.LockDurationTooLong.selector);
        stakedHemi.createLock(amount, unlockTime);
    }

    function testBalanceOfReturnsWeightedSupply() public {
        uint256 amount = 100 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 * 365 days;

        vm.prank(user);
        stakedHemi.createLock(amount, unlockTime);

        // Use contract's integer math: slope = amount / MAXTIME, bias = slope * (unlockTime - nowTs)
        uint256 slope = amount / stakedHemi.MAXTIME();
        uint256 bias = slope * (unlockTime - nowTs);
        uint256 expected = amount + (stakedHemi.VOTE_WEIGHT_MULTIPLIER() * bias);

        uint256 bal = stakedHemi.balanceOf(user);
        assertEq(bal, expected, "balanceOf weighted supply mismatch");
    }

    function testBalanceOfAtReturnsWeightedSupply() public {
        uint256 amount = 50 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 4 * 365 days;

        vm.prank(user);
        stakedHemi.createLock(amount, unlockTime);

        uint256 blockNum = block.number;

        // Use contract's integer math for the block where lock was created
        uint256 slope = amount / stakedHemi.MAXTIME();
        uint256 bias = slope * (unlockTime - nowTs);
        uint256 expected = amount + (stakedHemi.VOTE_WEIGHT_MULTIPLIER() * bias);

        uint256 balAt = stakedHemi.balanceOfAt(user, blockNum);
        assertEq(balAt, expected, "balanceOfAt weighted supply mismatch at lock");

        // Move forward 1 year and check again
        vm.warp(nowTs + 365 days);
        uint256 elapsed = 365 days;
        uint256 biasNow = slope * (unlockTime - (nowTs + elapsed));
        uint256 expectedNow = amount + (stakedHemi.VOTE_WEIGHT_MULTIPLIER() * biasNow);

        uint256 balNow = stakedHemi.balanceOf(user);
        assertEq(balNow, expectedNow, "balanceOf weighted supply mismatch after 1 year");
    }
}

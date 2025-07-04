// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/StakedHemi.sol";
import "../src/interfaces/IStakedHemi.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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

    uint256 MAX_TIME = 4 * 365 days;
    uint256 BALANCE_WHEN_MAX_TIME = 999171462654082575;
    uint256 BALANCE_WHEN_HALF_TIME = 495746805179602575;
    uint256 BALANCE_WHEN_1_YEAR = 24574680523842209090;
    uint256 WEEK = 7 days;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_NODE_URL"), vm.envUint("FORK_BLOCK_NUMBER"));
        hemi = new ERC20Mock();
        hemi.mint(user, 1_000 ether);

        // Deploy logic contract
        StakedHemi logic = new StakedHemi(address(hemi));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(StakedHemi.initialize.selector, address(this), address(0))
        );
        stakedHemi = StakedHemi(address(proxy));

        vm.prank(user);
        hemi.approve(address(stakedHemi), type(uint256).max);
    }

    function testCreateLock() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 * 365 days);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), user);

        // Check locked balance
        (
            int128 lockedAmount,
            uint256 lockExpiry,
            uint256 cooldownPeriod,
            ,
            bool cooldownStarted,

        ) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockExpiry, 0, "Unlock time mismatch");
        assertEq(cooldownPeriod, 2 * 365 days, "Cool down period mismatch");
        assertEq(cooldownStarted, false, "Cool down started mismatch");
        assertEq(stakedHemi.supply(), amount, "Supply mismatch");

        uint256 slope = amount / MAX_TIME;

        uint256 bias = slope * cooldownPeriod;

        uint256 veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        console.log(" testCreateLock ~ veHemiBalance:", veHemiBalance);
        assertEq(veHemiBalance, bias, "veHemi balance mismatch");
    }

    function testIncreaseCooldownPeriod() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 * 365 days);

        vm.warp(block.timestamp + 100 days);

        (int128 lockedAmountBefore, , uint256 cooldownPeriodBefore, , , ) = stakedHemi.locked(
            tokenId
        );

        console.log(" testIncreaseCooldownPeriod ~ _totalSupplyBefore:", stakedHemi.totalSupply());

        console.log(
            " testIncreaseCooldownPeriod ~ veHemiBalanceBefore:",
            stakedHemi.balanceOfNFT(tokenId)
        );
        vm.prank(user);
        stakedHemi.increaseCooldownPeriod(tokenId, 4 * 365 days);
        uint256 _totalSupplyAfter = stakedHemi.totalSupply();
        console.log(" testIncreaseCooldownPeriod ~ _totalSupplyAfter:", _totalSupplyAfter);

        // Check locked balance
        (
            int128 lockedAmount,
            uint256 lockExpiry,
            uint256 cooldownPeriod,
            ,
            bool cooldownStarted,

        ) = stakedHemi.locked(tokenId);
        assertEq(lockedAmountBefore, lockedAmount, "Locked amount mismatch");
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockExpiry, 0, "Unlock time mismatch");
        assertEq(cooldownPeriod, 4 * 365 days, "Cool down period mismatch");
        assertEq(cooldownStarted, false, "Cool down started mismatch");
        assertEq(stakedHemi.supply(), amount, "Supply mismatch");

        uint256 slope = amount / MAX_TIME;

        uint256 expectedBias = slope * cooldownPeriod;

        uint256 veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        console.log(" testCreateLock ~ veHemiBalanceAfter:", veHemiBalance);
        assertEq(veHemiBalance, expectedBias, "veHemi balance mismatch");

        assertGt(cooldownPeriod, cooldownPeriodBefore, "Cool down period not increased");
    }

    function testBalanceOfNFTWithoutCooldown() public {
        uint256 amount = 100 ether;

        uint256 cooldownPeriod = 2 * 365 days;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, cooldownPeriod);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), user);

        uint256 slope = amount / MAX_TIME;

        uint256 bias = slope * cooldownPeriod;

        uint256 veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        uint256 totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, bias, "veHemi balance mismatch");

        vm.warp(block.timestamp + 100 days);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, bias, "veHemi balance mismatch after 100 days");

        vm.warp(block.timestamp + 365 days);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, bias, "veHemi balance mismatch after 365 days");

        vm.warp(block.timestamp + cooldownPeriod);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, bias, "veHemi balance mismatch after cool down period");
    }

    function testCooldown() public {
        uint256 amount = 2 ether;

        uint256 cooldownPeriod = 2 * 365 days;

        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(amount, cooldownPeriod);
        vm.stopPrank();

        uint256 slope = amount / MAX_TIME;

        uint256 biasAtStart = slope * cooldownPeriod;

        uint256 veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        uint256 totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, biasAtStart, "veHemi balance mismatch");
        assertEq(totalSupply, veHemiBalance, "total supply wrong");

        vm.warp(block.timestamp + 100 days);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, biasAtStart, "veHemi balance mismatch after 100 days");
        assertEq(totalSupply, veHemiBalance, "total supply wrong after 100 days");

        vm.prank(user);
        stakedHemi.startCooldown(tokenId);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(totalSupply, veHemiBalance, "total supply wrong after 100 days");

        vm.warp(block.timestamp + 365 days);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(totalSupply, veHemiBalance, "total supply wrong after 365 days");
        assertApproxEqRel(
            veHemiBalance,
            (biasAtStart * 365 days) / cooldownPeriod,
            0.005e18,
            "veHemi balance mismatch after 365 days"
        );

        vm.warp(block.timestamp + cooldownPeriod);
        veHemiBalance = stakedHemi.balanceOfNFT(tokenId);
        totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance, 0, "veHemi balance mismatch after cool down period");

        assertEq(totalSupply, 0, "total supply wrong after cool down period");
    }

    function testMultipleLocksNoCooldown() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        uint256 tokenId1 = stakedHemi.createLock(amount, 4 * 365 days);
        uint256 tokenId2 = stakedHemi.createLock(amount, 2 * 365 days);
        vm.stopPrank();
        uint256 slope = amount / MAX_TIME;
        uint256 bias1 = slope * 4 * 365 days;
        uint256 bias2 = slope * 2 * 365 days;

        uint256 veHemiBalance1 = stakedHemi.balanceOfNFT(tokenId1);
        uint256 veHemiBalance2 = stakedHemi.balanceOfNFT(tokenId2);
        uint256 totalSupply = stakedHemi.totalSupply();
        assertEq(veHemiBalance1, bias1, "veHemi balance1 mismatch");
        assertEq(veHemiBalance2, bias2, "veHemi balance2 mismatch");
        assertEq(totalSupply, bias1 + bias2, "total supply wrong");
    }

    function testMultipleLocksWithOneCooldown() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        uint256 tokenId1 = stakedHemi.createLock(amount, 4 * 365 days);
        uint256 tokenId2 = stakedHemi.createLock(amount, 2 * 365 days);
        stakedHemi.startCooldown(tokenId2);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 slope = amount / MAX_TIME;
        uint256 bias1 = slope * 4 * 365 days;
        uint256 bias2 = slope * 365 days;

        uint256 veHemiBalance1 = stakedHemi.balanceOfNFT(tokenId1);
        uint256 veHemiBalance2 = stakedHemi.balanceOfNFT(tokenId2);
        console.log(" testMultipleLocksWithOneCooldown ~ veHemiBalance2:", veHemiBalance2);
        uint256 totalSupply = stakedHemi.totalSupply();
        console.log(" testMultipleLocksWithOneCooldown ~ totalSupply:", totalSupply);
        assertEq(veHemiBalance1, bias1, "veHemi balance1 mismatch");
        assertApproxEqRel(
            veHemiBalance2,
            BALANCE_WHEN_1_YEAR,
            0.005e18,
            "veHemi balance2 mismatch"
        );
        assertEq(totalSupply, bias1 + BALANCE_WHEN_1_YEAR, "total supply wrong");
    }

    function testWithdraw() public {
        uint256 amount = 50 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 weeks;

        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 weeks);

        // Fast forward past unlock
        vm.warp(unlockTime + 1);

        uint256 userBalanceBefore = hemi.balanceOf(user);

        vm.expectRevert(StakedHemi.CooldownNotStarted.selector);
        stakedHemi.withdraw(tokenId);

        stakedHemi.startCooldown(tokenId);

        vm.warp(block.timestamp + 2 weeks);

        stakedHemi.withdraw(tokenId);

        // NFT should be burned
        vm.expectRevert();
        stakedHemi.ownerOf(tokenId);

        // User should get tokens back
        uint256 userBalanceAfter = hemi.balanceOf(user);
        assertEq(userBalanceAfter, userBalanceBefore + amount, "Withdraw did not return tokens");

        // Lock should be cleared
        (int128 lockedAmount, uint256 lockedEnd, , , , ) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), 0, "Lock not cleared");
        assertEq(lockedEnd, 0, "Lock end not cleared");
    }

    function testNonTransferableNFT() public {
        uint256 amount = 1 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 1 weeks);

        // Attempt transferFrom
        vm.prank(user);
        vm.expectRevert("NFT is non-transferable");
        stakedHemi.transferFrom(user, address(0xABCD), tokenId);

        // Attempt approve
        vm.prank(user);
        vm.expectRevert("NFT is non-transferable");
        stakedHemi.approve(address(0xABCD), tokenId);

        // Attempt setApprovalForAll
        vm.prank(user);
        vm.expectRevert("NFT is non-transferable");
        stakedHemi.setApprovalForAll(address(0xABCD), true);

        // Attempt safeTransferFrom
        vm.prank(user);
        vm.expectRevert("NFT is non-transferable");
        stakedHemi.safeTransferFrom(user, address(0xABCD), tokenId);
    }

    function testERC721EnumerableFunctions() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        // User creates two locks (two NFTs)
        vm.prank(user);
        uint256 tokenId1 = stakedHemi.createLock(amount1, 1 weeks);

        vm.prank(user);
        uint256 tokenId2 = stakedHemi.createLock(amount2, 1 weeks);

        // Check balanceOf (number of NFTs owned)
        uint256 balance = stakedHemi.balanceOf(user);
        assertEq(balance, 2, "User should own 2 NFTs");

        // Check tokenOfOwnerByIndex
        uint256 foundTokenId1 = stakedHemi.tokenOfOwnerByIndex(user, 0);
        uint256 foundTokenId2 = stakedHemi.tokenOfOwnerByIndex(user, 1);
        assertTrue(
            (foundTokenId1 == tokenId1 && foundTokenId2 == tokenId2) ||
                (foundTokenId1 == tokenId2 && foundTokenId2 == tokenId1),
            "tokenOfOwnerByIndex should return both tokenIds"
        );

        // Check totalSupply increases
        uint256 total = stakedHemi.totalNftSupply();
        assertEq(total, 2, "Total supply should be 2");

        // Check ownerOf returns correct owner
        assertEq(stakedHemi.ownerOf(tokenId1), user, "Owner of tokenId1 should be user");
        assertEq(stakedHemi.ownerOf(tokenId2), user, "Owner of tokenId2 should be user");
    }

    function testIncreasesLockAmount() public {
        uint256 amount = 10 ether;
        uint256 extra = 5 ether;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 4 weeks);

        // Another user deposits for this lock
        address depositor = address(0xCAFE);
        hemi.mint(depositor, 100 ether);
        vm.prank(depositor);
        hemi.approve(address(stakedHemi), type(uint256).max);

        vm.prank(depositor);
        stakedHemi.increaseAmount(tokenId, extra);

        // Check locked amount increased
        (int128 lockedAmount, , , , , ) = stakedHemi.locked(tokenId);
        assertEq(
            uint256(uint128(lockedAmount)),
            amount + extra,
            "depositFor did not increase lock amount"
        );
    }

    function testIncreasesLockAmountWhenCooldownStarted() public {
        uint256 amount = 20 ether;
        uint256 extra = 7 ether;
        uint256 cooldownPeriod = 8 weeks;

        // User creates a lock
        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(amount, cooldownPeriod);

        vm.warp(block.timestamp + 10 days);

        uint256 biasBefore = stakedHemi.balanceOfNFT(tokenId);
        uint256 totalSupplyBefore = stakedHemi.totalSupply();

        // User increases their lock amount

        stakedHemi.startCooldown(tokenId);
        stakedHemi.increaseAmount(tokenId, extra);
        vm.stopPrank();

        // Check locked amount increased
        (int128 lockedAmount, , , , , ) = stakedHemi.locked(tokenId);

        assertEq(
            uint256(uint128(lockedAmount)),
            amount + extra,
            "increaseAmount did not increase lock amount"
        );
        assertGt(stakedHemi.balanceOfNFT(tokenId), biasBefore, "balance of nft did not increase");
        assertGt(stakedHemi.totalSupply(), totalSupplyBefore, "total supply did not increase");
    }

    function testCheckpointUpdatesUserPointHistory() public {
        uint256 amount_ = 10 ether;
        // User creates a lock
        vm.prank(user);
        uint256 tokenId_ = stakedHemi.createLock(amount_, 4 * 52 weeks);

        // Call checkpoint with old and new locked (simulate increase)
        uint256 extraAmount_ = 1 ether;

        // Only owner can call internal, so use a helper or make _checkpoint public for testing
        vm.prank(address(stakedHemi));

        // User epoch should increase
        uint256 userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 1, "User epoch not incremented");
        vm.warp(block.timestamp + 50 weeks); // Simulate time passing
        stakedHemi.checkpoint();
        assertEq(stakedHemi.epoch(), 52, "Global epoch should be 52 after checkpoint");

        vm.prank(user);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testCheckpointUpdatesUserPointHistory ~ userEpochAfter_:", userEpochAfter_);
        assertEq(userEpochAfter_, 2, "User epoch not incremented");

        // User point history should be updated
        StakedHemi.Point memory pt_ = stakedHemi.getUserPoint(tokenId_, userEpochAfter_);
        assertEq(pt_.amount, uint256(uint128(amount_ + extraAmount_)), "User point not updated");
    }

    function testEpoch() public {
        uint256 amount_ = 10 ether;
        // User creates a lock
        vm.startPrank(user);

        uint256 initialWeekNumber = block.timestamp / stakedHemi.WEEK();

        console.log("initialWeekNumber", initialWeekNumber);
        uint256 tokenId_ = stakedHemi.createLock(amount_, 4 * 52 weeks);
        uint256 userEpochBefore = stakedHemi.userPointEpoch(tokenId_);
        assertEq(userEpochBefore, 1, "user epoch not 1");
        // Increase amount through normal methods
        uint256 extraAmount_ = 5 ether;

        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        uint256 expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        uint256 newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);
        // assertEq(newUserEpoch_, 2, "user epoch not incremented");

        vm.warp(block.timestamp + 8 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 12 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 15 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 16 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 19 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 23 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 29 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 39 weeks);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 49 weeks);
        vm.roll(block.number + 1);
        stakedHemi.createLock(amount_, 4 * 52 weeks);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 71 weeks);
        vm.roll(block.number + 1);
        stakedHemi.createLock(amount_, 4 * 52 weeks);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 75 weeks);
        vm.roll(block.number + 1);
        stakedHemi.createLock(amount_, 4 * 52 weeks);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        vm.warp(block.timestamp + 91 weeks);
        vm.roll(block.number + 1);
        stakedHemi.createLock(amount_, 4 * 52 weeks);
        expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        console.log(" testEpoch ~ expectedGlobalEpoch:", expectedGlobalEpoch);
        console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        console.log("global epoch", stakedHemi.epoch());
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented");
        newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testEpoch ~ newUserEpoch_:", newUserEpoch_);

        // assertEq(newUserEpoch_, 2, "user epoch not incremented");

        // console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        // newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        // assertEq(newUserEpoch_, 3, "user epoch not incremented");
        // expectedGlobalEpoch = block.timestamp / stakedHemi.WEEK() - initialWeekNumber;
        // console.log("current week", (block.timestamp / stakedHemi.WEEK()));
        // assertEq(stakedHemi.epoch(), expectedGlobalEpoch, "global epoch not incremented");

        // vm.warp(block.timestamp + 5 weeks);
        // stakedHemi.increaseAmount(tokenId_, extraAmount_);
        // newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        // assertEq(newUserEpoch_, 2, "user epoch not incremented");
        // assertEq(stakedHemi.epoch(), 7, "global epoch not incremented");
    }

    function testIncreaseUnlockTimeRevertsIfNotOwner() public {
        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);
        vm.stopPrank();

        // Try from another address
        vm.startPrank(address(0xA));
        vm.expectRevert(StakedHemi.NotOwner.selector);
        stakedHemi.increaseCooldownPeriod(tokenId, 2 * 365 days);
        vm.stopPrank();
    }

    function testIncreaseUnlockTimeRevertsIfNotGreater() public {
        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);
        // Try to set to the same or lower end
        vm.expectRevert(StakedHemi.CooldownPeriodTooShort.selector);
        stakedHemi.increaseCooldownPeriod(tokenId, 100 days);
        vm.stopPrank();
    }

    function testBalanceOfNFT() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 4 weeks;
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, lockDuration);

        // Should return the full amount right after creation
        uint256 bal = stakedHemi.balanceOfNFT(tokenId);
        assertGt(bal, 0, "balanceOfNFT should be > 0 after lock");
        assertLe(bal, amount, "balanceOfNFT should not exceed locked amount");
        vm.prank(user);
        stakedHemi.startCooldown(tokenId);

        // Fast forward to after expiry
        vm.warp(block.timestamp + lockDuration + 1);
        bal = stakedHemi.balanceOfNFT(tokenId);
        assertEq(bal, 0, "balanceOfNFT should be 0 after lock expires");
    }

    function testBalanceOfNFTAt() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 4 weeks;
        uint256 start = block.timestamp;
        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(amount, lockDuration);
        stakedHemi.startCooldown(tokenId);
        vm.stopPrank();

        // At creation time
        uint256 balAtStart = stakedHemi.balanceOfNFTAt(tokenId, start);
        assertLt(balAtStart, amount, "balanceOfNFTAt should not exceed locked amount");

        // Halfway through lock
        uint256 half = start + lockDuration / 2;
        uint256 balAtHalf = stakedHemi.balanceOfNFTAt(tokenId, half);
        assertGt(balAtHalf, 0, "balanceOfNFTAt should be > 0 halfway");
        assertLt(balAtHalf, balAtStart, "balanceOfNFTAt should decrease over time");

        // After expiry
        uint256 afterExpiry = start + lockDuration + 1;
        uint256 balAfter = stakedHemi.balanceOfNFTAt(tokenId, afterExpiry);
        assertEq(balAfter, 0, "balanceOfNFTAt should be 0 after expiry");
    }

    function testUpdateRewardDistributor() public {
        address newRewardDistributor = address(0x1234);

        // Only owner should be able to call this
        vm.prank(user);
        vm.expectRevert();
        stakedHemi.updateRewardDistributor(newRewardDistributor);

        // Owner should be able to update
        vm.prank(address(this)); // address(this) is the owner from setUp
        stakedHemi.updateRewardDistributor(newRewardDistributor);

        // Check that the reward distributor was updated
        assertEq(address(stakedHemi.rewardDistributor()), newRewardDistributor);
    }

    function testUpdateRewardDistributorToZero() public {
        // Owner should be able to set to zero address
        vm.prank(address(this));
        stakedHemi.updateRewardDistributor(address(0));

        // Check that the reward distributor was set to zero
        assertEq(address(stakedHemi.rewardDistributor()), address(0));
    }

    function testTotalSupply() public {
        // Initially should be 0
        assertEq(stakedHemi.totalSupply(), 0, "Initial total supply should be 0");
        uint256 amount = 100 ether;
        vm.prank(user);
        uint256 tokenId1 = stakedHemi.createLock(amount, MAX_TIME);

        uint256 balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId1);
        uint256 expectedBalanceOfTokenId1 = (amount / MAX_TIME) * (MAX_TIME);

        assertEq(balanceOfTokenId1, expectedBalanceOfTokenId1, "user1 nft balance is not correct");
        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1,
            "Total supply should equal locked amount"
        );

        // Create another lock
        address user2 = address(0xCAFE);
        hemi.mint(user2, amount);
        vm.prank(user2);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(user2);
        uint256 tokenId2 = stakedHemi.createLock(amount, MAX_TIME / 2);
        uint256 balanceOfTokenId2 = stakedHemi.balanceOfNFT(tokenId2);
        uint256 expectedBalanceOfTokenId2 = (amount / MAX_TIME) * (MAX_TIME / 2);
        assertEq(balanceOfTokenId2, expectedBalanceOfTokenId2, "user2 nft balance is not correct");

        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );
        vm.prank(user2);
        stakedHemi.startCooldown(tokenId2);
        vm.prank(user);
        stakedHemi.startCooldown(tokenId1);
        vm.warp(block.timestamp + 1 * 365 days);
        balanceOfTokenId2 = stakedHemi.balanceOfNFT(tokenId2);
        balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId1);
        assertEq(
            balanceOfTokenId2,
            BALANCE_WHEN_1_YEAR,
            "user2 nft balance is not correct after time travel"
        );
        assertGt(balanceOfTokenId1, 0, "Total supply should equal locked amount");

        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );
    }

    function testSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(stakedHemi.totalSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        vm.prank(user);
        stakedHemi.createLock(100 ether, MAX_TIME);

        uint256 expectedTotalSupply = (100 ether / MAX_TIME) * (MAX_TIME);

        // At creation time
        assertEq(
            stakedHemi.totalSupplyAt(startTime),
            expectedTotalSupply,
            "Total supply at creation should be locked amount"
        );

        // At future time (before expiry)
        uint256 futureTime = startTime + (2 * 365 days);
        assertEq(
            stakedHemi.totalSupplyAt(futureTime),
            expectedTotalSupply,
            "Total supply should remain same if no cooldown"
        );

        // After expiry
        uint256 afterExpiry = startTime + MAX_TIME + 1;
        assertEq(
            stakedHemi.totalSupplyAt(afterExpiry),
            expectedTotalSupply,
            "Total supply should remains same if no cooldown"
        );
    }

    function testPastSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(stakedHemi.totalSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        vm.prank(user);
        stakedHemi.createLock(1 ether, MAX_TIME);

        vm.warp(block.timestamp + 100 days);

        uint256 timestamp_ = block.timestamp;

        uint256 supplyAt_ = stakedHemi.totalSupply();

        vm.warp(block.timestamp + 200 days);

        // At creation time
        assertEq(stakedHemi.totalSupplyAt(timestamp_), supplyAt_, "Total at past is not correct");
    }
}

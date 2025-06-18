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
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(logic), abi.encodeWithSelector(StakedHemi.initialize.selector, address(this)));
        stakedHemi = StakedHemi(address(proxy));

        vm.prank(user);
        hemi.approve(address(stakedHemi), type(uint256).max);
    }

    function testCreateLock() public {
        uint256 amount = 100 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 * 365 days;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), user);

        // Check locked balance
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockedEnd, (unlockTime / stakedHemi.WEEK()) * stakedHemi.WEEK(), "Unlock time mismatch");

        // Check supply
        assertEq(stakedHemi.supply(), amount, "Supply mismatch");
    }

    function testWithdraw() public {
        uint256 amount = 50 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 weeks;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

        // Fast forward past unlock
        vm.warp(unlockTime + 1);

        uint256 userBalanceBefore = hemi.balanceOf(user);

        vm.prank(user);
        stakedHemi.withdraw(tokenId);

        // NFT should be burned
        vm.expectRevert();
        stakedHemi.ownerOf(tokenId);

        // User should get tokens back
        uint256 userBalanceAfter = hemi.balanceOf(user);
        assertEq(userBalanceAfter, userBalanceBefore + amount, "Withdraw did not return tokens");

        // Lock should be cleared
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), 0, "Lock not cleared");
        assertEq(lockedEnd, 0, "Lock end not cleared");
    }

    function testNonTransferableNFT() public {
        uint256 amount = 1 ether;
        uint256 unlockTime = block.timestamp + 1 weeks;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

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
        uint256 unlockTime = block.timestamp + 1 weeks;

        // User creates two locks (two NFTs)
        vm.prank(user);
        uint256 tokenId1 = stakedHemi.createLock(amount1, unlockTime);

        vm.prank(user);
        uint256 tokenId2 = stakedHemi.createLock(amount2, unlockTime + 1 weeks);

        // Check balanceOf (number of NFTs owned)
        uint256 balance = stakedHemi.balanceOf(user);
        assertEq(balance, 2, "User should own 2 NFTs");

        // Check tokenOfOwnerByIndex
        uint256 foundTokenId1 = stakedHemi.tokenOfOwnerByIndex(user, 0);
        uint256 foundTokenId2 = stakedHemi.tokenOfOwnerByIndex(user, 1);
        assertTrue(
            (foundTokenId1 == tokenId1 && foundTokenId2 == tokenId2)
                || (foundTokenId1 == tokenId2 && foundTokenId2 == tokenId1),
            "tokenOfOwnerByIndex should return both tokenIds"
        );

        // Check totalSupply increases
        uint256 total = stakedHemi.totalSupply();
        assertEq(total, 2, "Total supply should be 2");

        // Check ownerOf returns correct owner
        assertEq(stakedHemi.ownerOf(tokenId1), user, "Owner of tokenId1 should be user");
        assertEq(stakedHemi.ownerOf(tokenId2), user, "Owner of tokenId2 should be user");
    }

    function testDepositForIncreasesLockAmount() public {
        uint256 amount = 10 ether;
        uint256 extra = 5 ether;
        uint256 unlockTime = block.timestamp + 4 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

        // Another user deposits for this lock
        address depositor = address(0xCAFE);
        hemi.mint(depositor, 100 ether);
        vm.prank(depositor);
        hemi.approve(address(stakedHemi), type(uint256).max);

        vm.prank(depositor);
        stakedHemi.depositFor(tokenId, extra);

        // Check locked amount increased
        (int128 lockedAmount,) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount + extra, "depositFor did not increase lock amount");
    }

    function testIncreaseAmountIncreasesLockAmount() public {
        uint256 amount = 20 ether;
        uint256 extra = 7 ether;
        uint256 unlockTime = block.timestamp + 8 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

        // User increases their lock amount
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId, extra);

        // Check locked amount increased
        (int128 lockedAmount,) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount + extra, "increaseAmount did not increase lock amount");
    }

    function testCheckpointUpdatesUserPointHistory() public {
        uint256 amount_ = 10 ether;
        uint256 unlockTime_ = block.timestamp + 4 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId_ = stakedHemi.createLock(amount_, unlockTime_);

        // Get user epoch before checkpoint
        uint256 userEpochBefore_ = stakedHemi.userPointEpoch(tokenId_);

        // Call checkpoint with old and new locked (simulate increase)
        (int128 oldAmount_, uint256 oldEnd_) = stakedHemi.locked(tokenId_);
        StakedHemi.LockedBalance memory oldLocked_ = StakedHemi.LockedBalance(oldAmount_, oldEnd_);
        StakedHemi.LockedBalance memory newLocked_ =
            StakedHemi.LockedBalance(oldAmount_ + int128(int256(1 ether)), oldEnd_);

        // Only owner can call internal, so use a helper or make _checkpoint public for testing
        vm.prank(address(stakedHemi));
        stakedHemi.checkpoint();

        // User epoch should increase
        uint256 userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        console2.log(" testCheckpointUpdatesUserPointHistory ~ userEpochAfter_:", userEpochAfter_);
        assertEq(userEpochAfter_, 1, "User epoch not incremented");

        // User point history should be updated
        StakedHemi.Point memory pt_ = stakedHemi.getUserPoint(tokenId_, userEpochAfter_);
        assertEq(pt_.amount, uint256(uint128(newLocked_.amount)), "User point not updated");
    }

    function testCheckpoint() public {
        uint256 amount_ = 10 ether;
        uint256 unlockTime_ = block.timestamp + 52 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId_ = stakedHemi.createLock(amount_, unlockTime_);

        // Get user epoch after lock creation
        uint256 userEpoch_ = stakedHemi.userPointEpoch(tokenId_);

        // Store initial values for later comparison
        uint256 initialHemiAmount_ = amount_;

        // Increase amount through normal methods
        uint256 extraAmount_ = 5 ether;
        // vm.warp(block.timestamp + 10 weeks); // Simulate time passing
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);

        // User epoch should increase
        uint256 newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testCheckpoint ~ newUserEpoch_:", newUserEpoch_);
        assertEq(newUserEpoch_, userEpoch_ + 1, "User epoch not incremented");

        // Get the locked balance to verify it increased
        (int128 lockedAmount_,) = stakedHemi.locked(tokenId_);
        assertEq(uint256(uint128(lockedAmount_)), amount_ + extraAmount_, "Locked amount not updated correctly");

        // Check global state
        uint256 globalEpoch_ = stakedHemi.epoch();
        assertTrue(globalEpoch_ > 0, "Global epoch should be updated");
    }
}

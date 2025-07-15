// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/StakedHemi.sol";
import "../src/interfaces/IStakedHemi.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../src/interfaces/IHemiVoteDelegation.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

contract StakedHemiTest is Test {
    MockERC20 hemi;
    StakedHemi stakedHemi;
    MockHemiVoteDelegation mockDelegation;
    address user = address(0xBEEF);
    address alice = address(0x1122);
    address bob = address(0x3344);
    address charlie = address(0x5566);

    uint256 MAX_TIME = 4 * 365 days;
    uint256 WEEK = 7 days;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        hemi.mint(user, 1_000 ether);
        hemi.mint(alice, 1_000 ether);
        hemi.mint(bob, 1_000 ether);
        hemi.mint(charlie, 1_000 ether);

        // Deploy logic contract
        StakedHemi logic = new StakedHemi(address(hemi));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(StakedHemi.initialize.selector, address(this), address(0))
        );
        stakedHemi = StakedHemi(address(proxy));

        // Deploy and set mock delegation contract
        mockDelegation = new MockHemiVoteDelegation();
        vm.prank(address(this));
        stakedHemi.updateVoteDelegation(IHemiVoteDelegation(address(mockDelegation)));

        vm.prank(user);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(alice);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(bob);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(charlie);
        hemi.approve(address(stakedHemi), type(uint256).max);
    }

    function testCreateLock() public {
        uint256 amount = 100 ether;
        uint256 currentTimestamp = block.timestamp;
        uint256 lockDuration = 2 * 365 days;
        uint256 unlockTime = currentTimestamp + lockDuration;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, lockDuration);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), user);

        // Check locked balance
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockedEnd, (unlockTime / WEEK) * WEEK, "Unlock time mismatch");
        // Check supply
        assertEq(stakedHemi.totalLocked(), amount, "Supply mismatch");
    }

    function testCreateLockFor() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLockFor(amount, 2 * 365 days, alice, true);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), alice);
    }

    function testWithdraw() public {
        uint256 amount = 50 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 weeks);

        // Fast forward past unlock
        vm.warp(block.timestamp + 2 weeks + 1);

        uint256 userBalanceBefore = hemi.balanceOf(user);

        vm.prank(user);
        stakedHemi.withdraw(tokenId);

        // NFT should be burned
        vm.expectRevert();
        stakedHemi.ownerOf(tokenId);

        assertEq(
            hemi.balanceOf(user),
            userBalanceBefore + amount,
            "Withdraw did not return tokens"
        );

        // Lock should be cleared
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), 0, "Lock not cleared");
        assertEq(lockedEnd, 0, "Lock end not cleared");
    }

    function testNonTransferableNFT() public {
        uint256 amount = 1 ether;

        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLockFor(amount, 1 weeks, alice, false);

        vm.expectRevert("NFT is non-transferable");
        stakedHemi.transferFrom(user, address(0xABCD), tokenId);

        vm.expectRevert("NFT is non-transferable");
        stakedHemi.safeTransferFrom(user, address(0xABCD), tokenId);
        vm.stopPrank();
    }

    function testERC721EnumerableFunctions() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        // User creates two locks (two NFTs)
        vm.startPrank(user);
        uint256 tokenId1 = stakedHemi.createLock(amount1, 1 weeks);
        uint256 tokenId2 = stakedHemi.createLock(amount2, 1 weeks);
        vm.stopPrank();

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

    function testDepositForIncreasesLockAmount() public {
        uint256 amount = 10 ether;
        uint256 extra = 5 ether;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 4 weeks);

        // Another user deposits for this lock
        address depositor = address(0xCAFE);
        hemi.mint(depositor, 100 ether);
        vm.startPrank(depositor);
        hemi.approve(address(stakedHemi), type(uint256).max);
        stakedHemi.increaseAmount(tokenId, extra);
        vm.stopPrank();

        // Check locked amount increased
        (int128 lockedAmount, ) = stakedHemi.locked(tokenId);
        assertEq(
            uint256(uint128(lockedAmount)),
            amount + extra,
            "depositFor did not increase lock amount"
        );
    }

    function testCheckpointUpdatesUserPointHistory() public {
        uint256 amount_ = 10 ether;
        // User creates a lock
        vm.prank(user);
        uint256 tokenId_ = stakedHemi.createLock(amount_, 4 * 52 weeks);

        // Call checkpoint with old and new locked (simulate increase)
        (int128 oldAmount_, uint256 oldEnd_) = stakedHemi.locked(tokenId_);
        uint256 extraAmount_ = 1 ether;

        // User epoch should increase
        uint256 userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 1, "User epoch not incremented");
        vm.warp(block.timestamp + 50 weeks); // Simulate time passing
        stakedHemi.checkpoint();
        assertEq(stakedHemi.epoch(), 52, "Global epoch should be 52 after checkpoint");
        IStakedHemi.LockedBalance memory newLocked_ = IStakedHemi.LockedBalance(
            oldAmount_ + int128(int256(extraAmount_)),
            uint64(oldEnd_)
        );
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 2, "User epoch not incremented");

        // User point history should be updated
        StakedHemi.Point memory pt_ = stakedHemi.getUserPoint(tokenId_, userEpochAfter_);
        assertEq(pt_.amount, uint256(uint128(newLocked_.amount)), "User point not updated");
    }

    function testEpoch() public {
        uint256 amount_ = 10 ether;
        // User creates a lock
        vm.startPrank(user);

        uint256 initialWeekNumber = block.timestamp / WEEK;

        uint256 tokenId_ = stakedHemi.createLock(amount_, 4 * 52 weeks);
        uint256 userEpochBefore = stakedHemi.userPointEpoch(tokenId_);
        assertEq(userEpochBefore, 1, "user epoch not 1");
        // Increase amount through normal methods
        uint256 extraAmount_ = 5 ether;

        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 1);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        uint256 expectedGlobalEpoch = block.timestamp / WEEK - initialWeekNumber;
        assertEq(stakedHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented1");
        uint256 newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        assertEq(newUserEpoch_, 2, "user epoch not incremented");
    }

    function testIncreaseUnlockTime() public {
        vm.startPrank(user);

        // Create a lock for 1 year
        uint256 amount = 100 ether;
        uint256 oneYear = 365 days;
        uint256 tokenId = stakedHemi.createLock(amount, oneYear);

        // Fast forward half a year
        vm.warp(block.timestamp + 182 days);

        // Try to increase unlock time by another year
        uint256 newDuration = 2 * 365 days; // 2 years from now
        stakedHemi.increaseUnlockTime(tokenId, newDuration);

        // Check that the lock's end is updated
        (, uint256 end) = stakedHemi.locked(tokenId);
        uint256 expectedUnlockTime = ((block.timestamp + newDuration) / WEEK) * WEEK;
        assertEq(end, expectedUnlockTime);

        vm.stopPrank();
    }

    function testIncreaseUnlockTimeRevertsIfNotOwner() public {
        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);
        vm.stopPrank();

        // Try from another address
        vm.startPrank(address(0xA));
        vm.expectRevert(StakedHemi.NotOwner.selector);
        stakedHemi.increaseUnlockTime(tokenId, 2 * 365 days);
        vm.stopPrank();
    }

    function testIncreaseUnlockTimeRevertsIfNotGreater() public {
        vm.startPrank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);
        // Try to set to the same or lower end
        vm.expectRevert(StakedHemi.NewLockDurationNotGreater.selector);
        stakedHemi.increaseUnlockTime(tokenId, 100 days);
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

        // Fast forward to after expiry
        vm.warp(block.timestamp + lockDuration + 1);
        bal = stakedHemi.balanceOfNFT(tokenId);
        assertEq(bal, 0, "balanceOfNFT should be 0 after lock expires");
        assertEq(stakedHemi.totalSupply(), 0, "totalSupply should be 0 after lock expires");
    }

    function testBalanceOfNFTAt() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 4 weeks;
        uint256 start = block.timestamp;
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, lockDuration);

        // At creation time
        uint256 balAtStart = stakedHemi.balanceOfNFTAt(tokenId, start);
        assertGt(balAtStart, 0, "balanceOfNFTAt should be > 0 at start");
        assertLe(balAtStart, amount, "balanceOfNFTAt should not exceed locked amount");

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
        IRewardDistributor newRewardDistributor = IRewardDistributor(address(0x1234));

        // Only owner should be able to call this
        vm.prank(user);
        vm.expectRevert();
        stakedHemi.updateRewardDistributor(newRewardDistributor);

        // Owner should be able to update
        vm.prank(address(this)); // address(this) is the owner from setUp
        stakedHemi.updateRewardDistributor(newRewardDistributor);

        // Check that the reward distributor was updated
        assertEq(address(stakedHemi.rewardDistributor()), address(newRewardDistributor));
    }

    function testUpdateRewardDistributorToZero() public {
        // Owner should be able to set to zero address
        vm.prank(address(this));
        stakedHemi.updateRewardDistributor(IRewardDistributor(address(0)));

        // Check that the reward distributor was set to zero
        assertEq(address(stakedHemi.rewardDistributor()), address(0));
    }

    function testTotalSupply() public {
        // Initially should be 0
        assertEq(stakedHemi.totalSupply(), 0, "Initial total supply should be 0");
        uint256 amountIn = 1 ether;
        uint256 lockDuration = MAX_TIME;
        uint256 user1Slope = amountIn / MAX_TIME;

        vm.prank(user);
        uint256 tokenId1 = stakedHemi.createLock(1 ether, lockDuration);
        uint256 expectedBalance = user1Slope *
            (stakedHemi.getLockedBalance(tokenId1).end - block.timestamp);

        uint256 balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId1, expectedBalance, "user1 nft balance is not correct");
        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1,
            "Total supply should equal locked amount"
        );

        // Create another lock
        address user2 = address(0xCAFE);
        hemi.mint(user2, amountIn);
        vm.prank(user2);
        hemi.approve(address(stakedHemi), type(uint256).max);
        uint256 user2LockDuration = MAX_TIME / 2;
        uint256 user2Slope = amountIn / MAX_TIME;
        vm.prank(user2);
        uint256 tokenId2 = stakedHemi.createLock(amountIn, user2LockDuration);
        uint256 expectedBalance2 = user2Slope *
            (stakedHemi.getLockedBalance(tokenId2).end - block.timestamp);
        uint256 balanceOfTokenId2 = stakedHemi.balanceOfNFT(tokenId2);
        assertEq(balanceOfTokenId2, expectedBalance2, "user2 nft balance is not correct");

        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );

        vm.warp(block.timestamp + 1 * 365 days);

        expectedBalance2 =
            user2Slope *
            (stakedHemi.getLockedBalance(tokenId2).end - block.timestamp);
        balanceOfTokenId2 = stakedHemi.balanceOfNFT(tokenId2);
        balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId2, expectedBalance2, "user2 nft balance is not correct");
        assertGt(balanceOfTokenId1, 0, "Total supply should equal locked amount");

        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );
    }

    function testSupplyAt() public {
        uint256 startTime = block.timestamp;
        uint256 amountIn = 1 ether;
        uint256 lockDuration = MAX_TIME;
        uint256 slope = amountIn / lockDuration;

        // Initially should be 0
        assertEq(stakedHemi.totalSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(1 ether, MAX_TIME);

        uint256 expectedBalance = slope *
            (stakedHemi.getLockedBalance(tokenId).end - block.timestamp);

        // At creation time
        assertEq(
            stakedHemi.totalSupplyAt(startTime),
            expectedBalance,
            "Total supply at creation should be locked amount"
        );

        // At future time (before expiry)
        uint256 futureTime = startTime + (2 * 365 days);
        expectedBalance = slope * (stakedHemi.getLockedBalance(tokenId).end - futureTime);
        assertEq(
            stakedHemi.totalSupplyAt(futureTime),
            expectedBalance,
            "Total supply should remain same before expiry"
        );

        // After expiry
        uint256 afterExpiry = startTime + MAX_TIME + 1;
        assertEq(stakedHemi.totalSupplyAt(afterExpiry), 0, "Total supply should be 0 after expiry");
    }

    function testPastSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(stakedHemi.totalSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        vm.prank(user);
        stakedHemi.createLock(1 ether, MAX_TIME);

        vm.warp(block.timestamp + 100 days);
        uint256 t1 = block.timestamp;
        uint256 supplyAtT1 = stakedHemi.totalSupply();
        vm.warp(block.timestamp + 200 days);

        vm.prank(user);
        stakedHemi.createLock(1 ether, MAX_TIME);
        vm.warp(block.timestamp + 10);

        // At creation time
        assertEq(stakedHemi.totalSupplyAt(t1), supplyAtT1, "Total at past is not correct");
    }

    function testPastSupplyAtBlock() public {
        uint256 blockNumber = block.number;

        // Initially should be 0
        assertEq(
            stakedHemi.totalSupplyAtBlock(blockNumber - 1),
            0,
            "Initial total supply should be 0"
        );

        // Create a lock
        vm.prank(user);
        stakedHemi.createLock(1 ether, MAX_TIME);
        uint256 b1 = block.number;
        uint256 supplyAtT1 = stakedHemi.totalSupply();

        vm.warp(block.timestamp + 200 days);
        vm.roll(block.number + (200 days / 10));

        vm.prank(user);
        stakedHemi.createLock(1 ether, MAX_TIME);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);

        assertEq(stakedHemi.totalSupplyAtBlock(b1), supplyAtT1, "Total at past is not correct");
    }

    // --- Transfer Control Tests ---

    function testTransferNotAllowedFlag() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLockFor(amount, 2 * 365 days, alice, false);

        // Check that transfer is not allowed
        assertFalse(stakedHemi.isTransferable(tokenId), "Token should not be transferable");
    }

    function testTransferAfterExpiry() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLockFor(amount, 2 * 365 days, alice, false);

        // Check that transfer is not allowed
        assertFalse(stakedHemi.isTransferable(tokenId), "Token should not be transferable");

        vm.warp(block.timestamp + 2 * 365 days + 1);
        assertTrue(stakedHemi.isTransferable(tokenId), "Token should be transferable");

        vm.prank(alice);
        stakedHemi.transferFrom(alice, bob, tokenId);
        assertEq(stakedHemi.ownerOf(tokenId), bob, "Token should be transferred to john");
    }

    function testTransferAllowedByDefault() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 * 365 days);

        // Check that transfer is allowed by default
        assertTrue(stakedHemi.isTransferable(tokenId), "Token should be transferable by default");
    }

    function testExtendLockShouldNotExtendTransferable() public {
        uint256 amount = 100 ether;
        uint256 firstLockDuration = 2 * 365 days;
        uint256 newLockDuration = 3 * 365 days;
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLockFor(amount, firstLockDuration, alice, false);
        assertFalse(stakedHemi.isTransferable(tokenId), "Token should not be transferable");

        vm.prank(alice);
        stakedHemi.increaseUnlockTime(tokenId, newLockDuration);

        vm.warp(block.timestamp + firstLockDuration + 1);
        assertTrue(stakedHemi.isTransferable(tokenId), "Token should be transferable by default");

        vm.prank(alice);
        stakedHemi.transferFrom(alice, bob, tokenId);
        assertEq(stakedHemi.ownerOf(tokenId), bob, "Token should be transferred to bob");

        assertGt(
            stakedHemi.getLockedBalance(tokenId).end,
            block.timestamp,
            "Lock should be extended"
        );
    }

    function testTransferFrom_CallsDelegateToSelf() public {
        // Create a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 1 weeks);

        // First, delegate the token to another token
        vm.prank(user);
        mockDelegation.delegate(tokenId, 999);

        // Transfer token to alice
        vm.prank(user);
        stakedHemi.transferFrom(user, alice, tokenId);

        // Check that delegation was updated in the mock
        assertEq(
            mockDelegation.delegation(tokenId).delegatee,
            tokenId,
            "Delegation should move to self on transfer"
        );
    }

    function testTransferFrom_DelegationMovesToSelf_WhenNoPreviousDelegation() public {
        // Switch to real delegation contract for this test
        // Create a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 1 weeks);

        // Transfer token to alice
        vm.prank(user);
        stakedHemi.transferFrom(user, alice, tokenId);

        // Check that delegation was updated in the mock
        assertEq(
            mockDelegation.delegation(tokenId).delegatee,
            0,
            "Delegation should move to self on transfer"
        );
    }

    function testTransferFrom_WhenTokenIsExpired() public {
        // Switch to real delegation contract for this test
        // Create a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 1 weeks);

        // First, delegate the token to another token (alice's token)
        vm.prank(user);
        mockDelegation.delegate(tokenId, 999); // Delegate to a non-existent token for testing

        vm.warp(block.timestamp + 1 weeks + 1);
        // Transfer token to alice
        vm.prank(user);
        stakedHemi.transferFrom(user, alice, tokenId);

        assertEq(stakedHemi.ownerOf(tokenId), alice, "Token should be transferred to alice");
    }

    function testTransferFrom_WhenVoteDelegationContractIsNotSet() public {
        // Remove vote delegation contract
        vm.prank(address(this));
        stakedHemi.updateVoteDelegation(IHemiVoteDelegation(address(0)));

        // Create locks
        vm.prank(user);
        uint256 userTokenId = stakedHemi.createLock(100 ether, 2 * 365 days);

        // User transfers token to Alice
        vm.prank(user);
        stakedHemi.transferFrom(user, alice, userTokenId);

        // Verify token ownership changed
        assertEq(stakedHemi.ownerOf(userTokenId), alice, "Token should be transferred to Alice");
    }
}

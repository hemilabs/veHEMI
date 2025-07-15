// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("HEMI", "HEMI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VeHemiTest is Test {
    ERC20Mock hemi;
    VeHemi veHemi;
    address user = address(0xBEEF);
    address alice = address(0x1122);

    uint256 MAX_TIME = 4 * 365 days;
    uint256 MAX_AMOUNT = 1_000 ether;
    uint256 WEEK = 7 days;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    function setUp() public {
        hemi = new ERC20Mock();
        hemi.mint(user, MAX_AMOUNT);

        // Deploy logic contract
        VeHemi logic = new VeHemi(address(hemi));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this), address(0))
        );
        veHemi = VeHemi(address(proxy));

        vm.prank(user);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    function createLock(
        address account_,
        uint256 amount_,
        uint256 duration_
    ) public returns (uint256 _tokenId, uint256 _slope, uint256 _end) {
        vm.startPrank(account_);
        hemi.mint(account_, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        _tokenId = veHemi.createLock(amount_, duration_);
        vm.stopPrank();
        _slope = amount_ / MAX_TIME;
        _end = veHemi.getLockedBalance(_tokenId).end;
    }

    function testCreateLock() public {
        uint256 amount = 100 ether;
        uint256 currentTimestamp = block.timestamp;
        uint256 lockDuration = 2 * 365 days;
        uint256 unlockTime = currentTimestamp + lockDuration;

        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        // Check NFT ownership
        assertEq(veHemi.ownerOf(tokenId), user);

        // Check locked balance
        (int128 lockedAmount, uint256 lockedEnd) = veHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockedEnd, (unlockTime / WEEK) * WEEK, "Unlock time mismatch");
        // Check supply
        assertEq(veHemi.totalLocked(), amount, "Supply mismatch");
    }

    function testCreateLockFor() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, alice, true);

        // Check NFT ownership
        assertEq(veHemi.ownerOf(tokenId), alice);
    }

    function testWithdraw() public {
        uint256 amount = 50 ether;

        (uint256 tokenId, , ) = createLock(user, amount, 2 weeks);

        // Fast forward past unlock
        vm.warp(block.timestamp + 2 weeks + 1);

        uint256 userBalanceBefore = hemi.balanceOf(user);

        vm.prank(user);
        veHemi.withdraw(tokenId);

        // NFT should be burned
        vm.expectRevert();
        veHemi.ownerOf(tokenId);

        assertEq(
            hemi.balanceOf(user),
            userBalanceBefore + amount,
            "Withdraw did not return tokens"
        );

        // Lock should be cleared
        (int128 lockedAmount, uint256 lockedEnd) = veHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), 0, "Lock not cleared");
        assertEq(lockedEnd, 0, "Lock end not cleared");
    }

    function testNonTransferableNFT() public {
        uint256 amount = 1 ether;

        vm.startPrank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 1 weeks, alice, false);

        vm.expectRevert("NFT is non-transferable");
        veHemi.transferFrom(user, address(0xABCD), tokenId);

        vm.expectRevert("NFT is non-transferable");
        veHemi.safeTransferFrom(user, address(0xABCD), tokenId);
        vm.stopPrank();
    }

    function testERC721EnumerableFunctions() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        // User creates two locks (two NFTs)
        (uint256 tokenId1, , ) = createLock(user, amount1, 1 weeks);
        (uint256 tokenId2, , ) = createLock(user, amount2, 1 weeks);

        // Check balanceOf (number of NFTs owned)
        uint256 balance = veHemi.balanceOf(user);
        assertEq(balance, 2, "User should own 2 NFTs");

        // Check tokenOfOwnerByIndex
        uint256 foundTokenId1 = veHemi.tokenOfOwnerByIndex(user, 0);
        uint256 foundTokenId2 = veHemi.tokenOfOwnerByIndex(user, 1);
        assertTrue(
            (foundTokenId1 == tokenId1 && foundTokenId2 == tokenId2) ||
                (foundTokenId1 == tokenId2 && foundTokenId2 == tokenId1),
            "tokenOfOwnerByIndex should return both tokenIds"
        );

        // Check totalSupply increases
        uint256 total = veHemi.totalNftSupply();
        assertEq(total, 2, "Total supply should be 2");

        // Check ownerOf returns correct owner
        assertEq(veHemi.ownerOf(tokenId1), user, "Owner of tokenId1 should be user");
        assertEq(veHemi.ownerOf(tokenId2), user, "Owner of tokenId2 should be user");
    }

    function testDepositForIncreasesLockAmount() public {
        uint256 amount = 10 ether;
        uint256 extra = 5 ether;

        // User creates a lock
        (uint256 tokenId, , ) = createLock(user, amount, 4 weeks);

        // Another user deposits for this lock
        address depositor = address(0xCAFE);
        hemi.mint(depositor, 100 ether);
        vm.startPrank(depositor);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(tokenId, extra);
        vm.stopPrank();

        // Check locked amount increased
        (int128 lockedAmount, ) = veHemi.locked(tokenId);
        assertEq(
            uint256(uint128(lockedAmount)),
            amount + extra,
            "depositFor did not increase lock amount"
        );
    }

    function testCheckpointUpdatesUserPointHistory() public {
        uint256 amount_ = 10 ether;
        // User creates a lock
        (uint256 tokenId_, , ) = createLock(user, amount_, 4 * 52 weeks);

        // Call checkpoint with old and new locked (simulate increase)
        (int128 oldAmount_, uint256 oldEnd_) = veHemi.locked(tokenId_);
        uint256 extraAmount_ = 1 ether;

        // User epoch should increase
        uint256 userEpochAfter_ = veHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 1, "User epoch not incremented");
        vm.warp(block.timestamp + 50 weeks); // Simulate time passing
        veHemi.checkpoint();
        assertEq(veHemi.epoch(), 52, "Global epoch should be 52 after checkpoint");
        IVeHemi.LockedBalance memory newLocked_ = IVeHemi.LockedBalance(
            oldAmount_ + int128(int256(extraAmount_)),
            uint64(oldEnd_)
        );
        vm.startPrank(user);
        hemi.approve(address(veHemi), extraAmount_);
        veHemi.increaseAmount(tokenId_, extraAmount_);
        vm.stopPrank();
        userEpochAfter_ = veHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 2, "User epoch not incremented");

        // User point history should be updated
        VeHemi.Point memory pt_ = veHemi.getUserPoint(tokenId_, userEpochAfter_);
        assertEq(pt_.amount, uint256(uint128(newLocked_.amount)), "User point not updated");
    }

    function testEpoch() public {
        uint256 amount_ = 10 ether;

        uint256 initialWeekNumber = block.timestamp / WEEK;

        (uint256 tokenId_, , ) = createLock(user, amount_, 4 * 52 weeks);
        uint256 userEpochBefore = veHemi.userPointEpoch(tokenId_);
        assertEq(userEpochBefore, 1, "user epoch not 1");
        // Increase amount through normal methods
        uint256 extraAmount_ = 5 ether;

        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 1);
        vm.prank(user);
        veHemi.increaseAmount(tokenId_, extraAmount_);
        uint256 expectedGlobalEpoch = block.timestamp / WEEK - initialWeekNumber;
        assertEq(veHemi.epoch(), expectedGlobalEpoch + 2, "global epoch not incremented1");
        uint256 newUserEpoch_ = veHemi.userPointEpoch(tokenId_);
        assertEq(newUserEpoch_, 2, "user epoch not incremented");
    }

    function testIncreaseUnlockTime() public {
        // Create a lock for 1 year
        uint256 amount = 100 ether;
        uint256 oneYear = 365 days;
        (uint256 tokenId, , ) = createLock(user, amount, oneYear);

        // Fast forward half a year
        vm.warp(block.timestamp + 182 days);

        // Try to increase unlock time by another year
        uint256 newDuration = 2 * 365 days; // 2 years from now
        vm.prank(user);
        veHemi.increaseUnlockTime(tokenId, newDuration);

        // Check that the lock's end is updated
        (, uint256 end) = veHemi.locked(tokenId);
        uint256 expectedUnlockTime = ((block.timestamp + newDuration) / WEEK) * WEEK;
        assertEq(end, expectedUnlockTime);
    }

    function testIncreaseUnlockTimeRevertsIfNotOwner() public {
        (uint256 tokenId, , ) = createLock(user, 100 ether, 365 days);
        // Try from another address
        vm.startPrank(address(0xA));
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseUnlockTime(tokenId, 2 * 365 days);
        vm.stopPrank();
    }

    function testIncreaseUnlockTimeRevertsIfNotGreater() public {
        (uint256 tokenId, , ) = createLock(user, 100 ether, 365 days);
        // Try to set to the same or lower end
        vm.prank(user);
        vm.expectRevert(VeHemi.NewLockDurationNotGreater.selector);
        veHemi.increaseUnlockTime(tokenId, 100 days);
    }

    function testBalanceOfNFT() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 4 weeks;
        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        // Should return the full amount right after creation
        uint256 bal = veHemi.balanceOfNFT(tokenId);
        assertGt(bal, 0, "balanceOfNFT should be > 0 after lock");
        assertLe(bal, amount, "balanceOfNFT should not exceed locked amount");

        // Fast forward to after expiry
        vm.warp(block.timestamp + lockDuration + 1);
        bal = veHemi.balanceOfNFT(tokenId);
        assertEq(bal, 0, "balanceOfNFT should be 0 after lock expires");
        assertEq(veHemi.totalSupply(), 0, "totalSupply should be 0 after lock expires");
    }

    function testBalanceOfNFTAt() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 4 weeks;
        uint256 start = block.timestamp;
        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        // At creation time
        uint256 balAtStart = veHemi.balanceOfNFTAt(tokenId, start);
        assertGt(balAtStart, 0, "balanceOfNFTAt should be > 0 at start");
        assertLe(balAtStart, amount, "balanceOfNFTAt should not exceed locked amount");

        // Halfway through lock
        uint256 half = start + lockDuration / 2;
        uint256 balAtHalf = veHemi.balanceOfNFTAt(tokenId, half);
        assertGt(balAtHalf, 0, "balanceOfNFTAt should be > 0 halfway");
        assertLt(balAtHalf, balAtStart, "balanceOfNFTAt should decrease over time");

        // After expiry
        uint256 afterExpiry = start + lockDuration + 1;
        uint256 balAfter = veHemi.balanceOfNFTAt(tokenId, afterExpiry);
        assertEq(balAfter, 0, "balanceOfNFTAt should be 0 after expiry");
    }

    function testUpdateRewardDistributor() public {
        IRewardDistributor newRewardDistributor = IRewardDistributor(address(0x1234));

        // Only owner should be able to call this
        vm.prank(user);
        vm.expectRevert();
        veHemi.updateRewardDistributor(newRewardDistributor);

        // Owner should be able to update
        vm.prank(address(this)); // address(this) is the owner from setUp
        veHemi.updateRewardDistributor(newRewardDistributor);

        // Check that the reward distributor was updated
        assertEq(address(veHemi.rewardDistributor()), address(newRewardDistributor));
    }

    function testUpdateRewardDistributorToZero() public {
        // Owner should be able to set to zero address
        vm.prank(address(this));
        veHemi.updateRewardDistributor(IRewardDistributor(address(0)));

        // Check that the reward distributor was set to zero
        assertEq(address(veHemi.rewardDistributor()), address(0));
    }

    function testTotalSupply() public {
        // Initially should be 0
        assertEq(veHemi.totalSupply(), 0, "Initial total supply should be 0");
        uint256 amountIn = 1 ether;
        uint256 lockDuration = MAX_TIME;

        (uint256 tokenId1, uint256 user1Slope, ) = createLock(user, 1 ether, lockDuration);
        uint256 expectedBalance = user1Slope *
            (veHemi.getLockedBalance(tokenId1).end - block.timestamp);

        uint256 balanceOfTokenId1 = veHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId1, expectedBalance, "user1 nft balance is not correct");
        assertEq(
            veHemi.totalSupply(),
            balanceOfTokenId1,
            "Total supply should equal locked amount"
        );

        uint256 user2LockDuration = MAX_TIME / 2;
        (uint256 tokenId2, uint256 user2Slope, ) = createLock(alice, amountIn, user2LockDuration);
        uint256 expectedBalance2 = user2Slope *
            (veHemi.getLockedBalance(tokenId2).end - block.timestamp);
        uint256 balanceOfTokenId2 = veHemi.balanceOfNFT(tokenId2);
        assertEq(balanceOfTokenId2, expectedBalance2, "user2 nft balance is not correct");

        assertEq(
            veHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );

        vm.warp(block.timestamp + 1 * 365 days);

        expectedBalance2 = user2Slope * (veHemi.getLockedBalance(tokenId2).end - block.timestamp);
        balanceOfTokenId2 = veHemi.balanceOfNFT(tokenId2);
        balanceOfTokenId1 = veHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId2, expectedBalance2, "user2 nft balance is not correct");
        assertGt(balanceOfTokenId1, 0, "Total supply should equal locked amount");

        assertEq(
            veHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );
    }

    function testSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(veHemi.totalSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        (uint256 tokenId, uint256 slope, ) = createLock(user, 1 ether, MAX_TIME);

        uint256 expectedBalance = slope * (veHemi.getLockedBalance(tokenId).end - block.timestamp);

        // At creation time
        assertEq(
            veHemi.totalSupplyAt(startTime),
            expectedBalance,
            "Total supply at creation should be locked amount"
        );

        // At future time (before expiry)
        uint256 futureTime = startTime + (2 * 365 days);
        expectedBalance = slope * (veHemi.getLockedBalance(tokenId).end - futureTime);
        assertEq(
            veHemi.totalSupplyAt(futureTime),
            expectedBalance,
            "Total supply should remain same before expiry"
        );

        // After expiry
        uint256 afterExpiry = startTime + MAX_TIME + 1;
        assertEq(veHemi.totalSupplyAt(afterExpiry), 0, "Total supply should be 0 after expiry");
    }

    function testPastSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(veHemi.totalSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        createLock(user, 1 ether, MAX_TIME);

        vm.warp(block.timestamp + 100 days);
        uint256 t1 = block.timestamp;
        uint256 supplyAtT1 = veHemi.totalSupply();
        vm.warp(block.timestamp + 200 days);

        createLock(user, 1 ether, MAX_TIME);
        vm.warp(block.timestamp + 10);

        // At creation time
        assertEq(veHemi.totalSupplyAt(t1), supplyAtT1, "Total at past is not correct");
    }

    function testPastSupplyAtBlock() public {
        uint256 blockNumber = block.number;

        // Initially should be 0
        assertEq(veHemi.totalSupplyAtBlock(blockNumber - 1), 0, "Initial total supply should be 0");

        // Create a lock
        createLock(user, 1 ether, MAX_TIME);
        uint256 b1 = block.number;
        uint256 supplyAtT1 = veHemi.totalSupply();

        vm.warp(block.timestamp + 200 days);
        vm.roll(block.number + (200 days / 10));

        createLock(user, 1 ether, MAX_TIME);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);

        assertEq(veHemi.totalSupplyAtBlock(b1), supplyAtT1, "Total at past is not correct");
    }

    // --- Transfer Control Tests ---

    function testTransferNotAllowedFlag() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, alice, false);

        // Check that transfer is not allowed
        assertFalse(veHemi.isTransferable(tokenId), "Token should not be transferable");
    }

    function testTransferAfterExpiry() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, alice, false);

        // Check that transfer is not allowed
        assertFalse(veHemi.isTransferable(tokenId), "Token should not be transferable");

        vm.warp(block.timestamp + 2 * 365 days + 1);
        assertTrue(veHemi.isTransferable(tokenId), "Token should be transferable");

        address bob = address(0xB);
        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);
        assertEq(veHemi.ownerOf(tokenId), bob, "Token should be transferred to bob");
    }

    function testTransferAllowedByDefault() public {
        uint256 amount = 100 ether;

        (uint256 tokenId, , ) = createLock(user, amount, 2 * 365 days);

        // Check that transfer is allowed by default
        assertTrue(veHemi.isTransferable(tokenId), "Token should be transferable by default");
    }

    function testExtendLockShouldNotExtendTransferable() public {
        uint256 amount = 100 ether;
        uint256 firstLockDuration = 2 * 365 days;
        uint256 newLockDuration = 3 * 365 days;
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, firstLockDuration, alice, false);
        assertFalse(veHemi.isTransferable(tokenId), "Token should not be transferable");

        vm.prank(alice);
        veHemi.increaseUnlockTime(tokenId, newLockDuration);

        vm.warp(block.timestamp + firstLockDuration + 1);
        assertTrue(veHemi.isTransferable(tokenId), "Token should be transferable by default");

        address bob = address(0xB);
        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);
        assertEq(veHemi.ownerOf(tokenId), bob, "Token should be transferred to bob");

        assertGt(veHemi.getLockedBalance(tokenId).end, block.timestamp, "Lock should be extended");
    }

    // --- Balance and Supply Fuzz Tests ---

    function testFuzz_BalanceOfNFT_TimeDecay(uint256 amount, uint256 timeAdvance) public {
        amount = bound(amount, 1 ether, MAX_AMOUNT);
        timeAdvance = bound(timeAdvance, 0, MAX_TIME);

        (uint256 tokenId, uint256 slope, uint256 end) = createLock(user, amount, MAX_TIME);

        uint256 balanceAtStart = veHemi.balanceOfNFT(tokenId);
        assertGt(balanceAtStart, 0);

        vm.warp(block.timestamp + timeAdvance);

        uint256 balanceAfterTime = veHemi.balanceOfNFT(tokenId);

        if (block.timestamp >= end) {
            assertEq(balanceAfterTime, 0, "Balance should be 0 after lock expires");
        } else {
            uint256 expectedBalance = slope * (end - block.timestamp);

            assertEq(
                balanceAfterTime,
                expectedBalance,
                "Balance should be equal to the expected balance"
            );
        }
    }

    function testFuzz_TotalSupply_Consistency(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1 ether, MAX_AMOUNT / 2);
        amount2 = bound(amount2, 1 ether, MAX_AMOUNT / 2);

        (uint256 tokenId1, , ) = createLock(user, amount1, MAX_TIME);

        (uint256 tokenId2, , ) = createLock(alice, amount2, MAX_TIME);

        uint256 totalSupply = veHemi.totalSupply();
        uint256 balance1 = veHemi.balanceOfNFT(tokenId1);
        uint256 balance2 = veHemi.balanceOfNFT(tokenId2);

        assertEq(
            totalSupply,
            balance1 + balance2,
            "Total supply should be equal to the sum of the balances"
        );
    }

    function testFuzz_TotalSupplyAt_TimeConsistency(
        uint256 amount,
        uint256 futureTime1,
        uint256 futureTime2,
        uint256 duration1,
        uint256 duration2
    ) public {
        amount = bound(amount, 1 ether, MAX_AMOUNT);
        futureTime2 = bound(futureTime2, 0, MAX_TIME);
        futureTime1 = bound(futureTime1, 0, futureTime2);
        duration1 = bound(duration1, 1 weeks, MAX_TIME);
        duration2 = bound(duration2, 1 weeks, MAX_TIME);

        (uint256 tokenId1, , ) = createLock(user, amount, duration1);
        (uint256 tokenId2, , ) = createLock(alice, amount, duration2);

        uint256 lockCreatedAt = block.timestamp;

        vm.warp(lockCreatedAt + futureTime1);

        uint256 totalSupplyAtFutureTime1 = veHemi.totalSupply();
        uint256 b1 = veHemi.balanceOfNFT(tokenId1);
        uint256 b2 = veHemi.balanceOfNFT(tokenId2);
        assertEq(
            totalSupplyAtFutureTime1,
            b1 + b2,
            "total supply should be the sum of the balances"
        );

        vm.warp(lockCreatedAt + futureTime2);

        uint256 totalSupplyAtFutureTime1_1 = veHemi.totalSupplyAt(lockCreatedAt + futureTime1);

        uint256 b1_1 = veHemi.balanceOfNFTAt(tokenId1, lockCreatedAt + futureTime1);
        uint256 b2_1 = veHemi.balanceOfNFTAt(tokenId2, lockCreatedAt + futureTime1);

        assertEq(
            totalSupplyAtFutureTime1,
            totalSupplyAtFutureTime1_1,
            "total supply should be the same"
        );

        assertEq(b1, b1_1, "balance of token 1 should be the same");
        assertEq(b2, b2_1, "balance of token 2 should be the same");
        assertEq(
            totalSupplyAtFutureTime1_1,
            b1_1 + b2_1,
            "total supply should be the sum of the balances"
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

contract VeHemiTest is Test {
    MockERC20 hemi;
    VeHemi veHemi;
    MockHemiVoteDelegation mockDelegation;
    address user = address(0xBEEF);
    address alice = address(0x1122);
    address bob = address(0x3344);
    address charlie = address(0x5566);

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;
    uint256 private constant MAX_TIME = 4 * YEAR; // 4 years

    uint256 MAX_AMOUNT = 1_000 ether;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        hemi.mint(user, MAX_AMOUNT);
        hemi.mint(alice, MAX_AMOUNT);
        hemi.mint(bob, MAX_AMOUNT);
        hemi.mint(charlie, MAX_AMOUNT);

        // Deploy logic contract
        VeHemi logic = new VeHemi(address(hemi));

        // Deploy and set mock delegation contract
        mockDelegation = new MockHemiVoteDelegation();

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        vm.prank(address(this));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));

        vm.prank(user);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(bob);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(charlie);
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
        IVeHemi.LockedBalance memory lockedBalance = veHemi.getLockedBalance(tokenId);
        assertEq(uint256(uint128(lockedBalance.amount)), amount, "Locked amount mismatch");
        assertEq(lockedBalance.end, (unlockTime / SIX_DAYS) * SIX_DAYS, "Unlock time mismatch");
        // Check supply
        assertEq(veHemi.totalLocked(), amount, "Supply mismatch");
    }

    function testCreateLockFor() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, alice, true, false);

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

        assertEq(
            hemi.balanceOf(user),
            userBalanceBefore + amount,
            "Withdraw did not return tokens"
        );

        // Lock should be cleared
        IVeHemi.LockedBalance memory lockedBalance = veHemi.getLockedBalance(tokenId);
        assertEq(uint256(uint128(lockedBalance.amount)), 0, "Lock not cleared");
        assertEq(lockedBalance.end, 0, "Lock end not cleared");
    }

    // User should not be able to withdraw and extend lock after expiry and withdraw
    function testWithdrawAfterExpiry() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 2 weeks;
        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        vm.warp(block.timestamp + lockDuration + 1);

        vm.startPrank(user);

        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.increaseUnlockTime(tokenId, 4 weeks);

        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.increaseAmount(tokenId, 2 weeks);

        veHemi.withdraw(tokenId);

        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseUnlockTime(tokenId, 4 weeks);

        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.increaseAmount(tokenId, 2 weeks);

        vm.stopPrank();
    }

    function testNonTransferableNFT() public {
        uint256 amount = 1 ether;

        vm.startPrank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 1 weeks, alice, false, false);

        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(user, address(0xABCD), tokenId);

        vm.expectRevert(VeHemi.NotTransferable.selector);
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

        uint256 total = veHemi.totalSupply();
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
        IVeHemi.LockedBalance memory lockedBalance = veHemi.getLockedBalance(tokenId);
        assertEq(
            uint256(uint128(lockedBalance.amount)),
            amount + extra,
            "depositFor did not increase lock amount"
        );
    }

    function testCheckpointUpdatesUserPointHistory() public {
        uint256 amount_ = 10 ether;
        // User creates a lock
        (uint256 tokenId_, , ) = createLock(user, amount_, 4 * 52 weeks);

        // Call checkpoint with old and new locked (simulate increase)
        IVeHemi.LockedBalance memory oldLocked_ = veHemi.getLockedBalance(tokenId_);
        uint256 extraAmount_ = 1 ether;

        // User epoch should increase
        uint256 userEpochAfter_ = veHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 1, "User epoch not incremented");
        vm.warp(block.timestamp + 58 * 6 days); // Simulate time passing
        veHemi.checkpoint();
        assertEq(veHemi.epoch(), 59, "Global epoch should be 59 after checkpoint");
        IVeHemi.LockedBalance memory newLocked_ = IVeHemi.LockedBalance(
            oldLocked_.amount + int128(int256(extraAmount_)),
            uint64(oldLocked_.end)
        );
        vm.startPrank(user);
        hemi.approve(address(veHemi), extraAmount_);
        veHemi.increaseAmount(tokenId_, extraAmount_);
        vm.stopPrank();
        userEpochAfter_ = veHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 2, "User epoch not incremented");

        // User point history should be updated
        VeHemi.UserPoint memory pt_ = veHemi.getUserPoint(tokenId_, userEpochAfter_);
        assertEq(pt_.point.amount, uint256(uint128(newLocked_.amount)), "User point not updated");
    }

    function testEpoch() public {
        uint256 amount_ = 10 ether;

        uint256 initialSixDaysCount = block.timestamp / SIX_DAYS;

        (uint256 tokenId_, , ) = createLock(user, amount_, 4 * 52 weeks);
        uint256 userEpochBefore = veHemi.userPointEpoch(tokenId_);
        assertEq(userEpochBefore, 1, "user epoch not 1");
        // Increase amount through normal methods
        uint256 extraAmount_ = 5 ether;

        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        veHemi.increaseAmount(tokenId_, extraAmount_);
        uint256 expectedGlobalEpoch = block.timestamp / SIX_DAYS - initialSixDaysCount;
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
        IVeHemi.LockedBalance memory lockedBalance = veHemi.getLockedBalance(tokenId);
        uint256 expectedUnlockTime = ((block.timestamp + newDuration) / SIX_DAYS) * SIX_DAYS;
        assertEq(lockedBalance.end, expectedUnlockTime);
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
        (uint256 tokenId, uint256 slope, ) = createLock(user, amount, lockDuration);

        // Should return the full amount right after creation
        uint256 bal = veHemi.balanceOfNFT(tokenId);
        assertGt(bal, 0, "balanceOfNFT should be > 0 after lock");
        assertEq(
            bal,
            slope * (veHemi.getLockedBalance(tokenId).end - block.timestamp),
            "balanceOfNFT is not accurate"
        );
        assertLe(bal, amount, "balanceOfNFT should not exceed locked amount");

        // Fast forward to after expiry
        vm.warp(block.timestamp + lockDuration + 1);
        bal = veHemi.balanceOfNFT(tokenId);
        assertEq(bal, 0, "balanceOfNFT should be 0 after lock expires");
        assertEq(veHemi.totalVeHemiSupply(), 0, "totalVeHemiSupply should be 0 after lock expires");
    }

    function test_BalanceOfNFTAt() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 4 weeks;
        uint256 start = block.timestamp;
        (uint256 tokenId, uint256 slope, ) = createLock(user, amount, lockDuration);

        // At creation time
        uint256 balAtStart = veHemi.balanceOfNFTAt(tokenId, start);
        assertGt(balAtStart, 0, "balanceOfNFTAt should be > 0 at start");
        assertEq(
            balAtStart,
            slope * (veHemi.getLockedBalance(tokenId).end - start),
            "balanceOfNFT is not accurate"
        );
        assertLe(balAtStart, amount, "balanceOfNFTAt should not exceed locked amount");

        // Halfway through lock
        uint256 half = start + lockDuration / 2;
        uint256 balAtHalf = veHemi.balanceOfNFTAt(tokenId, half);
        assertGt(balAtHalf, 0, "balanceOfNFTAt should be > 0 halfway");
        assertEq(
            balAtHalf,
            slope * (veHemi.getLockedBalance(tokenId).end - half),
            "balanceOfNFT is not accurate"
        );
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

    function testSameBlock() public {
        (uint256 tokenId, , ) = createLock(alice, 1 ether, MAX_TIME / 2);

        assertEq(veHemi.userPointEpoch(tokenId), 1);
        assertApproxEqRel(
            veHemi.balanceOfNFT(tokenId),
            0.5 ether,
            0.0015e18,
            "balance should be ~= 1/2 locked"
        );

        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);

        vm.prank(bob);
        veHemi.increaseAmount(tokenId, 1 ether);

        assertApproxEqRel(veHemi.totalVeHemiSupply(), 1 ether, 0.0015e18);
        assertEq(veHemi.getLockedBalance(tokenId).amount, 2 ether, "locked amount is not correct");
        assertApproxEqRel(
            veHemi.balanceOfNFT(tokenId),
            1 ether,
            0.0015e18,
            "balance should be ~= locked"
        );

        vm.prank(bob);
        veHemi.increaseUnlockTime(tokenId, MAX_TIME);
        vm.prank(bob);
        veHemi.transferFrom(bob, alice, tokenId);

        assertApproxEqRel(
            veHemi.totalVeHemiSupply(),
            2 ether,
            0.0015e18,
            "supply should be ~= locked"
        );
        assertEq(veHemi.getLockedBalance(tokenId).amount, 2 ether, "locked amount is not correct");
        assertApproxEqRel(
            veHemi.balanceOfNFT(tokenId),
            2 ether,
            0.0015e18,
            "balance should be ~= locked"
        );
        assertEq(veHemi.userPointEpoch(tokenId), 1, "epoch should not change");
    }

    function testTotalVeHemiSupply() public {
        // Initially should be 0
        assertEq(veHemi.totalVeHemiSupply(), 0, "Initial total supply should be 0");
        uint256 amountIn = 1 ether;
        uint256 lockDuration = MAX_TIME;

        (uint256 tokenId1, uint256 user1Slope, ) = createLock(user, 1 ether, lockDuration);
        uint256 expectedBalance1 = user1Slope *
            (veHemi.getLockedBalance(tokenId1).end - block.timestamp);

        uint256 balanceOfTokenId1 = veHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId1, expectedBalance1, "user1 nft balance is not correct");
        assertEq(
            veHemi.totalVeHemiSupply(),
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
            veHemi.totalVeHemiSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );

        vm.warp(block.timestamp + 365 days);

        expectedBalance1 = user1Slope * (veHemi.getLockedBalance(tokenId1).end - block.timestamp);
        expectedBalance2 = user2Slope * (veHemi.getLockedBalance(tokenId2).end - block.timestamp);
        balanceOfTokenId2 = veHemi.balanceOfNFT(tokenId2);
        balanceOfTokenId1 = veHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId1, expectedBalance1, "user2 nft balance is not correct");
        assertGt(balanceOfTokenId1, 0, "Total supply should equal locked amount");
        assertEq(balanceOfTokenId2, expectedBalance2, "user2 nft balance is not correct");
        assertGt(balanceOfTokenId2, 0, "Total supply should equal locked amount");
        assertEq(
            veHemi.totalVeHemiSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );
    }

    function testSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(veHemi.totalVeHemiSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        (uint256 tokenId, uint256 slope, ) = createLock(user, 1 ether, MAX_TIME);

        uint256 expectedBalance = slope * (veHemi.getLockedBalance(tokenId).end - block.timestamp);

        // At creation time
        assertEq(
            veHemi.totalVeHemiSupplyAt(startTime),
            expectedBalance,
            "Total supply at creation should be locked amount"
        );

        // At future time (before expiry)
        uint256 futureTime = startTime + (2 * 365 days);
        expectedBalance = slope * (veHemi.getLockedBalance(tokenId).end - futureTime);
        assertEq(
            veHemi.totalVeHemiSupplyAt(futureTime),
            expectedBalance,
            "Total supply should remain same before expiry"
        );

        // After expiry
        uint256 afterExpiry = startTime + MAX_TIME + 1;
        assertEq(
            veHemi.totalVeHemiSupplyAt(afterExpiry),
            0,
            "Total supply should be 0 after expiry"
        );
    }

    function testPastSupplyAt() public {
        uint256 startTime = block.timestamp;

        // Initially should be 0
        assertEq(veHemi.totalVeHemiSupplyAt(startTime), 0, "Initial total supply should be 0");

        // Create a lock
        createLock(user, 1 ether, MAX_TIME);

        vm.warp(block.timestamp + 100 days);
        uint256 t1 = block.timestamp;
        uint256 supplyAtT1 = veHemi.totalVeHemiSupply();
        vm.warp(block.timestamp + 200 days);

        createLock(user, 1 ether, MAX_TIME);
        vm.warp(block.timestamp + 10);

        // At creation time
        assertEq(veHemi.totalVeHemiSupplyAt(t1), supplyAtT1, "Total at past is not correct");
    }

    //     // --- Transfer Control Tests ---

    function testTransferNotAllowedFlag() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, alice, false, false);

        // Check that transfer is not allowed
        assertFalse(veHemi.isTransferable(tokenId), "Token should not be transferable");
    }

    function testTransferAfterExpiry() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, alice, false, false);

        // Check that transfer is not allowed
        assertFalse(veHemi.isTransferable(tokenId), "Token should not be transferable");

        vm.warp(block.timestamp + 2 * 365 days + 1);
        assertTrue(veHemi.isTransferable(tokenId), "Token should be transferable");

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
        uint256 tokenId = veHemi.createLockFor(amount, firstLockDuration, alice, false, false);
        assertFalse(veHemi.isTransferable(tokenId), "Token should not be transferable");

        vm.prank(alice);
        veHemi.increaseUnlockTime(tokenId, newLockDuration);

        vm.warp(block.timestamp + firstLockDuration + 1);
        assertTrue(veHemi.isTransferable(tokenId), "Token should be transferable by default");

        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);
        assertEq(veHemi.ownerOf(tokenId), bob, "Token should be transferred to bob");

        assertGt(veHemi.getLockedBalance(tokenId).end, block.timestamp, "Lock should be extended");
    }

    function testTransferUpdatesUserPointHistory() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 2 * 365 days;

        // Create a transferable lock
        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        // Get initial user point epoch
        uint256 initialEpoch = veHemi.userPointEpoch(tokenId);
        assertEq(initialEpoch, 1, "Initial epoch should be 1");

        // Get initial user point
        IVeHemi.UserPoint memory initialPoint = veHemi.getUserPoint(tokenId, initialEpoch);
        assertEq(initialPoint.owner, user, "Initial owner should be user");

        // Fast forward time to make token transferable and ensure different timestamp
        vm.warp(block.timestamp + 1 days);

        // Transfer the NFT
        vm.prank(user);
        veHemi.transferFrom(user, alice, tokenId);
        assertEq(veHemi.ownerOf(tokenId), alice, "Token should be transferred to alice");

        // Check that user point epoch increased (due to different timestamp)
        uint256 newEpoch = veHemi.userPointEpoch(tokenId);
        assertEq(newEpoch, initialEpoch + 1, "User point epoch should increase after transfer");

        // Check that the new user point has the correct owner
        IVeHemi.UserPoint memory newPoint = veHemi.getUserPoint(tokenId, newEpoch);
        assertEq(newPoint.owner, alice, "New user point should have alice as owner");

        // Check that the point data (amount, timestamp, etc.) is preserved
        assertEq(
            newPoint.point.amount,
            initialPoint.point.amount,
            "Point amount should be preserved"
        );
        assertEq(
            newPoint.point.timestamp,
            uint64(block.timestamp),
            "Point timestamp should be current time"
        );
        assertEq(
            newPoint.point.blockNumber,
            uint64(block.number),
            "Point block number should be current block"
        );

        // Verify the old point is still accessible and unchanged
        IVeHemi.UserPoint memory oldPoint = veHemi.getUserPoint(tokenId, initialEpoch);
        assertEq(oldPoint.owner, user, "Old point should still have user as owner");
        assertEq(
            oldPoint.point.amount,
            initialPoint.point.amount,
            "Old point amount should be unchanged"
        );
    }

    function testMultipleTransfersUpdateUserPointHistory() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 2 * 365 days;

        // Create a transferable lock
        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        // Fast forward time to make token transferable
        vm.warp(block.timestamp + 1 days);

        // First transfer: user -> alice
        vm.prank(user);
        veHemi.transferFrom(user, alice, tokenId);

        uint256 epochAfterFirstTransfer = veHemi.userPointEpoch(tokenId);
        assertEq(epochAfterFirstTransfer, 2, "Epoch should be 2 after first transfer");

        IVeHemi.UserPoint memory pointAfterFirstTransfer = veHemi.getUserPoint(
            tokenId,
            epochAfterFirstTransfer
        );
        assertEq(
            pointAfterFirstTransfer.owner,
            alice,
            "Owner should be alice after first transfer"
        );

        // Fast forward more time
        vm.warp(block.timestamp + 1 days);

        // Second transfer: alice -> bob
        vm.prank(alice);
        veHemi.transferFrom(alice, bob, tokenId);

        uint256 epochAfterSecondTransfer = veHemi.userPointEpoch(tokenId);
        assertEq(epochAfterSecondTransfer, 3, "Epoch should be 3 after second transfer");

        IVeHemi.UserPoint memory pointAfterSecondTransfer = veHemi.getUserPoint(
            tokenId,
            epochAfterSecondTransfer
        );
        assertEq(pointAfterSecondTransfer.owner, bob, "Owner should be bob after second transfer");

        // Verify all historical points are preserved
        IVeHemi.UserPoint memory originalPoint = veHemi.getUserPoint(tokenId, 1);
        assertEq(originalPoint.owner, user, "Original point should have user as owner");

        IVeHemi.UserPoint memory firstTransferPoint = veHemi.getUserPoint(tokenId, 2);
        assertEq(
            firstTransferPoint.owner,
            alice,
            "First transfer point should have alice as owner"
        );

        IVeHemi.UserPoint memory secondTransferPoint = veHemi.getUserPoint(tokenId, 3);
        assertEq(secondTransferPoint.owner, bob, "Second transfer point should have bob as owner");
    }

    function testTransferAfterLockModificationUpdatesHistory() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 2 * 365 days;

        // Create a transferable lock
        (uint256 tokenId, , ) = createLock(user, amount, lockDuration);

        // Modify the lock (increase amount)
        uint256 extraAmount = 50 ether;
        vm.startPrank(user);
        hemi.approve(address(veHemi), extraAmount);
        veHemi.increaseAmount(tokenId, extraAmount);
        vm.stopPrank();

        uint256 epochAfterModification = veHemi.userPointEpoch(tokenId);
        assertEq(epochAfterModification, 1, "Epoch should be 1 after modification");

        // Fast forward time to make token transferable
        vm.warp(block.timestamp + 1 days);

        // Transfer the NFT
        vm.prank(user);
        veHemi.transferFrom(user, alice, tokenId);

        uint256 epochAfterTransfer = veHemi.userPointEpoch(tokenId);
        assertEq(epochAfterTransfer, 2, "Epoch should be 2 after transfer");

        // Check that the transfer point has the correct owner and updated amount
        IVeHemi.UserPoint memory transferPoint = veHemi.getUserPoint(tokenId, epochAfterTransfer);
        assertEq(transferPoint.owner, alice, "Transfer point should have alice as owner");
        assertEq(
            transferPoint.point.amount,
            amount + extraAmount,
            "Transfer point should have updated amount"
        );

        // Verify the modification point is preserved
        IVeHemi.UserPoint memory modificationPoint = veHemi.getUserPoint(
            tokenId,
            epochAfterModification
        );
        assertEq(modificationPoint.owner, user, "Modification point should have user as owner");
        assertEq(
            modificationPoint.point.amount,
            amount + extraAmount,
            "Modification point should have updated amount"
        );
    }

    // --- Balance and Supply Fuzz Tests ---

    function testFuzz_BalanceOfNFT_TimeDecay(
        uint256 amount,
        uint256 duration,
        uint256 timeAdvance
    ) public {
        amount = bound(amount, 1 ether, MAX_AMOUNT);
        duration = bound(duration, SIX_DAYS, MAX_TIME);
        timeAdvance = bound(timeAdvance, 0, duration);

        (uint256 tokenId, uint256 slope, uint256 end) = createLock(user, amount, duration);

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

    function testFuzz_TotalVeHemiSupply_Consistency(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1 ether, MAX_AMOUNT / 2);
        amount2 = bound(amount2, 1 ether, MAX_AMOUNT / 2);

        (uint256 tokenId1, , ) = createLock(user, amount1, MAX_TIME);

        (uint256 tokenId2, , ) = createLock(alice, amount2, MAX_TIME);

        uint256 totalVeHemiSupply = veHemi.totalVeHemiSupply();
        uint256 balance1 = veHemi.balanceOfNFT(tokenId1);
        uint256 balance2 = veHemi.balanceOfNFT(tokenId2);

        assertEq(
            totalVeHemiSupply,
            balance1 + balance2,
            "Total supply should be equal to the sum of the balances"
        );
    }

    function testFuzz_TotalVeHemiSupplyAt_TimeConsistency(
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

        uint256 totalVeHemiSupplyAtFutureTime1 = veHemi.totalVeHemiSupply();
        uint256 b1 = veHemi.balanceOfNFT(tokenId1);
        uint256 b2 = veHemi.balanceOfNFT(tokenId2);
        assertEq(
            totalVeHemiSupplyAtFutureTime1,
            b1 + b2,
            "total supply should be the sum of the balances"
        );

        vm.warp(lockCreatedAt + futureTime2);

        uint256 totalVeHemiSupplyAtFutureTime1_1 = veHemi.totalVeHemiSupplyAt(
            lockCreatedAt + futureTime1
        );

        uint256 b1_1 = veHemi.balanceOfNFTAt(tokenId1, lockCreatedAt + futureTime1);
        uint256 b2_1 = veHemi.balanceOfNFTAt(tokenId2, lockCreatedAt + futureTime1);

        assertEq(
            totalVeHemiSupplyAtFutureTime1,
            totalVeHemiSupplyAtFutureTime1_1,
            "total supply should be the same"
        );

        assertEq(b1, b1_1, "balance of token 1 should be the same");
        assertEq(b2, b2_1, "balance of token 2 should be the same");
        assertEq(
            totalVeHemiSupplyAtFutureTime1_1,
            b1_1 + b2_1,
            "total supply should be the sum of the balances"
        );
    }

    //     // --- Forfeitable Lock Tests ---

    function testForfeitLockByAdmin() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock for team member
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, true);

        // Check initial state
        assertTrue(veHemi.forfeitable(tokenId), "Lock should be forfeitable");
        assertEq(veHemi.totalLocked(), amount, "Total locked should be correct");

        // Forfeit admin should be able to forfeit the lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(tokenId);

        // Lock should be cleared
        IVeHemi.LockedBalance memory lockedBalance = veHemi.getLockedBalance(tokenId);
        assertEq(uint256(uint128(lockedBalance.amount)), 0, "Lock not cleared");
        assertEq(lockedBalance.end, 0, "Lock end not cleared");

        // Total locked should be reduced
        assertEq(veHemi.totalLocked(), 0, "Total locked should be reduced");

        vm.startPrank(teamMember);

        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseUnlockTime(tokenId, 4 weeks);

        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.increaseAmount(tokenId, 2 weeks);

        vm.stopPrank();
    }

    function testForfeitLockRevertsIfNotAdmin() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock for team member
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, true);

        // Non-admin should not be able to forfeit
        vm.prank(user);
        vm.expectRevert(VeHemi.NotForfeitAdmin.selector);
        veHemi.forfeit(tokenId);
    }

    function testForfeitLockRevertsIfNotForfeitable() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create non-forfeitable lock
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, false);

        // Check that lock is not forfeitable
        assertFalse(veHemi.forfeitable(tokenId), "Lock should not be forfeitable");

        // Forfeit admin should not be able to forfeit non-forfeitable lock
        vm.prank(forfeitAdmin);
        vm.expectRevert(VeHemi.NotForfeitable.selector);
        veHemi.forfeit(tokenId);
    }

    function testForfeitLockRevertsIfLockExpired() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock with short duration
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 1 weeks, teamMember, false, true);

        // Fast forward past unlock
        vm.warp(block.timestamp + 1 weeks + 1);

        // Forfeit admin should not be able to forfeit expired lock
        vm.prank(forfeitAdmin);
        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.forfeit(tokenId);
    }

    function testForfeitLockTransfersTokensToAdmin() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock for team member
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, true);

        // Check initial balances
        uint256 adminBalanceBefore = hemi.balanceOf(forfeitAdmin);
        uint256 teamMemberBalanceBefore = hemi.balanceOf(teamMember);

        // Forfeit the lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(tokenId);

        // Check that tokens were transferred to admin
        assertEq(
            hemi.balanceOf(forfeitAdmin),
            adminBalanceBefore + amount,
            "Tokens should be transferred to forfeit admin"
        );

        // Team member balance should remain unchanged
        assertEq(
            hemi.balanceOf(teamMember),
            teamMemberBalanceBefore,
            "Team member balance should remain unchanged"
        );
    }

    function testForfeitLockUpdatesTotalVeHemiSupply() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 50 ether;
        address teamMember1 = address(0x1111);
        address teamMember2 = address(0x2222);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create two forfeitable locks
        vm.prank(user);
        uint256 tokenId1 = veHemi.createLockFor(amount1, 2 * 365 days, teamMember1, false, true);

        vm.prank(user);
        uint256 tokenId2 = veHemi.createLockFor(amount2, 2 * 365 days, teamMember2, false, true);

        // Check initial total supply
        uint256 initialTotalVeHemiSupply = veHemi.totalVeHemiSupply();
        assertGt(initialTotalVeHemiSupply, 0, "Total supply should be greater than 0");

        // Forfeit first lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(tokenId1);

        // Check total supply is reduced
        uint256 totalVeHemiSupplyAfterFirstForfeit = veHemi.totalVeHemiSupply();
        assertLt(
            totalVeHemiSupplyAfterFirstForfeit,
            initialTotalVeHemiSupply,
            "Total supply should be reduced"
        );

        // Forfeit second lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(tokenId2);

        // Check total supply is further reduced
        uint256 totalVeHemiSupplyAfterSecondForfeit = veHemi.totalVeHemiSupply();
        assertLt(
            totalVeHemiSupplyAfterSecondForfeit,
            totalVeHemiSupplyAfterFirstForfeit,
            "Total supply should be further reduced"
        );
    }

    function testForfeitLockEmitsCorrectEvents() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock for team member
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, true);

        // Expect Withdraw event when forfeiting
        vm.prank(forfeitAdmin);
        vm.expectEmit(true, true, false, true);
        emit IVeHemi.Withdraw(forfeitAdmin, tokenId, amount, block.timestamp);
        veHemi.forfeit(tokenId);
    }

    function testForfeitAdminCanBeUpdated() public {
        address oldForfeitAdmin = address(0x3333);
        address newForfeitAdmin = address(0x4444);

        // Set initial forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(oldForfeitAdmin);
        assertEq(veHemi.forfeitAdmin(), oldForfeitAdmin, "Initial forfeit admin should be set");

        // Update forfeit admin
        vm.prank(address(this));
        vm.expectEmit(true, true, false, true);
        emit IVeHemi.ForfeitAdminUpdated(oldForfeitAdmin, newForfeitAdmin);
        veHemi.updateForfeitAdmin(newForfeitAdmin);

        // Check that forfeit admin was updated
        assertEq(veHemi.forfeitAdmin(), newForfeitAdmin, "Forfeit admin should be updated");
    }

    function testForfeitAdminUpdateRevertsIfNotOwner() public {
        address newForfeitAdmin = address(0x4444);

        // Non-owner should not be able to update forfeit admin
        vm.prank(user);
        vm.expectRevert();
        veHemi.updateForfeitAdmin(newForfeitAdmin);
    }

    function testForfeitAdminCanBeSetToZero() public {
        address forfeitAdmin = address(0x5678);

        // Set forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);
        assertEq(veHemi.forfeitAdmin(), forfeitAdmin, "Forfeit admin should be set");

        // Set to zero address
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(address(0));
        assertEq(veHemi.forfeitAdmin(), address(0), "Forfeit admin should be set to zero");
    }

    function testForfeitLockWithZeroForfeitAdmin() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);

        // Set forfeit admin to zero
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(address(0));

        // Create forfeitable lock for team member
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, true);

        // No one should be able to forfeit when forfeit admin is zero
        vm.prank(user);
        vm.expectRevert(VeHemi.NotForfeitAdmin.selector);
        veHemi.forfeit(tokenId);
    }

    function testForfeitLockMixedWithRegularLocks() public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create regular lock
        (uint256 regularTokenId, , ) = createLock(user, amount, 2 * 365 days);

        // Create forfeitable lock
        vm.prank(user);
        uint256 forfeitableTokenId = veHemi.createLockFor(
            amount,
            2 * 365 days,
            teamMember,
            false,
            true
        );

        // Check that regular lock is not forfeitable
        assertFalse(veHemi.forfeitable(regularTokenId), "Regular lock should not be forfeitable");

        // Check that forfeitable lock is forfeitable
        assertTrue(
            veHemi.forfeitable(forfeitableTokenId),
            "Forfeitable lock should be forfeitable"
        );

        // Forfeit admin should not be able to forfeit regular lock
        vm.prank(forfeitAdmin);
        vm.expectRevert(VeHemi.NotForfeitable.selector);
        veHemi.forfeit(regularTokenId);

        // Forfeit admin should be able to forfeit forfeitable lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(forfeitableTokenId);

        // Regular lock should still exist
        assertEq(veHemi.ownerOf(regularTokenId), user, "Regular lock should still exist");
    }

    function testFuzz_ForfeitLockWithDifferentAmounts(uint256 amount) public {
        amount = bound(amount, 1 ether, MAX_AMOUNT);
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, 2 * 365 days, teamMember, false, true);

        // Check initial state
        assertTrue(veHemi.forfeitable(tokenId), "Lock should be forfeitable");
        assertEq(veHemi.totalLocked(), amount, "Total locked should be correct");

        // Forfeit the lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(tokenId);

        // Total locked should be reduced
        assertEq(veHemi.totalLocked(), 0, "Total locked should be reduced");
    }

    function testFuzz_ForfeitLockWithDifferentDurations(uint256 duration) public {
        uint256 amount = 100 ether;
        address teamMember = address(0x1234);
        address forfeitAdmin = address(0x5678);

        // Bound duration to reasonable range
        duration = bound(duration, 1 weeks, MAX_TIME);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(amount, duration, teamMember, false, true);

        // Check initial state
        assertTrue(veHemi.forfeitable(tokenId), "Lock should be forfeitable");

        // Forfeit the lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(tokenId);

        // Lock should be cleared
        IVeHemi.LockedBalance memory lockedBalance = veHemi.getLockedBalance(tokenId);
        assertEq(uint256(uint128(lockedBalance.amount)), 0, "Lock not cleared");
        assertEq(lockedBalance.end, 0, "Lock end not cleared");
    }
}

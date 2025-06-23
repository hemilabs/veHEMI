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
    uint256 BALANCE_WHEN_1_YEAR = 245746805209282575;

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
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 * 365 days;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 * 365 days);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), user);

        // Check locked balance
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(
            lockedEnd,
            (unlockTime / stakedHemi.WEEK()) * stakedHemi.WEEK(),
            "Unlock time mismatch"
        );

        // Check supply
        assertEq(stakedHemi.supply(), amount, "Supply mismatch");
    }

    function testWithdraw() public {
        uint256 amount = 50 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 weeks;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 2 weeks);

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
        uint256 unlockTime = block.timestamp + 1 weeks;

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
        uint256 tokenId = stakedHemi.createLock(amount, 4 weeks);

        // Another user deposits for this lock
        address depositor = address(0xCAFE);
        hemi.mint(depositor, 100 ether);
        vm.prank(depositor);
        hemi.approve(address(stakedHemi), type(uint256).max);

        vm.prank(depositor);
        stakedHemi.increaseAmount(tokenId, extra);

        // Check locked amount increased
        (int128 lockedAmount, ) = stakedHemi.locked(tokenId);
        assertEq(
            uint256(uint128(lockedAmount)),
            amount + extra,
            "depositFor did not increase lock amount"
        );
    }

    function testIncreaseAmountIncreasesLockAmount() public {
        uint256 amount = 20 ether;
        uint256 extra = 7 ether;
        uint256 unlockTime = block.timestamp + 8 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, 8 weeks);

        // User increases their lock amount
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId, extra);

        // Check locked amount increased
        (int128 lockedAmount, ) = stakedHemi.locked(tokenId);
        assertEq(
            uint256(uint128(lockedAmount)),
            amount + extra,
            "increaseAmount did not increase lock amount"
        );
    }

    function testCheckpointUpdatesUserPointHistory() public {
        uint256 amount_ = 10 ether;
        uint256 unlockTime_ = block.timestamp + 4 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId_ = stakedHemi.createLock(amount_, 4 weeks);

        // Get user epoch before checkpoint
        uint256 userEpochBefore_ = stakedHemi.userPointEpoch(tokenId_);

        // Call checkpoint with old and new locked (simulate increase)
        (int128 oldAmount_, uint256 oldEnd_) = stakedHemi.locked(tokenId_);
        IStakedHemi.LockedBalance memory oldLocked_ = IStakedHemi.LockedBalance(
            oldAmount_,
            oldEnd_
        );
        IStakedHemi.LockedBalance memory newLocked_ = IStakedHemi.LockedBalance(
            oldAmount_ + int128(int256(1 ether)),
            oldEnd_
        );

        // Only owner can call internal, so use a helper or make _checkpoint public for testing
        vm.prank(address(stakedHemi));
        console.log("epoch", stakedHemi.epoch());

        // User epoch should increase
        uint256 userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        assertEq(userEpochAfter_, 1, "User epoch not incremented");
        vm.warp(block.timestamp + 2 weeks); // Simulate time passing
        stakedHemi.checkpoint();
        assertEq(stakedHemi.epoch(), 2, "Global epoch should be 52 after checkpoint");
        uint256 extraAmount_ = 5 ether;
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);
        userEpochAfter_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testCheckpointUpdatesUserPointHistory ~ userEpochAfter_:", userEpochAfter_);
        assertEq(userEpochAfter_, 2, "User epoch not incremented");

        // User point history should be updated
        StakedHemi.Point memory pt_ = stakedHemi.getUserPoint(tokenId_, userEpochAfter_);
        assertEq(pt_.amount, uint256(uint128(newLocked_.amount)), "User point not updated");
    }

    function testCheckpoint() public {
        uint256 amount_ = 10 ether;
        uint256 unlockTime_ = block.timestamp + 52 weeks;

        // User creates a lock
        vm.prank(user);
        uint256 tokenId_ = stakedHemi.createLock(amount_, 52 weeks);

        // Get user epoch after lock creation
        uint256 userEpoch_ = stakedHemi.userPointEpoch(tokenId_);

        // Store initial values for later comparison
        uint256 initialHemiAmount_ = amount_;

        // Increase amount through normal methods
        uint256 extraAmount_ = 5 ether;
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId_, extraAmount_);

        // User epoch should increase
        uint256 newUserEpoch_ = stakedHemi.userPointEpoch(tokenId_);
        console.log(" testCheckpoint ~ newUserEpoch_:", newUserEpoch_);
        assertEq(newUserEpoch_, userEpoch_ + 1, "User epoch not incremented");

        // Get the locked balance to verify it increased
        (int128 lockedAmount_, ) = stakedHemi.locked(tokenId_);
        assertEq(
            uint256(uint128(lockedAmount_)),
            amount_ + extraAmount_,
            "Locked amount not updated correctly"
        );

        // Check global state
        uint256 globalEpoch_ = stakedHemi.epoch();
        assertTrue(globalEpoch_ > 0, "Global epoch should be updated");
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
        uint256 expectedUnlockTime = ((block.timestamp + newDuration) / stakedHemi.WEEK()) *
            stakedHemi.WEEK();
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
        (, uint256 oldEnd) = stakedHemi.locked(tokenId);
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

        vm.prank(user);
        uint256 tokenId1 = stakedHemi.createLock(1 ether, MAX_TIME);

        uint256 balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId1, BALANCE_WHEN_MAX_TIME, "user1 nft balance is not correct");
        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1,
            "Total supply should equal locked amount"
        );

        // Create another lock
        address user2 = address(0xCAFE);
        hemi.mint(user2, 2 ether);
        vm.prank(user2);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(user2);
        uint256 tokenId2 = stakedHemi.createLock(1 ether, MAX_TIME / 2);
        uint256 balanceOfTokenId2 = stakedHemi.balanceOfNFT(tokenId2);
        assertEq(balanceOfTokenId2, BALANCE_WHEN_HALF_TIME, "user2 nft balance is not correct");

        assertEq(
            stakedHemi.totalSupply(),
            balanceOfTokenId1 + balanceOfTokenId2,
            "Total supply should be sum of all locks"
        );

        vm.warp(block.timestamp + 1 * 365 days);
        balanceOfTokenId2 = stakedHemi.balanceOfNFT(tokenId2);
        balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId1);
        assertEq(balanceOfTokenId2, BALANCE_WHEN_1_YEAR, "user2 nft balance is not correct");
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
        stakedHemi.createLock(1 ether, MAX_TIME);

        // At creation time
        assertEq(
            stakedHemi.totalSupplyAt(startTime),
            BALANCE_WHEN_MAX_TIME,
            "Total supply at creation should be locked amount"
        );

        // At future time (before expiry)
        uint256 futureTime = startTime + (2 * 365 days);
        assertEq(
            stakedHemi.totalSupplyAt(futureTime),
            499171462713442575,
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

        uint256 timestamp_ = block.timestamp;

        uint256 supplyAt_ = stakedHemi.totalSupply();

        vm.warp(block.timestamp + 200 days);

        // At creation time
        assertEq(stakedHemi.totalSupplyAt(timestamp_), supplyAt_, "Total at past is not correct");
    }
}

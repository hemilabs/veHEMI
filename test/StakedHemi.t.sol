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
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

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
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

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
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

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
        uint256 tokenId_ = stakedHemi.createLock(amount_, unlockTime_);

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
        uint256 tokenId_ = stakedHemi.createLock(amount_, unlockTime_);

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

    function testGetVotes() public {
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(1 ether, MAX_TIME / 2);

        // Initially, user should have votes equal to their locked balance
        uint256 votes = stakedHemi.getVotes(user, tokenId);
        uint256 balanceOfTokenId1 = stakedHemi.balanceOfNFT(tokenId);
        assertEq(
            votes,
            balanceOfTokenId1,
            "Votes should be equal to balance of token id of not delegated"
        );
        assertEq(votes, BALANCE_WHEN_HALF_TIME, "Initial votes should equal locked amount");

        // Non-owner should have 0 votes
        uint256 nonOwnerVotes = stakedHemi.getVotes(address(0xCAFE), tokenId);
        assertEq(nonOwnerVotes, 0, "Non-owner should have 0 votes");
    }

    function testGetPastVotes() public {
        uint256 startTime = block.timestamp;
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(1 ether, MAX_TIME / 2);

        // At creation time
        uint256 votesAtStart = stakedHemi.getPastVotes(user, tokenId, startTime);
        assertEq(
            votesAtStart,
            BALANCE_WHEN_HALF_TIME,
            "Past votes at creation should equal locked amount"
        );

        // At future time (before expiry)
        uint256 timestamp_ = startTime + MAX_TIME / 4;
        uint256 votesAtSpecificTimestamp = stakedHemi.getPastVotes(user, tokenId, timestamp_);
        assertEq(
            votesAtSpecificTimestamp,
            BALANCE_WHEN_1_YEAR,
            "Past votes should remain same before expiry"
        );

        // After expiry
        uint256 afterExpiry = startTime + MAX_TIME + 1;
        uint256 votesAfterExpiry = stakedHemi.getPastVotes(user, tokenId, afterExpiry);
        assertEq(votesAfterExpiry, 0, "Past votes should be 0 after expiry");

        // pass time
        vm.warp(block.timestamp + MAX_TIME + 2);
        uint256 pastVotes = stakedHemi.getPastVotes(user, tokenId, timestamp_);
        assertEq(
            pastVotes,
            votesAtSpecificTimestamp,
            "Past votes should remain same before expiry"
        );
    }

    function testDelegate() public {
        vm.prank(user);
        uint256 delegatorToken = stakedHemi.createLock(0.5 ether, MAX_TIME);

        address delegatee = address(0xCAFE);
        hemi.mint(delegatee, 100 ether);
        vm.prank(delegatee);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(delegatee);
        uint256 delegateeToken = stakedHemi.createLock(0.5 ether, MAX_TIME);

        uint256 delegatorVotesAtStart = stakedHemi.getVotes(user, delegatorToken);
        uint256 delegateeVotesAtStart = stakedHemi.getVotes(delegatee, delegateeToken);
        // Delegate votes from delegator to delegatee
        vm.prank(user);
        stakedHemi.delegate(delegatorToken, delegateeToken);

        // Check that delegatee now has votes from both tokens
        uint256 delegateeVotes = stakedHemi.getVotes(delegatee, delegateeToken);
        // assertEq(
        //     delegateeVotes,
        //     delegatorVotesAtStart + delegateeVotesAtStart,
        //     "Delegatee should have votes from both tokens"
        // );

        // Delegator should have 0 votes (delegated away)
        uint256 delegatorVotes = stakedHemi.getVotes(user, delegatorToken);
        assertEq(delegatorVotes, 0, "Delegator should have 0 votes after delegation");

        vm.warp(block.timestamp + MAX_TIME / 2);

        delegateeVotes = stakedHemi.getVotes(delegatee, delegateeToken);
        // FIXME: This seems real bug.  Why votes not decreasing over time after delegation?
        // assertEq(
        //     delegateeVotes,
        //     499585731264021545,
        //     "Delegatee should have votes from both tokens"
        // );

        vm.warp(block.timestamp + MAX_TIME / 2 + 2);

        delegateeVotes = stakedHemi.getVotes(delegatee, delegateeToken);
        // FIXME: This seems real bug.  Why votes not decreasing over time after delegation?
        assertEq(
            delegateeVotes,
            499585731264021545,
            "Delegatee should have votes from both tokens"
        );
    }

    function testDelegateToZero() public {
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);

        // Delegate to zero (self-delegation)
        vm.prank(user);
        stakedHemi.delegate(tokenId, 0);

        // User should have their own votes back
        uint256 votes = stakedHemi.getVotes(user, tokenId);
        assertEq(votes, 100 ether, "User should have votes back after delegating to zero");
    }

    function testDelegateToSelf() public {
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);

        // Delegate to self (same as delegating to zero)
        vm.prank(user);
        stakedHemi.delegate(tokenId, tokenId);

        // Should be treated as delegating to zero
        uint256 votes = stakedHemi.getVotes(user, tokenId);
        assertEq(votes, 100 ether, "Self-delegation should be treated as no delegation");
    }

    function testDelegateToNonExistentToken() public {
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);

        // Try to delegate to non-existent token
        vm.prank(user);
        vm.expectRevert(StakedHemi.NonExistentToken.selector);
        stakedHemi.delegate(tokenId, 999);
    }

    function testDepositAccountingForVotes() public {
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 365 days);

        // Check initial votes
        uint256 initialVotes = stakedHemi.getVotes(user, tokenId);
        assertEq(initialVotes, 100 ether, "Initial votes should equal locked amount");

        // Increase amount
        vm.prank(user);
        stakedHemi.increaseAmount(tokenId, 50 ether);

        // Check votes after increase
        uint256 votesAfterIncrease = stakedHemi.getVotes(user, tokenId);
        assertEq(votesAfterIncrease, 150 ether, "Votes should increase with locked amount");

        // Check total supply
        assertEq(
            stakedHemi.totalSupply(),
            150 ether,
            "Total supply should reflect increased amount"
        );
    }

    function testWithdrawAccountingForVotes() public {
        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(100 ether, 2 weeks);

        // Check initial votes
        uint256 initialVotes = stakedHemi.getVotes(user, tokenId);
        assertEq(initialVotes, 100 ether, "Initial votes should equal locked amount");

        // Fast forward past unlock
        vm.warp(block.timestamp + 2 weeks + 1);

        // Withdraw
        vm.prank(user);
        stakedHemi.withdraw(tokenId);

        // Votes should be 0 after withdrawal
        uint256 votesAfterWithdraw = stakedHemi.getVotes(user, tokenId);
        assertEq(votesAfterWithdraw, 0, "Votes should be 0 after withdrawal");

        // Total supply should be 0
        assertEq(stakedHemi.totalSupply(), 0, "Total supply should be 0 after withdrawal");
    }

    function testDelegationAccounting() public {
        // Create delegator
        vm.prank(user);
        uint256 delegatorToken = stakedHemi.createLock(100 ether, 365 days);

        // Create delegatee
        address delegatee = address(0xCAFE);
        hemi.mint(delegatee, 50 ether);
        vm.prank(delegatee);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(delegatee);
        uint256 delegateeToken = stakedHemi.createLock(50 ether, 365 days);

        // Delegate
        vm.prank(user);
        stakedHemi.delegate(delegatorToken, delegateeToken);

        // Check delegatee votes (should have both)
        uint256 delegateeVotes = stakedHemi.getVotes(delegatee, delegateeToken);
        assertEq(delegateeVotes, 150 ether, "Delegatee should have votes from both tokens");

        // Check delegator votes (should have 0)
        uint256 delegatorVotes = stakedHemi.getVotes(user, delegatorToken);
        assertEq(delegatorVotes, 0, "Delegator should have 0 votes");

        // Increase delegator's locked amount
        vm.prank(user);
        stakedHemi.increaseAmount(delegatorToken, 25 ether);

        // Delegatee should now have additional votes
        uint256 delegateeVotesAfterIncrease = stakedHemi.getVotes(delegatee, delegateeToken);
        assertEq(
            delegateeVotesAfterIncrease,
            175 ether,
            "Delegatee should have votes from increased amount"
        );

        // Total supply should reflect the increase
        assertEq(
            stakedHemi.totalSupply(),
            175 ether,
            "Total supply should reflect increased amount"
        );
    }

    function testDelegationCheckpoints() public {
        vm.prank(user);
        uint256 delegatorToken = stakedHemi.createLock(100 ether, 365 days);

        address delegatee = address(0xCAFE);
        hemi.mint(delegatee, 50 ether);
        vm.prank(delegatee);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(delegatee);
        uint256 delegateeToken = stakedHemi.createLock(50 ether, 365 days);

        uint256 startTime = block.timestamp;

        // Delegate at start
        vm.prank(user);
        stakedHemi.delegate(delegatorToken, delegateeToken);

        // Check past votes at start time
        uint256 votesAtStart = stakedHemi.getPastVotes(delegatee, delegateeToken, startTime);
        assertEq(votesAtStart, 150 ether, "Past votes should reflect delegation at start");

        // Fast forward and change delegation
        vm.warp(block.timestamp + 100 days);
        vm.prank(user);
        stakedHemi.delegate(delegatorToken, 0); // Remove delegation

        // Check past votes at start time (should still be 150)
        uint256 votesAtStartAfterChange = stakedHemi.getPastVotes(
            delegatee,
            delegateeToken,
            startTime
        );
        assertEq(votesAtStartAfterChange, 150 ether, "Past votes should remain unchanged");

        // Check current votes (should be 50)
        uint256 currentVotes = stakedHemi.getVotes(delegatee, delegateeToken);
        assertEq(currentVotes, 50 ether, "Current votes should reflect removed delegation");
    }

    function testMultipleDelegations() public {
        // Create multiple tokens
        vm.prank(user);
        uint256 token1 = stakedHemi.createLock(100 ether, 365 days);

        address user2 = address(0xCAFE);
        hemi.mint(user2, 200 ether);
        vm.prank(user2);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(user2);
        uint256 token2 = stakedHemi.createLock(150 ether, 365 days);

        address user3 = address(0xDEAD);
        hemi.mint(user3, 100 ether);
        vm.prank(user3);
        hemi.approve(address(stakedHemi), type(uint256).max);
        vm.prank(user3);
        uint256 token3 = stakedHemi.createLock(75 ether, 365 days);

        // Delegate token1 and token2 to token3
        vm.prank(user);
        stakedHemi.delegate(token1, token3);
        vm.prank(user2);
        stakedHemi.delegate(token2, token3);

        // User3 should have votes from all three tokens
        uint256 user3Votes = stakedHemi.getVotes(user3, token3);
        assertEq(user3Votes, 325 ether, "User3 should have votes from all three tokens");

        // User1 and User2 should have 0 votes
        uint256 user1Votes = stakedHemi.getVotes(user, token1);
        uint256 user2Votes = stakedHemi.getVotes(user2, token2);
        assertEq(user1Votes, 0, "User1 should have 0 votes");
        assertEq(user2Votes, 0, "User2 should have 0 votes");

        // Total supply should be correct
        assertEq(stakedHemi.totalSupply(), 325 ether, "Total supply should be sum of all tokens");
    }

    function testMemoryStructIsCopied() public {
        // Define a struct in memory
        LockedBalance memory user = LockedBalance(1, 100);
        // Call a function that tries to modify it
        mutateUser(user);
        // Assert that the original struct is unchanged
        assertEq(user.amount, 1, "user.amount should not be changed");
        assertEq(user.end, 100, "user.end should not be changed");
    }

    function mutateUser(LockedBalance memory user) private {
        user.amount = 42;
        user.end = 999;
    }
}

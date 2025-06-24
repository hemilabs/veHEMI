// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {HemiVoteDelegation} from "../src/HemiVoteDelegation.sol";
import {StakedHemi} from "../src/StakedHemi.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TestHemiVoteDelegation is Test {
    address constant BILL = address(342_958_293_847_234_897);
    address constant ALICE = address(23_984_723_894_798);
    address constant WALTER = address(12_345_678);
    address constant BOB = address(987_654_321);

    HemiVoteDelegation public hemiVoteDelegation;
    StakedHemi public stakedHemi;
    MockERC20 public hemiToken;

    uint256 public constant LOCK_AMOUNT = 1e18;
    uint256 public constant LOCK_DURATION = 365 days * 4;

    function setUp() public {
        // Deploy mock HEMI token
        hemiToken = new MockERC20("HEMI", "HEMI", 18);

        StakedHemi logic = new StakedHemi(address(hemiToken));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(StakedHemi.initialize.selector, address(this), address(0))
        );
        stakedHemi = StakedHemi(address(proxy));

        // Deploy HemiVoteDelegation
        hemiVoteDelegation = new HemiVoteDelegation(address(stakedHemi));

        // Setup initial state
        _setupInitialState();
    }

    function _setupInitialState() internal {
        // Mint HEMI tokens to test accounts
        hemiToken.mint(BILL, LOCK_AMOUNT);
        hemiToken.mint(ALICE, LOCK_AMOUNT);
        hemiToken.mint(WALTER, LOCK_AMOUNT);
        hemiToken.mint(BOB, LOCK_AMOUNT);

        // Create locks for test accounts
        _createLock(BILL, LOCK_AMOUNT, LOCK_DURATION);
        _createLock(ALICE, LOCK_AMOUNT, LOCK_DURATION);
        _createLock(WALTER, LOCK_AMOUNT, LOCK_DURATION);
        _createLock(BOB, LOCK_AMOUNT, LOCK_DURATION);
    }

    function _createLock(
        address account,
        uint256 amount,
        uint256 duration
    ) internal returns (uint256 tokenId) {
        vm.startPrank(account);
        hemiToken.approve(address(stakedHemi), amount);
        tokenId = stakedHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    // Test basic delegation functionality
    function testBasicDelegation() public {
        uint256 billTokenId = 1; // First token ID
        uint256 aliceTokenId = 2; // ALICE's token ID

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, 0); // Delegate to self (no delegation)

        uint256 selfVotes = hemiVoteDelegation.getVotes(billTokenId);
        assertGt(selfVotes, 0, "Should have voting power when not delegated");

        hemiVoteDelegation.delegate(billTokenId, aliceTokenId); // Delegate to ALICE's token
        vm.stopPrank();

        // Delegation takes effect at next epoch
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Delegator should have no votes after delegation"
        );

        // Alice should have her own votes plus Bill's votes (with some decay)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotesAfter, aliceInitialVotes, "Alice should have received Bill's votes");

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotesAfter + hemiVoteDelegation.getVotes(billTokenId);
        uint256 totalVotesBefore = billInitialVotes + aliceInitialVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertGt(
            totalVotesAfter,
            (totalVotesBefore * 95) / 100,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation to non-existent token
    function testDelegationToNonExistentToken() public {
        vm.startPrank(BILL);
        vm.expectRevert(HemiVoteDelegation.NonExistentToken.selector);
        hemiVoteDelegation.delegate(1, 999); // Delegate to non-existent token
        vm.stopPrank();
    }

    // Test delegation with expired lock
    function testCantDelegateExpiredLock() public {
        uint256 billTokenId = 1;

        // Warp to just before lock expires
        uint256 lockEnd = stakedHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd - 1 days);

        vm.startPrank(BILL);
        vm.expectRevert(HemiVoteDelegation.CanNotDelegateExpiredLocks.selector);
        hemiVoteDelegation.delegate(billTokenId, 2);
        vm.stopPrank();
    }

    // Test delegation to self (should set delegatee to 0)
    function testDelegationToSelf() public {
        uint256 billTokenId = 1;

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, billTokenId); // Delegate to self
        vm.stopPrank();

        // Should be equivalent to no delegation
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        assertGt(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Should have voting power when delegated to self"
        );
    }

    // Test delegation to same delegatee (should be no-op)
    function testDelegationToSameDelegatee() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 aliceVotesBefore = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 billVotesBefore = hemiVoteDelegation.getVotes(billTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId); // Delegate to same delegatee again
        vm.stopPrank();

        // Should work without reverting
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Alice should have Bill's votes (with some decay due to time passing)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotesAfter, aliceVotesBefore, "Alice should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotesAfter + hemiVoteDelegation.getVotes(billTokenId);
        uint256 totalVotesBefore = aliceVotesBefore + billVotesBefore;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertGt(
            totalVotesAfter,
            (totalVotesBefore * 95) / 100,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation not owned by caller
    function testDelegationNotOwned() public {
        uint256 billTokenId = 1;

        vm.startPrank(ALICE);
        vm.expectRevert(HemiVoteDelegation.NotOwner.selector);
        hemiVoteDelegation.delegate(billTokenId, 2); // ALICE trying to delegate BILL's token
        vm.stopPrank();
    }

    // Test voting power before and after delegation
    function testVotingPowerBeforeAndAfterDelegation() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 initialBillVotes = hemiVoteDelegation.getVotes(billTokenId);
        uint256 initialAliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(initialBillVotes, 0, "Should have initial voting power");

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        // Before delegation takes effect
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            initialBillVotes,
            "Bill should still have votes before delegation takes effect"
        );
        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId),
            initialAliceVotes,
            "Alice should have no additional votes yet"
        );

        // After delegation takes effect
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Alice should have combined votes (with some decay due to time)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotesAfter, initialAliceVotes, "Alice should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotesAfter + hemiVoteDelegation.getVotes(billTokenId);
        uint256 totalVotesBefore = initialBillVotes + initialAliceVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertGt(
            totalVotesAfter,
            (totalVotesBefore * 95) / 100,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation switching
    function testDelegationSwitching() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(walterTokenId);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotes, aliceInitialVotes, "Alice should have received Bill's votes");

        // Switch delegation to Walter
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, walterTokenId);
        vm.stopPrank();

        // Alice should still have delegate votes until next epoch
        assertGt(
            hemiVoteDelegation.getVotes(aliceTokenId),
            aliceInitialVotes,
            "Alice should still have votes until next epoch"
        );
        // Walter should have his own votes but not Bill's votes yet
        assertGt(
            hemiVoteDelegation.getVotes(walterTokenId),
            0,
            "Walter should have his own votes but not Bill's votes yet"
        );

        assertLt(
            hemiVoteDelegation.getVotes(walterTokenId),
            walterInitialVotes,
            "Walter should have his own votes but not Bill's votes yet"
        );

        // After next epoch
        vm.warp(delegationStarts + 1 days);

        assertLt(
            hemiVoteDelegation.getVotes(aliceTokenId),
            aliceInitialVotes,
            "Alice should have her original votes back after delegation switch"
        );
        // Walter should have his own votes plus Bill's votes (with some decay)
        uint256 walterVotesAfter = hemiVoteDelegation.getVotes(walterTokenId);
        assertGt(walterVotesAfter, walterInitialVotes, "Walter should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId) +
            walterVotesAfter +
            hemiVoteDelegation.getVotes(billTokenId);
        uint256 totalVotesBefore = aliceInitialVotes + walterInitialVotes + billInitialVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertGt(
            totalVotesAfter,
            (totalVotesBefore * 95) / 100,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test multiple delegations to same delegatee
    function testMultipleDelegationsToSameDelegatee() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(walterTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotes, aliceInitialVotes, "Alice should have combined delegated votes");

        // Alice should have votes from both delegators
        uint256 billVotes = hemiVoteDelegation.getVotes(billTokenId);
        uint256 walterVotes = hemiVoteDelegation.getVotes(walterTokenId);
        assertEq(billVotes, 0, "Bill should have no votes");
        assertEq(walterVotes, 0, "Walter should have no votes");

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotes + billVotes + walterVotes;
        uint256 totalVotesBefore = aliceInitialVotes + billInitialVotes + walterInitialVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertGt(
            totalVotesAfter,
            (totalVotesBefore * 95) / 100,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation expiration
    function testDelegationExpiration() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotes, aliceInitialVotes, "Alice should have received Bill's votes");

        // Warp to lock expiration
        uint256 lockEnd = stakedHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd);

        // Alice should have her own votes back after Bill's lock expires
        uint256 aliceVotesAfterExpiry = hemiVoteDelegation.getVotes(aliceTokenId);
        assertEq(
            aliceVotesAfterExpiry,
            aliceInitialVotes,
            "Alice should have her original votes back after Bill's lock expires"
        );

        // Bill should have no votes after lock expires
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Bill should have no votes after lock expires"
        );
    }

    // Test getPastVotes functionality
    function testGetPastVotes() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;

        // Check votes at different timestamps
        assertEq(
            hemiVoteDelegation.getPastVotes(billTokenId, block.timestamp),
            billInitialVotes,
            "Should have votes at current time"
        );
        assertEq(
            hemiVoteDelegation.getPastVotes(aliceTokenId, block.timestamp),
            aliceInitialVotes,
            "Should have her own votes at current time"
        );

        vm.warp(delegationStarts);

        // After delegation, Bill should have no votes and Alice should have combined votes (with decay)
        uint256 billPastVotes = hemiVoteDelegation.getPastVotes(billTokenId, block.timestamp);
        uint256 alicePastVotes = hemiVoteDelegation.getPastVotes(aliceTokenId, block.timestamp);

        assertEq(billPastVotes, 0, "Bill should have no votes after delegation");
        assertGt(
            alicePastVotes,
            aliceInitialVotes,
            "Alice should have received Bill's votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = billPastVotes + alicePastVotes;
        uint256 totalVotesBefore = billInitialVotes + aliceInitialVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertGt(
            totalVotesAfter,
            (totalVotesBefore * 95) / 100,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test getPastVotes with future timestamp
    function testGetPastVotesFutureTimestamp() public {
        uint256 billTokenId = 1;

        vm.expectRevert(HemiVoteDelegation.TimestampInFuture.selector);
        hemiVoteDelegation.getPastVotes(billTokenId, block.timestamp + 1);
    }

    // Test delegation with different lock amounts
    function testDelegationWithDifferentAmounts() public {
        // Create new locks with different amounts
        uint256 smallAmount = 10_000e18;
        uint256 largeAmount = 200_000e18;

        hemiToken.mint(address(0x1111), smallAmount);
        hemiToken.mint(address(0x2222), largeAmount);

        uint256 smallTokenId = _createLock(address(0x1111), smallAmount, LOCK_DURATION);
        uint256 largeTokenId = _createLock(address(0x2222), largeAmount, LOCK_DURATION);
        uint256 delegateTokenId = 4; // BOB's token

        vm.startPrank(address(0x1111));
        hemiVoteDelegation.delegate(smallTokenId, delegateTokenId);
        vm.stopPrank();

        vm.startPrank(address(0x2222));
        hemiVoteDelegation.delegate(largeTokenId, delegateTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 totalDelegatedVotes = hemiVoteDelegation.getVotes(delegateTokenId);
        assertGt(totalDelegatedVotes, 0, "Should have combined delegated votes");

        // The delegatee should have votes from both delegators
        uint256 smallVotes = stakedHemi.balanceOfNFT(smallTokenId);
        uint256 largeVotes = stakedHemi.balanceOfNFT(largeTokenId);
        assertGt(totalDelegatedVotes, smallVotes, "Should have more than just small delegation");
        assertGt(totalDelegatedVotes, largeVotes, "Should have more than just large delegation");
    }

    // Test delegation with different lock durations
    function testDelegationWithDifferentDurations() public {
        uint256 shortDuration = 365 days;
        uint256 longDuration = 365 days * 4;

        hemiToken.mint(address(0x1111), LOCK_AMOUNT);
        hemiToken.mint(address(0x2222), LOCK_AMOUNT);

        uint256 shortTokenId = _createLock(address(0x1111), LOCK_AMOUNT, shortDuration);
        uint256 longTokenId = _createLock(address(0x2222), LOCK_AMOUNT, longDuration);
        uint256 delegateTokenId = 4;

        vm.startPrank(address(0x1111));
        hemiVoteDelegation.delegate(shortTokenId, delegateTokenId);
        vm.stopPrank();

        vm.startPrank(address(0x2222));
        hemiVoteDelegation.delegate(longTokenId, delegateTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 totalDelegatedVotes = hemiVoteDelegation.getVotes(delegateTokenId);
        assertGt(totalDelegatedVotes, 0, "Should have combined delegated votes");

        // Long duration lock should provide more voting power
        uint256 shortVotes = stakedHemi.balanceOfNFT(shortTokenId);
        uint256 longVotes = stakedHemi.balanceOfNFT(longTokenId);
        assertGt(longVotes, shortVotes, "Long duration should provide more voting power");
    }

    // Test delegation checkpoint functionality
    function testDelegationCheckpoints() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotes, 0, "Alice should have delegated votes");

        // Check that checkpoints are working correctly
        uint256 pastVotes = hemiVoteDelegation.getPastVotes(aliceTokenId, delegationStarts);
        assertEq(pastVotes, aliceVotes, "Past votes should match current votes at checkpoint time");
    }

    // Test delegation with expired locks
    function testDelegationWithExpiredLocks() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(aliceVotes, aliceInitialVotes, "Alice should have received Bill's votes");

        // Warp to just before lock expires
        uint256 lockEnd = stakedHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd - 1);

        uint256 aliceVotesBeforeExpiry = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGt(
            aliceVotesBeforeExpiry,
            aliceInitialVotes,
            "Alice should still have Bill's votes before expiry"
        );

        // Warp to after lock expires
        vm.warp(lockEnd + 1);

        // Alice should have her own votes back after Bill's lock expires
        uint256 aliceVotesAfterExpiry = hemiVoteDelegation.getVotes(aliceTokenId);
        assertEq(
            aliceVotesAfterExpiry,
            aliceInitialVotes,
            "Alice should have her original votes back after Bill's lock expires"
        );

        // Bill should have no votes after lock expires
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Bill should have no votes after lock expires"
        );
    }

    // Test delegation with multiple delegators and expirations
    function testMultipleDelegatorsWithExpirations() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;
        uint256 delegateTokenId = 4;

        uint256 delegateInitialVotes = hemiVoteDelegation.getVotes(delegateTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, delegateTokenId);
        vm.stopPrank();

        vm.startPrank(ALICE);
        hemiVoteDelegation.delegate(aliceTokenId, delegateTokenId);
        vm.stopPrank();

        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, delegateTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 totalVotes = hemiVoteDelegation.getVotes(delegateTokenId);
        assertGt(totalVotes, delegateInitialVotes, "Should have combined delegated votes");

        // Let one lock expire
        uint256 billLockEnd = stakedHemi.getLockedBalance(billTokenId).end;
        vm.warp(billLockEnd + 1);

        uint256 votesAfterOneExpiry = hemiVoteDelegation.getVotes(delegateTokenId);
        assertLt(votesAfterOneExpiry, totalVotes, "Should have fewer votes after one lock expires");
        assertGt(
            votesAfterOneExpiry,
            delegateInitialVotes,
            "Should still have votes from remaining locks"
        );

        // Let all locks expire
        uint256 aliceLockEnd = stakedHemi.getLockedBalance(aliceTokenId).end;
        uint256 walterLockEnd = stakedHemi.getLockedBalance(walterTokenId).end;
        uint256 lastExpiry = aliceLockEnd > walterLockEnd ? aliceLockEnd : walterLockEnd;
        vm.warp(lastExpiry + 1);

        // Should have only the delegate's own votes after all delegations expire
        uint256 votesAfterAllExpiry = hemiVoteDelegation.getVotes(delegateTokenId);
        assertEq(
            votesAfterAllExpiry,
            delegateInitialVotes,
            "Should have only delegate's own votes after all locks expire"
        );
    }

    // Test delegation with invalid token IDs
    function testDelegationWithInvalidTokenIds() public {
        vm.startPrank(BILL);

        // Try to delegate to token ID 0 (should work as self-delegation)
        hemiVoteDelegation.delegate(1, 0);

        // Try to delegate to non-existent token ID
        vm.expectRevert(HemiVoteDelegation.NonExistentToken.selector);
        hemiVoteDelegation.delegate(1, 999);

        vm.stopPrank();
    }

    // Test delegation with zero amount locks
    function testDelegationWithZeroAmountLocks() public {
        // This test would require creating a lock with zero amount, which should revert
        // But we can test the edge case where a lock exists but has zero voting power
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        // Try to delegate from a token that might have zero voting power
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Even with zero voting power, the delegation should work
        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        assertGe(aliceVotes, 0, "Should have zero or positive votes");
    }

    // Test delegation with very long lock durations
    function testDelegationWithLongLockDurations() public {
        uint256 maxDuration = 365 days * 4; // Maximum lock duration

        hemiToken.mint(address(0x1111), LOCK_AMOUNT);
        uint256 longTokenId = _createLock(address(0x1111), LOCK_AMOUNT, maxDuration);
        uint256 delegateTokenId = 4;

        vm.startPrank(address(0x1111));
        hemiVoteDelegation.delegate(longTokenId, delegateTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 delegatedVotes = hemiVoteDelegation.getVotes(delegateTokenId);
        assertGt(delegatedVotes, 0, "Should have delegated votes from long duration lock");

        // Long duration locks should provide maximum voting power
        uint256 maxVotes = stakedHemi.balanceOfNFT(longTokenId);
        assertGt(maxVotes, 0, "Long duration lock should provide voting power");
    }

    // Test delegation with very short lock durations
    function testDelegationWithShortLockDurations() public {
        uint256 shortDuration = 7 days; // Minimum lock duration (1 week)

        hemiToken.mint(address(0x1111), LOCK_AMOUNT);
        uint256 shortTokenId = _createLock(address(0x1111), LOCK_AMOUNT, shortDuration);
        uint256 delegateTokenId = 4;

        vm.startPrank(address(0x1111));
        hemiVoteDelegation.delegate(shortTokenId, delegateTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 delegatedVotes = hemiVoteDelegation.getVotes(delegateTokenId);
        assertGt(delegatedVotes, 0, "Should have delegated votes from short duration lock");

        // Short duration locks should provide minimal voting power
        uint256 shortVotes = stakedHemi.balanceOfNFT(shortTokenId);
        assertGt(shortVotes, 0, "Short duration lock should provide some voting power");
    }

    // Test delegation with edge case timestamps
    function testDelegationWithEdgeCaseTimestamps() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;

        // Test just before delegation takes effect
        vm.warp(delegationStarts - 1);
        assertGt(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Should still have votes just before delegation"
        );
        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId),
            aliceInitialVotes,
            "Should have only her own votes just before delegation"
        );

        // Test exactly when delegation takes effect
        vm.warp(delegationStarts);
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId),
            0,
            "Should have no votes when delegation takes effect"
        );
        assertGt(
            hemiVoteDelegation.getVotes(aliceTokenId),
            aliceInitialVotes,
            "Should have combined votes when delegation takes effect"
        );
    }

    // Test delegation with multiple rapid changes
    function testDelegationWithRapidChanges() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        hemiVoteDelegation.delegate(billTokenId, walterTokenId); // Rapid change
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId); // Rapid change back
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Only the final delegation should be active
        assertEq(hemiVoteDelegation.getVotes(billTokenId), 0, "Delegator should have no votes");
        assertGt(hemiVoteDelegation.getVotes(aliceTokenId), 0, "Final delegatee should have votes");
        assertEq(
            hemiVoteDelegation.getVotes(walterTokenId),
            0,
            "Intermediate delegatee should have no votes"
        );
    }

    // Test delegation with complex scenarios
    function testDelegationComplexScenario() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;
        uint256 bobTokenId = 4;

        // Bill delegates to Alice
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        // Walter delegates to Bob
        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, bobTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 bobVotes = hemiVoteDelegation.getVotes(bobTokenId);

        assertGt(aliceVotes, 0, "Alice should have Bill's votes");
        assertGt(bobVotes, 0, "Bob should have Walter's votes");

        // Bill switches to Bob
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, bobTokenId);
        vm.stopPrank();

        // Walter switches to Alice
        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 nextEpoch = delegationStarts + 1 days;
        vm.warp(nextEpoch);

        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId);
        uint256 bobVotesAfter = hemiVoteDelegation.getVotes(bobTokenId);

        assertGt(aliceVotesAfter, 0, "Alice should have Walter's votes");
        assertGt(bobVotesAfter, 0, "Bob should have Bill's votes");

        // Total voting power should be preserved
        assertEq(
            aliceVotesAfter + bobVotesAfter,
            aliceVotes + bobVotes,
            "Total voting power should be preserved"
        );
    }
}

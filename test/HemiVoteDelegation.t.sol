// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemiVoteDelegation} from "../src/interfaces/IVeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeCast} from "../src/libraries/SafeCast.sol";

contract TestVeHemiVoteDelegation is Test {
    using SafeCast for uint256;
    using SafeCast for int128;

    address constant BILL = address(342_958_293_847_234_897);
    address constant ALICE = address(23_984_723_894_798);
    address constant WALTER = address(12_345_678);
    address constant BOB = address(987_654_321);

    VeHemiVoteDelegation public hemiVoteDelegation;
    VeHemi public veHemi;
    MockERC20 public hemiToken;

    uint256 public constant LOCK_AMOUNT = 1e18;
    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;
    uint256 private constant MAX_TIME = 4 * YEAR; // 4 years
    uint256 private constant MULTIPLIER = 1 ether;

    function setUp() public {
        // Deploy mock HEMI token
        hemiToken = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemiToken));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        // Deploy VeHemiVoteDelegation
        hemiVoteDelegation = new VeHemiVoteDelegation(address(veHemi));

        veHemi.updateVoteDelegation(hemiVoteDelegation);

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
        _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        _createLock(WALTER, LOCK_AMOUNT, MAX_TIME);
        _createLock(BOB, LOCK_AMOUNT, MAX_TIME);
    }

    function _createLock(
        address account,
        uint256 amount,
        uint256 duration
    ) internal returns (uint256 tokenId, uint256 slope) {
        hemiToken.mint(account, amount);
        vm.startPrank(account);
        hemiToken.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();
        slope = amount / MAX_TIME;
    }

    function _delegate(address account, uint256 tokenId, uint256 delegateeTokenId) internal {
        vm.prank(account);
        hemiVoteDelegation.delegate(tokenId, delegateeTokenId);
    }

    function _delegateAndWarp(address account, uint256 tokenId, uint256 delegateeTokenId) internal {
        _delegate(account, tokenId, delegateeTokenId);
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);
    }

    // Test basic delegation functionality
    function testBasicDelegation() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Delegator should have no votes after delegation"
        );

        // Alice should have her own votes plus Bill's votes (with some decay)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotesAfter,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes"
        );

        uint256 totalVotesBefore = billInitialVotes + aliceInitialVotes;
        assertLe(aliceVotesAfter, totalVotesBefore, "Total voting power should not increase");
        uint256 expectedAliceVotes = veHemi.balanceOfNFT(aliceTokenId) +
            veHemi.balanceOfNFT(billTokenId);
        assertEq(
            aliceVotesAfter,
            expectedAliceVotes,
            "Voting power should not decay more than 5% in one day"
        );
    }

    function testReDelegation() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        //delegate to self
        _delegateAndWarp(ALICE, aliceTokenId, aliceTokenId);
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        uint256 billBalance = veHemi.balanceOfNFT(billTokenId);
        uint256 aliceBalance = veHemi.balanceOfNFT(aliceTokenId);

        assertEq(
            aliceVotesAfter,
            aliceBalance + billBalance,
            "Alice vote should be the same after re-delegation"
        );
    }

    function testReDelegationWhenAmountIncreased() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        // remove delegation and assign to self
        _delegateAndWarp(BILL, billTokenId, billTokenId);

        uint256 billVoteBefore = hemiVoteDelegation.getVotes(billTokenId, BILL);

        // more amount added to alice lock
        hemiToken.mint(ALICE, LOCK_AMOUNT);
        vm.startPrank(ALICE);
        hemiToken.approve(address(veHemi), LOCK_AMOUNT);
        // add amount to bill lock
        veHemi.increaseAmount(billTokenId, LOCK_AMOUNT);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        assertGt(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            billVoteBefore,
            "Alice should have received Bill's votes"
        );
    }

    function testReDelegationWhenAmountIncreasedByDelegator() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVoteBefore = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        // more amount added to BILL lock
        hemiToken.mint(BILL, LOCK_AMOUNT);
        vm.startPrank(BILL);
        hemiToken.approve(address(veHemi), LOCK_AMOUNT);
        // add amount to bill lock
        veHemi.increaseAmount(billTokenId, LOCK_AMOUNT);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        assertGt(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            aliceVoteBefore,
            "Alice should have received Bill's votes"
        );
    }

    function testReDelegationWhenLockExtendedByDelegator() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, 1 * YEAR);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, 1 * YEAR);
        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVoteBefore = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        vm.prank(BILL);
        veHemi.increaseUnlockTime(billTokenId, 2 * YEAR);

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        assertGt(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            aliceVoteBefore,
            "Alice should have received Bill's votes"
        );
    }

    function testRemoveDelegation() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVotesAfterDelegation = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertGt(
            aliceVotesAfterDelegation,
            aliceInitialVotes,
            "Alice should have received Bill's votes"
        );
        uint256 billVoteAfterDelegation = hemiVoteDelegation.getVotes(billTokenId, BILL);
        assertEq(billVoteAfterDelegation, 0, "Bill should have no votes after delegation");

        // Switch delegation to Walter
        _delegateAndWarp(BILL, billTokenId, billTokenId);

        uint256 aliceExpectedVotes = veHemi.balanceOfNFT(aliceTokenId);

        uint256 aliceVotesAfterDelegationRemoved = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotesAfterDelegationRemoved,
            aliceExpectedVotes,
            "Alice should have her original votes back after delegation switch"
        );
        uint256 billVoteAfterDelegationRemoved = hemiVoteDelegation.getVotes(billTokenId, BILL);
        assertGt(billVoteAfterDelegationRemoved, 0, "Bill should have received his own votes");
    }

    // Test delegation to non-existent token
    function testDelegationToNonExistentToken() public {
        vm.startPrank(BILL);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        hemiVoteDelegation.delegate(1, 999); // Delegate to non-existent token
        vm.stopPrank();
    }

    // Test delegation with expired lock
    function testCantDelegateExpiredLock() public {
        uint256 billTokenId = 1;

        // Warp to just before lock expires
        uint256 lockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd + 1 days);

        vm.startPrank(BILL);
        vm.expectRevert(VeHemiVoteDelegation.CanNotDelegateExpiredLocks.selector);
        hemiVoteDelegation.delegate(billTokenId, 2);
        vm.stopPrank();
    }

    // Test delegation to self (should set delegatee to 0)
    function testDelegationToSelf() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        _delegateAndWarp(BILL, billTokenId, billTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            veHemi.balanceOfNFT(billTokenId),
            "Should have voting power when delegated to self"
        );

        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVotesAfterDelegation = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        assertEq(
            aliceVotesAfterDelegation,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Should have less voting power when delegator remove delegations"
        );

        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Should have voting power 0 delegated to other"
        );

        _delegateAndWarp(BILL, billTokenId, billTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            veHemi.balanceOfNFT(billTokenId),
            "Should have voting power when delegated to self"
        );
        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            veHemi.balanceOfNFT(aliceTokenId),
            "Should have less voting power when delegator remove delegations"
        );
    }

    // Test delegation to same delegatee (should be no-op)
    function testDelegationToSameDelegatee() public {
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        uint256 aliceVotesBefore = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 billVotesBefore = hemiVoteDelegation.getVotes(billTokenId, BILL);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId); // Delegate to same delegatee again
        vm.stopPrank();

        // Should work without reverting
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Alice should have Bill's votes (with some decay due to time passing)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotesAfter,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes (once)"
        );

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Bill should have no votes after delegation"
        );
        uint256 totalVotesAfter = aliceVotesAfter;
        uint256 totalVotesBefore = aliceVotesBefore + billVotesBefore;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertApproxEqRel(
            totalVotesAfter,
            totalVotesBefore,
            0.05e18,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation not owned by caller
    function testDelegationNotOwned() public {
        uint256 billTokenId = 1;

        vm.startPrank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.CallerIsNotAuthorized.selector);
        hemiVoteDelegation.delegate(billTokenId, 2); // ALICE trying to delegate BILL's token
        vm.stopPrank();
    }

    // Test voting power before and after delegation
    function testVotingPowerBeforeAndAfterDelegation() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 initialBillVotes = hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 initialAliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertGt(initialBillVotes, 0, "Should have initial voting power");

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        // Before delegation takes effect
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            initialBillVotes,
            "Bill should still have votes before delegation takes effect"
        );
        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            initialAliceVotes,
            "Alice should have no additional votes yet"
        );

        // After delegation takes effect
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Alice should have combined votes (with some decay due to time)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertGt(aliceVotesAfter, initialAliceVotes, "Alice should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotesAfter + hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 totalVotesBefore = initialBillVotes + initialAliceVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertApproxEqRel(
            totalVotesAfter,
            totalVotesBefore,
            0.05e18,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation switching
    function testDelegationSwitching() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(walterTokenId, WALTER);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId, BILL);

        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertGt(aliceVotes, aliceInitialVotes, "Alice should have received Bill's votes");

        // Switch delegation to Walter
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, walterTokenId);
        vm.stopPrank();

        // Alice should still have delegate votes until next epoch
        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should still have votes until next epoch"
        );
        // Walter should have his own votes but not Bill's votes yet
        uint256 walterVotes = hemiVoteDelegation.getVotes(walterTokenId, WALTER);
        assertEq(
            walterVotes,
            veHemi.balanceOfNFT(walterTokenId),
            "Walter should have his own votes but not Bill's votes yet"
        );

        // After next epoch
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts + 1 days);

        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            veHemi.balanceOfNFT(aliceTokenId),
            "Alice should have her original votes back after delegation switch"
        );
        // Walter should have his own votes plus Bill's votes (with some decay)
        uint256 walterVotesAfter = hemiVoteDelegation.getVotes(walterTokenId, WALTER);
        assertGt(walterVotesAfter, walterInitialVotes, "Walter should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId, ALICE) +
            walterVotesAfter +
            hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 totalVotesBefore = aliceInitialVotes + walterInitialVotes + billInitialVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertApproxEqRel(
            totalVotesAfter,
            totalVotesBefore,
            0.05e18,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test multiple delegations to same delegatee
    function testMultipleDelegationsToSameDelegatee() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(walterTokenId, WALTER);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, aliceTokenId);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) +
                veHemi.balanceOfNFT(billTokenId) +
                veHemi.balanceOfNFT(walterTokenId),
            "Alice should have combined delegated votes"
        );

        // Alice should have votes from both delegators
        uint256 billVotes = hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 walterVotes = hemiVoteDelegation.getVotes(walterTokenId, WALTER);
        assertEq(billVotes, 0, "Bill should have no votes");
        assertEq(walterVotes, 0, "Walter should have no votes");

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotes + billVotes + walterVotes;
        uint256 totalVotesBefore = aliceInitialVotes + billInitialVotes + walterInitialVotes;
        assertLe(totalVotesAfter, totalVotesBefore, "Total voting power should not increase");
        assertApproxEqRel(
            totalVotesAfter,
            totalVotesBefore,
            0.05e18,
            "Voting power should not decay more than 5% in one day"
        );
    }

    // Test delegation expiration
    function testDelegationExpiration() public {
        uint256 lockAmount = 1 ether;
        (uint256 aliceTokenId, ) = _createLock(ALICE, lockAmount, 4 * 365 days);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(aliceInitialVotes, veHemi.balanceOfNFT(aliceTokenId));

        (uint256 billTokenId, ) = _createLock(BILL, 1 ether, 365 days);
        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes"
        );

        // Warp to lock expiration
        uint256 lockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd + 1);

        // Alice should have her own votes back after Bill's lock expires
        uint256 aliceVotesAfterExpiry = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotesAfterExpiry,
            veHemi.balanceOfNFT(aliceTokenId),
            "Alice should have her original votes back after Bill's lock expires"
        );

        // Bill should have no votes after lock expires
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Bill should have no votes after lock expires"
        );
    }

    // Alice and Bill Delegate to WALTER . After some some time Walter lock is forfeited

    function testVoteAfterForfeit() public {
        uint256 lockAmount = 1 ether;
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        // Create forfeitable lock for WALTER
        hemiToken.mint(BILL, lockAmount);
        vm.startPrank(BILL);
        hemiToken.approve(address(veHemi), lockAmount);
        uint256 walterTokenId = veHemi.createLockFor(lockAmount, 4 * 365 days, WALTER, false, true);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);

        vm.prank(forfeitAdmin);
        veHemi.forfeit(walterTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(walterTokenId, WALTER),
            0,
            "Walter should have no votes after forfeit"
        );
    }

    function testDelegatedVotesAfterForfeit() public {
        uint256 lockAmount = 1 ether;
        address forfeitAdmin = address(0x5678);

        // Set up forfeit admin
        vm.prank(address(this));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        (uint256 billTokenId, ) = _createLock(BILL, lockAmount, 4 * 365 days);
        (uint256 aliceTokenId, ) = _createLock(ALICE, lockAmount, 4 * 365 days);

        // Create forfeitable lock for WALTER
        hemiToken.mint(BILL, lockAmount);
        vm.startPrank(BILL);
        hemiToken.approve(address(veHemi), lockAmount);
        uint256 walterTokenId = veHemi.createLockFor(lockAmount, 4 * 365 days, WALTER, false, true);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);

        _delegateAndWarp(BILL, billTokenId, walterTokenId);
        _delegateAndWarp(ALICE, aliceTokenId, walterTokenId);

        vm.prank(forfeitAdmin);
        veHemi.forfeit(walterTokenId);

        uint256 aliceBalance = veHemi.balanceOfNFT(aliceTokenId);
        uint256 billBalance = veHemi.balanceOfNFT(billTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(walterTokenId, WALTER),
            aliceBalance + billBalance,
            "Walter should have just delegated votes"
        );
    }

    function testVoteAfterDelegateeLockExpire() public {
        uint256 lockAmount = 1 ether;
        (uint256 aliceTokenId, ) = _createLock(ALICE, lockAmount, 365 days);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(aliceInitialVotes, veHemi.balanceOfNFT(aliceTokenId));

        (uint256 billTokenId, ) = _createLock(BILL, 1 ether, 2 * 365 days);
        _delegateAndWarp(BILL, billTokenId, aliceTokenId);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes"
        );

        // Warp to lock expiration
        uint256 lockEnd = veHemi.getLockedBalance(aliceTokenId).end;
        vm.warp(lockEnd + 1);

        // Alice should have her bill's votes after Alice lock expired

        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            veHemi.balanceOfNFT(billTokenId),
            "Alice should have BILL votes after Alice lock expired"
        );

        lockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd + 1);

        assertEq(
            hemiVoteDelegation.getVotes(aliceTokenId, ALICE),
            0,
            "Alice should have her original votes back after Bill's lock expires"
        );
    }

    // Test getPastVotes functionality
    function testGetPastVotes() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(billTokenId, BILL);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        // Check votes at different timestamps
        assertEq(
            hemiVoteDelegation.getPastVotes(billTokenId, block.timestamp, BILL),
            billInitialVotes,
            "Should have votes at current time"
        );
        assertEq(
            hemiVoteDelegation.getPastVotes(aliceTokenId, block.timestamp, ALICE),
            aliceInitialVotes,
            "Should have her own votes at current time"
        );

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // After delegation, Bill should have no votes and Alice should have combined votes (with decay)
        uint256 billPastVotes = hemiVoteDelegation.getPastVotes(billTokenId, block.timestamp, BILL);
        uint256 alicePastVotes = hemiVoteDelegation.getPastVotes(
            aliceTokenId,
            block.timestamp,
            ALICE
        );

        assertEq(billPastVotes, 0, "Bill should have no votes after delegation");
        assertEq(
            alicePastVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes after delegation"
        );
    }

    // Test getPastVotes with future timestamp
    function testGetPastVotesFutureTimestamp() public {
        uint256 billTokenId = 1;

        vm.expectRevert(VeHemiVoteDelegation.TimestampInFuture.selector);
        hemiVoteDelegation.getPastVotes(billTokenId, block.timestamp + 1, BILL);
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

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have delegated votes"
        );

        // Check that checkpoints are working correctly
        uint256 pastVotes = hemiVoteDelegation.getPastVotes(aliceTokenId, delegationStarts, ALICE);
        assertEq(pastVotes, aliceVotes, "Past votes should match current votes at checkpoint time");
    }

    // Test delegation with multiple delegators and expirations
    function testMultipleDelegatorsWithExpirations() public {
        (uint256 billTokenId, ) = _createLock(BILL, 1 ether, 365 days);
        (uint256 aliceTokenId, ) = _createLock(ALICE, 1 ether, 2 * 365 days);
        (uint256 walterTokenId, ) = _createLock(WALTER, 1 ether, 3 * 365 days);
        (uint256 delegateTokenId, uint256 delegateSlope) = _createLock(BOB, 1 ether, 4 * 365 days);

        uint256 delegateInitialVotes = hemiVoteDelegation.getVotes(delegateTokenId, BOB);

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

        uint256 totalVotes = hemiVoteDelegation.getVotes(delegateTokenId, BOB);
        uint256 expectedVotes = veHemi.balanceOfNFT(delegateTokenId) +
            veHemi.balanceOfNFT(billTokenId) +
            veHemi.balanceOfNFT(aliceTokenId) +
            veHemi.balanceOfNFT(walterTokenId);
        assertEq(totalVotes, expectedVotes, "Should have combined delegated votes");

        // Let one lock expire
        uint256 billLockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(billLockEnd + 1);

        uint256 votesAfterOneExpiry = hemiVoteDelegation.getVotes(delegateTokenId, BOB);
        expectedVotes =
            veHemi.balanceOfNFT(delegateTokenId) +
            veHemi.balanceOfNFT(aliceTokenId) +
            veHemi.balanceOfNFT(walterTokenId);

        assertEq(
            votesAfterOneExpiry,
            expectedVotes,
            "Should still have votes from remaining locks"
        );

        // Let all locks expire
        uint256 aliceLockEnd = veHemi.getLockedBalance(aliceTokenId).end;
        uint256 walterLockEnd = veHemi.getLockedBalance(walterTokenId).end;
        uint256 lastExpiry = aliceLockEnd > walterLockEnd ? aliceLockEnd : walterLockEnd;
        vm.warp(lastExpiry + 1);

        // Should have only the delegate's own votes after all delegations expire
        uint256 expectedDelegateVotes = delegateSlope *
            (veHemi.getLockedBalance(delegateTokenId).end - block.timestamp);

        uint256 votesAfterAllExpiry = hemiVoteDelegation.getVotes(delegateTokenId, BOB);
        assertEq(
            votesAfterAllExpiry,
            expectedDelegateVotes,
            "Should have only delegate's own votes after all locks expire"
        );
    }

    // Test delegation with multiple rapid changes
    function testDelegationWithRapidChanges() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;
        uint256 walterTokenId = 3;

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(walterTokenId, WALTER);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        hemiVoteDelegation.delegate(billTokenId, walterTokenId); // Rapid change
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId); // Rapid change back
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Only the final delegation should be active
        assertEq(
            hemiVoteDelegation.getVotes(billTokenId, BILL),
            0,
            "Delegator should have no votes"
        );
        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 walterVotes = hemiVoteDelegation.getVotes(walterTokenId, WALTER);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice delegatee should have delegated"
        );
        assertEq(walterVotes, veHemi.balanceOfNFT(walterTokenId), "Walter should not have");
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

        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 bobVotes = hemiVoteDelegation.getVotes(bobTokenId, BOB);

        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have Bill's votes"
        );
        assertEq(
            bobVotes,
            veHemi.balanceOfNFT(bobTokenId) + veHemi.balanceOfNFT(walterTokenId),
            "Bob should have Walter's votes"
        );
        assertEq(hemiVoteDelegation.getVotes(billTokenId, BILL), 0, "Bill shouldn't have votes");
        assertEq(
            hemiVoteDelegation.getVotes(walterTokenId, WALTER),
            0,
            "Walter shouldn't have votes"
        );

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

        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(aliceTokenId, ALICE);
        uint256 bobVotesAfter = hemiVoteDelegation.getVotes(bobTokenId, BOB);

        assertEq(
            aliceVotesAfter,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(walterTokenId),
            "Alice should have Bill's votes"
        );
        assertEq(
            bobVotesAfter,
            veHemi.balanceOfNFT(bobTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Bob should have Walter's votes"
        );

        // Total voting power should be preserved
        assertApproxEqAbs(
            aliceVotesAfter + bobVotesAfter,
            aliceVotes + bobVotes,
            0.005e18,
            "Total voting power should be preserved"
        );
    }

    // ===== TESTS FOR calculateExpiredDelegations AND writeNewCheckpointForExpiredDelegations =====

    function testNoDelegationExpired() public view {
        uint256 tokenId = 1;

        // No delegations exist, should return empty checkpoint
        IVeHemiVoteDelegation.DelegateCheckpoint memory emptyCheckpoint = hemiVoteDelegation
            .calculateExpiredDelegations(tokenId);

        assertEq(
            emptyCheckpoint.timestamp,
            0,
            "Should return empty checkpoint for token with no delegations"
        );
        assertEq(emptyCheckpoint.normalizedBias, 0, "Should have zero bias");
        assertEq(emptyCheckpoint.normalizedSlope, 0, "Should have zero slope");
        assertEq(emptyCheckpoint.totalAmount, 0, "Should have zero amount");
    }

    function testWhenNoExpirations() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        // Create delegation
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        // Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Calculate expired delegations immediately after delegation starts
        // Should return empty checkpoint since no time has passed for expirations
        IVeHemiVoteDelegation.DelegateCheckpoint memory noExpirationCheckpoint = hemiVoteDelegation
            .calculateExpiredDelegations(aliceTokenId);

        assertEq(
            noExpirationCheckpoint.timestamp,
            0,
            "Should return empty checkpoint when no expirations occurred"
        );
    }

    // Test calculateExpiredDelegations with expirations
    function testExpirations() public {
        uint256 aliceTokenId = 2;

        // Create delegation with short lock duration
        uint256 shortLockDuration = 7 days; // 1 week
        (uint256 billTokenIdNew, ) = _createLock(BILL, LOCK_AMOUNT, shortLockDuration);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenIdNew, aliceTokenId);
        vm.stopPrank();

        // Get the lock end time
        uint256 lockEnd = veHemi.getLockedBalance(billTokenIdNew).end;

        // Warp past the lock expiration
        vm.warp(lockEnd + 1 days);

        // Calculate expired delegations
        IVeHemiVoteDelegation.DelegateCheckpoint memory expirationCheckpoint = hemiVoteDelegation
            .calculateExpiredDelegations(aliceTokenId);

        // Should have a new checkpoint with expired values
        assertGt(expirationCheckpoint.timestamp, 0, "Should have timestamp for new checkpoint");
        assertEq(expirationCheckpoint.normalizedBias, 0, "Should have some bias in checkpoint");
        assertEq(expirationCheckpoint.normalizedSlope, 0, "Should have some slope in checkpoint");
        assertEq(expirationCheckpoint.totalAmount, 0, "Should have some amount in checkpoint");
    }

    function testWriteNewCheckpointNoExpirations() public {
        uint256 billTokenId = 1;
        uint256 aliceTokenId = 2;

        // Create delegation
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, aliceTokenId);
        vm.stopPrank();

        // Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Should revert with NoExpirations error
        vm.expectRevert(VeHemiVoteDelegation.NoExpirations.selector);
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(aliceTokenId);
    }

    // Test writeNewCheckpointForExpiredDelegations with expirations
    function testWriteNewCheckpointWithExpirations() public {
        uint256 aliceTokenId = 2;

        // Create delegation with short lock duration
        uint256 shortLockDuration = 7 days; // 1 week
        (uint256 billTokenIdNew, ) = _createLock(BILL, LOCK_AMOUNT, shortLockDuration);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenIdNew, aliceTokenId);
        vm.stopPrank();

        // Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        IVeHemiVoteDelegation.DelegateCheckpoint[]
            memory delegationCheckpointsBefore = hemiVoteDelegation.getDelegationCheckpoints(
                aliceTokenId
            );

        assertEq(delegationCheckpointsBefore.length, 1, "Should have 1 checkpoint");

        vm.warp(delegationStarts + 8 days);
        // Write new checkpoint for expirations
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(aliceTokenId);

        IVeHemiVoteDelegation.DelegateCheckpoint[] memory delegationCheckpoints = hemiVoteDelegation
            .getDelegationCheckpoints(aliceTokenId);

        assertEq(
            delegationCheckpoints.length,
            delegationCheckpointsBefore.length + 1,
            "Should have 2 checkpoints"
        );
    }

    function testDifferentExpirations() public {
        uint256 delegateTokenId = 4;

        // Create delegations with different lock durations
        (uint256 billTokenIdNew, ) = _createLock(BILL, LOCK_AMOUNT, 7 days); // 1 week
        (uint256 walterTokenIdNew, ) = _createLock(WALTER, LOCK_AMOUNT, 14 days); // 2 weeks

        // Bill delegates to delegate
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenIdNew, delegateTokenId);
        vm.stopPrank();

        // Walter delegates to delegate
        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenIdNew, delegateTokenId);
        vm.stopPrank();

        // Warp to delegation start
        vm.warp(block.timestamp + 9 days);

        IVeHemiVoteDelegation.DelegateCheckpoint[] memory delegationCheckpoints = hemiVoteDelegation
            .getDelegationCheckpoints(delegateTokenId);

        assertEq(delegationCheckpoints.length, 1, "Should have 1 checkpoint");

        // Write checkpoint for Bill's expiration
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(delegateTokenId);

        delegationCheckpoints = hemiVoteDelegation.getDelegationCheckpoints(delegateTokenId);

        assertEq(delegationCheckpoints.length, 2, "Should have 2 checkpoints");

        vm.warp(block.timestamp + 9 days);
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(delegateTokenId);

        delegationCheckpoints = hemiVoteDelegation.getDelegationCheckpoints(delegateTokenId);

        assertEq(delegationCheckpoints.length, 3, "Should have 3 checkpoints");
    }

    // Test delegateBySig functionality
    function testDelegateBySig() public {
        // Create private key for Alice
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);

        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);

        (uint256 bobTokenId, ) = _createLock(BOB, LOCK_AMOUNT, 30 days);

        // Set timestamp and create signature
        uint256 currentTimestamp = block.timestamp;
        uint256 expiry = currentTimestamp + 3600; // 1 hour from now

        bytes32 digest = _getTypesDataHash(aliceTokenId, bobTokenId, 0, expiry);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        // Call delegateBySig
        hemiVoteDelegation.delegateBySig(aliceTokenId, bobTokenId, 0, expiry, v, r, s);

        // Warp to delegation start to see the effect
        uint256 delegationStarts = ((block.timestamp / 1 days) * 1 days) + 1 days;
        vm.warp(delegationStarts);

        // Verify delegation took effect
        uint256 aliceVotes = hemiVoteDelegation.getVotes(aliceTokenId, alice);
        uint256 bobVotes = hemiVoteDelegation.getVotes(bobTokenId, BOB);

        assertEq(aliceVotes, 0, "Alice should have no votes after delegation");
        assertEq(
            bobVotes,
            veHemi.balanceOfNFT(bobTokenId) + veHemi.balanceOfNFT(aliceTokenId),
            "Bob should have received Alice's votes"
        );
    }

    // Test delegateBySig with invalid signature
    function testDelegateBySigInvalidSignature() public {
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);

        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);

        (uint256 bobTokenId, ) = _createLock(BOB, LOCK_AMOUNT, 30 days);

        // Set timestamp and create signature
        uint256 currentTimestamp = block.timestamp;
        uint256 expiry = currentTimestamp + 3600; // 1 hour from now

        bytes32 digest = _getTypesDataHash(aliceTokenId, bobTokenId, 0, expiry);

        // Create signature with wrong private key
        uint256 wrongPrivateKey = 0xB0B;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        // Should revert with NotOwner
        vm.expectRevert(VeHemiVoteDelegation.NotOwner.selector);
        hemiVoteDelegation.delegateBySig(aliceTokenId, bobTokenId, 0, expiry, v, r, s);
    }

    // // Test delegateBySig with expired signature
    function testDelegateBySigExpiredSignature() public {
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);

        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);

        (uint256 bobTokenId, ) = _createLock(BOB, LOCK_AMOUNT, 30 days);

        // Set timestamp and create signature
        uint256 currentTimestamp = block.timestamp;
        uint256 expiry = currentTimestamp + 3600; // 1 hour from now

        bytes32 digest = _getTypesDataHash(aliceTokenId, bobTokenId, 0, expiry);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        // Warp past expiry
        vm.warp(expiry + 1);

        // Should revert with SignatureExpired
        vm.expectRevert(VeHemiVoteDelegation.SignatureExpired.selector);
        hemiVoteDelegation.delegateBySig(aliceTokenId, bobTokenId, 0, expiry, v, r, s);
    }

    // // Test delegateBySig with invalid nonce
    function testDelegateBySigInvalidNonce() public {
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);

        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);

        (uint256 bobTokenId, ) = _createLock(BOB, LOCK_AMOUNT, 30 days);

        // Set timestamp and create signature
        uint256 currentTimestamp = block.timestamp;
        uint256 expiry = currentTimestamp + 3600; // 1 hour from now

        bytes32 digest = _getTypesDataHash(aliceTokenId, bobTokenId, 1, expiry);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        // Should revert with InvalidNonce
        vm.expectRevert(VeHemiVoteDelegation.InvalidNonce.selector);
        hemiVoteDelegation.delegateBySig(aliceTokenId, bobTokenId, 1, expiry, v, r, s);
    }

    function _getTypesDataHash(
        uint256 delegator_,
        uint256 delegatee_,
        uint256 nonce_,
        uint256 expiry_
    ) internal view returns (bytes32) {
        bytes32 DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );
        bytes32 DELEGATION_TYPEHASH = keccak256(
            "Delegation(uint256 delegator,uint256 delegatee,uint256 nonce,uint256 expiry)"
        );

        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("veHEMIDelegation")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                address(hemiVoteDelegation)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegator_, delegatee_, nonce_, expiry_)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }
}

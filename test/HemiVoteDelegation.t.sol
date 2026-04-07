// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemiVoteDelegation} from "../src/interfaces/IVeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MockVeHemi} from "./mocks/MockVeHemi.sol";

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

        // Step 1: Deploy VeHemi logic contract
        VeHemi logic = new VeHemi(address(hemiToken));

        // Step 2: Deploy VeHemi proxy with initialization
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        // Step 3: Deploy VeHemiVoteDelegation with VeHemi proxy address
        hemiVoteDelegation = new VeHemiVoteDelegation(address(veHemi));

        // Step 4: Update VeHemi with the vote delegation address
        veHemi.updateVoteDelegation(hemiVoteDelegation);
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

    function _delegate(uint256 tokenId, address delegatee) internal {
        address _owner = veHemi.ownerOf(tokenId);
        vm.prank(_owner);
        hemiVoteDelegation.delegate(tokenId, delegatee);
    }

    function _delegateAndWarp(uint256 tokenId, address delegatee) internal {
        _delegate(tokenId, delegatee);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);
    }

    function testEvents() public {
        //
        // given
        //
        uint256 amount = 100e18;
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        hemiToken.mint(user1, amount);

        vm.prank(user1);
        hemiToken.approve(address(veHemi), amount);

        uint256 tokenId = 1;
        uint256 expectedVotes = 99941535477891810000; // 99.94e18 (evaluated at next hour boundary)

        //
        // Emit events when creating lock
        //
        vm.expectEmit();
        emit IVeHemiVoteDelegation.DelegateVotesChanged(user1, 0, expectedVotes);

        vm.expectEmit();
        emit IVeHemiVoteDelegation.DelegateChanged(tokenId, address(0), user1);

        vm.prank(user1);
        veHemi.createLock(amount, MAX_TIME);

        //
        // Emit events when delegating
        //
        vm.expectEmit();
        emit IVeHemiVoteDelegation.DelegateVotesChanged(user1, expectedVotes, 0);

        vm.expectEmit();
        emit IVeHemiVoteDelegation.DelegateVotesChanged(user2, 0, expectedVotes);

        vm.expectEmit();
        emit IVeHemiVoteDelegation.DelegateChanged(tokenId, user1, user2);

        vm.prank(user1);
        hemiVoteDelegation.delegate(tokenId, user2);
    }

    // Test basic delegation functionality
    function testBasicDelegation() public {
        // Given - Bill and Alice have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(BILL);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);

        // When - Bill delegates to Alice
        _delegateAndWarp(billTokenId, ALICE);

        // Then - Delegator should have no votes, delegatee should have combined votes
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            0,
            "Delegator should have no votes after delegation"
        );

        // Alice should have her own votes plus Bill's votes (with some decay)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(ALICE);
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

    // This test following scenario
    // 1. User1 create lock for x days delegate to Alice. Alice's original lock has amount less than amount locked by User1
    // 2. Before x days passed.  User1 increase lock time to x+ y days
    // 3. After x days passed , User1 delegate to User2 .
    // In this flow, previous delegation  removed and expired delegation also removed.
    // This subtract two times that cause underflow. Alice get huge voting power due to underflow.
    // Must use MockVeHemi to test this scenario because redelegate during extend lock prevent this underflow
    function testExtendLockAfterExpiredDelegation() public {
        MockVeHemi logic = new MockVeHemi(address(hemiToken));

        // Step 2: Deploy VeHemi proxy with initialization
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        MockVeHemi mockVeHemi = MockVeHemi(address(proxy));
        VeHemiVoteDelegation _hemiVoteDelegation = new VeHemiVoteDelegation(address(mockVeHemi));

        // Step 4: Update VeHemi with the vote delegation address
        mockVeHemi.updateVoteDelegation(_hemiVoteDelegation);
        address user1 = address(0x11111);
        address user2 = address(0x22222);

        hemiToken.mint(user1, 1_000 ether);
        hemiToken.mint(user2, 1_000 ether);
        hemiToken.mint(ALICE, 1_000 ether);

        uint256 amount = 1 ether;
        uint256 firstLockDuration = 2 * 365 days;
        uint256 newLockDuration = 3 * 365 days;

        vm.startPrank(ALICE);
        hemiToken.approve(address(mockVeHemi), amount / 2);
        uint256 aliceTokenId = mockVeHemi.createLock(amount / 2, MAX_TIME);
        vm.stopPrank();

        vm.startPrank(user2);
        hemiToken.approve(address(mockVeHemi), amount);
        uint256 tokenId2 = mockVeHemi.createLock(amount, newLockDuration);
        vm.stopPrank();

        vm.startPrank(user1);
        hemiToken.approve(address(mockVeHemi), amount);
        uint256 tokenId1 = mockVeHemi.createLock(amount, firstLockDuration);
        _hemiVoteDelegation.delegate(tokenId1, ALICE);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);
        mockVeHemi.increaseUnlockTime(tokenId1, newLockDuration);
        vm.warp(block.timestamp + firstLockDuration + 2 days);
        _hemiVoteDelegation.delegate(tokenId1, user2);
        delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);
        vm.stopPrank();

        assertEq(_hemiVoteDelegation.getVotes(user1), 0, "user1 should have no votes");

        assertEq(
            _hemiVoteDelegation.getVotes(user2),
            mockVeHemi.balanceOfNFT(tokenId2) + mockVeHemi.balanceOfNFT(tokenId1),
            "User2 should have self and delegate vote"
        );

        assertEq(
            _hemiVoteDelegation.getVotes(ALICE),
            mockVeHemi.balanceOfNFT(aliceTokenId),
            "Alice should have self votes only"
        );
    }

    function testReDelegation() public {
        // Given - Bill and Alice have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        // When - Bill delegates to Alice
        _delegateAndWarp(billTokenId, ALICE);

        // Then - Alice should have combined voting power
        uint256 billBalance = veHemi.balanceOfNFT(billTokenId);
        uint256 aliceBalance = veHemi.balanceOfNFT(aliceTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            aliceBalance + billBalance,
            "Alice vote should be the same after re-delegation"
        );

        // When - Bill delegates back to himself
        _delegateAndWarp(billTokenId, BILL);

        // Then - Each should have their own voting power
        billBalance = veHemi.balanceOfNFT(billTokenId);
        aliceBalance = veHemi.balanceOfNFT(aliceTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            aliceBalance,
            "Alice vote should be the same after re-delegation"
        );

        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            billBalance,
            "Alice vote should be the same after re-delegation"
        );
    }

    function testReDelegationWhenAmountIncreased() public {
        // Given - Bill has a lock
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);

        // When - Bill delegates to Alice
        _delegateAndWarp(billTokenId, ALICE);

        // Then - Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            0,
            "Bill should have no votes after delegation"
        );

        // When - Remove delegation and assign to self, then increase amount
        _delegateAndWarp(billTokenId, BILL);

        assertGt(hemiVoteDelegation.getVotes(BILL), 0, "Bill should have get votes power back");

        uint256 billVoteBefore = hemiVoteDelegation.getVotes(BILL);

        // more amount added to Bill's lock by someone else
        hemiToken.mint(ALICE, LOCK_AMOUNT);
        vm.startPrank(ALICE);
        hemiToken.approve(address(veHemi), LOCK_AMOUNT);
        veHemi.increaseAmount(billTokenId, LOCK_AMOUNT);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Bill should have increased voting power
        assertGt(
            hemiVoteDelegation.getVotes(BILL),
            billVoteBefore,
            "Alice should have received Bill's votes"
        );
    }

    function testReDelegationWhenAmountIncreasedByDelegator() public {
        // Given - Bill has a lock
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        _delegateAndWarp(billTokenId, ALICE);

        // When - Bill increases his lock amount
        uint256 aliceVoteBefore = hemiVoteDelegation.getVotes(ALICE);

        // more amount added to BILL lock
        hemiToken.mint(BILL, LOCK_AMOUNT);
        vm.startPrank(BILL);
        hemiToken.approve(address(veHemi), LOCK_AMOUNT);
        // add amount to bill lock
        veHemi.increaseAmount(billTokenId, LOCK_AMOUNT);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Alice should have increased voting power
        assertGt(
            hemiVoteDelegation.getVotes(ALICE),
            aliceVoteBefore,
            "Alice should have received Bill's votes"
        );
    }

    function testReDelegationWhenLockExtendedByDelegator() public {
        // Given - Bill has a lock
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, 1 * YEAR);
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        _delegateAndWarp(billTokenId, ALICE);

        // When - Bill extends his lock duration
        uint256 aliceVoteBefore = hemiVoteDelegation.getVotes(ALICE);

        vm.prank(BILL);
        veHemi.increaseUnlockTime(billTokenId, 2 * YEAR);

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Alice should have increased voting power
        assertGt(
            hemiVoteDelegation.getVotes(ALICE),
            aliceVoteBefore,
            "Alice should have received Bill's votes"
        );
    }

    function testRemoveDelegation() public {
        // Given
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);

        // When
        _delegateAndWarp(billTokenId, ALICE);

        // Then
        uint256 aliceVotesAfterDelegation = hemiVoteDelegation.getVotes(ALICE);
        assertGt(
            aliceVotesAfterDelegation,
            aliceInitialVotes,
            "Alice should have received Bill's votes"
        );
        uint256 billVoteAfterDelegation = hemiVoteDelegation.getVotes(BILL);
        assertEq(billVoteAfterDelegation, 0, "Bill should have no votes after delegation");

        // When - Switch delegation to BILL
        _delegateAndWarp(billTokenId, BILL);

        // Then
        uint256 aliceExpectedVotes = veHemi.balanceOfNFT(aliceTokenId);

        uint256 aliceVotesAfterDelegationRemoved = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotesAfterDelegationRemoved,
            aliceExpectedVotes,
            "Alice should have her original votes back after delegation switch"
        );
        uint256 billVoteAfterDelegationRemoved = hemiVoteDelegation.getVotes(BILL);
        assertGt(billVoteAfterDelegationRemoved, 0, "Bill should have received his own votes");
    }

    // Test delegation to non-existent token
    function testDelegationToNonExistentToken() public {
        // Given - Bill tries to delegate a non-existent token
        vm.startPrank(BILL);

        // When - Attempt to delegate non-existent token
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        hemiVoteDelegation.delegate(999, address(0)); // Delegate to non-existent token

        // Then - Should revert with ERC721NonexistentToken error
        vm.stopPrank();
    }

    // Test delegation with expired lock
    function testCantDelegateExpiredLock() public {
        // Given - Bill has a lock that will expire soon
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, 14 days); // Short lock duration

        // When - Warp to just before lock expires
        uint256 lockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd + 1 days);

        // Then - Should not be able to delegate expired lock
        vm.startPrank(BILL);
        vm.expectRevert(VeHemiVoteDelegation.CanNotDelegateExpiredLocks.selector);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();
    }

    // Test delegation to self (should set delegatee to 0)
    function testDelegationToSelf() public {
        // Given - Bill and Alice have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        // When - Bill delegates to himself
        _delegateAndWarp(billTokenId, BILL);

        // Then - Bill should have his own voting power
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            veHemi.balanceOfNFT(billTokenId),
            "Should have voting power when delegated to self"
        );

        // When - Bill delegates to Alice
        _delegateAndWarp(billTokenId, ALICE);

        // Then - Alice should have combined voting power
        uint256 aliceVotesAfterDelegation = hemiVoteDelegation.getVotes(ALICE);

        assertEq(
            aliceVotesAfterDelegation,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Should have less voting power when delegator remove delegations"
        );

        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            0,
            "Should have voting power 0 delegated to other"
        );

        // When - Bill delegates back to himself
        _delegateAndWarp(billTokenId, BILL);

        // Then - Bill should have his voting power back, Alice should have hers
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            veHemi.balanceOfNFT(billTokenId),
            "Should have voting power when delegated to self"
        );
        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            veHemi.balanceOfNFT(aliceTokenId),
            "Should have less voting power when delegator remove delegations"
        );
    }

    // Test delegation to same delegatee (should be no-op)
    function testDelegationToSameDelegatee() public {
        // Given - Bill and Alice have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 aliceVotesBefore = hemiVoteDelegation.getVotes(ALICE);
        uint256 billVotesBefore = hemiVoteDelegation.getVotes(BILL);

        // When - Bill delegates to Alice twice
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        hemiVoteDelegation.delegate(billTokenId, ALICE); // Delegate to same delegatee again
        vm.stopPrank();

        // Then - Should work without reverting and have correct voting power
        delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Alice should have Bill's votes (with some decay due to time passing)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotesAfter,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes (once)"
        );

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
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
        // Given - Bill has a lock, Alice tries to delegate it
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);

        // When - Alice tries to delegate Bill's token
        vm.startPrank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.CallerIsNotAuthorized.selector);
        hemiVoteDelegation.delegate(billTokenId, ALICE); // ALICE trying to delegate BILL's token

        // Then - Should revert with CallerIsNotAuthorized error
        vm.stopPrank();
    }

    // Test voting power before and after delegation
    function testVotingPowerBeforeAndAfterDelegation() public {
        // Given - Bill and Alice have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 initialBillVotes = hemiVoteDelegation.getVotes(BILL);
        uint256 initialAliceVotes = hemiVoteDelegation.getVotes(ALICE);
        assertGt(initialBillVotes, 0, "Should have initial voting power");

        // When - Bill delegates to Alice
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();

        // Then - Before delegation takes effect
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            initialBillVotes,
            "Bill should still have votes before delegation takes effect"
        );
        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            initialAliceVotes,
            "Alice should have no additional votes yet"
        );

        // When - After delegation takes effect
        delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Alice should have combined votes (with some decay due to time)
        uint256 aliceVotesAfter = hemiVoteDelegation.getVotes(ALICE);
        assertGt(aliceVotesAfter, initialAliceVotes, "Alice should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = aliceVotesAfter + hemiVoteDelegation.getVotes(BILL);
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
        // Given - Bill, Alice, and Walter have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        (uint256 walterTokenId, ) = _createLock(WALTER, LOCK_AMOUNT, MAX_TIME);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(WALTER);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(BILL);

        // When - Bill delegates to Alice
        _delegateAndWarp(billTokenId, ALICE);

        // Then - Alice should have received Bill's votes
        uint256 aliceVotes = hemiVoteDelegation.getVotes(ALICE);
        assertGt(aliceVotes, aliceInitialVotes, "Alice should have received Bill's votes");

        // When - Switch delegation to Walter
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, WALTER);
        vm.stopPrank();

        // Then - Alice should still have delegate votes until next epoch
        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should still have votes until next epoch"
        );
        // Walter should have his own votes but not Bill's votes yet
        uint256 walterVotes = hemiVoteDelegation.getVotes(WALTER);
        assertEq(
            walterVotes,
            veHemi.balanceOfNFT(walterTokenId),
            "Walter should have his own votes but not Bill's votes yet"
        );

        // When - After next epoch
        delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts + 1 days);

        // Then - Alice should have her original votes back, Walter should have Bill's votes
        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            veHemi.balanceOfNFT(aliceTokenId),
            "Alice should have her original votes back after delegation switch"
        );
        // Walter should have his own votes plus Bill's votes (with some decay)
        uint256 walterVotesAfter = hemiVoteDelegation.getVotes(WALTER);
        assertGt(walterVotesAfter, walterInitialVotes, "Walter should have received Bill's votes");

        // Bill should have no votes after delegation
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            0,
            "Bill should have no votes after delegation"
        );

        // Total voting power should be preserved (with minor decay due to time)
        uint256 totalVotesAfter = hemiVoteDelegation.getVotes(ALICE) +
            walterVotesAfter +
            hemiVoteDelegation.getVotes(BILL);
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
        // Given - Bill, Alice, and Walter have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        (uint256 walterTokenId, ) = _createLock(WALTER, LOCK_AMOUNT, MAX_TIME);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);
        uint256 billInitialVotes = hemiVoteDelegation.getVotes(BILL);
        uint256 walterInitialVotes = hemiVoteDelegation.getVotes(WALTER);

        // When - Bill and Walter delegate to Alice
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();

        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, ALICE);
        vm.stopPrank();

        delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Alice should have combined delegated votes
        uint256 aliceVotes = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) +
                veHemi.balanceOfNFT(billTokenId) +
                veHemi.balanceOfNFT(walterTokenId),
            "Alice should have combined delegated votes"
        );

        // Alice should have votes from both delegators
        uint256 billVotes = hemiVoteDelegation.getVotes(BILL);
        uint256 walterVotes = hemiVoteDelegation.getVotes(WALTER);
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
        // Given - Alice has a long lock, Bill has a shorter lock
        uint256 lockAmount = 1 ether;
        (uint256 aliceTokenId, ) = _createLock(ALICE, lockAmount, 4 * 365 days);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);
        assertEq(aliceInitialVotes, veHemi.balanceOfNFT(aliceTokenId));

        (uint256 billTokenId, ) = _createLock(BILL, 1 ether, 365 days);
        _delegateAndWarp(billTokenId, ALICE);

        // When - Bill delegates to Alice
        uint256 aliceVotes = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes"
        );

        // When - Warp to lock expiration
        uint256 lockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd + 1);

        // Then - Alice should have her own votes back after Bill's lock expires
        uint256 aliceVotesAfterExpiry = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotesAfterExpiry,
            veHemi.balanceOfNFT(aliceTokenId),
            "Alice should have her original votes back after Bill's lock expires"
        );

        // Bill should have no votes after lock expires
        assertEq(
            hemiVoteDelegation.getVotes(BILL),
            0,
            "Bill should have no votes after lock expires"
        );
    }

    // Alice and Bill Delegate to WALTER . After some some time Walter lock is forfeited

    function testVoteAfterForfeit() public {
        // Given - Set up forfeit admin and create forfeitable lock for Walter
        uint256 lockAmount = 10 ether;
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

        // When - Forfeit Walter's lock
        vm.prank(forfeitAdmin);
        veHemi.forfeit(walterTokenId);

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Walter should have no votes after forfeit
        assertEq(
            hemiVoteDelegation.getVotes(WALTER),
            0,
            "Walter should have no votes after forfeit"
        );
    }

    function testDelegatedVotesAfterForfeit() public {
        // Given - Set up forfeit admin and create locks
        uint256 lockAmount = 10 ether;
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

        // When - Bill and Alice delegate to Walter, then Walter's lock is forfeited
        _delegateAndWarp(billTokenId, WALTER);
        _delegateAndWarp(aliceTokenId, WALTER);

        vm.prank(forfeitAdmin);
        veHemi.forfeit(walterTokenId);

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Walter should have just delegated votes
        uint256 aliceBalance = veHemi.balanceOfNFT(aliceTokenId);
        uint256 billBalance = veHemi.balanceOfNFT(billTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(WALTER),
            aliceBalance + billBalance,
            "Walter should have just delegated votes"
        );
    }

    function testVoteAfterDelegateeLockExpire() public {
        // Given - Alice and Bill have locks, Bill delegates to Alice
        uint256 lockAmount = 1 ether;
        (uint256 aliceTokenId, ) = _createLock(ALICE, lockAmount, 365 days);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);
        assertEq(aliceInitialVotes, veHemi.balanceOfNFT(aliceTokenId));

        (uint256 billTokenId, ) = _createLock(BILL, 1 ether, 2 * 365 days);
        _delegateAndWarp(billTokenId, ALICE);

        // When - Bill delegates to Alice
        uint256 aliceVotes = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes"
        );

        // When - Warp to Alice's lock expiration
        uint256 lockEnd = veHemi.getLockedBalance(aliceTokenId).end;
        vm.warp(lockEnd + 1);

        // Alice should have her bill's votes after Alice lock expired

        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            veHemi.balanceOfNFT(billTokenId),
            "Alice should have BILL votes after Alice lock expired"
        );

        // When - Warp to Bill's lock expiration
        lockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(lockEnd + 1);

        assertEq(
            hemiVoteDelegation.getVotes(ALICE),
            0,
            "Alice should have her original votes back after Bill's lock expires"
        );
    }

    // Test getPastVotes functionality
    function testGetPastVotes() public {
        // Given - Bill and Alice have locks
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 billInitialVotes = hemiVoteDelegation.getVotes(BILL);
        uint256 aliceInitialVotes = hemiVoteDelegation.getVotes(ALICE);

        // When - Bill delegates to Alice
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();

        // Then - Check votes at different timestamps
        assertEq(
            hemiVoteDelegation.getPastVotes(BILL, block.timestamp),
            billInitialVotes,
            "Should have votes at current time"
        );
        assertEq(
            hemiVoteDelegation.getPastVotes(ALICE, block.timestamp),
            aliceInitialVotes,
            "Should have her own votes at current time"
        );

        delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // After delegation, Bill should have no votes and Alice should have combined votes (with decay)
        uint256 billPastVotes = hemiVoteDelegation.getPastVotes(BILL, block.timestamp);
        uint256 alicePastVotes = hemiVoteDelegation.getPastVotes(ALICE, block.timestamp);

        assertEq(billPastVotes, 0, "Bill should have no votes after delegation");
        assertEq(
            alicePastVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have received Bill's votes after delegation"
        );
    }

    // Test getPastVotes with future timestamp
    function testGetPastVotesFutureTimestamp() public {
        // Given - Bill has a lock
        _createLock(BILL, LOCK_AMOUNT, MAX_TIME);

        // When/Then - Should revert with TimestampInFuture error
        vm.expectRevert(VeHemiVoteDelegation.TimestampInFuture.selector);
        hemiVoteDelegation.getPastVotes(BILL, block.timestamp + 1);
    }

    // Test delegation checkpoint functionality
    function testDelegationCheckpoints() public {
        // Given - Bill delegates to Alice
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        (uint256 aliceTokenId, ) = _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 aliceVotes = hemiVoteDelegation.getVotes(ALICE);
        assertEq(
            aliceVotes,
            veHemi.balanceOfNFT(aliceTokenId) + veHemi.balanceOfNFT(billTokenId),
            "Alice should have delegated votes"
        );

        // Check that checkpoints are working correctly
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory checkpoints = hemiVoteDelegation
            .getDelegationCheckpoints(ALICE);
        assertGt(checkpoints.length, 0, "Should have at least one checkpoint");
    }

    // Test delegation with multiple delegators and expirations
    function testMultipleDelegatorsWithExpirations() public {
        (uint256 billTokenId, ) = _createLock(BILL, 1 ether, 365 days);
        (uint256 aliceTokenId, ) = _createLock(ALICE, 1 ether, 2 * 365 days);
        (uint256 walterTokenId, ) = _createLock(WALTER, 1 ether, 3 * 365 days);
        (uint256 delegateTokenId, uint256 delegateSlope) = _createLock(BOB, 1 ether, 4 * 365 days);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, BOB);
        vm.stopPrank();

        vm.startPrank(ALICE);
        hemiVoteDelegation.delegate(aliceTokenId, BOB);
        vm.stopPrank();

        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, BOB);
        vm.stopPrank();

        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        uint256 totalVotes = hemiVoteDelegation.getVotes(BOB);
        uint256 expectedVotes = veHemi.balanceOfNFT(delegateTokenId) +
            veHemi.balanceOfNFT(billTokenId) +
            veHemi.balanceOfNFT(aliceTokenId) +
            veHemi.balanceOfNFT(walterTokenId);
        assertEq(totalVotes, expectedVotes, "Should have combined delegated votes");

        // Let one lock expire
        uint256 billLockEnd = veHemi.getLockedBalance(billTokenId).end;
        vm.warp(billLockEnd + 1);

        uint256 votesAfterOneExpiry = hemiVoteDelegation.getVotes(BOB);
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

        uint256 votesAfterAllExpiry = hemiVoteDelegation.getVotes(BOB);
        assertEq(
            votesAfterAllExpiry,
            expectedDelegateVotes,
            "Should have only delegate's own votes after all locks expire"
        );
    }

    // ===== TESTS FOR calculateExpiredDelegations AND writeNewCheckpointForExpiredDelegations =====

    function testNoDelegationExpired() public view {
        // Given - No delegations exist
        address delegatee = address(0x1234);

        // When - Calculate expired delegations
        IVeHemiVoteDelegation.DelegateCheckpoint memory emptyCheckpoint = hemiVoteDelegation
            .calculateExpiredDelegations(delegatee);

        // Then - Should return empty checkpoint for account with no delegations
        assertEq(
            emptyCheckpoint.timestamp,
            0,
            "Should return empty checkpoint for account with no delegations"
        );
        assertEq(emptyCheckpoint.normalizedBias, 0, "Should have zero bias");
        assertEq(emptyCheckpoint.normalizedSlope, 0, "Should have zero slope");
        assertEq(emptyCheckpoint.totalAmount, 0, "Should have zero amount");
    }

    function testWhenNoExpirations() public {
        // Given - Bill delegates to Alice
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();

        // When - Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Should return empty checkpoint since no time has passed for expirations
        IVeHemiVoteDelegation.DelegateCheckpoint memory noExpirationCheckpoint = hemiVoteDelegation
            .calculateExpiredDelegations(ALICE);

        assertEq(
            noExpirationCheckpoint.timestamp,
            0,
            "Should return empty checkpoint when no expirations occurred"
        );
    }

    function testExpirations() public {
        // Given - Bill delegates to Alice with short lock duration
        uint256 shortLockDuration = 14 days; // 1 week
        (uint256 billTokenIdNew, ) = _createLock(BILL, LOCK_AMOUNT, shortLockDuration);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenIdNew, ALICE);
        vm.stopPrank();

        // When - Warp past the lock expiration
        uint256 lockEnd = veHemi.getLockedBalance(billTokenIdNew).end;
        vm.warp(lockEnd + 1 days);

        // Then - Should have a new checkpoint with expired values
        IVeHemiVoteDelegation.DelegateCheckpoint memory expirationCheckpoint = hemiVoteDelegation
            .calculateExpiredDelegations(ALICE);

        assertGt(expirationCheckpoint.timestamp, 0, "Should have timestamp for new checkpoint");
        assertEq(expirationCheckpoint.normalizedBias, 0, "Should have some bias in checkpoint");
        assertEq(expirationCheckpoint.normalizedSlope, 0, "Should have some slope in checkpoint");
        assertEq(expirationCheckpoint.totalAmount, 0, "Should have some amount in checkpoint");
    }

    function testWriteNewCheckpointNoExpirations() public {
        // Given - Bill delegates to Alice
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, MAX_TIME);
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, ALICE);
        vm.stopPrank();

        // When - Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Should revert with NoExpirations error
        vm.expectRevert(VeHemiVoteDelegation.NoExpirations.selector);
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(ALICE);
    }

    function testWriteNewCheckpointWithExpirations() public {
        // Given - Bill delegates to Alice with short lock duration
        _createLock(ALICE, LOCK_AMOUNT, MAX_TIME);
        uint256 shortLockDuration = 14 days; // 2 weeks
        (uint256 billTokenIdNew, ) = _createLock(BILL, LOCK_AMOUNT, shortLockDuration);

        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenIdNew, ALICE);
        vm.stopPrank();

        // When - Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        IVeHemiVoteDelegation.DelegateCheckpoint[]
            memory delegationCheckpointsBefore = hemiVoteDelegation.getDelegationCheckpoints(ALICE);
        assertEq(delegationCheckpointsBefore.length, 1, "Should have 1 checkpoint");

        // When - Warp past expiration and write new checkpoint
        vm.warp(delegationStarts + 15 days);
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(ALICE);

        // Then - Should have 2 checkpoints
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory delegationCheckpoints = hemiVoteDelegation
            .getDelegationCheckpoints(ALICE);
        assertEq(
            delegationCheckpoints.length,
            delegationCheckpointsBefore.length + 1,
            "Should have 2 checkpoints"
        );
    }

    function testDifferentExpirations() public {
        // Given - Bill and Walter delegate to Bob with different lock durations
        (uint256 bobTokenId, ) = _createLock(BOB, LOCK_AMOUNT, 4 * 365 days);
        (uint256 billTokenId, ) = _createLock(BILL, LOCK_AMOUNT, 14 days); // 2 weeks
        (uint256 walterTokenId, ) = _createLock(WALTER, LOCK_AMOUNT, 28 days); // 4 weeks

        // When - Bill and Walter delegate to Bob
        vm.startPrank(BILL);
        hemiVoteDelegation.delegate(billTokenId, BOB);
        vm.stopPrank();

        vm.startPrank(WALTER);
        hemiVoteDelegation.delegate(walterTokenId, BOB);
        vm.stopPrank();

        // When - Warp to after Bill's expiration and write checkpoint
        vm.warp(block.timestamp + 15 days);
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory delegationCheckpoints = hemiVoteDelegation
            .getDelegationCheckpoints(BOB);
        assertEq(delegationCheckpoints.length, 1, "Should have 1 checkpoint");
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(BOB);
        delegationCheckpoints = hemiVoteDelegation.getDelegationCheckpoints(BOB);
        assertEq(delegationCheckpoints.length, 2, "Should have 2 checkpoints");

        uint256 bobExpectedVotes = veHemi.balanceOfNFT(bobTokenId) +
            veHemi.balanceOfNFT(walterTokenId);

        assertEq(
            hemiVoteDelegation.getVotes(BOB),
            bobExpectedVotes,
            "Bob should have self and walter"
        );

        // When - Warp to after Walter's expiration and write checkpoint
        vm.warp(block.timestamp + 15 days);
        hemiVoteDelegation.writeNewCheckpointForExpiredDelegations(BOB);
        delegationCheckpoints = hemiVoteDelegation.getDelegationCheckpoints(BOB);
        assertEq(delegationCheckpoints.length, 3, "Should have 3 checkpoints");

        // Voting power checks

        assertEq(
            hemiVoteDelegation.getVotes(BOB),
            veHemi.balanceOfNFT(bobTokenId),
            "Should have left only self votes"
        );
    }

    function testDelegateBySig() public {
        // Given - Alice and Bob have locks, Alice will delegate to Bob by signature
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);
        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);
        (uint256 bobTokenId, ) = _createLock(BOB, LOCK_AMOUNT, 30 days);

        // When - Alice signs and delegates to Bob
        uint256 currentTimestamp = block.timestamp;
        uint256 expiry = currentTimestamp + 3600; // 1 hour from now
        bytes32 digest = _getTypesDataHash(aliceTokenId, BOB, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        hemiVoteDelegation.delegateBySig(aliceTokenId, BOB, 0, expiry, v, r, s);

        // When - Warp to delegation start
        uint256 delegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        vm.warp(delegationStarts);

        // Then - Alice should have no votes, Bob should have received Alice's votes
        uint256 aliceVotes = hemiVoteDelegation.getVotes(alice);
        uint256 bobVotes = hemiVoteDelegation.getVotes(BOB);
        assertEq(aliceVotes, 0, "Alice should have no votes after delegation");
        assertEq(
            bobVotes,
            veHemi.balanceOfNFT(bobTokenId) + veHemi.balanceOfNFT(aliceTokenId),
            "Bob should have received Alice's votes"
        );
    }

    function testDelegateBySigInvalidSignature() public {
        // Given - Alice and Bob have locks, but signature is from wrong key
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);
        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);
        _createLock(BOB, LOCK_AMOUNT, 30 days);
        uint256 expiry = block.timestamp + 3600;
        bytes32 digest = _getTypesDataHash(aliceTokenId, BOB, 0, expiry);
        uint256 wrongPrivateKey = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);
        // When/Then - Should revert with NotOwner
        vm.expectRevert(VeHemiVoteDelegation.NotOwner.selector);
        hemiVoteDelegation.delegateBySig(aliceTokenId, BOB, 0, expiry, v, r, s);
    }

    function testDelegateBySigExpiredSignature() public {
        // Given - Alice and Bob have locks, signature is expired
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);
        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);
        _createLock(BOB, LOCK_AMOUNT, 30 days);
        uint256 expiry = block.timestamp + 3600;
        bytes32 digest = _getTypesDataHash(aliceTokenId, BOB, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        // When - Warp past expiry
        vm.warp(expiry + 1);
        // Then - Should revert with SignatureExpired
        vm.expectRevert(VeHemiVoteDelegation.SignatureExpired.selector);
        hemiVoteDelegation.delegateBySig(aliceTokenId, BOB, 0, expiry, v, r, s);
    }

    function testDelegateBySigInvalidNonce() public {
        // Given - Alice and Bob have locks, signature has wrong nonce
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);
        (uint256 aliceTokenId, ) = _createLock(alice, LOCK_AMOUNT, 30 days);
        _createLock(BOB, LOCK_AMOUNT, 30 days);
        uint256 expiry = block.timestamp + 3600;
        bytes32 digest = _getTypesDataHash(aliceTokenId, BOB, 1, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        // When/Then - Should revert with InvalidNonce
        vm.expectRevert(VeHemiVoteDelegation.InvalidNonce.selector);
        hemiVoteDelegation.delegateBySig(aliceTokenId, BOB, 1, expiry, v, r, s);
    }

    function _getTypesDataHash(
        uint256 delegator_,
        address delegatee_,
        uint256 nonce_,
        uint256 expiry_
    ) internal view returns (bytes32) {
        bytes32 DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );
        bytes32 DELEGATION_TYPEHASH = keccak256(
            "Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)"
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

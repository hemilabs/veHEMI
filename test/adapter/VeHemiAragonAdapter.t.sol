// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemiAragonAdapter, IVotes} from "../../src/adapter/VeHemiAragonAdapter.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VeHemiAragonAdapterTest is Test {
    MockERC20 hemiToken;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;
    VeHemiAragonAdapter adapter;

    address constant ALICE = address(23_984_723_894_798);
    address constant BOB = address(987_654_321);
    address constant CAROL = address(12_345_678);

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MAX_TIME = 4 * YEAR;
    uint256 private constant ONE_DAY = 1 days;

    function setUp() public {
        hemiToken = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemiToken));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);

        adapter = new VeHemiAragonAdapter(address(veHemi));
    }

    function _createLock(address account, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        hemiToken.mint(account, amount);
        vm.startPrank(account);
        hemiToken.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    function _delegateAndWarp(uint256 tokenId, address delegatee) internal {
        address owner_ = veHemi.ownerOf(tokenId);
        vm.prank(owner_);
        delegation.delegate(tokenId, delegatee);
        uint256 delegationStarts = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;
        vm.warp(delegationStarts);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor_storesVeHemi() public view {
        assertEq(adapter.veHemi(), address(veHemi));
    }

    function test_constructor_voteDelegationReadsDynamically() public view {
        // voteDelegation() reads from veHemi.voteDelegation() dynamically
        assertEq(adapter.voteDelegation(), address(delegation));
        assertEq(adapter.voteDelegation(), address(veHemi.voteDelegation()));
    }

    function test_constructor_revertsZeroVeHemi() public {
        vm.expectRevert("zero veHemi");
        new VeHemiAragonAdapter(address(0));
    }

    // ─── balanceOf ──────────────────────────────────────────────────────

    function test_balanceOf_zeroForUnknownAddress() public view {
        assertEq(adapter.balanceOf(ALICE), 0);
    }

    function test_balanceOf_returnsNFTCount() public {
        _createLock(ALICE, 1e18, YEAR);
        assertEq(adapter.balanceOf(ALICE), 1);

        _createLock(ALICE, 1e18, YEAR);
        assertEq(adapter.balanceOf(ALICE), 2);
    }

    function test_balanceOf_nonZeroAfterDelegation() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, BOB);
        assertEq(adapter.balanceOf(ALICE), 1);
    }

    function test_balanceOf_zeroAfterWithdraw() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        vm.warp(block.timestamp + YEAR + 1);
        vm.prank(ALICE);
        veHemi.withdraw(tokenId);
        assertEq(adapter.balanceOf(ALICE), 0);
    }

    // ─── getVotes ───────────────────────────────────────────────────────

    function test_getVotes_zeroWithoutDelegation() public {
        _createLock(ALICE, 1e18, YEAR);
        assertEq(adapter.getVotes(ALICE), 0);
    }

    function test_getVotes_nonZeroAfterSelfDelegation() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);
        assertGt(adapter.getVotes(ALICE), 0);
    }

    function test_getVotes_matchesDelegation() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, BOB);
        assertEq(adapter.getVotes(BOB), delegation.getVotes(BOB));
        assertEq(adapter.getVotes(ALICE), 0);
    }

    // ─── getPastVotes ───────────────────────────────────────────────────

    function test_getPastVotes_forwardsCorrectly() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        uint256 ts = block.timestamp;
        vm.warp(ts + 1);

        assertEq(adapter.getPastVotes(ALICE, ts), delegation.getPastVotes(ALICE, ts));
        assertGt(adapter.getPastVotes(ALICE, ts), 0);
    }

    function test_getPastVotes_zeroForUnknownAddress() public {
        uint256 ts = block.timestamp;
        vm.warp(ts + 1);
        assertEq(adapter.getPastVotes(ALICE, ts), 0);
    }

    function test_getPastVotes_revertsForFutureTimestamp() public {
        vm.expectRevert();
        adapter.getPastVotes(ALICE, block.timestamp + 1);
    }

    function test_getPastVotes_snapshotAtTimestampMinusOne() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        // _delegateAndWarp puts us at exactly the day boundary where delegation
        // activates. Warp 1 more second so that block.timestamp - 1 = the
        // boundary itself, which includes the active delegation checkpoint.
        vm.warp(block.timestamp + 1);

        // Simulate Aragon's snapshot: block.timestamp - 1
        uint256 snapshot = block.timestamp - 1;
        uint256 power = adapter.getPastVotes(ALICE, snapshot);
        assertGt(power, 0, "voting power at snapshot should be non-zero");
    }

    // ─── getPastTotalSupply ─────────────────────────────────────────────

    function test_getPastTotalSupply_forwardsCorrectly() public {
        _createLock(ALICE, 1e18, YEAR);

        uint256 ts = block.timestamp;
        vm.warp(ts + 1);

        assertEq(adapter.getPastTotalSupply(ts), delegation.getPastTotalSupply(ts));
        assertGt(adapter.getPastTotalSupply(ts), 0);
    }

    function test_getPastTotalSupply_zeroBeforeAnyLocks() public view {
        assertEq(adapter.getPastTotalSupply(0), 0);
    }

    function test_getPastTotalSupply_reflectsMultipleLocks() public {
        _createLock(ALICE, 10e18, YEAR);
        _createLock(BOB, 20e18, 2 * YEAR);

        uint256 ts = block.timestamp;
        vm.warp(ts + 1);

        uint256 totalSupply = adapter.getPastTotalSupply(ts);
        assertGt(totalSupply, 0);
        assertEq(totalSupply, delegation.getPastTotalSupply(ts));
    }

    // ─── clock / CLOCK_MODE ─────────────────────────────────────────────

    function test_clock_returnsBlockTimestamp() public view {
        assertEq(adapter.clock(), uint48(block.timestamp));
    }

    function test_CLOCK_MODE_returnsTimestamp() public view {
        assertEq(keccak256(bytes(adapter.CLOCK_MODE())), keccak256(bytes("mode=timestamp")));
    }

    function test_clockConsistency() public view {
        // Aragon's _detectTokenClock requires these to agree
        bool isTimestampMode = keccak256(bytes(adapter.CLOCK_MODE())) == keccak256(bytes("mode=timestamp"));
        bool clockMatchesTimestamp = adapter.clock() == uint48(block.timestamp);
        assertTrue(isTimestampMode && clockMatchesTimestamp, "clock and CLOCK_MODE must both indicate timestamp");
    }

    // ─── delegates ──────────────────────────────────────────────────────

    function test_delegates_returnsZero() public view {
        assertEq(adapter.delegates(ALICE), address(0));
        assertEq(adapter.delegates(BOB), address(0));
        assertEq(adapter.delegates(address(0)), address(0));
    }

    // ─── delegate ───────────────────────────────────────────────────────

    function test_delegate_reverts() public {
        vm.expectRevert("Use VeHemiVoteDelegation.delegate(tokenId, delegatee)");
        adapter.delegate(ALICE);
    }

    // ─── delegateBySig ──────────────────────────────────────────────────

    function test_delegateBySig_reverts() public {
        vm.expectRevert("Use VeHemiVoteDelegation.delegateBySig");
        adapter.delegateBySig(ALICE, 0, 0, 0, bytes32(0), bytes32(0));
    }

    // ─── ERC-165 ────────────────────────────────────────────────────────

    function test_supportsInterface_IERC165() public view {
        assertTrue(adapter.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_IVotes() public view {
        bytes4 ivotesId = type(IVotes).interfaceId;
        assertTrue(adapter.supportsInterface(ivotesId));
    }

    function test_supportsInterface_IVotes_matchesManualComputation() public pure {
        bytes4 manual = bytes4(keccak256("getVotes(address)"))
            ^ bytes4(keccak256("getPastVotes(address,uint256)"))
            ^ bytes4(keccak256("getPastTotalSupply(uint256)"))
            ^ bytes4(keccak256("delegates(address)"))
            ^ bytes4(keccak256("delegate(address)"))
            ^ bytes4(keccak256("delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertEq(type(IVotes).interfaceId, manual);
    }

    function test_supportsInterface_falseForRandom() public view {
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    function test_supportsInterface_falseForZero() public view {
        assertFalse(adapter.supportsInterface(0xffffffff));
    }

    // ─── Metadata ───────────────────────────────────────────────────────

    function test_name() public view {
        assertEq(keccak256(bytes(adapter.name())), keccak256(bytes("veHEMI Votes")));
    }

    function test_symbol() public view {
        assertEq(keccak256(bytes(adapter.symbol())), keccak256(bytes("veHEMI")));
    }

    // ─── Integration: multiple users ────────────────────────────────────

    function test_multipleUsers_votingPower() public {
        uint256 tokenId1 = _createLock(ALICE, 1e18, YEAR);
        uint256 tokenId2 = _createLock(BOB, 2e18, 2 * YEAR);

        _delegateAndWarp(tokenId1, ALICE);

        vm.prank(BOB);
        delegation.delegate(tokenId2, BOB);
        uint256 nextDay = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;
        vm.warp(nextDay);

        assertGt(adapter.getVotes(ALICE), 0);
        assertGt(adapter.getVotes(BOB), 0);
        // BOB locked 2x amount for 2x duration → significantly more voting power
        assertGt(adapter.getVotes(BOB), adapter.getVotes(ALICE));
    }

    function test_delegateToThirdParty() public {
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);
        _delegateAndWarp(tokenId, CAROL);

        assertEq(adapter.getVotes(ALICE), 0);
        assertGt(adapter.getVotes(CAROL), 0);
        // CAROL has voting power but no NFT
        assertEq(adapter.balanceOf(CAROL), 0);
    }

    function test_isMember_pattern() public {
        // Aragon's isMember: balanceOf > 0 || getVotes > 0
        uint256 tokenId = _createLock(ALICE, 1e18, YEAR);

        // Before delegation: ALICE is member via balanceOf, not getVotes
        assertTrue(adapter.balanceOf(ALICE) > 0);
        assertEq(adapter.getVotes(ALICE), 0);

        // After delegation to BOB: ALICE still member (owns NFT), BOB also member (has votes)
        _delegateAndWarp(tokenId, BOB);
        assertTrue(adapter.balanceOf(ALICE) > 0 || adapter.getVotes(ALICE) > 0);
        assertTrue(adapter.balanceOf(BOB) > 0 || adapter.getVotes(BOB) > 0);
    }

    function test_votingPowerDecaysOverTime() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        uint256 powerNow = adapter.getVotes(ALICE);

        // Warp 6 months forward
        vm.warp(block.timestamp + YEAR / 2);
        uint256 powerLater = adapter.getVotes(ALICE);

        assertGt(powerNow, powerLater, "voting power should decay over time");
        assertGt(powerLater, 0, "voting power should not be zero yet");
    }

    // ─── CRITICAL: balanceOf with expired but unwithdrawn locks ─────────

    function test_balanceOf_nonZeroForExpiredButUnwithdrawnLock() public {
        // A user who created a lock that has expired but hasn't called withdraw()
        // still owns the NFT. Aragon uses balanceOf > 0 for isMember, so this
        // user should still be considered a "member" even though their voting
        // power has decayed to zero.
        _createLock(ALICE, 10e18, YEAR);

        // Warp past lock expiry
        vm.warp(block.timestamp + YEAR + 1);

        // The lock is expired, but ALICE hasn't withdrawn — she still owns the NFT
        assertEq(adapter.balanceOf(ALICE), 1, "balanceOf should be 1 for expired but unwithdrawn lock");

        // Voting power should be zero (lock expired, power fully decayed)
        // Self-delegation was never set, so getVotes is 0 regardless.
        // But even if we could check the underlying veHemi, the bias would be 0.
        assertEq(adapter.getVotes(ALICE), 0, "getVotes should be 0 for expired lock without delegation");

        // Aragon's isMember pattern: balanceOf > 0 || getVotes > 0
        // ALICE is still a member via balanceOf
        assertTrue(
            adapter.balanceOf(ALICE) > 0 || adapter.getVotes(ALICE) > 0,
            "expired-but-unwithdrawn user should still be isMember"
        );
    }

    // ─── CRITICAL: getVotes/getPastVotes after delegation expiry ────────

    function test_getVotes_zeroAfterDelegationExpiry() public {
        // When a delegation expires (the delegator's lock ends), the delegatee's
        // voting power from that delegation must drop to zero. If it doesn't,
        // we have vote inflation.
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);

        // BOB should have votes now
        uint256 votesBefore = adapter.getVotes(BOB);
        assertGt(votesBefore, 0, "BOB should have delegated votes before expiry");

        // Warp past the lock expiry (delegation expires when the lock expires)
        vm.warp(block.timestamp + YEAR + 1);

        // BOB's delegated votes must be zero — the delegation has expired
        uint256 votesAfter = adapter.getVotes(BOB);
        assertEq(votesAfter, 0, "BOB should have zero votes after delegation expiry (vote inflation check)");
    }

    function test_getPastVotes_zeroAfterDelegationExpiry() public {
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, BOB);

        uint256 tsBeforeExpiry = block.timestamp;

        // Warp past lock expiry
        vm.warp(block.timestamp + YEAR + 1);

        uint256 tsAfterExpiry = block.timestamp;
        vm.warp(tsAfterExpiry + 1); // move 1 second ahead so we can query tsAfterExpiry

        // getPastVotes before expiry should be non-zero
        uint256 pastVotesBeforeExpiry = adapter.getPastVotes(BOB, tsBeforeExpiry);
        assertGt(pastVotesBeforeExpiry, 0, "getPastVotes before expiry should be non-zero");

        // getPastVotes after expiry should be zero
        uint256 pastVotesAfterExpiry = adapter.getPastVotes(BOB, tsAfterExpiry);
        assertEq(pastVotesAfterExpiry, 0, "getPastVotes after expiry should be zero (vote inflation check)");
    }

    // ─── CRITICAL: getPastTotalSupply at block.timestamp - 1 ────────────

    function test_getPastTotalSupply_atTimestampMinusOne() public {
        // Aragon's TokenVoting snapshots voting power at block.timestamp - 1.
        // This test verifies that getPastTotalSupply works correctly at that
        // specific offset, which is the actual pattern used in production.
        _createLock(ALICE, 10e18, YEAR);
        _createLock(BOB, 20e18, 2 * YEAR);

        // Advance time so we have a valid past timestamp
        vm.warp(block.timestamp + 1);

        // Simulate Aragon's snapshot pattern: block.timestamp - 1
        uint256 snapshot = block.timestamp - 1;
        uint256 totalSupply = adapter.getPastTotalSupply(snapshot);
        assertGt(totalSupply, 0, "getPastTotalSupply at timestamp-1 should be non-zero");
        assertEq(
            totalSupply,
            delegation.getPastTotalSupply(snapshot),
            "getPastTotalSupply at timestamp-1 should match delegation contract"
        );
    }

    // ─── HIGH: getVotes with multiple delegated NFTs from different users ─

    function test_getVotes_withMultipleDelegationsFromDifferentUsers() public {
        // When multiple users delegate their NFTs to the same delegatee,
        // the delegatee's voting power should aggregate correctly.
        uint256 tokenId1 = _createLock(ALICE, 10e18, YEAR);
        uint256 tokenId2 = _createLock(BOB, 20e18, 2 * YEAR);

        // Both ALICE and BOB delegate to CAROL
        _delegateAndWarp(tokenId1, CAROL);

        vm.prank(BOB);
        delegation.delegate(tokenId2, CAROL);
        // Advance to next day boundary so BOB's delegation is active
        uint256 nextDay = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;
        vm.warp(nextDay);

        // CAROL should have votes from both delegations
        uint256 carolVotes = adapter.getVotes(CAROL);
        assertGt(carolVotes, 0, "CAROL should have aggregated votes from multiple delegators");

        // CAROL's votes should be more than what either delegation alone would provide.
        // We can verify by checking that CAROL has more than ALICE's individual contribution.
        // Create a separate lock for comparison: delegate only from a fresh user with same params as ALICE
        uint256 tokenId3 = _createLock(address(0xBEEF), 10e18, YEAR);
        vm.prank(address(0xBEEF));
        delegation.delegate(tokenId3, address(0xCAFE));
        uint256 nextDay2 = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;
        vm.warp(nextDay2);

        uint256 singleDelegationVotes = adapter.getVotes(address(0xCAFE));
        assertGt(carolVotes, singleDelegationVotes, "aggregated votes should exceed single delegation");

        // ALICE and BOB should have zero votes (they delegated away)
        assertEq(adapter.getVotes(ALICE), 0, "ALICE should have zero votes after delegating");
        assertEq(adapter.getVotes(BOB), 0, "BOB should have zero votes after delegating");

        // CAROL owns no NFTs
        assertEq(adapter.balanceOf(CAROL), 0, "CAROL should own no NFTs");
    }

    // ─── HIGH: getPastTotalSupply reverts for future timestamp ──────────

    function test_getPastTotalSupply_revertsForFutureTimestamp() public {
        vm.expectRevert();
        adapter.getPastTotalSupply(block.timestamp + 1);
    }

    // ─── HIGH: Constructor with non-contract addresses ──────────────────

    function test_constructor_withNonContractAddress() public {
        // The adapter constructor does not check for code at the provided address.
        // It only checks for address(0). A non-contract address (EOA) will be
        // accepted, but calls to it will revert at runtime.
        address fakeVeHemi = address(0xDEAD);

        VeHemiAragonAdapter badAdapter = new VeHemiAragonAdapter(fakeVeHemi);

        assertEq(badAdapter.veHemi(), fakeVeHemi, "should store non-contract veHemi address");

        // balanceOf reverts because fakeVeHemi is an EOA (no code)
        vm.expectRevert();
        badAdapter.balanceOf(ALICE);

        // voteDelegation() reverts because fakeVeHemi has no voteDelegation() function
        vm.expectRevert();
        badAdapter.voteDelegation();

        // getVotes reverts because voteDelegation() on the EOA reverts first
        vm.expectRevert();
        badAdapter.getVotes(ALICE);

        // clock() also reverts
        vm.expectRevert();
        badAdapter.clock();
    }

    // ─── HIGH: Fuzz test for getPastVotes with random timestamps ────────

    function testFuzz_getPastVotes_randomTimestamps(uint256 queryOffset) public {
        // Create a lock and delegate so there is actual voting power to query
        uint256 tokenId = _createLock(ALICE, 10e18, YEAR);
        _delegateAndWarp(tokenId, ALICE);

        uint256 delegationActiveTime = block.timestamp;

        // Warp forward a substantial amount so we have a wide range to query
        vm.warp(delegationActiveTime + YEAR / 2);

        // Bound the query offset to be within the valid range:
        // [delegationActiveTime, block.timestamp - 1]
        // We need block.timestamp > queryTs for getPastVotes to not revert
        uint256 rangeSize = block.timestamp - delegationActiveTime;
        queryOffset = bound(queryOffset, 0, rangeSize - 1);
        uint256 queryTs = delegationActiveTime + queryOffset;

        // Should not revert for any valid past timestamp
        uint256 power = adapter.getPastVotes(ALICE, queryTs);

        // Adapter result must match delegation contract
        assertEq(
            power,
            delegation.getPastVotes(ALICE, queryTs),
            "fuzz: getPastVotes must match delegation contract"
        );

        // Power should always be non-negative (it's uint256, but verify it's reasonable)
        // The voting power should be <= the initial lock amount (1e18 * MAX_TIME / MAX_TIME at most)
        // In practice, veHemi voting power = amount * remaining_time / MAX_TIME, so it should
        // be at most ~10e18 (the locked amount)
        assertLe(power, 10e18, "fuzz: voting power should not exceed locked amount");
    }
}

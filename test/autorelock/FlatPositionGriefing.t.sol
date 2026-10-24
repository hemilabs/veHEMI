// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import "../mocks/RevertingVoteDelegation.sol";

/// @dev `delegateAllFor` is adapter-only and `setTrustedAdapter` demands a
///      contract, so the batch path needs a caller with bytecode.
contract BatchDelegationAdapter {
    VeHemiVoteDelegation public d;
    constructor(VeHemiVoteDelegation d_) { d = d_; }
    function go(address owner_, address delegatee_) external { d.delegateAllFor(owner_, delegatee_); }
    function notifyVotesChanged(address, uint256, uint256) external {}
    function notifyDelegateChanged(address, address, address) external {}
}

/// @title  Griefing and denial against flat positions.
///
/// @notice No one can lock a victim's principal, strand votes permanently or
///         brick state: top-ups cannot move R or the exit date, `withdraw`
///         refuses while flat, the adapter batch keeps flat positions, a broken
///         delegation module cannot lock funds, `refreshVotingPower`
///         broadcasts the forward-dated (`block.timestamp + 1`) value, a
///         move-away is exact, the
///         permissionless stale retire is not a confiscation, and retiring an
///         already-expired term does not underflow.
contract FlatPositionGriefingTest is AutoRelockTestBase {
    // ------------------------------------------------------------------
    // C1 — REPEATED TOP-UPS CANNOT MOVE `R` OR THE EXIT DATE. A top-up
    //      re-materialises the lazily-maintained end; it only heals the
    //      documented staleness. (`increaseAmount` is owner-only, so the
    //      owner sends them.)
    // ------------------------------------------------------------------
    function test_C1_topUpsCannotMoveR() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        (uint256 twin, , ) = createLock(bob, 1_000 ether, 2 * 365 days);
        enable(victim, id);
        enable(bob, twin);
        uint64 r0 = veHemi.autoRelockRemaining(id);

        for (uint256 i = 0; i < 50; ++i) {
            vm.warp(block.timestamp + 7 hours);
            vm.prank(victim);
            veHemi.increaseAmount(id, 10 ether); // 10 HEMI a shot, owner-driven
            assertEq(veHemi.autoRelockRemaining(id), r0, "a top-up MOVED R");
            assertEq(veHemi.autoRelockRemaining(id) % SIX_DAYS, 0, "R left the grid");
            assertEq(veHemi.effectiveLockEnd(id), veHemi.effectiveLockEnd(twin), "a top-up MOVED THE EXIT DATE");
        }
        // and the victim exits on exactly the untouched twin's schedule.
        disable(victim, id);
        disable(bob, twin);
        assertEq(veHemi.getLockedBalance(id).end, veHemi.getLockedBalance(twin).end, "restored end diverged from the untouched twin");
    }

    // ------------------------------------------------------------------
    // C2 — A BURST OF TOP-UPS ON A DELEGATED FLAT POSITION: the delegatee's
    //      votes are healed (and higher) by the next hourly boundary however
    //      many writes land in the interval, and every top-up is returned with
    //      the principal at exit.
    // ------------------------------------------------------------------
    function test_C2_topUpBurstHealsByTheNextBoundary() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        enable(victim, id);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);
        uint256 votes0 = delegation.getVotes(dele);
        assertGt(votes0, 0, "probe: no votes to punch out");

        // land the grief one second into an hourly epoch: the widest hole.
        vm.warp((block.timestamp / 3600) * 3600 + 3600 + 1);
        uint256 t0 = block.timestamp;
        uint256 principal0 = uint256(uint128(veHemi.getLockedBalance(id).amount));

        for (uint256 shot = 0; shot < 5; ++shot) {
            vm.prank(victim);
            veHemi.increaseAmount(id, 10 ether); // 10 HEMI, owner-driven
        }
        // healed by the next hourly boundary.
        uint256 boundary = ((t0 / 3600) * 3600) + 3600;
        vm.warp(boundary);
        assertGt(delegation.getVotes(dele), votes0, "votes did not heal at the boundary");
        // principal and weight both went UP.
        assertGt(uint256(uint128(veHemi.getLockedBalance(id).amount)), principal0, "top-ups did not land on the position");
        vm.prank(victim);
        veHemi.disableAutoRelock(id);
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        uint256 balBefore = hemi.balanceOf(victim);
        vm.prank(victim);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(victim) - balBefore, principal0 + 50 ether, "victim did not receive principal + the top-ups");
    }

    // ------------------------------------------------------------------
    // C3 — `withdraw` REFUSES WHILE FLAT, even with the stored end 40+
    //      buckets in the past: max weight and zero lock-up if it fails.
    // ------------------------------------------------------------------
    function test_C3_withdrawRefusesWhileFlatWithStaleEnd() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        enable(attacker, id);
        vm.warp(block.timestamp + 160 * SIX_DAYS);
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "probe: end not stale");
        assertGt(veHemi.balanceOfNFT(id), 0, "probe: no weight held");
        vm.prank(attacker);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);
    }

    // ------------------------------------------------------------------
    // C4 — THE ADAPTER BATCH KEEPS FLAT POSITIONS.
    //      If `delegateAllFor` drops the flat term a victim's whole
    //      auto-relocked book silently stops following their delegation.
    // ------------------------------------------------------------------
    function test_C4_delegateAllForIncludesFlatPositions() public {
        BatchDelegationAdapter ad = new BatchDelegationAdapter(delegation);
        delegation.setTrustedAdapter(address(ad));

        (uint256 flatId, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        (uint256 liveId, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        enable(victim, flatId);
        // drive the flat position's STORED end into the past: only the flag
        // keeps it in the batch.
        vm.warp(block.timestamp + 250 * SIX_DAYS);
        assertLt(veHemi.getLockedBalance(flatId).end, block.timestamp, "probe: flat end not stale");

        uint256 wFlat = veHemi.balanceOfNFT(flatId);
        assertGt(wFlat, 0, "probe: flat weight gone");
        ad.go(victim, dele);
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(dele), wFlat + veHemi.balanceOfNFT(liveId), "batch DROPPED the flat position");
    }

    // ------------------------------------------------------------------
    // C5 — A BROKEN DELEGATION MODULE CANNOT LOCK A VICTIM'S FUNDS. Every
    //      `VeHemi -> VVD` call is inside a try/catch.
    // ------------------------------------------------------------------
    function test_C5_brokenDelegationCannotLockFunds() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        enable(attacker, id);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new RevertingVoteDelegation())));
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        disable(attacker, id); // must not revert
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether, "principal trapped behind a broken delegation module");
    }

    // ------------------------------------------------------------------
    // C6 — `refreshVotingPower` BROADCASTS THE FORWARD-DATED VALUE (the
    //      votes at `block.timestamp + 1`, the instant delegation events are
    //      dated). It is permissionless; broadcasting the CURRENT value would
    //      change what every indexer records.
    // ------------------------------------------------------------------
    function test_C6_refreshVotingPowerBroadcastsNextHour() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);
        // a decaying position: the forward-dated value is STRICTLY below the
        // current one, so the two are distinguishable.
        vm.warp((block.timestamp / 3600) * 3600 + 1);
        uint256 live = delegation.getVotes(dele);
        uint256 nextHour = delegation.getPastVotes(dele, block.timestamp); // == live
        assertEq(live, nextHour, "probe");
        vm.recordLogs();
        vm.prank(stranger);
        delegation.refreshVotingPower(dele);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 broadcast = type(uint256).max;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("DelegateVotesChanged(address,uint256,uint256)")) {
                (, uint256 newV) = abi.decode(logs[i].data, (uint256, uint256));
                broadcast = newV;
            }
        }
        assertTrue(broadcast != type(uint256).max, "no DelegateVotesChanged emitted");
        assertLt(broadcast, live, "refreshVotingPower broadcast the CURRENT value, not the next-hour one");
    }

    // ------------------------------------------------------------------
    // C7 — A MOVE-AWAY DECREMENTS THE EXPIRATION BUCKET. If it stops, the
    //      old delegatee's book over-claims and a later honest retirement
    //      panics (0x11).
    // ------------------------------------------------------------------
    function test_C7_moveAwayIsExactAndTheBookSurvivesExpiry() public {
        (uint256 a, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        (uint256 b, , ) = createLock(bob, 500 ether, 2 * 365 days);
        delegateTo(victim, a, dele);
        delegateTo(bob, b, dele);
        vm.warp(block.timestamp + 7200);
        uint256 both = delegation.getVotes(dele);
        assertGt(both, 0, "probe");

        delegateTo(victim, a, dele2); // move away
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(b), "move-away left residue on the old delegatee");
        assertEq(delegation.getVotes(dele2), veHemi.balanceOfNFT(a), "move-away did not land on the new delegatee");

        // walk both books past expiry: nothing may panic and nothing may
        // survive.
        vm.warp(block.timestamp + 150 * SIX_DAYS);
        assertEq(delegation.getVotes(dele), 0, "old delegatee's book did not drain");
        assertEq(delegation.getVotes(dele2), 0, "new delegatee's book did not drain");
        delegation.writeNewCheckpointForExpiredDelegations(dele);
        assertEq(delegation.getVotes(dele), 0, "amortiser left residue");
    }

    // ------------------------------------------------------------------
    // C8 — THE PERMISSIONLESS RETIRE IS NOT A CONFISCATION PRIMITIVE.
    //      `retireStaleAutoRelock` is callable by ANYONE, so bound it:
    //      it takes nothing, it restores exactly the end `disableAutoRelock`
    //      would have restored, the owner may re-enable immediately, and it
    //      cannot be aimed at a position whose owner is still paying.
    // ------------------------------------------------------------------
    function test_C8_staleRetireIsNotConfiscation() public {
        (uint256 grief, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        (uint256 twin, , ) = createLock(bob, 1_000 ether, 4 * 365 days);
        enable(victim, grief);
        enable(bob, twin);
        vm.warp(veHemi.autoRelockStaleAt(grief));

        // the twin's owner disables by hand in the same second.
        disable(bob, twin);
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(grief);

        // the stranger's retire IS the owner's disable, to the second and to
        // the wei.
        assertEq(veHemi.getLockedBalance(grief).end, veHemi.getLockedBalance(twin).end, "retire restored a different end than disable");
        assertEq(uint256(uint128(veHemi.getLockedBalance(grief).amount)), 1_000 ether, "retire TOOK principal");
        assertEq(veHemi.balanceOfNFT(grief), veHemi.balanceOfNFT(twin), "retire left a different weight than disable");
        assertEq(veHemi.ownerOf(grief), victim, "retire moved ownership");

        // and the owner is not locked out: re-enable works immediately.
        enable(victim, grief);
        assertGt(veHemi.autoRelockRemaining(grief), 0, "owner cannot re-enable after a stranger's retire");

        // the griefer cannot repeat it: the clock restarted.
        vm.prank(stranger);
        vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
        veHemi.retireStaleAutoRelock(grief);
    }

    // ------------------------------------------------------------------
    // C10 — RETIRING AN ALREADY-EXPIRED TERM MUST NOT UNDERFLOW. The
    //       SIX_DAYS sweep has already taken the bias and slope of an expired
    //       delegation, so the retirement path must
    //       subtract NOTHING. If it subtracts unconditionally the delegatee's
    //       book panics 0x11 and the holder's own exit reverts -- funds
    //       trapped behind a delegatee they do not control.
    // ------------------------------------------------------------------
    function test_C10_expiredTermRetiresWithoutUnderflow() public {
        (uint256 a, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        (uint256 b, , ) = createLock(bob, 500 ether, 4 * 365 days);
        delegateTo(victim, a, dele);
        delegateTo(bob, b, dele);
        vm.warp(block.timestamp + 7200);
        assertGt(delegation.getVotes(dele), 0, "probe");

        // let a's term expire and its SIX_DAYS bucket sweep
        vm.warp(veHemi.getLockedBalance(a).end + 3 * SIX_DAYS);
        uint256 coDelegator = veHemi.balanceOfNFT(b);
        assertEq(delegation.getVotes(dele), coDelegator, "sweep did not leave exactly the co-delegator");

        // An EXPIRED record cannot be moved away at all
        // (`CanNotDelegateExpiredLocks`) -- the only path that
        // retires it is the holder's own exit, which routes
        // `_delegate(id, address(0))` through the cleanup branch.
        vm.prank(victim);
        vm.expectRevert(VeHemiVoteDelegation.CanNotDelegateExpiredLocks.selector);
        delegation.delegate(a, dele2);

        // The exit must return the principal and leave the book exact.
        uint256 before = hemi.balanceOf(victim);
        vm.prank(victim);
        veHemi.withdraw(a);
        assertEq(hemi.balanceOf(victim) - before, 1_000 ether, "exit behind an expired delegation reverted or short-paid");
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(b), "withdraw of an EXPIRED term corrupted the book");
    }
}

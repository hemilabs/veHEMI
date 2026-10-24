// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";

/// @title  Auto-relock composed with the other entry points.
///
/// @notice An attacker composes auto-relock with transfer, seeding, forfeit,
///         `increaseAmount` or the delegation try/catch and must not get a
///         result no single entry point permits — most sharply a flat term
///         retired from the escrow but never from the delegatee (permanent
///         votes with no position behind them). `forfeit` runs its delegation
///         cleanup BEFORE the bookkeeping, so starving it cannot commit such a
///         phantom (D11, D11b).
contract EntryPointCompositionTest is AutoRelockTestBase {
    // ------------------------------------------------------------------
    // D1 — TRANSFER CREDITS THE RECIPIENT'S auto-delegate, never `to_`
    //      directly.
    // ------------------------------------------------------------------
    function test_D1_transferCreditsTheAutoDelegate() public {
        vm.prank(bob);
        delegation.setAutoDelegate(delegateeB);
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        delegateTo(attacker, id, delegateeA);
        vm.warp(block.timestamp + 7200);

        vm.prank(attacker);
        veHemi.transferFrom(attacker, bob, id);
        vm.warp(block.timestamp + 7200);
        // The transfer disarmed the position into a decaying lock, so compare
        // against its LIVE weight: the buyer's AUTO-DELEGATE is credited, the
        // seller's delegatee is not, and the buyer's own account is not
        // credited directly.
        assertEq(delegation.getVotes(delegateeA), 0, "seller's delegatee kept the flat term");
        assertEq(delegation.getVotes(delegateeB), veHemi.balanceOfNFT(id), "buyer's AUTO-DELEGATE was not credited");
        assertEq(delegation.getVotes(bob), 0, "buyer was credited DIRECTLY, bypassing autoDelegate");
    }

    // ------------------------------------------------------------------
    // D2 — THE SEEDING GUARD: a still-non-transferable position cannot be
    //      frozen before or during the seeding window.
    // ------------------------------------------------------------------
    function test_D2_seedingGuardRefusesMidWindowFreeze() public {
        // fresh deployment: this test needs the seeding latch DOWN.
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, admin));
        VeHemi freshVeHemi = VeHemi(address(proxy));
        VeHemiVoteDelegation freshDelegation = new VeHemiVoteDelegation(address(freshVeHemi));
        freshVeHemi.updateVoteDelegation(freshDelegation);
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(freshVeHemi), type(uint256).max);

        uint256 id = freshVeHemi.createLockFor(1_000 ether, 4 * 365 days, victim, false, false);
        assertGt(freshVeHemi.transferableAfter(id), block.timestamp, "premise: the position is already transferable");
        // before markSeedingStarted
        vm.prank(victim);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        freshVeHemi.enableAutoRelock(id);
        // during the window
        freshVeHemi.markSeedingStarted();
        vm.prank(victim);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        freshVeHemi.enableAutoRelock(id);
        // and after finalisation it is admitted
        freshVeHemi.seedBatch(type(uint256).max);
        freshVeHemi.finalizeSeeding();
        vm.prank(victim);
        freshVeHemi.enableAutoRelock(id);
        assertGt(freshVeHemi.autoRelockRemaining(id), 0, "post-seeding enable refused");
    }

    // ------------------------------------------------------------------
    // D3 — THE BURN CLEARS THE FLAT FLAG BEFORE THE CHECKPOINT.
    //      If it does not, the flat aggregate outlives the token.
    // ------------------------------------------------------------------
    function test_D3_forfeitOfAFlatPositionClearsEverything() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        (uint256 honest, , ) = createLock(bob, 100 ether, 4 * 365 days);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        enable(victim, id);
        delegateTo(victim, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "premise: not in the forfeitable subcurve");

        veHemi.forfeit(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "forfeit left the flat flag set");
        assertEq(veHemi.balanceOfNFT(id), 0, "forfeit left weight behind");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeit left the forfeitable subcurve dirty");
        assertEq(veHemi.totalVeHemiSupply(), veHemi.balanceOfNFT(honest), "forfeit stranded the flat aggregate");
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(delegateeA), 0, "forfeit stranded the flat term at the delegatee");
    }

    // ------------------------------------------------------------------
    // D4 — THE FORFEIT WINDOW IS NOT MOVED BY THE FREEZE, in either
    //      direction. (After `transferableAfter` the stored end is in the past
    //      too, so from one bucket on the refusal is `LockExpired`.)
    // ------------------------------------------------------------------
    function test_D4_forfeitWindowUnmovedByTheFreeze() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 transferableAfter = veHemi.transferableAfter(id);
        enable(victim, id);
        // sweep the last 12 buckets of the window: open before
        // `transferableAfter`, shut at and after it.
        for (uint256 k = 12; k >= 1; --k) {
            uint256 snap = vm.snapshotState();
            vm.warp(transferableAfter - k * SIX_DAYS);
            veHemi.forfeit(id);
            vm.revertToState(snap);
        }
        for (uint256 k = 0; k < 4; ++k) {
            uint256 snap = vm.snapshotState();
            vm.warp(transferableAfter + k * SIX_DAYS);
            vm.expectRevert(k == 0 ? VeHemi.ForfeitWindowExpired.selector : VeHemi.LockExpired.selector);
            veHemi.forfeit(id);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------
    // D5 — REPEATED TOP-UPS CANNOT RATCHET `R`, and each re-materialises the
    //      stored end on the grid. (`increaseAmount` is owner-gated.)
    // ------------------------------------------------------------------
    function test_D5_topUpCannotRatchetR() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        enable(victim, id);
        uint64 r0 = veHemi.autoRelockRemaining(id);
        vm.warp(block.timestamp + 20 * SIX_DAYS);
        for (uint256 i = 0; i < 8; ++i) {
            vm.prank(victim);
            veHemi.increaseAmount(id, 10 ether);
            assertEq(veHemi.autoRelockRemaining(id), r0, "a top-up RATCHETED R");
            // the stored end is re-materialised, not left in the past
            assertEq(veHemi.getLockedBalance(id).end, veHemi.effectiveLockEnd(id), "stored end not re-materialised by a top-up");
            assertEq(veHemi.getLockedBalance(id).end % SIX_DAYS, 0, "stored end left the grid");
        }
        disable(victim, id);
        assertEq(veHemi.getLockedBalance(id).end, ((block.timestamp / SIX_DAYS) + uint256(r0) / SIX_DAYS) * SIX_DAYS, "restored end is not grid(now) + R");
    }

    // ------------------------------------------------------------------
    // D6 — `increaseAmount`'s SEEDING GUARD: the owner's top-up of a
    //      non-transferable position is refused during the seeding window and
    //      admitted once it is shut.
    // ------------------------------------------------------------------
    function test_D6_increaseAmountRefusedDuringSeedingAdmittedAfter() public {
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, admin));
        VeHemi freshVeHemi = VeHemi(address(proxy));
        freshVeHemi.updateVoteDelegation(new VeHemiVoteDelegation(address(freshVeHemi)));
        hemi.mint(admin, 3_000 ether);
        hemi.approve(address(freshVeHemi), type(uint256).max);
        uint256 id = freshVeHemi.createLockFor(1_000 ether, 4 * 365 days, victim, false, false);
        freshVeHemi.markSeedingStarted();
        vm.prank(victim);
        hemi.approve(address(freshVeHemi), type(uint256).max);
        hemi.mint(victim, 100 ether);
        vm.prank(victim);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        freshVeHemi.increaseAmount(id, 10 ether);
        freshVeHemi.seedBatch(type(uint256).max);
        freshVeHemi.finalizeSeeding();
        vm.prank(victim);
        freshVeHemi.increaseAmount(id, 10 ether); // admitted once the window is shut
    }

    // ------------------------------------------------------------------
    // D8 — CONTROL: a DECAYING delegated term self-heals through its
    //      SIX_DAYS expiration bucket, so only a FLAT stranded term can be
    //      permanent (which is what D3 and D11 rule out).
    // ------------------------------------------------------------------
    function test_D8_control_decayingDelegatedTermExpiresToZeroVotes() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        delegateTo(victim, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        assertGt(delegation.getVotes(delegateeA), 0, "premise: no votes at delegateeA");
        vm.warp(veHemi.getLockedBalance(id).end + SIX_DAYS);
        assertEq(delegation.getVotes(delegateeA), 0, "a DECAYING term did not self-heal -- vacuity control failed");
    }

    // ------------------------------------------------------------------
    // D9 — THE FORFEITABLE SUBCURVE, COMPOSED. A non-transferable
    //      FORFEITABLE grant kept flat (heartbeat paid) until its window opens
    //      and then sold must not become a perpetual asset: the sale disarms
    //      it, and it and the forfeitable subcurve drain on their own.
    // ------------------------------------------------------------------
    function test_D9_frozenForfeitableIsBoundedAndTheSubcurveDrains() public {
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 transferableAfter = veHemi.transferableAfter(id);
        enable(victim, id);
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "premise: not in the forfeitable subcurve");

        // the grant holder keeps the heartbeat paid until the window opens,
        // so the sale happens at FULL weight.
        while (block.timestamp < transferableAfter) {
            uint256 nextDue = veHemi.autoRelockStaleAt(id);
            vm.warp(nextDue < transferableAfter ? nextDue - 1 : transferableAfter + 1);
            if (block.timestamp < transferableAfter) { vm.prank(victim); veHemi.refreshAutoRelock(id); }
        }
        assertGt(veHemi.balanceOfNFT(id), 0, "premise: no weight to sell");
        vm.prank(victim);
        veHemi.transferFrom(victim, attacker, id); // sold at full weight

        // DISARM-ON-TRANSFER: the sale DISARMS the grant, so the buyer
        // receives a plain DECAYING lock with no abandonment clock running.
        assertEq(veHemi.autoRelockRemaining(id), 0, "the sale left the grant armed on the buyer");
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        veHemi.autoRelockStaleAt(id);

        // The decaying grant drains naturally: the subcurve and the denominator
        // heal on their own, without any permissionless retire.
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(veHemi.balanceOfNFT(id), 0, "the sold frozen grant outlived its decay");
        assertEq(veHemi.totalVeHemiSupply(), 0, "denominator never healed");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve never drained");
        (uint256 total, uint256 locked_, uint256 forfeitable_, ) = veHemi.supplyBreakdown();
        assertEq(total, 0, "supplyBreakdown total not drained");
        assertEq(locked_, 0, "supplyBreakdown locked not drained");
        assertEq(forfeitable_, 0, "supplyBreakdown forfeitable not drained");
    }

    // D12 — the forfeit-window / transferable-window DISJOINTNESS. An ARMED
    // forfeitable position stays flat past its original end, but while
    // `now < transferableAfter` it is NON-transferable -- a transfer reverts
    // NotTransferable BEFORE the disarm can run, so there is NO
    // transfer-to-disarm forfeit escape. The two windows flip at exactly
    // `transferableAfter` (`forfeit` refuses at `>= transferableAfter`,
    // `isTransferable` is true at `>= transferableAfter`). The post-window
    // transfer and drain is D9.
    function test_D12_armedForfeitableNotTransferableDuringForfeitWindow() public {
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 transferableAfter = veHemi.transferableAfter(id);
        enable(victim, id); // arm the forfeitable position (flat => survives past transferableAfter)

        // DURING the forfeit window: non-transferable, so the transfer reverts
        // before the disarm line is ever reached.
        assertTrue(block.timestamp < transferableAfter, "premise: already past the forfeit window");
        assertFalse(veHemi.isTransferable(id), "forfeitable must be non-transferable in-window");
        vm.prank(victim);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(victim, attacker, id);

        // AT transferableAfter the forfeit window has permanently closed and the
        // position becomes transferable -- the disjointness holds exactly at transferableAfter.
        vm.warp(transferableAfter);
        assertTrue(veHemi.isTransferable(id), "must be transferable once the window closes");
    }

    // ------------------------------------------------------------------
    // D10 — THE ANTI-IMMORTALITY TWIN. Enable/disable cycling can hold lock
    //       life near MAX_TIME, but a manual `increaseUnlockTime` twin does the
    //       same, so cycling must never beat the twin on life or on weight.
    // ------------------------------------------------------------------
    function test_D10_cyclingConfersNoAdvantageOverTheManualTwin() public {
        (uint256 cycledId, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        (uint256 manualId, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        for (uint256 i = 0; i < 120; ++i) {
            vm.warp(grid() + SIX_DAYS + 3);
            enable(attacker, cycledId);
            vm.warp(block.timestamp + SIX_DAYS - 6);
            disable(attacker, cycledId);
            vm.prank(victim);
            try veHemi.increaseUnlockTime(manualId, MAX_TIME) {} catch {}
        }
        vm.warp(grid() + SIX_DAYS + 3);
        vm.prank(victim);
        try veHemi.increaseUnlockTime(manualId, MAX_TIME) {} catch {}
        uint256 cycledLife = veHemi.getLockedBalance(cycledId).end > block.timestamp ? veHemi.getLockedBalance(cycledId).end - block.timestamp : 0;
        uint256 manualLife = veHemi.getLockedBalance(manualId).end > block.timestamp ? veHemi.getLockedBalance(manualId).end - block.timestamp : 0;
        emit log_named_uint("cycled life left", cycledLife);
        emit log_named_uint("manual life left", manualLife);
        assertLe(cycledLife, manualLife, "CYCLING BEAT THE MANUAL TWIN -- free lock life");
        assertLe(veHemi.balanceOfNFT(cycledId), veHemi.balanceOfNFT(manualId), "CYCLING BEAT THE MANUAL TWIN on weight");
        assertLe(cycledLife, MAX_TIME, "cycled position above MAX_TIME");
    }

    // ------------------------------------------------------------------
    // D11 — A STARVED FORFEIT OF A FLAT POSITION CANNOT COMMIT A PHANTOM.
    //       `forfeit` is reachable on a flat position and retires its flat
    //       term; its delegation cleanup (`_delegate(id, 0)`) runs BEFORE the
    //       bookkeeping. On a directly called module a starved cleanup trips
    //       `_requireNotStarved`; behind the delegatecall proxy (live) it
    //       reads as a refusal, and the call still cannot commit because the
    //       `_withdraw` tail needs more than the roughly 1/32 a starved
    //       cleanup leaves.
    //       So at every gas limit the call either reverts (out of gas, or
    //       `DelegationCallStarved`) or commits with the term fully retired.
    //       `forfeit` does not pass `_reDelegate`'s REMOVAL_GAS_FLOOR, so the
    //       sweep's low end really is refused by the tripwire or the tail, not
    //       the floor. D11 sweeps the direct module; D11b sweeps an
    //       `ERC1967Proxy` in front of the real module with the delegatee
    //       dormant for 200 buckets, so the cleanup is a long walk.
    //       Oracle per committing gas limit, O(1): the token holds no weight,
    //       the supply is 0, and at the next hour the delegatee holds 0 votes
    //       (a stranded FLAT term never decays, so 0 rules it out).
    // ------------------------------------------------------------------
    function test_D11_starvedForfeitOfAFlatPositionCommitsNoPhantom() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        enable(victim, id);
        delegateTo(victim, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id), "premise: flat term not booked at the delegatee");
        uint256 nextHourBoundary = ((block.timestamp / 1 hours) + 1) * 1 hours;

        uint256 committed;
        uint256 refused;
        uint256 refusedAsStarved;
        // fine steps from below the starved-cleanup band (where the tripwire
        // fires) across the refuse/commit edge, coarse above it
        for (uint256 gasLimit = 20_000; gasLimit <= 1_500_000; gasLimit += (gasLimit < 400_000 ? 2_000 : 50_000)) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(veHemi).call{gas: gasLimit}(abi.encodeWithSignature("forfeit(uint256)", id));
            if (ok) {
                ++committed;
                assertEq(veHemi.autoRelockRemaining(id), 0, "committed forfeit left the flag");
                assertEq(veHemi.balanceOfNFT(id), 0, "starved forfeit left weight");
                assertEq(veHemi.totalVeHemiSupply(), 0, "starved forfeit left supply");
                vm.warp(nextHourBoundary);
                assertEq(delegation.getVotes(delegateeA), 0, "STARVED FORFEIT LEFT A PERMANENT FLAT PHANTOM");
            } else {
                ++refused;
                // out of gas (no data) or the starvation tripwire; nothing else
                assertTrue(
                    ret.length == 0 || bytes4(ret) == VeHemi.DelegationCallStarved.selector,
                    "forfeit refused for a reason other than starvation"
                );
                if (ret.length >= 4 && bytes4(ret) == VeHemi.DelegationCallStarved.selector) ++refusedAsStarved;
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("committed", committed);
        emit log_named_uint("refused", refused);
        emit log_named_uint("refused with DelegationCallStarved", refusedAsStarved);
        assertGt(committed, 0, "the call committed at no gas limit -- the sweep checked nothing");
        assertGt(refused, 0, "the call was refused at no gas limit -- the sweep never starved the call");
        assertGt(refusedAsStarved, 0, "the tripwire never fired -- the sweep never starved the cleanup");
    }

    /// @dev D11b. The D11 sweep behind a delegatecall proxy, where the
    ///      tripwire cannot fire (a starved callee hands back about 1/32), with
    ///      the delegatee untouched for 200 buckets so the cleanup is the
    ///      expensive part of the call. Same oracle as D11.
    function test_D11b_starvedProxiedForfeitWithDormantDelegateeCommitsNoPhantom() public {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(proxy));
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 4 * 365 days, victim, false, true);
        enable(victim, id);
        delegateTo(victim, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id), "premise: flat term not booked at the delegatee");
        vm.warp(block.timestamp + 200 * SIX_DAYS); // the delegatee is not touched again
        veHemi.checkpoint(); // VeHemi's global curve stays fresh; only the module's walk is long
        assertLt(block.timestamp, veHemi.transferableAfter(id), "premise: forfeit window closed");
        uint256 nextHourBoundary = ((block.timestamp / 1 hours) + 1) * 1 hours;
        {
            uint256 snap = vm.snapshotState();
            uint256 gasBefore = gasleft();
            veHemi.forfeit(id);
            uint256 used = gasBefore - gasleft();
            emit log_named_uint("forfeit gas with a dormant delegatee", used);
            assertGt(used, 600_000, "premise: the dormant cleanup is not the expensive part of the call");
            vm.revertToState(snap);
        }

        uint256 committed;
        uint256 refused;
        uint256 outOfGas;
        for (uint256 gasLimit = 100_000; gasLimit <= 1_600_000; gasLimit += 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(veHemi).call{gas: gasLimit}(abi.encodeWithSignature("forfeit(uint256)", id));
            if (ok) {
                ++committed;
                assertEq(veHemi.autoRelockRemaining(id), 0, "committed forfeit left the flag");
                assertEq(veHemi.balanceOfNFT(id), 0, "starved forfeit left weight");
                assertEq(veHemi.totalVeHemiSupply(), 0, "starved forfeit left supply");
                vm.warp(nextHourBoundary);
                assertEq(delegation.getVotes(delegateeA), 0, "STARVED FORFEIT LEFT A PERMANENT FLAT PHANTOM (proxied)");
            } else {
                ++refused;
                assertTrue(
                    ret.length == 0 || bytes4(ret) == VeHemi.DelegationCallStarved.selector,
                    "forfeit refused for a reason other than starvation"
                );
                if (ret.length == 0) ++outOfGas;
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("committed", committed);
        emit log_named_uint("refused", refused);
        emit log_named_uint("refused out of gas", outOfGas);
        assertGt(committed, 0, "the call committed at no gas limit -- the sweep checked nothing");
        assertGt(outOfGas, 0, "the call ran out of gas at no gas limit -- the sweep never starved the call");
    }
}

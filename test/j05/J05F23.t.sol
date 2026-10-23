// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./J05Base.sol";

/// @title  Auto-relock composed with the other entry points.
///
/// @notice An attacker composes auto-relock with transfer, seeding, forfeit,
///         `increaseAmount` or the delegation try/catch and must not get a
///         result no single entry point permits — most sharply a flat term
///         retired from the escrow but never from the delegatee (permanent
///         votes with no position behind them). `forfeit` runs its delegation
///         cleanup BEFORE the bookkeeping, so starving it cannot commit such a
///         phantom (D11, D11b).
contract J05F23 is J05Base {
    // ------------------------------------------------------------------
    // D1 — TRANSFER CREDITS THE RECIPIENT'S auto-delegate, never `to_`
    //      directly.
    // ------------------------------------------------------------------
    function test_F23_D1_transferCreditsTheAutoDelegate() public {
        vm.prank(bob);
        delegation.setAutoDelegate(dele2);
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, id);
        delegateTo(attacker, id, dele);
        vm.warp(block.timestamp + 7200);

        vm.prank(attacker);
        veHemi.transferFrom(attacker, bob, id);
        vm.warp(block.timestamp + 7200);
        // The transfer disarmed the position into a decaying lock, so compare
        // against its LIVE weight: the buyer's AUTO-DELEGATE is credited, the
        // seller's delegatee is not, and the buyer's own account is not
        // credited directly.
        assertEq(delegation.getVotes(dele), 0, "seller's delegatee kept the flat term");
        assertEq(delegation.getVotes(dele2), veHemi.balanceOfNFT(id), "buyer's AUTO-DELEGATE was not credited");
        assertEq(delegation.getVotes(bob), 0, "buyer was credited DIRECTLY, bypassing autoDelegate");
    }

    // ------------------------------------------------------------------
    // D2 — THE SEEDING GUARD: a still-non-transferable position cannot be
    //      frozen before or during the seeding window.
    // ------------------------------------------------------------------
    function test_F23_D2_guard8RefusesMidWindowFreeze() public {
        // fresh deployment: this test needs the seeding latch DOWN.
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy p = new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, admin));
        VeHemi ve2 = VeHemi(address(p));
        VeHemiVoteDelegation d2 = new VeHemiVoteDelegation(address(ve2));
        ve2.updateVoteDelegation(d2);
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(ve2), type(uint256).max);

        uint256 id = ve2.createLockFor(1_000 ether, 4 * 365 days, victim, false, false);
        assertGt(ve2.transferableAfter(id), block.timestamp, "probe: window already open");
        // before markSeedingStarted
        vm.prank(victim);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        ve2.enableAutoRelock(id);
        // during the window
        ve2.markSeedingStarted();
        vm.prank(victim);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        ve2.enableAutoRelock(id);
        // and after finalisation it is admitted
        ve2.seedBatch(type(uint256).max);
        ve2.finalizeSeeding();
        vm.prank(victim);
        ve2.enableAutoRelock(id);
        assertGt(ve2.autoRelockRemaining(id), 0, "post-seeding enable refused");
    }

    // ------------------------------------------------------------------
    // D3 — THE BURN CLEARS THE FLAT FLAG BEFORE THE CHECKPOINT.
    //      If it does not, the flat aggregate outlives the token.
    // ------------------------------------------------------------------
    function test_F23_D3_forfeitOfAFlatPositionClearsEverything() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        (uint256 honest, , ) = createLock(bob, 100 ether, 4 * 365 days);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        enable(victim, id);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "probe: not in the forfeitable subcurve");

        veHemi.forfeit(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "forfeit left the flat flag set");
        assertEq(veHemi.balanceOfNFT(id), 0, "forfeit left weight behind");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeit left the forfeitable subcurve dirty");
        assertEq(veHemi.totalVeHemiSupply(), veHemi.balanceOfNFT(honest), "forfeit stranded the flat aggregate");
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(dele), 0, "forfeit stranded the flat term at the delegatee");
    }

    // ------------------------------------------------------------------
    // D4 — THE FORFEIT WINDOW IS NOT MOVED BY THE FREEZE, in either
    //      direction. (After `ta` the frozen stored end is in the past too, so
    //      from one bucket on the refusal is `LockExpired`.)
    // ------------------------------------------------------------------
    function test_F23_D4_forfeitWindowUnmovedByTheFreeze() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 ta = veHemi.transferableAfter(id);
        enable(victim, id);
        // sweep the last 12 buckets of the window: open before `ta`, shut at
        // and after it.
        for (uint256 k = 12; k >= 1; --k) {
            uint256 snap = vm.snapshotState();
            vm.warp(ta - k * SIX_DAYS);
            veHemi.forfeit(id);
            vm.revertToState(snap);
        }
        for (uint256 k = 0; k < 4; ++k) {
            uint256 snap = vm.snapshotState();
            vm.warp(ta + k * SIX_DAYS);
            vm.expectRevert(k == 0 ? VeHemi.ForfeitWindowExpired.selector : VeHemi.LockExpired.selector);
            veHemi.forfeit(id);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------
    // D5 — REPEATED TOP-UPS CANNOT RATCHET `R`, and each re-materialises the
    //      stored end on the grid. (`increaseAmount` is owner-gated.)
    // ------------------------------------------------------------------
    function test_F23_D5_topUpCannotRatchetR() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        enable(victim, id);
        uint64 r0 = veHemi.autoRelockRemaining(id);
        vm.warp(block.timestamp + 20 * SIX_DAYS);
        for (uint256 i = 0; i < 8; ++i) {
            vm.prank(victim);
            veHemi.increaseAmount(id, 10 ether);
            assertEq(veHemi.autoRelockRemaining(id), r0, "a top-up RATCHETED R");
            // the lazily-maintained end is re-materialised, not left stale
            assertEq(veHemi.getLockedBalance(id).end, veHemi.effectiveLockEnd(id), "stored end left stale by a top-up");
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
    function test_F23_D6_increaseAmountSeedingGuard() public {
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy p = new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, admin));
        VeHemi ve2 = VeHemi(address(p));
        ve2.updateVoteDelegation(new VeHemiVoteDelegation(address(ve2)));
        hemi.mint(admin, 3_000 ether);
        hemi.approve(address(ve2), type(uint256).max);
        uint256 id = ve2.createLockFor(1_000 ether, 4 * 365 days, victim, false, false);
        ve2.markSeedingStarted();
        vm.prank(victim);
        hemi.approve(address(ve2), type(uint256).max);
        hemi.mint(victim, 100 ether);
        vm.prank(victim);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        ve2.increaseAmount(id, 10 ether);
        ve2.seedBatch(type(uint256).max);
        ve2.finalizeSeeding();
        vm.prank(victim);
        ve2.increaseAmount(id, 10 ether); // admitted once the window is shut
    }

    // ------------------------------------------------------------------
    // D8 — CONTROL: a DECAYING delegated term self-heals through its
    //      SIX_DAYS expiration bucket, so only a FLAT stranded term can be
    //      permanent (which is what D3 and D11 rule out).
    // ------------------------------------------------------------------
    function test_F23_D8_decayingStrandedTermSelfHeals() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 2 * 365 days);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);
        assertGt(delegation.getVotes(dele), 0, "probe");
        vm.warp(veHemi.getLockedBalance(id).end + SIX_DAYS);
        assertEq(delegation.getVotes(dele), 0, "a DECAYING term did not self-heal -- vacuity control failed");
    }

    // ------------------------------------------------------------------
    // D9 — THE FORFEITABLE SUBCURVE, COMPOSED. A non-transferable
    //      FORFEITABLE grant kept flat (heartbeat paid) until its window opens
    //      and then sold must not become a perpetual asset: the sale disarms
    //      it, and it and the forfeitable subcurve drain on their own.
    // ------------------------------------------------------------------
    function test_F23_D9_frozenForfeitableIsBoundedAndTheSubcurveDrains() public {
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 ta = veHemi.transferableAfter(id);
        enable(victim, id);
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "probe: not in the forfeitable subcurve");

        // the grant holder keeps the heartbeat paid until the window opens,
        // so the sale happens at FULL weight.
        while (block.timestamp < ta) {
            uint256 nextDue = veHemi.autoRelockStaleAt(id);
            vm.warp(nextDue < ta ? nextDue - 1 : ta + 1);
            if (block.timestamp < ta) { vm.prank(victim); veHemi.refreshAutoRelock(id); }
        }
        assertGt(veHemi.balanceOfNFT(id), 0, "probe: no weight to sell");
        vm.prank(victim);
        veHemi.transferFrom(victim, attacker, id); // sold at full weight

        // DISARM-ON-TRANSFER: the sale DISARMS the grant, so the buyer
        // receives a plain DECAYING lock with no auto-relock clock running.
        assertEq(veHemi.autoRelockRemaining(id), 0, "the sale left the grant armed on the buyer");
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        veHemi.autoRelockStaleAt(id);

        // The decaying grant drains naturally: the subcurve and the denominator
        // heal on their own, without any permissionless retire.
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(veHemi.balanceOfNFT(id), 0, "the sold frozen grant outlived its decay");
        assertEq(veHemi.totalVeHemiSupply(), 0, "denominator never healed");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve never drained");
        (uint256 tot, uint256 lok, uint256 forf, ) = veHemi.supplyBreakdown();
        assertEq(tot, 0, "supplyBreakdown total not drained");
        assertEq(lok, 0, "supplyBreakdown locked not drained");
        assertEq(forf, 0, "supplyBreakdown forfeitable not drained");
    }

    // D12 — the forfeit-window / transferable-window DISJOINTNESS. An ARMED
    // forfeitable position stays flat past its original end, but while
    // `now < transferableAfter` it is NON-transferable -- a transfer reverts
    // NotTransferable BEFORE the disarm can run, so there is NO
    // transfer-to-disarm forfeit escape. The two windows flip at exactly
    // `transferableAfter` (`forfeit` refuses at `>= ta`, `isTransferable` is
    // true at `>= ta`). The post-window transfer and drain is D9.
    function test_F23_D12_armedForfeitableNotTransferableDuringForfeitWindow() public {
        hemi.mint(admin, 2_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        uint256 ta = veHemi.transferableAfter(id);
        enable(victim, id); // arm the forfeitable position (flat => survives past ta)

        // DURING the forfeit window: non-transferable, so the transfer reverts
        // before the disarm line is ever reached.
        assertTrue(block.timestamp < ta, "probe: already past the forfeit window");
        assertFalse(veHemi.isTransferable(id), "forfeitable must be non-transferable in-window");
        vm.prank(victim);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(victim, attacker, id);

        // AT transferableAfter the forfeit window has permanently closed and the
        // position becomes transferable -- the disjointness holds exactly at ta.
        vm.warp(ta);
        assertTrue(veHemi.isTransferable(id), "must be transferable once the window closes");
    }

    // ------------------------------------------------------------------
    // D10 — THE ANTI-IMMORTALITY TWIN. Enable/disable cycling can hold lock
    //       life near MAX_TIME, but a manual `increaseUnlockTime` twin does the
    //       same, so cycling must never beat the twin on life or on weight.
    // ------------------------------------------------------------------
    function test_F23_D10_cyclingConfersNoAdvantageOverTheManualTwin() public {
        (uint256 a, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        (uint256 b, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        for (uint256 i = 0; i < 120; ++i) {
            vm.warp(grid() + SIX_DAYS + 3);
            enable(attacker, a);
            vm.warp(block.timestamp + SIX_DAYS - 6);
            disable(attacker, a);
            vm.prank(victim);
            try veHemi.increaseUnlockTime(b, MAX_TIME) {} catch {}
        }
        vm.warp(grid() + SIX_DAYS + 3);
        vm.prank(victim);
        try veHemi.increaseUnlockTime(b, MAX_TIME) {} catch {}
        uint256 lifeA = veHemi.getLockedBalance(a).end > block.timestamp ? veHemi.getLockedBalance(a).end - block.timestamp : 0;
        uint256 lifeB = veHemi.getLockedBalance(b).end > block.timestamp ? veHemi.getLockedBalance(b).end - block.timestamp : 0;
        emit log_named_uint("A (cycled) life left", lifeA);
        emit log_named_uint("B (manual) life left", lifeB);
        assertLe(lifeA, lifeB, "CYCLING BEAT THE MANUAL TWIN -- free lock life");
        assertLe(veHemi.balanceOfNFT(a), veHemi.balanceOfNFT(b), "CYCLING BEAT THE MANUAL TWIN on weight");
        assertLe(lifeA, MAX_TIME, "cycled position above MAX_TIME");
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
    //       Oracle per committed point, O(1): the token holds no weight, the
    //       supply is 0, and at the next hour the delegatee holds 0 votes (a
    //       stranded FLAT term never decays, so 0 rules it out).
    // ------------------------------------------------------------------
    function test_F23_D11_forfeitOfAFlatPositionCannotBeStarved() public {
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 2 * 365 days, victim, false, true);
        enable(victim, id);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "probe: flat term not booked at the delegatee");
        uint256 nextHour = ((block.timestamp / 1 hours) + 1) * 1 hours;

        uint256 committed;
        uint256 refused;
        uint256 starvedSelector;
        // fine steps from below the starved-cleanup band (where the tripwire
        // fires) across the refuse/commit edge, coarse above it
        for (uint256 g = 20_000; g <= 1_500_000; g += (g < 400_000 ? 2_000 : 50_000)) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(veHemi).call{gas: g}(abi.encodeWithSignature("forfeit(uint256)", id));
            if (ok) {
                ++committed;
                assertEq(veHemi.autoRelockRemaining(id), 0, "committed forfeit left the flag");
                assertEq(veHemi.balanceOfNFT(id), 0, "starved forfeit left weight");
                assertEq(veHemi.totalVeHemiSupply(), 0, "starved forfeit left supply");
                vm.warp(nextHour);
                assertEq(delegation.getVotes(dele), 0, "STARVED FORFEIT LEFT A PERMANENT FLAT PHANTOM");
            } else {
                ++refused;
                // out of gas (no data) or the starvation tripwire; nothing else
                assertTrue(
                    ret.length == 0 || bytes4(ret) == VeHemi.DelegationCallStarved.selector,
                    "forfeit refused for a reason other than starvation"
                );
                if (ret.length >= 4 && bytes4(ret) == VeHemi.DelegationCallStarved.selector) ++starvedSelector;
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("committed", committed);
        emit log_named_uint("refused", refused);
        emit log_named_uint("refused with DelegationCallStarved", starvedSelector);
        assertGt(committed, 0, "no grid point committed -- the sweep checked nothing");
        assertGt(refused, 0, "no grid point was refused -- the sweep never starved the call");
        assertGt(starvedSelector, 0, "the tripwire never fired -- the sweep never starved the cleanup");
    }

    /// @dev D11b. The D11 sweep behind a delegatecall proxy, where the
    ///      tripwire cannot fire (a starved callee hands back about 1/32), with
    ///      the delegatee untouched for 200 buckets so the cleanup is the
    ///      expensive part of the call. Same oracle as D11.
    function test_F23_D11b_proxiedDormantForfeitCannotBeStarved() public {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(p));
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(admin);
        hemi.mint(admin, 1_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(1_000 ether, 4 * 365 days, victim, false, true);
        enable(victim, id);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "probe: flat term not booked at the delegatee");
        vm.warp(block.timestamp + 200 * SIX_DAYS); // the delegatee is not touched again
        veHemi.checkpoint(); // VeHemi's global curve stays fresh; only the module's walk is long
        assertLt(block.timestamp, veHemi.transferableAfter(id), "probe: forfeit window closed");
        uint256 nextHour = ((block.timestamp / 1 hours) + 1) * 1 hours;
        {
            uint256 snap = vm.snapshotState();
            uint256 g0 = gasleft();
            veHemi.forfeit(id);
            uint256 used = g0 - gasleft();
            emit log_named_uint("forfeit gas with a dormant delegatee", used);
            assertGt(used, 600_000, "probe: the dormant cleanup is not the expensive part of the call");
            vm.revertToState(snap);
        }

        uint256 committed;
        uint256 refused;
        uint256 outOfGas;
        for (uint256 g = 100_000; g <= 1_600_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(veHemi).call{gas: g}(abi.encodeWithSignature("forfeit(uint256)", id));
            if (ok) {
                ++committed;
                assertEq(veHemi.autoRelockRemaining(id), 0, "committed forfeit left the flag");
                assertEq(veHemi.balanceOfNFT(id), 0, "starved forfeit left weight");
                assertEq(veHemi.totalVeHemiSupply(), 0, "starved forfeit left supply");
                vm.warp(nextHour);
                assertEq(delegation.getVotes(dele), 0, "STARVED FORFEIT LEFT A PERMANENT FLAT PHANTOM (proxied)");
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
        assertGt(committed, 0, "no grid point committed -- the sweep checked nothing");
        assertGt(outOfGas, 0, "no grid point ran out of gas -- the sweep never starved the call");
    }
}

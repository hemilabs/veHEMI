// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// Retirement leaves no phantom votes.
// ----------------------------------------------------------------------------
// When a delegated position's weight steps DOWN -- forfeit, burn, disable, or a
// move to another delegatee -- the delegatee's votes must never exceed the
// escrow that is left, sampled every few seconds over the hours after the step
// and, for a forfeit, at twelve phases of the hour. A co-delegator's weight
// must not be shaved, sealed `getPastVotes` answers must not change, and the
// retirement must not be swallowed by `VeHemi._reDelegate`'s try/catch
// (`DelegationUpdateFailed`).
//
// The clock starts OFF an hourly boundary (+1380 s) so that a booking dated on
// the hourly grid is genuinely deferred.
// ============================================================================

import "./TwinOracle.sol";

contract RetirementNoPhantomVotesTest is TwinOracle {
    address internal constant ALICE    = address(0xA11CE);
    address internal constant CAROL    = address(0xCA401);   // the delegatee
    address internal constant VICTIM   = address(0x71C711);  // a SECOND delegator to CAROL
    address internal constant ADMIN    = address(0xAD1);

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;

    event DelegationUpdateFailed(uint256 indexed tokenId);

    function setUp() public {
        setUpTwinOracle();
        X.ve.updateForfeitAdmin(ADMIN);
        vm.warp(block.timestamp + 1380);
    }

    function _driveCandidate(uint256) internal override {}
    function _id(uint256 i) internal view returns (uint256) { return positions[i].tokenId; }

    function _mintForfeitable(address owner, uint256 amount, uint256 n)
        internal returns (uint256 id)
    {
        X.hemi.mint(owner, amount);
        vm.startPrank(owner);
        X.hemi.approve(address(X.ve), type(uint256).max);
        id = X.ve.createLockFor(amount, n * SIX_DAYS, owner, false, true);
        vm.stopPrank();
    }

    /// @dev worst (votes - escrow) over `win` seconds after now, sampled every 5 s.
    function _sweepPhantom(uint256 win) internal returns (uint256 worst) {
        uint256 t = block.timestamp;
        for (uint256 s = 1; s <= win; s += 5) {
            vm.warp(t + s);
            uint256 v = X.del.getVotes(CAROL);
            uint256 e = X.ve.totalVeHemiSupply();
            if (v > e && v - e > worst) worst = v - e;
        }
        vm.warp(t);
    }

    /// @dev worst (votes(CAROL) - escrow(id)) over two hours after now, every 5 s.
    function _sweepExcessOver(uint256 id) internal returns (uint256 worst) {
        uint256 t = block.timestamp;
        for (uint256 s = 1; s <= 7200; s += 5) {
            vm.warp(t + s);
            uint256 v = X.del.getVotes(CAROL);
            uint256 e = X.ve.balanceOfNFTAt(id, block.timestamp);
            if (v > e && v - e > worst) worst = v - e;
        }
    }

    // ====================================================================
    /// @notice A mid-life `forfeit()` takes the escrow to zero; no 5-second
    ///         sample of the next two hours may show votes above it, at twelve
    ///         phases of the hour.
    function test_forfeit_phantom_at_every_phase() public {
        uint256 worstAll;
        for (uint256 p; p < 12; ++p) {
            uint256 snap = vm.snapshotState();
            uint256 floorH = (block.timestamp / 1 hours) * 1 hours;
            vm.warp(floorH + 1 hours + p * 300);

            uint256 id = _mintForfeitable(ALICE, AMT, N);
            vm.prank(ALICE);
            X.del.delegate(id, CAROL);
            vm.warp(block.timestamp + 2 hours);
            vm.prank(ADMIN);
            X.ve.forfeit(id);

            uint256 w = _sweepPhantom(7200);
            if (w > worstAll) worstAll = w;
            vm.revertToState(snap);
        }
        assertEq(worstAll, 0, "PHANTOM: some phase of the hour leaks");
    }

    // ====================================================================
    /// @notice A top-up re-books the record in the same hour the token is
    ///         forfeited; the forfeit still leaves no phantom.
    function test_owner_rebook_then_forfeit() public {
        uint256 id = _mintForfeitable(ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + 2 hours);

        // `increaseAmount` is owner-only.
        X.hemi.mint(ALICE, 1 ether);
        vm.startPrank(ALICE);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(id, 1);
        vm.stopPrank();

        vm.prank(ADMIN);
        X.ve.forfeit(id);
        assertEq(X.ve.totalVeHemiSupply(), 0, "setup: escrow must be zero");

        assertEq(_sweepPhantom(7200), 0, "PHANTOM survives a 1-wei re-book");
    }

    // ====================================================================
    /// @notice NO VICTIM MAY BE SHAVED. VICTIM delegates to the same delegatee;
    ///         after ALICE's forfeit settles, CAROL carries exactly VICTIM's
    ///         escrow.
    function test_victim_weight_is_not_destroyed() public {
        uint256 vid = _mintForfeitable(VICTIM, AMT, N);
        vm.prank(VICTIM);
        X.del.delegate(vid, CAROL);

        uint256 id = _mintForfeitable(ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(ADMIN);
        X.ve.forfeit(id);
        vm.warp(block.timestamp + 1 hours);

        assertEq(X.del.getVotes(CAROL), X.ve.balanceOfNFT(vid), "VICTIM SHAVED: an innocent co-delegator lost weight");
    }

    // ====================================================================
    /// @notice SEALED HISTORY IS IMMUTABLE. Twelve `getPastVotes` answers are
    ///         read before the forfeit and re-read after it. Not one may change.
    function test_sealed_history_is_immutable() public {
        uint256 id = _mintForfeitable(ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);

        uint256[12] memory ts;
        uint256[12] memory sealedV;
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + 17 minutes);
            ts[i] = block.timestamp - 1;
            sealedV[i] = X.del.getPastVotes(CAROL, ts[i]);
        }
        vm.prank(ADMIN);
        X.ve.forfeit(id);
        vm.warp(block.timestamp + 3 hours);

        for (uint256 i; i < 12; ++i) {
            assertEq(X.del.getPastVotes(CAROL, ts[i]), sealedV[i], "SEALED HISTORY MUTATED");
        }
    }

    // ====================================================================
    /// @notice NO SWALLOWED FAILURE. `VeHemi._reDelegate` catches a failing
    ///         delegation call and emits `DelegationUpdateFailed` instead of
    ///         reverting, so the forfeit's retirement must never emit it.
    function test_no_swallowed_delegation_failure() public {
        uint256 id = _mintForfeitable(ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + 2 hours);

        vm.recordLogs();
        vm.prank(ADMIN);
        X.ve.forfeit(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != DelegationUpdateFailed.selector, "SWALLOWED: DelegationUpdateFailed on forfeit");
        }
    }

    // ====================================================================
    /// @notice THE OTHER RETIREMENT PATH. `withdraw` burns the position after
    ///         the term ends; no phantom may survive there either.
    function test_withdraw_burn_leaves_no_phantom() public {
        uint256 id = _mintForfeitable(ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + N * SIX_DAYS + 1 hours);

        vm.prank(ALICE);
        X.ve.withdraw(id);
        assertEq(X.ve.totalVeHemiSupply(), 0, "setup: escrow must be zero");

        assertEq(_sweepPhantom(7200), 0, "PHANTOM: votes above escrow after a burn");
    }

    // ====================================================================
    /// @notice `disableAutoRelock` steps the weight from the flat level to the
    ///         decaying curve. Over the next two hours the delegatee's votes
    ///         must never exceed the position's own escrow weight.
    function test_disable_never_pays_above_escrow() public {
        uint256 id = _id(spawn(true, ALICE, AMT, N, Cadence.NEVER, false, false));
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(id);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(ALICE);
        X.ve.disableAutoRelock(id);

        assertEq(_sweepExcessOver(id), 0, "votes above escrow after disable");
    }

    // ====================================================================
    /// @notice A 1-wei top-up in the SAME hour as the disable re-books the
    ///         record ahead of the disable. The disable must neither be
    ///         swallowed nor leave the delegatee above the escrow.
    function test_owner_dust_then_disable() public {
        uint256 id = _id(spawn(true, ALICE, AMT, N, Cadence.NEVER, false, false));
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.prank(ALICE);
        X.ve.enableAutoRelock(id);
        vm.warp(block.timestamp + 2 hours);

        // `increaseAmount` is owner-only.
        X.hemi.mint(ALICE, 1);
        vm.startPrank(ALICE);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(id, 1);
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(ALICE);
        X.ve.disableAutoRelock(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k; k < logs.length; ++k) {
            assertTrue(
                logs[k].topics[0] != DelegationUpdateFailed.selector,
                "SWALLOWED: DelegationUpdateFailed on the disable path"
            );
        }

        assertEq(_sweepExcessOver(id), 0, "votes above escrow after dust + disable");
    }

    // ====================================================================
    /// @notice NO THIRD-PARTY DESTRUCTION. A co-delegator runs 50 same-hour
    ///         enable/disable round trips; the delegatee's votes stay between
    ///         the victim's own escrow and the pair's escrow.
    function test_roundtrips_do_not_destroy_a_third_party() public {
        uint256 vid = _id(spawn(true, VICTIM, AMT, N, Cadence.NEVER, false, false));
        vm.prank(VICTIM);
        X.del.delegate(vid, CAROL);
        vm.warp(block.timestamp + 3 hours);

        uint256 aid = _id(spawn(true, ALICE, AMT / 4, N, Cadence.NEVER, false, false));
        vm.prank(ALICE);
        X.del.delegate(aid, CAROL);
        vm.warp(block.timestamp + 2 hours);

        uint256 victimAlone = X.ve.balanceOfNFTAt(vid, block.timestamp);
        uint256 attackerAlone = X.ve.balanceOfNFTAt(aid, block.timestamp);
        assertEq(X.del.getVotes(CAROL), victimAlone + attackerAlone, "setup");

        for (uint256 r; r < 50; ++r) {
            vm.prank(ALICE);
            X.ve.enableAutoRelock(aid);
            vm.prank(ALICE);
            X.ve.disableAutoRelock(aid);
            vm.warp(block.timestamp + 1 hours + 17);
        }

        uint256 v = X.del.getVotes(CAROL);
        uint256 vAlone = X.ve.balanceOfNFTAt(vid, block.timestamp);
        uint256 aAlone = X.ve.balanceOfNFTAt(aid, block.timestamp);
        assertGe(v, vAlone, "VICTIM DESTROYED: votes fell below the victim's own escrow");
        assertLe(v, vAlone + aAlone, "INFLATION: votes above the pair's escrow");
    }

    // ====================================================================
    /// @notice THE CHECKPOINT HISTORY IS ORDERED AND IMMUTABLE.
    ///         (a) `delegateCheckpoints` timestamps stay STRICTLY INCREASING;
    ///         (b) every `getPastVotes(a, t)` sampled after the last write of
    ///             its block reads back the same value three days later.
    ///         The stress mixes same-second, intra-hour and cross-hour writes so
    ///         that several checkpoints share one hourly epoch.
    function test_history_is_ordered_and_immutable() public {
        uint256 a = _id(spawn(true, ALICE, AMT, N, Cadence.NEVER, false, false));
        uint256 b = _id(spawn(true, VICTIM, AMT / 3, N, Cadence.NEVER, false, false));
        vm.prank(ALICE);  X.del.delegate(a, CAROL);
        vm.prank(VICTIM); X.del.delegate(b, CAROL);

        uint256[] memory ts = new uint256[](60);
        uint256[] memory vv = new uint256[](60);
        uint256 k;

        for (uint256 r; r < 40; ++r) {
            // 1 s, 37 s and 1 h 41 s gaps; enable + disable inside ONE block
            // also exercises the same-second overwrite path.
            vm.warp(block.timestamp + (r % 3 == 0 ? 1 : (r % 3 == 1 ? 37 : 1 hours + 41)));
            vm.prank(ALICE);
            X.ve.enableAutoRelock(a);
            vm.prank(ALICE);
            X.ve.disableAutoRelock(a);
            if (r % 2 == 0) { vm.prank(VICTIM); X.del.delegate(b, CAROL); }
            // Sampled AFTER every write in this block, so the reading is final
            // for this timestamp.
            ts[k] = block.timestamp; vv[k] = X.del.getVotes(CAROL); ++k;
        }

        // (a) strictly increasing
        uint256 prev;
        uint256 n;
        while (true) {
            try X.del.delegateCheckpoints(CAROL, n) returns (
                uint128, uint128, uint128, uint64, uint64 cts
            ) {
                if (n > 0) assertGt(uint256(cts), prev, "checkpoints not strictly increasing");
                prev = uint256(cts);
                ++n;
            } catch { break; }
        }
        assertGt(n, 4, "stress produced no history");

        // (b) immutability, re-queried from far in the future
        vm.warp(block.timestamp + 3 days);
        for (uint256 i; i < k; ++i) {
            assertEq(X.del.getPastVotes(CAROL, ts[i]), vv[i], "getPastVotes retroactively mutated");
        }
    }

    // ====================================================================
    /// @notice `delegationBookedAt` is `block.timestamp + 1` right after a
    ///         delegate, and is cleared on the forfeit path.
    function test_bookedAt_is_maintained() public {
        uint256 id = _mintForfeitable(ALICE, AMT, N);
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        assertEq(uint256(X.del.delegationBookedAt(id)), block.timestamp + 1, "bookedAt != block.timestamp + 1");

        vm.warp(block.timestamp + 2 hours);
        vm.prank(ADMIN);
        X.ve.forfeit(id);
        assertEq(uint256(X.del.delegationBookedAt(id)), 0, "bookedAt not cleared on forfeit");
    }

    // ====================================================================
    /// @notice A MOVE between two delegatees never leaves the pair carrying
    ///         more than the position's escrow, at any 5-second sample of the
    ///         next two hours.
    function test_move_between_delegatees_never_pays_above_escrow() public {
        uint256 id = _id(spawn(true, ALICE, AMT, N, Cadence.NEVER, false, false));
        vm.prank(ALICE);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(ALICE);
        X.del.delegate(id, VICTIM);   // VICTIM is just "the other delegatee" here

        uint256 t = block.timestamp;
        uint256 worstExcess;
        for (uint256 s = 1; s <= 7200; s += 5) {
            vm.warp(t + s);
            uint256 pair = X.del.getVotes(CAROL) + X.del.getVotes(VICTIM);
            uint256 e = X.ve.balanceOfNFTAt(id, block.timestamp);
            if (pair > e && pair - e > worstExcess) worstExcess = pair - e;
        }
        assertEq(worstExcess, 0, "INFLATION: the pair carries more than the escrow");
    }

    // ====================================================================
    /// @notice TWO FLAT TERMS ON ONE DELEGATEE, THEN A STEP. Two armed
    ///         positions are delegated to CAROL some time apart; the first one
    ///         then moves to another delegatee, is disabled, or is topped up by
    ///         its owner. At every gap tried, the step must succeed, must not
    ///         be swallowed (`DelegationUpdateFailed`), and the delegatees must
    ///         never carry more than the two positions' escrow (sampled every
    ///         300 s over the next hour).
    function test_two_flat_terms_then_move_disable_or_topup() public {
        address bob  = address(0xB0B);
        address dave = address(0xDA7E);
        uint256[3] memory gaps = [uint256(1 hours), SIX_DAYS + 1380, (N + 1) * SIX_DAYS + 1380];
        for (uint256 g; g < gaps.length; ++g) {
            for (uint256 v; v < 3; ++v) {
                uint256 snap = vm.snapshotState();
                uint256 a = _mintForfeitable(ALICE, AMT, N);
                vm.startPrank(ALICE);
                X.ve.enableAutoRelock(a);
                X.del.delegate(a, CAROL);
                vm.stopPrank();
                vm.warp(block.timestamp + gaps[g]);
                uint256 b = _mintForfeitable(bob, AMT, N);
                vm.startPrank(bob);
                X.ve.enableAutoRelock(b);
                X.del.delegate(b, CAROL);
                vm.stopPrank();
                vm.warp(block.timestamp + 1 hours);

                vm.recordLogs();
                if (v == 0) {
                    vm.prank(ALICE);
                    X.del.delegate(a, dave);
                } else if (v == 1) {
                    vm.prank(ALICE);
                    X.ve.disableAutoRelock(a);
                } else {
                    X.hemi.mint(ALICE, 1 ether);
                    vm.prank(ALICE);
                    X.ve.increaseAmount(a, 1 ether);
                }
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 k; k < logs.length; ++k) {
                    assertTrue(logs[k].topics[0] != DelegationUpdateFailed.selector, "SWALLOWED: DelegationUpdateFailed");
                }

                uint256 t = block.timestamp;
                for (uint256 s = 1; s <= 3600; s += 300) {
                    vm.warp(t + s);
                    uint256 votes = X.del.getVotes(CAROL) + X.del.getVotes(dave);
                    uint256 esc = X.ve.balanceOfNFTAt(a, block.timestamp) + X.ve.balanceOfNFTAt(b, block.timestamp);
                    assertGt(votes, 0, "the step zeroed the delegatees");
                    assertLe(votes, esc, "the delegatees carry more than the escrow");
                }
                vm.revertToState(snap);
            }
        }
    }
}

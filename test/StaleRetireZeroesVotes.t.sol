// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// The stale retire takes a THIRD-PARTY delegatee's votes and the
// quorum denominator to zero.
// ----------------------------------------------------------------------------
// The retire path must not lean on a revert: `VeHemi._reDelegate` swallows a
// failing delegation module on this leg (`strict_ = false`), so a module that
// reverts on the retire is visible only as events (`DelegationUpdateFailed`,
// then `AutoRelockRetirementUnverified` from the read-back) and a delegatee
// that keeps its votes. Every body here checks the votes directly.
// ============================================================================

import "./TwinOracle.sol";

contract StaleRetireZeroesVotesTest is TwinOracle {
    address internal constant BOB    = address(0xB0B);   // abandoned flat holder
    address internal constant CAROL  = address(0xCA401); // THIRD-PARTY delegatee
    address internal constant KEEPER = address(0xCAFE);  // a stranger

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 6;

    uint256 internal K;
    uint256 internal bi; // BOB's flat position (universe X)

    function setUp() public {
        setUpTwinOracle();
        K = X.ve.STALE_FLAT_BUCKETS();
        bi = spawn(true, BOB,  AMT, N,  Cadence.NEVER, false, false);
        // BOB delegates to a THIRD PARTY before going flat, then abandons.
        vm.prank(BOB);
        X.del.delegate(_id(bi), CAROL);
        vm.prank(BOB);
        X.ve.enableAutoRelock(_id(bi));
        assertEq(uint256(X.ve.autoRelockRemaining(_id(bi))), N * SIX_DAYS, "R != N buckets");
    }

    function _driveCandidate(uint256) internal override {}
    function _id(uint256 i) internal view returns (uint256) { return positions[i].tokenId; }

    function _toStale() internal {
        uint256 open = X.ve.autoRelockStaleAt(_id(bi));
        for (uint256 k = 1; k <= K; ++k) { vm.warp(t0 + k * SIX_DAYS); vm.roll(block.number + 43_830); }
        assertEq(block.timestamp, open, "clock did not land on staleAt");
    }

    // ===================================================================
    /// @notice THE RETIRE IS NOT SWALLOWED, AND THE DELEGATEE'S VOTES FOLLOW
    ///         THE ESCROW FROM THE NEXT SECOND.
    ///           (a) no `DelegationUpdateFailed` is emitted;
    ///           (b) at the retire instant the escrow is the restored decaying
    ///               weight `slope * N * SIX_DAYS` (end = grid(now) + N buckets)
    ///               while the delegatee still reads the bucket-mean flat level:
    ///               the re-booking is dated `block.timestamp + 1`, so nothing
    ///               moves in the same second;
    ///           (c) from `t + 1` on, every second for two hours, the
    ///               delegatee's live votes equal the position's escrow weight.
    function test_retire_moves_the_delegatee_votes_to_the_escrow() public {
        _toStale();
        uint256 flat = X.ve.balanceOfNFT(_id(bi));
        assertEq(flat, meanLevelOf(AMT, N), "not flat at the bucket-mean level");
        assertEq(X.del.getVotes(CAROL), flat, "delegatee is not carrying the flat level");

        // (a) the forced re-delegation must NOT be swallowed.
        vm.recordLogs();
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(bi));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("DelegationUpdateFailed(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "retire hit the try/catch swallow");
        }

        // (b) the retire instant.
        uint256 t = block.timestamp;
        assertEq(X.ve.getLockedBalance(_id(bi)).end, t + N * SIX_DAYS, "restored end != grid(now) + N buckets");
        assertEq(X.ve.balanceOfNFT(_id(bi)), peakOf(AMT, N), "escrow != the restored decaying weight");
        assertEq(X.del.getVotes(CAROL), flat, "delegatee votes moved in the retire's own second");

        // (c) every second of the next two hours.
        for (uint256 s = 1; s <= 7200; ++s) {
            vm.warp(t + s);
            assertEq(X.del.getVotes(CAROL), X.ve.balanceOfNFT(_id(bi)), "delegatee votes != escrow after the retire");
        }
    }

    // ===================================================================
    /// @notice VOTES TO ZERO, AND THEY STAY THERE. Uses universe M, which
    ///         holds this one retired position alone.
    function test_votes_and_supply_reach_exact_zero_and_stay() public {
        // universe M is empty; give it the same abandoned flat position.
        uint256 mi = spawn(false, BOB, AMT, N, Cadence.NEVER, false, false);
        vm.prank(BOB);
        M.del.delegate(_id(mi), CAROL);
        vm.prank(BOB);
        M.ve.enableAutoRelock(_id(mi));
        uint256 open = M.ve.autoRelockStaleAt(_id(mi));
        for (uint256 k = 1; k <= K; ++k) { vm.warp(t0 + k * SIX_DAYS); vm.roll(block.number + 43_830); }
        assertEq(block.timestamp, open, "clock");

        assertEq(M.del.getVotes(CAROL), meanLevelOf(AMT, N), "pre-retire votes");
        assertEq(M.ve.totalVeHemiSupply(), meanLevelOf(AMT, N), "pre-retire supply");

        vm.prank(KEEPER);
        M.ve.retireStaleAutoRelock(_id(mi));

        uint256 zeroAt;
        for (uint256 k = 1; k <= N + 4; ++k) {
            vm.warp(open + k * SIX_DAYS);
            vm.roll(block.number + 43_830);
            if (zeroAt == 0 && M.ve.totalVeHemiSupply() == 0) zeroAt = k;
        }
        assertEq(zeroAt, N, "supply did not die N buckets after the retire");

        // the three governance reads, now and for a long time afterwards
        assertEq(M.del.getVotes(CAROL), 0, "getVotes != 0");
        assertEq(M.ve.totalVeHemiSupply(), 0, "totalVeHemiSupply != 0");
        assertEq(M.del.getPastTotalSupply(block.timestamp), 0, "getPastTotalSupply != 0");
        for (uint256 k = 1; k <= 60; ++k) {
            vm.warp(open + (N + k) * SIX_DAYS);
            vm.roll(block.number + 43_830);
            assertEq(M.del.getVotes(CAROL), 0, "votes came back");
            assertEq(M.del.getPastTotalSupply(block.timestamp), 0, "denominator came back");
            assertEq(M.ve.totalVeHemiSupply(), 0, "supply came back");
        }
        // and every historical instant AFTER the serve-out reads zero too. k
        // starts at 1: `getPastTotalSupply(T)` / `getPastVotes(_, T)` read the
        // state at T - 1, and at T = the restored end that is the position's
        // last live second (one second of slope).
        for (uint256 k = 1; k <= 60; ++k) {
            uint256 ts = open + (N + k) * SIX_DAYS;
            assertEq(M.del.getPastVotes(CAROL, ts), 0, "getPastVotes came back");
            assertEq(M.del.getPastTotalSupply(ts), 0, "past denominator came back");
        }
    }

    // ===================================================================
    /// @notice NO ARITHMETIC PANIC ON ANY RETIRE PATH. The swallow at
    ///         `_reDelegate` means a panic INSIDE the delegation module would
    ///         not surface as a revert. Drive the retire in eight distinct
    ///         phases and assert (i) no revert and (ii) no swallow, on every one.
    function test_no_panic_and_no_swallow_on_any_retire_phase() public {
        bytes32 sig = keccak256("DelegationUpdateFailed(uint256)");
        uint256 done;
        for (uint256 phase; phase < 8; ++phase) {
            uint256 snap = vm.snapshotState();
            _toStale();
            // phase controls WHEN, past staleness, the retire happens and how
            // stale the global head is when it does.
            if (phase >= 1) { vm.warp(block.timestamp + 1); vm.roll(block.number + 1); }
            if (phase >= 2) { vm.warp(block.timestamp + 3600); vm.roll(block.number + 1); }
            if (phase >= 3) { vm.warp(block.timestamp + SIX_DAYS - 1); vm.roll(block.number + 1); }
            if (phase >= 4) { vm.warp(block.timestamp + 30 * SIX_DAYS); vm.roll(block.number + 1); }
            if (phase >= 5) { vm.warp(block.timestamp + 100 * SIX_DAYS); vm.roll(block.number + 1); }
            if (phase == 6) { X.ve.checkpoint(); }                       // warm head
            if (phase == 7) { vm.prank(BOB); X.del.delegate(_id(bi), BOB); } // self-delegated

            vm.recordLogs();
            vm.prank(KEEPER);
            try X.ve.retireStaleAutoRelock(_id(bi)) {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 i; i < logs.length; ++i) {
                    assertTrue(logs[i].topics[0] != sig,
                        string.concat("SWALLOW on phase ", vm.toString(phase)));
                }
                assertEq(uint256(X.ve.autoRelockRemaining(_id(bi))), 0,
                    string.concat("flag survived phase ", vm.toString(phase)));
                assertEq(uint256(X.ve.autoRelockRefreshedAt(_id(bi))), 0,
                    string.concat("stamp survived phase ", vm.toString(phase)));
                ++done;
            } catch (bytes memory err) {
                emit log_named_uint("PHASE", phase);
                emit log_named_bytes("REVERT DATA", err);
                fail();
            }
            vm.revertToState(snap);
        }
        assertEq(done, 8, "not every phase retired");
    }

    // ===================================================================
    /// @notice A TOP-UP MOVES NEITHER THE CLOCK NOR THE VOTES ABOVE ESCROW.
    ///         `increaseAmount` (owner-only) re-materialises the lazy end but
    ///         must not stamp, and a 10-HEMI top-up must not leave the
    ///         delegatee above the escrow once the deferral hour passes.
    function test_topup_moves_neither_clock_nor_votes_above_escrow() public {
        uint256 open = X.ve.autoRelockStaleAt(_id(bi));
        vm.warp(t0 + (K / 2) * SIX_DAYS);
        vm.roll(block.number + 43_830);
        address _oz = X.ve.ownerOf(_id(bi));
        X.hemi.mint(_oz, 10 ether);
        vm.startPrank(_oz);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(_id(bi), 10 ether);
        vm.stopPrank();
        assertEq(X.ve.autoRelockStaleAt(_id(bi)), open, "top-up moved the abandonment clock");
        // and the delegatee is not above escrow once the deferral hour passes
        vm.warp(block.timestamp + 3600);
        vm.roll(block.number + 1);
        assertLe(X.del.getVotes(CAROL), X.ve.balanceOfNFT(_id(bi)), "top-up left the delegatee above escrow");
        // the retire still opens on time
        for (uint256 k = K / 2 + 1; k <= K; ++k) { vm.warp(t0 + k * SIX_DAYS); vm.roll(block.number + 43_830); }
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(_id(bi));
        assertEq(uint256(X.ve.autoRelockRemaining(_id(bi))), 0, "retire did not open on time");
    }

    // ===================================================================
    /// @notice THE STAMP'S WHOLE LIFECYCLE: written at enable, rewritten by
    ///         the heartbeat, deleted at disable, deleted at retire, deleted
    ///         with the token.
    function test_stamp_lifecycle() public {
        uint256 id = _id(bi);
        assertEq(uint256(X.ve.autoRelockRefreshedAt(id)), t0, "not stamped at enable");
        vm.warp(t0 + 3 * SIX_DAYS); vm.roll(block.number + 1);
        vm.prank(BOB); X.ve.refreshAutoRelock(id);
        assertEq(uint256(X.ve.autoRelockRefreshedAt(id)), block.timestamp, "heartbeat did not stamp");
        // a stranger cannot
        vm.prank(KEEPER); vm.expectRevert(VeHemi.NotOwner.selector); X.ve.refreshAutoRelock(id);
        // disable clears it
        vm.prank(BOB); X.ve.disableAutoRelock(id);
        assertEq(uint256(X.ve.autoRelockRefreshedAt(id)), 0, "stamp survived disable");
        // re-enable, retire, cleared again
        vm.prank(BOB); X.ve.enableAutoRelock(id);
        uint256 open = X.ve.autoRelockStaleAt(id);
        vm.warp(open); vm.roll(block.number + 1);
        vm.prank(KEEPER); X.ve.retireStaleAutoRelock(id);
        assertEq(uint256(X.ve.autoRelockRefreshedAt(id)), 0, "stamp survived retire");
        // burn clears it
        vm.prank(BOB); X.ve.enableAutoRelock(id);
        assertGt(uint256(X.ve.autoRelockRefreshedAt(id)), 0, "stamp not re-set");
        vm.prank(BOB); X.ve.disableAutoRelock(id);
        uint256 end = X.ve.getLockedBalance(id).end;
        vm.warp(end); vm.roll(block.number + 1);
        vm.prank(BOB); X.ve.withdraw(id);
        assertEq(uint256(X.ve.autoRelockRefreshedAt(id)), 0, "stamp survived the burn");
    }

    // ===================================================================
    /// @notice THE STAMP REALLY LIVES AT SLOT 65, AT RUNTIME. After a real
    ///         enable (in `setUp`) and a real refresh, this body reads the raw
    ///         word at `keccak256(id . 65)` back off the proxy. It pins VeHemi's
    ///         own compiled layout (no library touches `autoRelockRefreshedAt`).
    ///         Until the onchain anchor is re-based on the v3 implementation, no
    ///         frozen fixture covers V3: this test and the hardcoded V3 pins in
    ///         `StorageLayoutGolden.t.sol` and `StorageLayoutOnchainAnchor.t.sol`
    ///         are the machine guards against deleting or reordering a V3
    ///         declaration after go-live. That moves the live heartbeat off slot
    ///         65: every armed id would read a heartbeat of 0 (or another
    ///         field's word) and could be retired at once. Once v3 is live,
    ///         never "fix" this test by changing 65.
    function test_the_stamp_is_written_at_slot_65_at_runtime() public {
        uint256 id = _id(bi);
        bytes32 slot = keccak256(abi.encode(id, uint256(65)));
        assertEq(uint256(vm.load(address(X.ve), slot)), t0, "slot 65 does not carry the enable stamp");
        assertEq(uint256(vm.load(address(X.ve), slot)), uint256(X.ve.autoRelockRefreshedAt(id)),
            "the accessor and slot 65 disagree");

        vm.warp(t0 + 4 * SIX_DAYS); vm.roll(block.number + 1);
        vm.prank(BOB);
        X.ve.refreshAutoRelock(id);
        assertEq(uint256(vm.load(address(X.ve), slot)), block.timestamp, "the heartbeat did not land on slot 65");

        // slot 65 ITSELF (the mapping base) must stay zero -- a mapping stores
        // nothing there.
        assertEq(uint256(vm.load(address(X.ve), bytes32(uint256(65)))), 0, "mapping base 65 is not zero");

        // and the retire clears the word, not just the accessor
        uint256 open = X.ve.autoRelockStaleAt(id);
        vm.warp(open); vm.roll(block.number + 1);
        vm.prank(KEEPER);
        X.ve.retireStaleAutoRelock(id);
        assertEq(uint256(vm.load(address(X.ve), slot)), 0, "slot 65 still carries a stamp after the retire");
    }
}

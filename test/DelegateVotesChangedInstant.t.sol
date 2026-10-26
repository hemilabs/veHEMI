// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @dev Minimal conforming adapter: records the LAST relayed tuple per
///      delegatee.
contract LastRelayRecordingAdapter {
    mapping(address => uint256) public lastPreviousVotes;
    mapping(address => uint256) public lastNewVotes;
    mapping(address => bool)    public relayed;

    function notifyVotesChanged(address delegatee, uint256 previousVotes, uint256 newVotes) external {
        lastPreviousVotes[delegatee] = previousVotes;
        lastNewVotes[delegatee] = newVotes;
        relayed[delegatee] = true;
    }
    function notifyDelegateChanged(address, address, address) external {}
}

/// `DelegateVotesChanged` reports the instant the checkpoint takes
/// effect.
///
/// Both `_delegate` legs are dated `block.timestamp + 1`, so the event (and
/// the adapter relay) must carry the delegatee's votes at that instant, not
/// at the next hour boundary: a boundary reading would be the weight decayed
/// forward by up to 3,599 s.
///
/// Every assertion pins an EXPLICIT value read back off the vote surface
/// (`getPastVotes` / `getVotes`) at the effective instant. No body asserts a
/// tautology and no body can pass by reverting -- E5 additionally pins that
/// the expected value is NON-ZERO and DIFFERENT from the boundary reading, so
/// a world where both collapse to 0 cannot score green.
contract DelegateVotesChangedInstantTest is LockedCurveTestBase {
    address internal constant DEL_A = address(0xA1);
    address internal constant DEL_B = address(0xB2);

    // E1 carries more live values than this compiler configuration has stack
    // slots for (via_ir is false and MUST stay false -- it is what Hardhat
    // deploys, so the test tree must build the same way the src tree does).
    // The scratch values live in storage instead.
    uint256 internal moveAt; uint256 internal counterfactualA; uint256 internal counterfactualB;
    uint256 internal effectiveA; uint256 internal effectiveB; uint256 internal boundaryB;

    bytes32 internal constant TOPIC_DELEGATE_VOTES_CHANGED =
        keccak256("DelegateVotesChanged(address,uint256,uint256)");

    function _nextHourBoundary(uint256 t) internal pure returns (uint256) {
        return (t / 1 hours) * 1 hours + 1 hours;
    }

    /// @dev LAST `DelegateVotesChanged` for `who` in the recorded batch.
    function _lastEvent(Vm.Log[] memory logs, address who)
        internal pure returns (bool found, uint256 previousVotes, uint256 newVotes)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == TOPIC_DELEGATE_VOTES_CHANGED
                && logs[i].topics[1] == bytes32(uint256(uint160(who)))) {
                (previousVotes, newVotes) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
            }
        }
    }

    function _mkLock(address who, uint256 amt, uint256 dur) internal returns (uint256 id) {
        hemi.mint(who, amt);
        vm.prank(who); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(who); id = veHemi.createLock(amt, dur);
    }

    /// @dev `getVotes(who)` read at `t`, with the clock restored afterwards.
    function _votesAt(address who, uint256 t) internal returns (uint256 v) {
        uint256 back = block.timestamp;
        vm.warp(t);
        v = delegation.getVotes(who);
        vm.warp(back);
    }

    // ── E1 ────────────────────────────────────────────────────────────────
    // BOTH LEGS AT ONCE. A decaying position moves DEL_A -> DEL_B mid-hour.
    // The retirement leg emits for DEL_A, the addition leg for DEL_B. Both
    // `newVotes` must equal the vote surface at `t+1`, the instant the write
    // takes effect -- and both `previousVotes` must equal the COUNTERFACTUAL
    // reading at that same instant (read off the vote surface before the
    // move, so it is a real reading and not an algebraic restatement of
    // `newVotes`).
    function test_E1_bothLegsAtEffectiveInstant() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mkLock(alice, 100 ether, 2 * 365 days);
        // A SECOND delegator stays on DEL_A across the move, so the
        // retirement leg's post-write value is NON-ZERO and still decaying --
        // otherwise DEL_A collapses to 0 in every world and that leg's
        // assertion would be vacuous.
        uint256 stayingId = _mkLock(bob, 100 ether, 2 * 365 days);

        // Seed DEL_A, then move to DEL_B 1,200 s into a later hour so the
        // boundary is 2,399 s away and the two readings differ.
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 1200);
        vm.prank(bob);   delegation.delegate(stayingId, DEL_A);
        vm.prank(alice); delegation.delegate(id, DEL_A);

        vm.warp(((block.timestamp + 7 days) / 1 hours) * 1 hours + 1200);
        moveAt = block.timestamp;
        assertEq(moveAt % 1 hours, 1200, "E1 premise: the move is 1,200 s into the hour");

        // Counterfactual readings at the effective instant, taken BEFORE the
        // move: real readings off the vote surface (`getVotes` at `moveAt + 1`),
        // not an algebraic restatement of `newVotes`. `_votesAt` only warps --
        // it writes no state -- so no snapshot is needed (and one would be
        // wrong: `vm.revertToState` also rolls back this contract's storage).
        counterfactualA = _votesAt(DEL_A, moveAt + 1);
        counterfactualB = _votesAt(DEL_B, moveAt + 1);
        assertEq(block.timestamp, moveAt, "E1: the clock must be back at the move instant");
        assertGt(counterfactualA, 0, "E1: DEL_A must carry weight before the move");
        assertEq(counterfactualB, 0, "E1: DEL_B must be empty before the move");

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, DEL_B);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool foundA, uint256 previousVotesA, uint256 newVotesA) = _lastEvent(logs, DEL_A);
        (bool foundB, uint256 previousVotesB, uint256 newVotesB) = _lastEvent(logs, DEL_B);
        assertTrue(foundA, "E1: no DelegateVotesChanged for the OLD delegatee");
        assertTrue(foundB, "E1: no DelegateVotesChanged for the NEW delegatee");

        effectiveA = _votesAt(DEL_A, moveAt + 1);
        effectiveB = _votesAt(DEL_B, moveAt + 1);
        boundaryB = _votesAt(DEL_B, _nextHourBoundary(moveAt));

        emit log_named_uint("E1 RETIRE  emitted newVotes    ", newVotesA);
        emit log_named_uint("E1 RETIRE  getVotes at t+1     ", effectiveA);
        emit log_named_uint("E1 ADD     emitted newVotes    ", newVotesB);
        emit log_named_uint("E1 ADD     getVotes at t+1     ", effectiveB);
        emit log_named_uint("E1 ADD     getVotes at boundary", boundaryB);
        emit log_named_uint("E1 ADD     boundary gap (wei)  ",
            effectiveB > boundaryB ? effectiveB - boundaryB : boundaryB - effectiveB);

        // The construction must actually separate the two instants, or this
        // body could pass against an implementation that reports the
        // boundary reading; and the retirement leg must land on a NON-ZERO
        // value or its assertion is vacuous.
        assertTrue(effectiveB != boundaryB, "E1 premise: boundary and t+1 must differ");
        assertGt(effectiveA, 0, "E1 premise: the RETIREMENT leg must leave weight behind");
        assertTrue(effectiveA != _votesAt(DEL_A, _nextHourBoundary(moveAt)),
            "E1 premise: the RETIREMENT leg's two instants must differ");

        assertEq(newVotesA, effectiveA, "E1: RETIREMENT leg newVotes != getVotes at the effective instant");
        assertEq(newVotesB, effectiveB, "E1: ADDITION leg newVotes != getVotes at the effective instant");
        assertEq(previousVotesA, counterfactualA,
            "E1: RETIREMENT leg previousVotes != counterfactual at the effective instant");
        assertEq(previousVotesB, counterfactualB,
            "E1: ADDITION leg previousVotes != counterfactual at the effective instant");
        // The pair must describe the SAME instant: the reported delta is the
        // delta actually booked.
        assertEq(counterfactualA - effectiveA, newVotesB - previousVotesB,
            "E1: the two legs do not conserve weight at t+1");
    }

    // ── E2 ────────────────────────────────────────────────────────────────
    // THE FLAT (auto-relock) PATH. A flat delegator's weight rides in
    // `fixedBias`, which does not decay, so the boundary and `t+1` readings
    // of the FLAT term agree. Pin the leg anyway on a delegatee that ALSO
    // carries a decaying term, so the aggregate the event reports does move.
    function test_E2_flatAggregateAtEffectiveInstant() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 decaying = _mkLock(bob, 100 ether, 2 * 365 days);
        uint256 flat     = _mkLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice); veHemi.enableAutoRelock(flat);
        assertGt(veHemi.autoRelockRemaining(flat), 0, "E2 premise: the position is flat");

        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 60);
        vm.prank(bob); delegation.delegate(decaying, DEL_A);

        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 60);
        uint256 T = block.timestamp;

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(flat, DEL_A);
        (bool found, , uint256 newVotesA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
        assertTrue(found, "E2: no event");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, _nextHourBoundary(T));
        emit log_named_uint("E2 emitted newVotes        ", newVotesA);
        emit log_named_uint("E2 getVotes at t+1         ", eff);
        emit log_named_uint("E2 getVotes at boundary    ", bnd);
        assertTrue(eff != bnd, "E2 premise: boundary and t+1 must differ");
        assertEq(newVotesA, eff, "E2: FLAT-path newVotes != getVotes at the effective instant");
    }

    // ── E3 ────────────────────────────────────────────────────────────────
    // THE ADAPTER RELAY. `IAdapterNotify.notifyVotesChanged` is the number the
    // Aragon subgraph indexes. It must carry the SAME values as the event.
    // (Event order is pinned by AdapterCallbackOrder.)
    function test_E3_adapterRelayCarriesTheEffectiveInstantNumber() public {
        LastRelayRecordingAdapter adapter = new LastRelayRecordingAdapter();
        delegation.setTrustedAdapter(address(adapter));

        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mkLock(alice, 100 ether, 2 * 365 days);
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 900);
        uint256 T = block.timestamp;

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, DEL_A);
        (bool found, , uint256 newVotesA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
        assertTrue(found, "E3: no in-contract event");
        assertTrue(adapter.relayed(DEL_A), "E3: adapter relay never fired");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, _nextHourBoundary(T));
        assertTrue(eff != bnd, "E3 premise: boundary and t+1 must differ");
        assertEq(adapter.lastNewVotes(DEL_A), newVotesA, "E3: relayed newVotes != in-contract newVotes");
        assertEq(adapter.lastNewVotes(DEL_A), eff, "E3: RELAYED newVotes != getVotes at the effective instant");
    }

    // ── E4 ────────────────────────────────────────────────────────────────
    // THE WHOLE HOUR. Sweeps 20 phases of the hour (1 s, every 189 s, and
    // 3,599 s) and asserts the worst gap between the emitted number and the
    // vote surface at the effective instant is ZERO.
    function test_E4_gapIsZeroAcrossTheHour() public {
        uint256 worst;
        uint256 worstPhase;
        uint256 nonZeroBoundaryGaps;
        for (uint256 k = 0; k < 20; ++k) {
            uint256 phase = k == 19 ? 3599 : (k == 0 ? 1 : k * 189);
            uint256 snap = vm.snapshotState();

            vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
            uint256 id = _mkLock(alice, 100 ether, 2 * 365 days);
            vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + phase);
            uint256 T = block.timestamp;

            vm.recordLogs();
            vm.prank(alice); delegation.delegate(id, DEL_A);
            (bool found, , uint256 newVotesA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
            assertTrue(found, "E4: no event");

            uint256 eff = _votesAt(DEL_A, T + 1);
            uint256 bnd = _votesAt(DEL_A, _nextHourBoundary(T));
            if (eff != bnd) ++nonZeroBoundaryGaps;
            uint256 g = newVotesA > eff ? newVotesA - eff : eff - newVotesA;
            if (g > worst) { worst = g; worstPhase = phase; }

            vm.revertToState(snap);
        }
        emit log_named_uint("E4 phases swept                ", 20);
        emit log_named_uint("E4 phases where boundary != t+1", nonZeroBoundaryGaps);
        emit log_named_uint("E4 WORST |emitted - effective| ", worst);
        emit log_named_uint("E4 worst phase (s into hour)   ", worstPhase);
        // 19 of 20 phases must be discriminating (phase 3599 collapses the two
        // instants by construction), so a green here is not vacuous.
        assertGe(nonZeroBoundaryGaps, 19, "E4 premise: the sweep is not discriminating");
        assertEq(worst, 0, "E4: emitted newVotes deviates from the vote surface at the effective instant");
    }

    // ── E5 ────────────────────────────────────────────────────────────────
    // THE WORST RATIO, CHECKED BOTH WAYS. A lock ending just past the boundary
    // makes the boundary reading a tiny fraction of the real weight. Checks that
    // the emitted number equals the LARGE (true) value AND is strictly greater
    // than the boundary value -- so neither a zeroed world nor a boundary-read
    // world can score green.
    function test_E5_lockEndingPastTheBoundary_emitsTheEffectiveValueAboveTheBoundaryReading() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id; uint256 E;
        for (uint256 j = 20; j < 40; ++j) {
            uint256 snap = vm.snapshotState();
            uint256 trialId = _mkLock(charlie, 1000 ether, j * SIX_DAYS);
            uint256 trialEnd = veHemi.getLockedBalance(trialId).end;
            vm.revertToState(snap);
            if (trialEnd % 1 hours == 360) {
                id = _mkLock(charlie, 1000 ether, j * SIX_DAYS);
                E = veHemi.getLockedBalance(id).end;
                break;
            }
        }
        require(E != 0, "E5: no duration with the wanted end offset");

        uint256 T = E - 3960;
        assertEq(_nextHourBoundary(T), E - 360, "E5 premise: the next hour boundary is 360 s before the end");
        vm.warp(T);

        vm.recordLogs();
        vm.prank(charlie); delegation.delegate(id, DEL_A);
        (bool found, , uint256 newVotesA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
        assertTrue(found, "E5: no event");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, E - 360);
        emit log_named_uint("E5 emitted newVotes      ", newVotesA);
        emit log_named_uint("E5 TRUE votes at t+1     ", eff);
        emit log_named_uint("E5 boundary votes        ", bnd);
        emit log_named_uint("E5 emitted as % of true  ", eff == 0 ? 0 : (newVotesA * 100) / eff);
        assertGt(eff, 0, "E5 premise: the true value must be non-zero");
        assertGt(eff, bnd * 3, "E5 premise: the boundary value must be a small fraction");
        assertEq(newVotesA, eff, "E5: emitted newVotes != the true weight at the effective instant");
        assertGt(newVotesA, bnd, "E5: emitted newVotes is not above the boundary reading");
    }
}

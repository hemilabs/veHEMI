// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @dev Minimal conforming adapter: records the LAST relayed tuple per
///      delegatee.
contract O06MockAdapter {
    mapping(address => uint256) public lastPrev;
    mapping(address => uint256) public lastNew;
    mapping(address => bool)    public seen;

    function notifyVotesChanged(address d, uint256 p, uint256 n) external {
        lastPrev[d] = p; lastNew[d] = n; seen[d] = true;
    }
    function notifyDelegateChanged(address, address, address) external {}
}

/// O06 -- `DelegateVotesChanged` reports the instant the checkpoint takes
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
contract O06EventTest is LockedCurveTestBase {
    address internal constant DEL_A = address(0xA1);
    address internal constant DEL_B = address(0xB2);

    // E1 carries more live values than this compiler configuration has stack
    // slots for (via_ir is false and MUST stay false -- it is what Hardhat
    // deploys, so the test tree must build the same way the src tree does).
    // The scratch values live in storage instead.
    uint256 internal sT; uint256 internal sCfA; uint256 internal sCfB;
    uint256 internal sEffA; uint256 internal sEffB; uint256 internal sBndB;

    bytes32 internal constant DVC = keccak256("DelegateVotesChanged(address,uint256,uint256)");

    function _boundary(uint256 t) internal pure returns (uint256) {
        return (t / 1 hours) * 1 hours + 1 hours;
    }

    /// @dev LAST `DelegateVotesChanged` for `who` in the recorded batch.
    function _lastEvent(Vm.Log[] memory logs, address who)
        internal pure returns (bool found, uint256 prev, uint256 nw)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == DVC
                && logs[i].topics[1] == bytes32(uint256(uint160(who)))) {
                (prev, nw) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
            }
        }
    }

    function _mkLock(address who, uint256 amt, uint256 dur) internal returns (uint256 id) {
        hemi.mint(who, amt);
        vm.prank(who); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(who); id = veHemi.createLock(amt, dur);
    }

    /// @dev `getPastVotes(who, t)` WITHOUT leaving the warp in place.
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
    function test_O06_E1_bothLegsAtEffectiveInstant() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mkLock(alice, 100 ether, 2 * 365 days);
        // A SECOND delegator stays on DEL_A across the move, so the
        // retirement leg's post-write value is NON-ZERO and still decaying --
        // otherwise DEL_A collapses to 0 in every world and that leg's
        // assertion would be vacuous.
        uint256 stay = _mkLock(bob, 100 ether, 2 * 365 days);

        // Seed DEL_A, then move to DEL_B 1,200 s into a later hour so the
        // boundary is 2,399 s away and the two readings differ.
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 1200);
        vm.prank(bob);   delegation.delegate(stay, DEL_A);
        vm.prank(alice); delegation.delegate(id, DEL_A);

        vm.warp(((block.timestamp + 7 days) / 1 hours) * 1 hours + 1200);
        sT = block.timestamp;
        assertEq(sT % 1 hours, 1200, "E1: construction (phase)");

        // Counterfactual readings at the effective instant, taken BEFORE the
        // move: real readings off the vote surface (`getVotes` at `sT + 1`),
        // not an algebraic restatement of `newVotes`. `_votesAt` only warps --
        // it writes no state -- so no snapshot is needed (and one would be
        // wrong: `vm.revertToState` also rolls back this contract's storage).
        sCfA = _votesAt(DEL_A, sT + 1);
        sCfB = _votesAt(DEL_B, sT + 1);
        assertEq(block.timestamp, sT, "E1: the clock must be back at T");
        assertGt(sCfA, 0, "E1: DEL_A must carry weight before the move");
        assertEq(sCfB, 0, "E1: DEL_B must be empty before the move");

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, DEL_B);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool fA, uint256 pA, uint256 nA) = _lastEvent(logs, DEL_A);
        (bool fB, uint256 pB, uint256 nB) = _lastEvent(logs, DEL_B);
        assertTrue(fA, "E1: no DelegateVotesChanged for the OLD delegatee");
        assertTrue(fB, "E1: no DelegateVotesChanged for the NEW delegatee");

        sEffA = _votesAt(DEL_A, sT + 1);
        sEffB = _votesAt(DEL_B, sT + 1);
        sBndB = _votesAt(DEL_B, _boundary(sT));

        emit log_named_uint("E1 RETIRE  emitted newVotes    ", nA);
        emit log_named_uint("E1 RETIRE  getVotes at t+1     ", sEffA);
        emit log_named_uint("E1 ADD     emitted newVotes    ", nB);
        emit log_named_uint("E1 ADD     getVotes at t+1     ", sEffB);
        emit log_named_uint("E1 ADD     getVotes at boundary", sBndB);
        emit log_named_uint("E1 ADD     boundary gap (wei)  ",
            sEffB > sBndB ? sEffB - sBndB : sBndB - sEffB);

        // The construction must actually separate the two instants, or this
        // body could pass in the broken world; and the retirement leg must
        // land on a NON-ZERO value or its assertion is vacuous.
        assertTrue(sEffB != sBndB, "E1: construction -- boundary and t+1 must differ");
        assertGt(sEffA, 0, "E1: construction -- the RETIREMENT leg must leave weight behind");
        assertTrue(sEffA != _votesAt(DEL_A, _boundary(sT)),
            "E1: construction -- the RETIREMENT leg's two instants must differ");

        assertEq(nA, sEffA, "O06/E1: RETIREMENT leg newVotes != getVotes at the effective instant");
        assertEq(nB, sEffB, "O06/E1: ADDITION leg newVotes != getVotes at the effective instant");
        assertEq(pA, sCfA,  "O06/E1: RETIREMENT leg previousVotes != counterfactual at the effective instant");
        assertEq(pB, sCfB,  "O06/E1: ADDITION leg previousVotes != counterfactual at the effective instant");
        // The pair must describe the SAME instant: the reported delta is the
        // delta actually booked.
        assertEq(sCfA - sEffA, nB - pB, "O06/E1: the two legs do not conserve weight at t+1");
    }

    // ── E2 ────────────────────────────────────────────────────────────────
    // THE FLAT (auto-relock) PATH. A flat delegator's weight rides in
    // `fixedBias`, which does not decay, so the boundary and `t+1` readings
    // of the FLAT term agree. Pin the leg anyway on a delegatee that ALSO
    // carries a decaying term, so the aggregate the event reports does move.
    function test_O06_E2_flatAggregateAtEffectiveInstant() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 decaying = _mkLock(bob, 100 ether, 2 * 365 days);
        uint256 flat     = _mkLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice); veHemi.enableAutoRelock(flat);
        assertGt(veHemi.autoRelockRemaining(flat), 0, "E2: construction (flat flag)");

        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 60);
        vm.prank(bob); delegation.delegate(decaying, DEL_A);

        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 60);
        uint256 T = block.timestamp;

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(flat, DEL_A);
        (bool f, , uint256 nA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
        assertTrue(f, "E2: no event");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, _boundary(T));
        emit log_named_uint("E2 emitted newVotes        ", nA);
        emit log_named_uint("E2 getVotes at t+1         ", eff);
        emit log_named_uint("E2 getVotes at boundary    ", bnd);
        assertTrue(eff != bnd, "E2: construction -- boundary and t+1 must differ");
        assertEq(nA, eff, "O06/E2: FLAT-path newVotes != getVotes at the effective instant");
    }

    // ── E3 ────────────────────────────────────────────────────────────────
    // THE ADAPTER RELAY. `IAdapterNotify.notifyVotesChanged` is the number the
    // Aragon subgraph indexes. It must carry the SAME values as the event.
    // (Event order is pinned by P1Order.)
    function test_O06_E3_adapterRelayCarriesTheCorrectedNumber() public {
        O06MockAdapter ad = new O06MockAdapter();
        delegation.setTrustedAdapter(address(ad));

        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mkLock(alice, 100 ether, 2 * 365 days);
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 900);
        uint256 T = block.timestamp;

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, DEL_A);
        (bool f, , uint256 nA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
        assertTrue(f, "E3: no in-contract event");
        assertTrue(ad.seen(DEL_A), "E3: adapter relay never fired");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, _boundary(T));
        assertTrue(eff != bnd, "E3: construction -- boundary and t+1 must differ");
        assertEq(ad.lastNew(DEL_A), nA, "O06/E3: relayed newVotes != in-contract newVotes");
        assertEq(ad.lastNew(DEL_A), eff, "O06/E3: RELAYED newVotes != getVotes at the effective instant");
    }

    // ── E4 ────────────────────────────────────────────────────────────────
    // THE WHOLE HOUR. Sweeps 20 phases of the hour (1 s, every 189 s, and
    // 3,599 s) and asserts the worst gap between the emitted number and the
    // vote surface at the effective instant is ZERO.
    function test_O06_E4_gapIsZeroAcrossTheHour() public {
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
            (bool f, , uint256 nA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
            assertTrue(f, "E4: no event");

            uint256 eff = _votesAt(DEL_A, T + 1);
            uint256 bnd = _votesAt(DEL_A, _boundary(T));
            if (eff != bnd) ++nonZeroBoundaryGaps;
            uint256 g = nA > eff ? nA - eff : eff - nA;
            if (g > worst) { worst = g; worstPhase = phase; }

            vm.revertToState(snap);
        }
        emit log_named_uint("E4 phases swept                ", 20);
        emit log_named_uint("E4 phases where boundary != t+1", nonZeroBoundaryGaps);
        emit log_named_uint("E4 WORST |emitted - effective| ", worst);
        emit log_named_uint("E4 worst phase (s into hour)   ", worstPhase);
        // 19 of 20 phases must be discriminating (phase 3599 collapses the two
        // instants by construction), so a green here is not vacuous.
        assertGe(nonZeroBoundaryGaps, 19, "E4: construction -- the sweep is not discriminating");
        assertEq(worst, 0, "O06/E4: emitted newVotes deviates from the vote surface at the effective instant");
    }

    // ── E5 ────────────────────────────────────────────────────────────────
    // THE WORST RATIO, PINNED BOTH WAYS. A lock ending just past the boundary
    // makes the boundary reading a tiny fraction of the real weight. Pins that
    // the emitted number equals the LARGE (true) value AND is strictly greater
    // than the boundary value -- so neither a zeroed world nor a boundary-read
    // world can score green.
    function test_O06_E5_worstRatioPinnedBothWays() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id; uint256 E;
        for (uint256 j = 20; j < 40; ++j) {
            uint256 snap = vm.snapshotState();
            uint256 cand = _mkLock(charlie, 1000 ether, j * SIX_DAYS);
            uint256 candEnd = veHemi.getLockedBalance(cand).end;
            vm.revertToState(snap);
            if (candEnd % 1 hours == 360) {
                id = _mkLock(charlie, 1000 ether, j * SIX_DAYS);
                E = veHemi.getLockedBalance(id).end;
                break;
            }
        }
        require(E != 0, "E5: no duration with the wanted end offset");

        uint256 T = E - 3960;
        assertEq(_boundary(T), E - 360, "E5: construction");
        vm.warp(T);

        vm.recordLogs();
        vm.prank(charlie); delegation.delegate(id, DEL_A);
        (bool f, , uint256 nA) = _lastEvent(vm.getRecordedLogs(), DEL_A);
        assertTrue(f, "E5: no event");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, E - 360);
        emit log_named_uint("E5 emitted newVotes      ", nA);
        emit log_named_uint("E5 TRUE votes at t+1     ", eff);
        emit log_named_uint("E5 boundary votes        ", bnd);
        emit log_named_uint("E5 emitted as % of true  ", eff == 0 ? 0 : (nA * 100) / eff);
        assertGt(eff, 0, "E5: construction -- the true value must be non-zero");
        assertGt(eff, bnd * 3, "E5: construction -- the boundary value must be a small fraction");
        assertEq(nA, eff, "O06/E5: emitted newVotes != the true weight at the effective instant");
        assertGt(nA, bnd, "O06/E5: emitted newVotes is still the boundary reading");
    }
}

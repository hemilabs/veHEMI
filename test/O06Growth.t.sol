// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// O06 -- a delegatee's checkpoint array grown by a stranger.
///
/// Anyone holding a position can deepen another delegatee's checkpoint array
/// by re-delegating once per block. G1 pins that `getPastVotes` and `getVotes`
/// stay cheap at depth (both binary-search the array) and that the grind
/// cannot grow an unrelated address's array. G2 pins that
/// the paged view
/// (`getDelegationCheckpointsLength` / `getDelegationCheckpointsPage`) is
/// bounded by `limit` and returns the same elements as the unbounded
/// `getDelegationCheckpoints`.
contract O06GrowthTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);
    address internal constant DEL_A   = address(0xA1);
    address internal constant DEL_J   = address(0x3417);
    address internal constant VICTIM  = address(0x1C70);

    /// A 30M block gas limit is the reference ceiling this project uses.
    uint256 internal constant BLOCK_CEILING = 30_000_000;

    /// Gas bound on each vote read at 4,096 elements. Measured here: about
    /// 12,100 (`getPastVotes`) and 12,500 (`getVotes`), so the bound leaves
    /// about 8x headroom. `getVotes` reads after every pushed element and
    /// `getPastVotes` before all of them, so a linear walk of the array, from
    /// either end, makes one of the two visit every element: at least 4,096
    /// storage reads, over 400,000 gas even warm (as here).
    uint256 internal constant READ_GAS_BOUND = 100_000;

    function _b(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    function _grind(uint256 mid, uint256 t0, uint256 n) internal returns (uint256 gas) {
        for (uint256 i = 0; i < n; ++i) {
            vm.warp(t0 + i);
            vm.prank(MALLORY);
            uint256 g = gasleft();
            delegation.delegate(mid, (i % 2 == 0) ? DEL_A : DEL_J);
            gas += g - gasleft();
        }
    }

    function _setup() internal returns (uint256 mid, uint256 T0) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 vid = _mk(VICTIM, 500 ether, 60 * SIX_DAYS);
        vm.prank(VICTIM); delegation.delegate(vid, DEL_A);
        mid = _mk(MALLORY, 10 ether, 60 * SIX_DAYS);
        vm.warp(_b(block.timestamp) + 1 hours);
        T0 = block.timestamp;
    }

    // ── G1 ────────────────────────────────────────────────────────────────
    // THE COST CURVE. `getPastVotes` stays cheap at depth (both consensus
    // reads are logged), and the attacker cannot touch the VICTIM's own
    // delegatee record.
    function test_O06_G1_consensusReadsStayCheapAtDepth() public {
        (uint256 mid, uint256 T0) = _setup();
        uint256 readAt = T0 - 300;
        // VICTIM's own address carries ONE checkpoint already: `createLock`
        // auto-delegates the position to its owner. The claim under test is
        // that the grind does not change THAT number.
        uint256 victimLenBefore = delegation.getDelegationCheckpoints(VICTIM).length;
        assertEq(victimLenBefore, 1, "G1: construction -- VICTIM self-delegation checkpoint");

        uint256[4] memory marks = [uint256(0), 256, 1024, 4096];
        uint256 done; uint256 attackerGas; uint256 gPastAt4096; uint256 gLiveAt4096;
        for (uint256 s = 0; s < marks.length; ++s) {
            if (marks[s] > done) { attackerGas += _grind(mid, T0 + done, marks[s] - done); done = marks[s]; }
            vm.warp(T0 + done + 10);

            uint256 g = gasleft(); delegation.getPastVotes(DEL_A, readAt);
            uint256 gPast = g - gasleft();
            g = gasleft(); delegation.getVotes(DEL_A);
            uint256 gLive = g - gasleft();

            emit log_named_uint("G1 elements pushed             ", done);
            emit log_named_uint("   gas getPastVotes (sealed)   ", gPast);
            emit log_named_uint("   gas getVotes (live)         ", gLive);
            if (done == 4096) { gPastAt4096 = gPast; gLiveAt4096 = gLive; }
        }
        emit log_named_uint("G1 attacker gas TOTAL for 4096 ", attackerGas);
        emit log_named_uint("G1 attacker gas PER element    ", attackerGas / 4096);

        assertGt(delegation.getDelegationCheckpointsLength(DEL_A), 4000,
            "G1: construction -- the array must actually be deep");
        assertLt(gPastAt4096, READ_GAS_BOUND, "O06/G1: getPastVotes must stay cheap at depth (it is O(log n))");
        // `getVotes` is the live read: an O(n) walk here would let a stranger
        // raise the cost of every current-vote read of the delegatee without
        // bound, by growing its array.
        assertLt(gLiveAt4096, READ_GAS_BOUND, "O06/G1: getVotes must stay cheap at depth (it is O(log n))");
        assertEq(delegation.getDelegationCheckpoints(VICTIM).length, victimLenBefore,
            "O06/G1: a stranger must not be able to grow an unrelated address's array");
    }

    // ── G2 ────────────────────────────────────────────────────────────────
    // PAGINATION, PRICED AND PROVEN EQUIVALENT.
    function test_O06_G2_paginationIsBoundedAndFaithful() public {
        (uint256 mid, uint256 T0) = _setup();
        _grind(mid, T0, 4096);
        vm.warp(T0 + 4200);

        uint256 len = delegation.getDelegationCheckpointsLength(DEL_A);

        IVeHemiVoteDelegation.DelegateCheckpoint[] memory all =
            delegation.getDelegationCheckpoints(DEL_A);
        assertEq(len, all.length, "O06/G2: length view disagrees with the array");
        assertGt(len, 4000, "G2: construction -- the array must actually be deep");

        uint256 g = gasleft();
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory page =
            delegation.getDelegationCheckpointsPage(DEL_A, 0, 256);
        uint256 gPage = g - gasleft();

        g = gasleft(); delegation.getDelegationCheckpoints(DEL_A);
        uint256 gAll = g - gasleft();

        emit log_named_uint("G2 array length                ", len);
        emit log_named_uint("G2 gas UNBOUNDED view          ", gAll);
        emit log_named_uint("G2 gas PAGE(0,256)             ", gPage);
        emit log_named_uint("G2 pages needed at limit 256   ", (len + 255) / 256);
        emit log_named_uint("G2 reduction factor            ", gPage == 0 ? 0 : gAll / gPage);

        assertEq(page.length, 256, "O06/G2: a full page must return exactly `limit` elements");
        assertLt(gPage, BLOCK_CEILING / 10,
            "O06/G2: a bounded page must be servable inside a small fraction of a block");

        // FAITHFUL: the window is the array, element for element.
        for (uint256 i = 0; i < 256; ++i) {
            assertEq(page[i].timestamp, all[i].timestamp, "O06/G2: page/array timestamp mismatch");
            assertEq(page[i].normalizedBias, all[i].normalizedBias, "O06/G2: page/array bias mismatch");
            assertEq(page[i].normalizedSlope, all[i].normalizedSlope, "O06/G2: page/array slope mismatch");
            assertEq(page[i].totalAmount, all[i].totalAmount, "O06/G2: page/array amount mismatch");
            assertEq(page[i].fixedBias, all[i].fixedBias, "O06/G2: page/array fixedBias mismatch");
        }

        // TAIL: a page that runs off the end clamps instead of reverting.
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory tail =
            delegation.getDelegationCheckpointsPage(DEL_A, len - 3, 256);
        assertEq(tail.length, 3, "O06/G2: the last page must clamp to the array end");
        assertEq(tail[2].timestamp, all[len - 1].timestamp, "O06/G2: the last page must end at the last element");

        // PAST THE END: empty, not a revert -- so a paging loop terminates.
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory past =
            delegation.getDelegationCheckpointsPage(DEL_A, len, 256);
        assertEq(past.length, 0, "O06/G2: an offset past the end must return empty, not revert");

        // ZERO LIMIT: empty, not a revert.
        assertEq(delegation.getDelegationCheckpointsPage(DEL_A, 0, 0).length, 0,
            "O06/G2: limit 0 must return empty, not revert");

        // WHOLE ARRAY VIA PAGES: every element reachable, none duplicated.
        uint256 seen;
        for (uint256 off = 0; off < len; off += 512) {
            seen += delegation.getDelegationCheckpointsPage(DEL_A, off, 512).length;
        }
        assertEq(seen, len, "O06/G2: paging must enumerate the array exactly once");
    }
}

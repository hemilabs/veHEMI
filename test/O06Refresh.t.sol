// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// The other emitters of `DelegateVotesChanged`.
///
/// `_delegate`'s two legs are not the only writers of the event.
/// `refreshVotingPower` (permissionless, state-free, exists only to tell
/// indexers the current number), its batch form, and
/// `writeNewCheckpointForExpiredDelegations` (permissionless amortiser) must
/// report the same instant as the delegation events, `block.timestamp + 1`:
/// a boundary reading would let a refresh in the same block overwrite an
/// indexer's correct number with a boundary-decayed one.
///
/// R1/R2 pin the refresh paths. R3 pins the amortiser as VALUE-NEUTRAL and
/// reporting the effective instant.
contract O06RefreshTest is LockedCurveTestBase {
    address internal constant DEL_A = address(0xA1);
    bytes32 internal constant DVC = keccak256("DelegateVotesChanged(address,uint256,uint256)");

    function _boundary(uint256 t) internal pure returns (uint256) {
        return (t / 1 hours) * 1 hours + 1 hours;
    }

    function _lastEvent(address who) internal returns (bool found, uint256 prev, uint256 nw) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
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

    function _votesAt(address who, uint256 t) internal returns (uint256 v) {
        uint256 back = block.timestamp;
        vm.warp(t);
        v = delegation.getVotes(who);
        vm.warp(back);
    }

    function _seed() internal returns (uint256 T) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mkLock(alice, 100 ether, 2 * 365 days);
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 600);
        vm.prank(alice); delegation.delegate(id, DEL_A);
        T = block.timestamp;
    }

    // ── R1 ────────────────────────────────────────────────────────────────
    // `refreshVotingPower` in the SAME BLOCK as the delegation must not
    // contradict the delegation's own event.
    function test_O06_R1_refreshAgreesWithTheDelegationEvent() public {
        uint256 T = _seed();

        vm.recordLogs();
        vm.prank(alice); delegation.refreshVotingPower(DEL_A);
        (bool f, uint256 p, uint256 n) = _lastEvent(DEL_A);
        assertTrue(f, "R1: refreshVotingPower emitted nothing");
        assertEq(p, n, "R1: refresh must report a single value");

        uint256 eff = _votesAt(DEL_A, T + 1);
        uint256 bnd = _votesAt(DEL_A, _boundary(T));
        emit log_named_uint("R1 refresh emitted        ", n);
        emit log_named_uint("R1 getVotes at t+1        ", eff);
        emit log_named_uint("R1 getVotes at boundary   ", bnd);
        emit log_named_uint("R1 contradiction (wei)    ", eff > n ? eff - n : n - eff);
        assertTrue(eff != bnd, "R1: construction -- the two instants must differ");
        assertEq(n, eff,
            "R1: refreshVotingPower reports the boundary, contradicting the delegation event in the same block");
    }

    // ── R2 ────────────────────────────────────────────────────────────────
    // The batch entry point inherits whatever R1 pins.
    function test_O06_R2_refreshBatchAgreesToo() public {
        uint256 T = _seed();
        address[] memory who = new address[](1);
        who[0] = DEL_A;

        vm.recordLogs();
        delegation.refreshVotingPowerBatch(who);
        (bool f, , uint256 n) = _lastEvent(DEL_A);
        assertTrue(f, "R2: batch emitted nothing");

        uint256 eff = _votesAt(DEL_A, T + 1);
        emit log_named_uint("R2 batch emitted   ", n);
        emit log_named_uint("R2 getVotes at t+1 ", eff);
        assertEq(n, eff, "R2: refreshVotingPowerBatch reports the boundary");
    }

    // ── R3 ────────────────────────────────────────────────────────────────
    // `writeNewCheckpointForExpiredDelegations` is an AMORTISER: it
    // materialises expirations that the lazy reader already nets off, so it
    // must change NO readable value at ANY instant, and report the same
    // number before and after its own write.
    function test_O06_R3_amortiserIsValueNeutral() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 shortId = _mkLock(alice, 100 ether, 3 * SIX_DAYS);
        uint256 longId  = _mkLock(bob,   100 ether, 2 * 365 days);
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours + 600);
        vm.prank(alice); delegation.delegate(shortId, DEL_A);
        vm.prank(bob);   delegation.delegate(longId,  DEL_A);

        // Past the short lock's expiry, so there IS something to materialise.
        vm.warp(veHemi.getLockedBalance(shortId).end + 2 hours + 600);
        uint256 T = block.timestamp;

        uint256 beforeEff = _votesAt(DEL_A, T + 1);
        uint256 beforeBnd = _votesAt(DEL_A, _boundary(T));
        uint256 beforeNow = delegation.getVotes(DEL_A);

        vm.recordLogs();
        delegation.writeNewCheckpointForExpiredDelegations(DEL_A);
        (bool f, uint256 p, uint256 n) = _lastEvent(DEL_A);
        assertTrue(f, "R3: amortiser emitted nothing");

        uint256 afterEff = _votesAt(DEL_A, T + 1);
        uint256 afterBnd = _votesAt(DEL_A, _boundary(T));
        emit log_named_uint("R3 emitted previousVotes ", p);
        emit log_named_uint("R3 emitted newVotes      ", n);
        emit log_named_uint("R3 votes at t+1  before  ", beforeEff);
        emit log_named_uint("R3 votes at t+1  after   ", afterEff);
        emit log_named_uint("R3 votes at bnd  before  ", beforeBnd);
        emit log_named_uint("R3 votes at bnd  after   ", afterBnd);
        emit log_named_uint("R3 getVotes(now)         ", beforeNow);

        assertGt(beforeEff, 0, "R3: construction -- DEL_A must still carry the long lock");
        assertEq(afterEff, beforeEff, "R3: the amortiser changed the t+1 reading");
        assertEq(afterBnd, beforeBnd, "R3: the amortiser changed the boundary reading");
        assertEq(p, n, "R3: the amortiser reported a non-zero delta it did not make");
        assertEq(n, afterEff, "R3: the amortiser reports the boundary, not the effective instant");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// An owner's top-up never darkens its delegatee.
///
/// After an owner `increaseAmount`, the delegatee's SEALED ledger
/// (`getPastVotes`; "sealed" is defined in the header of
/// test/delegation-votes/VoteContinuityLaw.sol) reads strictly HIGHER at every
/// sampled instant of the window that follows the call (up to 600 s, stopping
/// before the next hour boundary). Measured as a differential against a
/// no-call counterfactual replayed from the same snapshot, on the read surface
/// only.
contract TopUpNeverDarkensTest is LockedCurveTestBase {
    function _nextHourBoundary(uint256 t) internal pure returns (uint256) {
        return (t / 1 hours) * 1 hours + 1 hours;
    }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    function _delegatedPositionMidHour() internal returns (uint256 id) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        id = _mk(alice, 500 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(_nextHourBoundary(block.timestamp) + 600);
        hemi.mint(alice, 1000 ether);
    }

    /// The delegatee's SEALED ledger over (T, min(T + 600, boundary - 1)].
    function _sweep(uint256 T) internal returns (uint256[] memory s) {
        uint256 nextHourBoundary = _nextHourBoundary(T);
        uint256 end = nextHourBoundary - 1;
        if (end > T + 600) end = T + 600;
        vm.warp(nextHourBoundary + 2);
        s = new uint256[](end - T);
        for (uint256 t = T + 1; t <= end; ++t) s[t - T - 1] = delegation.getPastVotes(bob, t);
    }

    /// The owner's top-up moves the delegatee's sealed ledger strictly UP
    /// at every sampled instant; no instant reads below the counterfactual.
    function test_ownerTopUpRaisesSealedVotesAtEveryInstant() public {
        uint256 id = _delegatedPositionMidHour();
        uint256 T = block.timestamp;
        uint256 snap = vm.snapshotState();
        uint256[] memory withoutTopUp = _sweep(T);
        vm.revertToState(snap);
        vm.prank(alice);
        veHemi.increaseAmount(id, 10 ether);
        uint256[] memory withTopUp = _sweep(T);
        assertEq(withoutTopUp.length, 600, "premise: the window must be 600 instants");
        uint256 up; uint256 down;
        for (uint256 i; i < withoutTopUp.length; ++i) {
            if (withTopUp[i] > withoutTopUp[i]) { unchecked { ++up; } }
            if (withTopUp[i] < withoutTopUp[i]) { unchecked { ++down; } }
        }
        assertEq(down, 0,   "the owner's top-up DARKENED the delegatee");
        assertEq(up,   600, "the owner's top-up did not raise the ledger at every instant");
    }
}

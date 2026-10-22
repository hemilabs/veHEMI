// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import {N04VoteContinuityLaw as N04} from "./N04VoteContinuityLaw.sol";

/// N04 — CLAUSE 4, THE GATE: a stranger cannot mutate the delegatee's ledger
/// through `increaseAmount`.
///
/// No law over `getVotes`/`getPastVotes` can tell an owner's write from a
/// stranger's (the two produce the same readings), so the caller-conditional
/// property is asserted on the access surface. The body is PAIRED: from one
/// snapshot, the OWNER's identical call must succeed and move the delegatee's
/// sealed ledger against a no-call counterfactual, and only then must the
/// stranger's call revert. A stranger's revert alone would prove nothing.
/// The dust-amount variant of this body is `N02OwnerGate.t.sol`'s G1.
contract N04GateTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1); o[0] = a;
    }

    function _arm() internal returns (uint256 id) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        id = _mk(alice, 500 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(N04.nextBoundary(block.timestamp) + 600);
        // Both callers are funded and approved, so a revert can only be the
        // GATE and never a missing allowance.
        hemi.mint(MALLORY, 100 ether);
        vm.prank(MALLORY); hemi.approve(address(veHemi), type(uint256).max);
        hemi.mint(alice, 100 ether);
    }

    function _topUp(uint256 id, uint256 amt) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("increaseAmount(uint256,uint256)", id, amt);
    }

    /// A real-size top-up by a stranger is refused, after the owner's identical
    /// call is shown to move the delegatee's ledger.
    function test_N04_C4_strangerCannotMutate_increaseAmount_realSize() public {
        uint256 id = _arm();
        N04.assertOnlyOwnerCanMutate(
            delegation, address(veHemi), _topUp(id, 10 ether),
            MALLORY, alice, bob, _ids(id), "increaseAmount/10e18"
        );
    }

    // The one other VeHemi entry point that re-delegates an EXISTING position
    // without its owner, `retireStaleAutoRelock`, is deliberately
    // permissionless (one-shot, after `STALE_FLAT_BUCKETS` of owner silence),
    // so it has no gate body.
}

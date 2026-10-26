// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import {VoteContinuityLaw} from "./VoteContinuityLaw.sol";

/// CLAUSE 4, THE GATE: a stranger cannot mutate the delegatee's ledger
/// through `increaseAmount`.
///
/// No law over `getVotes`/`getPastVotes` can tell an owner's write from a
/// stranger's (the two produce the same readings), so the caller-conditional
/// property is asserted on the access surface. The body is PAIRED: from one
/// snapshot, the OWNER's identical call must succeed and move the delegatee's
/// sealed ledger against a no-call counterfactual, and only then must the
/// stranger's call revert. A stranger's revert alone would prove nothing.
/// The dust-amount variant of this body is G1 of
/// `IncreaseAmountOwnerGate.t.sol`.
contract VoteContinuityGateTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);

    function _mk(address owner_, uint256 amount_, uint256 duration_) internal returns (uint256 id) {
        hemi.mint(owner_, amount_);
        vm.prank(owner_); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(owner_); id = veHemi.createLock(amount_, duration_);
    }

    function _ids(uint256 id_) internal pure returns (uint256[] memory ids_) {
        ids_ = new uint256[](1); ids_[0] = id_;
    }

    function _delegatedPositionWithFundedCallers() internal returns (uint256 id) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        id = _mk(alice, 500 ether, 12 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(VoteContinuityLaw.nextBoundary(block.timestamp) + 600);
        // Both callers are funded and approved, so a revert can only be the
        // GATE and never a missing allowance.
        hemi.mint(MALLORY, 100 ether);
        vm.prank(MALLORY); hemi.approve(address(veHemi), type(uint256).max);
        hemi.mint(alice, 100 ether);
    }

    function _increaseAmountCalldata(uint256 id, uint256 amt) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("increaseAmount(uint256,uint256)", id, amt);
    }

    /// A real-size top-up by a stranger is refused, after the owner's identical
    /// call is shown to move the delegatee's ledger.
    function test_C4_strangerCannotMutate_increaseAmount_realSize() public {
        uint256 id = _delegatedPositionWithFundedCallers();
        VoteContinuityLaw.assertOnlyOwnerCanMutate(
            delegation, address(veHemi), _increaseAmountCalldata(id, 10 ether),
            MALLORY, alice, bob, _ids(id), "increaseAmount/10e18"
        );
    }

    // The one other VeHemi entry point that re-delegates an EXISTING position
    // without its owner, `retireStaleAutoRelock`, is deliberately
    // permissionless (one-shot, after `STALE_FLAT_BUCKETS` of owner silence),
    // so it has no gate body.
}

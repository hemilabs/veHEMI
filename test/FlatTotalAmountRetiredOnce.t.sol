// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// A flat delegation's booked principal (`totalAmount`) is retired
// exactly once.
// ----------------------------------------------------------------------------
//   B1  a flat delegation whose stored `end` is in the past is moved away; the
//       old delegatee's `totalAmount` returns to zero.
//   B2  every `increaseAmount` re-delegates the position (move-away then
//       move-back); five 1-wei top-ups must not re-add the whole principal,
//       and must leave exactly the principal plus the top-ups booked.
// ============================================================================

import "./TwinOracle.sol";

contract FlatTotalAmountRetiredOnceTest is TwinOracle {
    address internal constant OWNER  = address(0xA11CE);
    address internal constant CAROL  = address(0xCA401);
    address internal constant DAVE   = address(0xDA7E);

    uint256 internal constant AMT = 1000 ether;
    uint256 internal constant N   = 40; // buckets

    function setUp() public {
        setUpTwinOracle();
    }

    function _driveCandidate(uint256) internal override {}

    function _lastTotalAmount(address who) internal view returns (uint256) {
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory checkpoints = X.del.getDelegationCheckpoints(who);
        if (checkpoints.length == 0) return 0;
        return uint256(checkpoints[checkpoints.length - 1].totalAmount);
    }

    function _mintFlat(address owner_, bool forfeitable_) internal returns (uint256 id) {
        X.hemi.mint(owner_, AMT);
        vm.startPrank(owner_);
        X.hemi.approve(address(X.ve), type(uint256).max);
        id = X.ve.createLockFor(AMT, N * SIX_DAYS, owner_, false, forfeitable_);
        X.ve.enableAutoRelock(id);
        vm.stopPrank();
    }

    // ================================================================== B1
    /// @notice A FLAT delegation whose stored `end` is in the past is moved
    ///         away; the old delegatee's `totalAmount` must return to zero.
    function test_B1_flatTotalAmountRetiredExactlyOnce() public {
        uint256 id = _mintFlat(OWNER, false);

        vm.prank(OWNER);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + 1 hours + 1);

        assertEq(_lastTotalAmount(CAROL), AMT, "B1 premise: the principal is booked");

        // walk the stored `end` into the past -- the position stays alive and
        // flat, `delegations[id].end` does not move
        vm.warp(block.timestamp + (N + 4) * SIX_DAYS);

        vm.prank(OWNER);
        X.del.delegate(id, DAVE);
        vm.warp(block.timestamp + 1 hours + 1);

        assertEq(_lastTotalAmount(CAROL), 0,
            "a flat delegation's totalAmount was NOT retired on move-away");
    }

    // ================================================================== B2
    /// @notice Each `increaseAmount` re-delegates (move-away then move-back).
    ///         Five 1-wei top-ups on a flat delegation with a past stored end
    ///         must leave the delegatee's `totalAmount` at no more than the
    ///         principal plus the dust, not re-add the whole principal each
    ///         time; and at exactly that: each move-away retires the booked
    ///         amount and each move-back books the new one, so the result is
    ///         `AMT + 5`.
    function test_B2_topUpsDoNotDoubleBookThePrincipal() public {
        uint256 id = _mintFlat(OWNER, false);

        vm.prank(OWNER);
        X.del.delegate(id, CAROL);
        vm.warp(block.timestamp + (N + 4) * SIX_DAYS);

        for (uint256 i; i < 5; ++i) {
            X.hemi.mint(OWNER, 1);
            vm.startPrank(OWNER);
            X.hemi.approve(address(X.ve), 1);
            X.ve.increaseAmount(id, 1);   // owner-only
            vm.stopPrank();
            vm.warp(block.timestamp + 1 hours + 1);
        }

        assertEq(uint256(uint128(X.ve.getLockedBalance(id).amount)), AMT + 5,
            "B2 premise: the five top-ups were not all deposited");
        assertEq(X.del.delegation(id).delegatee, CAROL, "B2 premise: the position left CAROL");
        assertLe(_lastTotalAmount(CAROL), AMT + 5,
            "a 1-wei increaseAmount double-booked the principal");
        assertEq(_lastTotalAmount(CAROL), AMT + 5,
            "B2: the delegatee's totalAmount is not the principal plus the top-ups (a re-booking was lost)");
    }
}

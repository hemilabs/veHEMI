// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ARLInvariantBase} from "./ARLInvariant.t.sol";
import {IVeHemiVoteDelegation} from "src/interfaces/IVeHemiVoteDelegation.sol";

/**
 * @title MaxLockWipeTest
 * @notice The delegation module's MAX_LOCK_DURATION wipe (a delegatee with no
 *         checkpoint for longer than MAX_LOCK_DURATION has every decaying
 *         contribution expired at its next write) must keep a live flat
 *         position's principal, and a later disable plus the permissionless
 *         expiry amortiser must leave the delegatee's votes equal to the live
 *         balances behind them.
 *
 * @dev The sequence is ordinary public calls:
 *        createLock -> delegate -> enableAutoRelock
 *          -> (four years and a month pass)
 *        createLock -> delegate            (a different, unrelated user)
 *          -> disableAutoRelock
 *      `test_control_decayingOnlyWipeIsExact` is the same shape without
 *      the auto-relock step.
 */
contract MaxLockWipeTest is ARLInvariantBase {
    /// @dev `MAX_LOCK_DURATION == 4 * YEAR == 240 * SIX_DAYS == 126,230,400 s`.
    uint256 internal constant MAX_LOCK_DURATION = 126_230_400;

    function setUp() public {
        _setUpCommon();
    }

    function _mintLock(address who, uint256 amount, uint256 duration) internal returns (uint256 id) {
        vm.startPrank(who);
        handler.hemi().mint(who, amount);
        handler.hemi().approve(address(veHemi), amount);
        id = veHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    function _last(address d) internal view returns (IVeHemiVoteDelegation.DelegateCheckpoint memory c) {
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory cs = delegation.getDelegationCheckpoints(d);
        if (cs.length > 0) c = cs[cs.length - 1];
    }

    /// @notice The wipe keeps a live flat principal (and its `fixedBias`).
    function test_flatPrincipalSurvivesMaxLockWipe() public {
        // 1. alice delegates a 100-HEMI position to carl and turns on auto-relock.
        uint256 a = _mintLock(alice, 100 ether, 730 days);
        vm.prank(alice);
        delegation.delegate(a, carl);
        vm.prank(alice);
        veHemi.enableAutoRelock(a);

        IVeHemiVoteDelegation.DelegateCheckpoint memory c0 = _last(carl);
        assertEq(uint256(c0.totalAmount), 100 ether, "flat principal not booked");
        assertGt(uint256(c0.fixedBias), 0, "not flat");

        // 2. More than MAX_LOCK_DURATION passes with no checkpoint on carl: a
        //    flat position never expires and books no SIX_DAYS bucket, so
        //    nothing forces one.
        vm.warp(block.timestamp + MAX_LOCK_DURATION + 30 days);

        // 3. A second, unrelated delegator books weight on carl; that write
        //    takes the MAX_LOCK_DURATION branch.
        uint256 b = _mintLock(bob, 200 ether, 730 days);
        vm.prank(bob);
        delegation.delegate(b, carl);

        IVeHemiVoteDelegation.DelegateCheckpoint memory c1 = _last(carl);
        assertEq(uint256(c1.fixedBias), uint256(c0.fixedBias), "fixedBias must survive the wipe");
        // `getVotes` reads `fixedBias` and the normalized bias/slope, never
        // `totalAmount`, so a destroyed principal would not show in the votes.
        assertEq(
            uint256(c1.totalAmount),
            300 ether,
            "MAX_LOCK_DURATION wipe destroyed a LIVE flat position's principal"
        );
    }

    /// @notice After the wipe, alice's disable must retire her principal from
    ///         carl exactly once (not out of bob's), and the public view and
    ///         the permissionless amortiser must not underflow; carl's votes
    ///         equal the live balances delegated to him, before and after.
    function test_disableAfterWipeLeavesVotesExact() public {
        uint256 a = _mintLock(alice, 100 ether, 730 days);
        vm.prank(alice);
        delegation.delegate(a, carl);
        vm.prank(alice);
        veHemi.enableAutoRelock(a);

        vm.warp(block.timestamp + MAX_LOCK_DURATION + 30 days);

        uint256 b = _mintLock(bob, 200 ether, 730 days);
        vm.prank(bob);
        delegation.delegate(b, carl);

        vm.prank(alice);
        veHemi.disableAutoRelock(a);

        // The re-booking is live from `block.timestamp + 1`; read it at the
        // next hourly boundary.
        vm.warp((block.timestamp / 1 hours) * 1 hours + 1 hours);
        assertGt(veHemi.balanceOfNFT(a), 0, "alice's restored position is not live");
        assertEq(
            delegation.getVotes(carl),
            veHemi.balanceOfNFT(a) + veHemi.balanceOfNFT(b),
            "after the disable, carl's votes != the live balances delegated to him"
        );

        // Walk past both expiries and use the public view and the
        // permissionless amortiser.
        vm.warp(block.timestamp + 800 days);
        delegation.calculateExpiredDelegations(carl);
        vm.prank(makeAddr("stranger"));
        delegation.writeNewCheckpointForExpiredDelegations(carl);
        assertEq(
            delegation.getVotes(carl),
            veHemi.balanceOfNFT(a) + veHemi.balanceOfNFT(b),
            "after amortising, carl's votes != the live balances delegated to him"
        );
    }

    /// @notice The same shape with no auto-relock: the wipe is exact for
    ///         decaying contributions, every one of which has expired by then.
    function test_control_decayingOnlyWipeIsExact() public {
        uint256 a = _mintLock(alice, 100 ether, 730 days);
        vm.prank(alice);
        delegation.delegate(a, carl);

        vm.warp(block.timestamp + MAX_LOCK_DURATION + 30 days);

        uint256 b = _mintLock(bob, 200 ether, 730 days);
        vm.prank(bob);
        delegation.delegate(b, carl);

        // alice's position expired long ago; bob's is live. The wipe is exact.
        IVeHemiVoteDelegation.DelegateCheckpoint memory c = _last(carl);
        assertEq(uint256(c.totalAmount), 200 ether, "decaying-only wipe is not exact");
        assertEq(uint256(c.fixedBias), 0, "no flat term in the control");

        vm.warp(block.timestamp + 800 days);
        delegation.calculateExpiredDelegations(carl);
        vm.prank(makeAddr("stranger"));
        delegation.writeNewCheckpointForExpiredDelegations(carl);
        assertEq(delegation.getVotes(carl), 0, "votes remain after every delegated position expired");
    }
}

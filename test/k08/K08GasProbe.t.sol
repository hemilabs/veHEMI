// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @title  K08 — an HONEST `voteDelegation.delegate` stays below the ceiling.
/// @notice VeHemi calls the delegation module with `DELEGATION_GAS_CEILING`
///         (8,000,000) and treats a module that consumes all of it as broken,
///         not starved. That is only safe if an honest module never needs the
///         ceiling. Its cost driver is `VeHemiVoteDelegation._calculateExpirations`,
///         whose SIX_DAYS walk is clamped at `MAX_LOCK_DURATION / SIX_DAYS`
///         = 240 iterations. The worst case is a delegatee with an expiration
///         in every bucket and 240 buckets since its last checkpoint.
contract K08GasProbe is J11Base {
    uint256 internal constant DELEGATION_GAS_CEILING = 8_000_000;

    function test_K08_worstCaseHonestDelegateGas() public {
        hemi.mint(attacker, 1_000_000 ether);
        vm.prank(attacker);
        hemi.approve(address(veHemi), type(uint256).max);

        // one decaying position per SIX_DAYS bucket (2 .. 239 buckets out),
        // all delegated to `dele`: the delegatee carries the maximum number of
        // expiration buckets.
        for (uint256 i = 2; i < 240; ++i) {
            (uint256 id, , ) = createLock(attacker, 10 ether, i * SIX_DAYS);
            delegateTo(attacker, id, dele);
        }
        vm.warp(block.timestamp + 7200);

        // the victim: a FLAT, delegated position on the same delegatee.
        (uint256 vid, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        enable(attacker, vid);
        delegateTo(attacker, vid, dele);

        // 240 idle buckets: the next write on `dele` walks the whole clamp,
        // across every populated expiration bucket.
        vm.warp(block.timestamp + 240 * SIX_DAYS);
        veHemi.checkpoint(); // VeHemi's own global catch-up is not the module's work
        uint256 snap = vm.snapshotState();

        // (1) the module's own write, called directly: a move-away from `dele`.
        uint256 g0 = gasleft();
        vm.prank(attacker);
        delegation.delegate(vid, dele2);
        uint256 direct = g0 - gasleft();
        emit log_named_uint("direct VVD.delegate gas, 240 idle buckets", direct);
        assertLt(direct, DELEGATION_GAS_CEILING, "an HONEST delegate exceeded the delegation gas ceiling");
        vm.revertToState(snap);

        // (2) the whole holder disable (re-books the flat term as decaying at
        //     `dele`), which contains that module call.
        uint256 g1 = gasleft();
        vm.prank(attacker);
        veHemi.disableAutoRelock(vid);
        uint256 whole = g1 - gasleft();
        emit log_named_uint("whole disableAutoRelock gas, 240 idle buckets", whole);
        assertLt(whole, DELEGATION_GAS_CEILING, "the worst-case honest disable used more than the ceiling");

        // and it really retired the flat term (the cost is not a cheap swallow):
        // every other position on `dele` has expired.
        assertEq(veHemi.autoRelockRemaining(vid), 0, "disable did not disarm");
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(vid), "disable mis-booked the delegatee");
    }
}

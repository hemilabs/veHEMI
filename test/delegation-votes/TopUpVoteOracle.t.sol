// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";

/// Vote continuity across an owner's own 1-wei top-up, checked by
/// oracles that read only `getVotes` / `getPastVotes` and compute no weight.
///
///   O1  FLAT CONSTANCY       oracle = the contract's own earlier reading: a
///                            flat (auto-relock) term never falls, live or
///                            sealed.
///   O2  COUNTERFACTUAL       oracle = the same scenario without the top-up,
///                            replayed from a state snapshot (decaying lock).
///   O3  FALSE-POSITIVE GUARD a re-delegation is invisible in its own block and
///                            live from `t+1`, so O1/O2 cannot be satisfied by
///                            making delegation instantaneous.
///
/// Every trigger is the POSITION OWNER: `increaseAmount` is owner-gated, so a
/// stranger's top-up would revert and the oracle would see nothing.
contract TopUpVoteOracleTest is LockedCurveTestBase {
    function _b(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    /// @dev The trigger: `who` tops up position `id` by `amt`. Every caller
    ///      passes the position owner.
    function _touch(uint256 id, address who, uint256 amt) internal {
        hemi.mint(who, amt);
        vm.prank(who); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(who); veHemi.increaseAmount(id, amt);
    }

    // =================================================================
    // O1. FLAT CONSTANCY.  A flat (auto-relock) term has no slope and no
    //     expiry, so its contribution is a CONSTANT. Away from a SIX_DAYS
    //     bucket edge the delegatee's weight therefore cannot legally fall,
    //     ever, and a 1-wei top-up by the owner can only RAISE it.
    //
    //     ORACLE: `before`, read from the contract itself one second earlier.
    //     TOLERANCE: none. Nothing is recomputed, so no change to the weight
    //     formula or the dating rule can make this body stale.
    // =================================================================
    function test_O1_flatTermNeverFalls() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 20 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        vm.warp(_b(block.timestamp) + 600);

        uint256 before_ = delegation.getVotes(bob);
        assertGt(before_, 0, "precondition: a flat term is booked on bob");

        _touch(id, alice, 1);      // the owner
        uint256 T = block.timestamp;

        // Live half, and the historical half, out to TWO hour boundaries so a
        // "heals at the boundary" argument cannot rescue it.
        uint256 worstDrop; uint256 belowSamples;
        for (uint256 t = T + 1; t <= T + 2 hours; ++t) {
            vm.warp(t);
            uint256 v = delegation.getVotes(bob);
            if (v < before_) { unchecked { ++belowSamples; } if (before_ - v > worstDrop) worstDrop = before_ - v; }
        }
        vm.warp(T + 400 days);
        uint256 sealedBelow;
        for (uint256 t = T + 1; t <= T + 2 hours; ++t) {
            if (delegation.getPastVotes(bob, t) < before_) { unchecked { ++sealedBelow; } }
        }

        emit log_named_uint("O1 flat term before        ", before_);
        emit log_named_uint("O1 live samples below      ", belowSamples);
        emit log_named_uint("O1 worst drop (wei)        ", worstDrop);
        emit log_named_uint("O1 SEALED samples below    ", sealedBelow);

        assertEq(belowSamples, 0, "O1: a constant flat term FELL after the OWNER's own 1-wei touch");
        assertEq(sealedBelow, 0, "O1: and the fall is sealed in getPastVotes for ever");
    }

    // =================================================================
    // O2. THE COUNTERFACTUAL.  Run the identical scenario TWICE from one
    //     state snapshot: arm B performs the owner's 1-wei top-up, arm A
    //     does not. The expected value at every instant is arm A's reading.
    //
    //     ORACLE: the contract, on the same tree, without the trigger. It
    //     needs NO closed form for the weight, so it works for a DECAYING
    //     position, where O1's zero tolerance would not.
    // =================================================================
    function test_O2_counterfactualDecayingPosition() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(_b(block.timestamp) + 600);

        uint256 T = block.timestamp;
        uint256 N = 120;              // 120 samples, 30 s apart == 1 hour
        uint256[] memory control = new uint256[](N);

        uint256 snap = vm.snapshotState();
        // ARM A -- no touch at all.
        for (uint256 i; i < N; ++i) { vm.warp(T + 1 + i * 30); control[i] = delegation.getVotes(bob); }
        vm.revertToState(snap);

        // ARM B -- the OWNER, one wei, everything else identical.
        _touch(id, alice, 1);
        assertEq(block.timestamp, T, "arm B must start at the same instant");
        uint256 worst; uint256 below;
        for (uint256 i; i < N; ++i) {
            vm.warp(T + 1 + i * 30);
            uint256 v = delegation.getVotes(bob);
            if (v < control[i]) { unchecked { ++below; } if (control[i] - v > worst) worst = control[i] - v; }
        }
        emit log_named_uint("O2 samples below control   ", below);
        emit log_named_uint("O2 worst deficit (wei)     ", worst);
        assertEq(below, 0, "O2: the OWNER's own 1 wei made her delegatee POORER than doing nothing");
    }

    // =================================================================
    // O3. THE FALSE-POSITIVE GUARD FOR O1/O2. A re-delegation must not count
    //     in the block that makes it (`CHECKPOINT_INTERVAL`'s docstring: both
    //     legs land after `block.timestamp`, the latest instant `getPastVotes`
    //     serves). With `t+1` dating the move is live from the next second and
    //     stays live through the hour boundary.
    // =================================================================
    function test_O3_moveIsLiveFromTheNextSecond() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(_b(block.timestamp) + 600);

        vm.prank(alice); delegation.delegate(id, charlie);
        uint256 T = block.timestamp;
        uint256 bnd = _b(T);

        // (1) THE STATED PROPERTY: the MOVE is not visible in its own block.
        assertEq(delegation.getVotes(charlie), 0,
            "O3: a MOVE became visible IN ITS OWN BLOCK -- same-block flash-delegation");

        // (2) Visible from the very next second.
        vm.warp(T + 1);
        uint256 atNextBlock = delegation.getVotes(charlie);
        assertGt(atNextBlock, 0, "O3: the move never landed at all");

        // (3) Live for the whole run from T+1 to the boundary, so the body
        //     fails loudly if the dating changes in either direction.
        uint256 live;
        for (uint256 t = T + 1; t < bnd; ++t) { vm.warp(t); if (delegation.getVotes(charlie) != 0) ++live; }
        emit log_named_uint("O3 seconds between T+1 and the boundary that are LIVE", live);
        assertEq(live, bnd - T - 1,
            "O3: the move is live at T+1 but NOT for the whole run to the boundary -- the dating is neither t+1 nor the grid");

        // (4) And it is still live at the boundary.
        vm.warp(bnd);
        assertGt(delegation.getVotes(charlie), 0, "O3: the move did not survive to the boundary");
    }
}

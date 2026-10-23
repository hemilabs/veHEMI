// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "../k08/K08Modules.sol";

/// @dev THE CALIBRATOR. Burns EXACTLY `K` gas inside `delegation()` and then
///      reverts cheaply. Its consumption is BOUNDED and, for `K` comfortably
///      below `DELEGATION_GAS_CEILING`, `gasBefore_ - _left < CEILING` is
///      always TRUE for it, so its starvation threshold is the PURE 63/64
///      RATIO boundary, independent of the ceiling conjunct.
contract Q38FixedEater is K08ModuleBase {
    uint256 public immutable K;
    constructor(uint256 k_) { K = k_; }
    function delegate(uint256, address) external override {}
    function delegation(uint256) external view override returns (Delegation memory) {
        uint256 g0 = gasleft();
        uint256 x = 1;
        while (g0 - gasleft() < K) { x = uint256(keccak256(abi.encode(x))); }
        revert("fixed eater");
    }
}

/// @title  THE DETECTOR FOR THE STARVATION TRIPWIRE'S CEILING CONJUNCT.
///
/// @notice `_requireNotStarved` reverts `DelegationCallStarved` only when
///         `_left < gasBefore_ / 63 && gasBefore_ - _left < DELEGATION_GAS_CEILING`.
///         The second conjunct says: a module that consumed the WHOLE ceiling
///         is at fault, so refusing the holder would only trap principal.
///         Removing it changes behaviour only in a window of about 2,500 gas
///         of transaction gas, which coarse starvation sweeps cannot resolve.
///
/// @dev    With `K08GasEaterRead` installed (its `delegation()` burns its whole
///         allowance), `enableAutoRelock` reverts `DelegationCallStarved`
///         below a sharp threshold `T_full` and is tolerated above it. The
///         bounded calibrator gives `T_cal` through the SAME entry point on the
///         SAME position, so the pre-guard cost cancels in
///         `DELTA = T_full - T_cal` (it is insensitive to pre-guard work, not
///         to `CAL_K` or to the guard site's own try/catch, both pinned here).
///         Removing the ceiling conjunct raises DELTA by about 2,548 gas.
///
///         Every probe is wrapped in `snapshotState`/`revertToState`, which
///         rolls storage back, so the reachability counters live in a
///         `memory` struct passed through the helpers. Both outcome classes
///         must be observed more than 4 times.
contract Q38Ceiling is J11Base {
    /// @dev `VeHemi.DELEGATION_GAS_CEILING` is `private`, so it is restated.
    ///      If the source constant moves, this detector must be RE-PINNED.
    uint256 internal constant CEIL = 8_000_000;

    /// @dev the calibrator's bounded burn. DELTA depends on it; it is pinned.
    uint256 internal constant CAL_K = 7_000_000;

    /// @dev *** THE PINNED BOUND ***, between the two measured values:
    ///        ceiling present : DELTA = 1,028,251 on this build (margin 1,295)
    ///        ceiling dropped : DELTA about 2,548 higher
    uint256 internal constant DELTA_MAX = 1_029_546;

    error DelegationCallStarved();

    /// @dev reachability, accumulated in memory-safe locals via the returns.
    struct Obs { uint256 starved; uint256 tolerated; }

    function _install(address m_) internal {
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(m_));
    }

    /// @dev true IFF the call reverted with `DelegationCallStarved()`.
    ///      An OOG (empty returndata) and a success are BOTH "not starved":
    ///      the classification is by SELECTOR, never by "it reverted".
    function _starved(address who_, bytes memory d_, uint256 g_, Obs memory o_)
        internal
        returns (bool s)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(who_);
        (bool ok, bytes memory ret) = address(veHemi).call{gas: g_}(d_);
        vm.revertToState(snap);
        if (ok || ret.length < 4) { s = false; }
        else {
            bytes4 sel;
            assembly { sel := mload(add(ret, 0x20)) }
            s = (sel == DelegationCallStarved.selector);
        }
        if (s) ++o_.starved; else ++o_.tolerated;
    }

    /// @dev the LARGEST budget that still starves, bisected to ONE gas unit.
    function _threshold(address who_, bytes memory d_, uint256 lo_, uint256 hi_, Obs memory o_)
        internal
        returns (uint256)
    {
        assertTrue(
            _starved(who_, d_, lo_, o_),
            "bracket LOW does not starve -- the starvation tripwire never fires. "
            "Either the bracket no longer fits the contract's gas costs or the "
            "tripwire itself is disarmed."
        );
        assertFalse(
            _starved(who_, d_, hi_, o_),
            "bracket HIGH still starves -- the tripwire never releases. "
            "Either the bracket no longer fits the contract's gas costs or the "
            "guard has been widened."
        );
        while (hi_ - lo_ > 1) {
            uint256 mid = lo_ + (hi_ - lo_) / 2;
            if (_starved(who_, d_, mid, o_)) lo_ = mid; else hi_ = mid;
        }
        return lo_;
    }

    // ====================================================================
    // THE DETECTOR
    // ====================================================================

    /// @notice The starved region is bounded by the ABSOLUTE CEILING, not by
    ///         the 63/64 ratio alone.
    function test_Q38_K08FIX7_ceilingBoundsTheStarvedRegion() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        bytes memory data = abi.encodeWithSignature("enableAutoRelock(uint256)", id);
        Obs memory o = Obs(0, 0);

        // (a) the CALIBRATOR — bounded burn, ceiling conjunct always TRUE,
        //     so its threshold does not move if the conjunct is removed.
        _install(address(new Q38FixedEater(CAL_K)));
        uint256 tCal = _threshold(victim, data, (CAL_K * 102) / 100, (CAL_K * 125) / 100, o);

        // (b) the UNBOUNDED eater — consumes the WHOLE stipend, so above the
        //     band's floor the ceiling conjunct is FALSE.
        _install(address(new K08GasEaterRead()));
        uint256 tFull = _threshold(victim, data, 7_800_000, 9_000_000, o);

        emit log_named_uint("T_cal  (bounded burn)", tCal);
        emit log_named_uint("T_full (ceiling burn)", tFull);
        emit log_named_uint("DELTA  (T_full - T_cal)", tFull - tCal);
        emit log_named_uint("starved observations", o.starved);
        emit log_named_uint("tolerated observations", o.tolerated);

        // NON-VACUITY: both outcome classes observed, and both bisections ran.
        assertGt(o.starved, 4, "VACUOUS: the STARVED branch was never observed");
        assertGt(o.tolerated, 4, "VACUOUS: the TOLERATED branch was never observed");
        assertGt(tFull, tCal, "T_full must exceed T_cal -- the two probes are not ordered");

        assertLe(
            tFull - tCal,
            DELTA_MAX,
            "the starvation threshold for a module "
            "that eats the WHOLE DELEGATION_GAS_CEILING has moved UP relative to a module that "
            "eats a BOUNDED amount. `_requireNotStarved`'s `gasBefore_ - _left < "
            "DELEGATION_GAS_CEILING` conjunct is no longer bounding the starved region -- "
            "THE CEILING IS DISARMED. A holder behind an exhausting module is then REFUSED "
            "in a ~2,548-gas window where the shipped contract lets them through, and the "
            "guarantee that a holder escapes by sending more gas is narrowed. "
            "If DELEGATION_GAS_CEILING or CAL_K changed, RE-PIN DELTA_MAX; do not widen it."
        );
    }

    /// @notice The semantic half: one gas unit above the threshold the call
    ///         does not merely stop reverting, it COMMITS — having paid the
    ///         whole ceiling inside the module. That is the ceiling conjunct's
    ///         own rationale ("refusing would only trap principal") stated as a
    ///         test.
    function test_Q38_K08FIX7_toleratedBranchCommitsAfterTheModuleAteTheCeiling() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        bytes memory data = abi.encodeWithSignature("enableAutoRelock(uint256)", id);
        Obs memory o = Obs(0, 0);

        _install(address(new K08GasEaterRead()));
        uint256 t = _threshold(victim, data, 7_800_000, 9_000_000, o);

        uint256 cells;
        assertTrue(_starved(victim, data, t, o), "the threshold itself is not starved");
        ++cells;

        uint256 g0 = gasleft();
        vm.prank(victim);
        (bool ok, ) = address(veHemi).call{gas: t + 1}(data);
        uint256 used = g0 - gasleft();
        ++cells;

        emit log_named_uint("threshold", t);
        emit log_named_uint("gas used at threshold+1", used);
        emit log_named_uint("autoRelockRemaining after", veHemi.autoRelockRemaining(id));
        emit log_named_uint("cells", cells);

        assertEq(cells, 2, "VACUOUS: neither side of the transition was executed");
        assertGt(o.starved, 4, "VACUOUS: the STARVED branch was never observed");
        assertTrue(ok, "one gas above the starvation threshold the call still fails");
        assertGt(
            veHemi.autoRelockRemaining(id),
            0,
            "the tolerated branch did not COMMIT -- the holder is still trapped "
            "behind the exhausting module, which is the trap the ceiling conjunct exists to avoid"
        );
        assertGe(
            used,
            CEIL,
            "the tolerated transaction did not pay DELEGATION_GAS_CEILING, so it "
            "is not the branch under test -- the module did not eat its whole allowance"
        );
    }
}

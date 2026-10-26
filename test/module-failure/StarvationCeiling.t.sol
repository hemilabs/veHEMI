// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "./BrokenModules.sol";

/// @dev THE CALIBRATOR. Burns EXACTLY `burnGas` gas inside `delegation()`
///      and then reverts cheaply. Its consumption is BOUNDED and, for
///      `burnGas` comfortably below `DELEGATION_GAS_CEILING`,
///      `gasBefore_ - _left < DELEGATION_GAS_CEILING` is always TRUE for it,
///      so its starvation threshold is the PURE 63/64 RATIO boundary,
///      independent of the ceiling conjunct.
contract FixedGasEater is BrokenModuleBase {
    uint256 public immutable burnGas;
    constructor(uint256 burnGas_) { burnGas = burnGas_; }
    function delegate(uint256, address) external override {}
    function delegation(uint256) external view override returns (Delegation memory) {
        uint256 gasAtEntry = gasleft();
        uint256 x = 1;
        while (gasAtEntry - gasleft() < burnGas) { x = uint256(keccak256(abi.encode(x))); }
        revert("fixed eater");
    }
}

/// @title  THE CEILING TEST: the starvation tripwire's ceiling conjunct.
///
/// @notice `_requireNotStarved` reverts `DelegationCallStarved` only when
///         `_left < gasBefore_ / 63 && gasBefore_ - _left < DELEGATION_GAS_CEILING`.
///         The second conjunct says: a module that consumed the WHOLE ceiling
///         is at fault, so refusing the holder would only trap principal.
///         Removing it changes behaviour only in a window of about 2,500 gas
///         of transaction gas, which coarse starvation sweeps cannot resolve.
///
/// @dev    With `GasEaterReadModule` installed (its `delegation()` burns its
///         whole allowance), `enableAutoRelock` reverts `DelegationCallStarved`
///         below a sharp threshold `T_full` and is tolerated above it. The
///         bounded calibrator gives `T_cal` through the SAME entry point on the
///         SAME position, so the pre-guard cost cancels in
///         `DELTA = T_full - T_cal` (it is insensitive to pre-guard work, not
///         to `CALIBRATOR_BURN_GAS` or to the guard site's own try/catch,
///         both held constant here).
///         Removing the ceiling conjunct raises DELTA by about 2,548 gas.
///
///         Every probe is wrapped in `snapshotState`/`revertToState`, which
///         rolls storage back, so the reachability counters live in a
///         `memory` struct passed through the helpers. Both outcome classes
///         must be observed more than 4 times.
contract StarvationCeilingTest is AutoRelockTestBase {
    /// @dev `VeHemi.DELEGATION_GAS_CEILING` is `private`, so it is restated.
    ///      If the source constant moves, restate it and re-measure DELTA_MAX.
    uint256 internal constant DELEGATION_GAS_CEILING = 8_000_000;

    /// @dev the calibrator's bounded burn. DELTA depends on it; it is held constant.
    uint256 internal constant CALIBRATOR_BURN_GAS = 7_000_000;

    /// @dev *** THE BOUND ***, between the two measured values:
    ///        ceiling present : DELTA = 1,028,251 on this build (margin 1,295)
    ///        ceiling dropped : DELTA about 2,548 higher
    uint256 internal constant DELTA_MAX = 1_029_546;

    error DelegationCallStarved();

    /// @dev reachability, accumulated in memory-safe locals via the returns.
    struct Observations { uint256 starved; uint256 tolerated; }

    function _install(address m_) internal {
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(m_));
    }

    /// @dev true IFF the call reverted with `DelegationCallStarved()`.
    ///      An OOG (empty returndata) and a success are BOTH "not starved":
    ///      the classification is by SELECTOR, never by "it reverted".
    function _starved(address who_, bytes memory data_, uint256 gasLimit_, Observations memory observations_)
        internal
        returns (bool starved)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(who_);
        (bool ok, bytes memory ret) = address(veHemi).call{gas: gasLimit_}(data_);
        vm.revertToState(snap);
        if (ok || ret.length < 4) { starved = false; }
        else {
            bytes4 selector;
            assembly { selector := mload(add(ret, 0x20)) }
            starved = (selector == DelegationCallStarved.selector);
        }
        if (starved) ++observations_.starved; else ++observations_.tolerated;
    }

    /// @dev the LARGEST budget that still starves, bisected to ONE gas unit.
    function _threshold(address who_, bytes memory data_, uint256 lo_, uint256 hi_, Observations memory observations_)
        internal
        returns (uint256)
    {
        assertTrue(
            _starved(who_, data_, lo_, observations_),
            "bracket LOW does not starve -- the starvation tripwire never fires. "
            "Either the bracket no longer fits the contract's gas costs or the "
            "tripwire itself has been removed."
        );
        assertFalse(
            _starved(who_, data_, hi_, observations_),
            "bracket HIGH still starves -- the tripwire never releases. "
            "Either the bracket no longer fits the contract's gas costs or the "
            "guard has been widened."
        );
        while (hi_ - lo_ > 1) {
            uint256 mid = lo_ + (hi_ - lo_) / 2;
            if (_starved(who_, data_, mid, observations_)) lo_ = mid; else hi_ = mid;
        }
        return lo_;
    }

    // ====================================================================
    // THE CEILING TEST
    // ====================================================================

    /// @notice The starved region is bounded by the ABSOLUTE CEILING, not by
    ///         the 63/64 ratio alone.
    function test_ceilingBoundsTheStarvedRegion() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        bytes memory data = abi.encodeWithSignature("enableAutoRelock(uint256)", id);
        Observations memory observations = Observations(0, 0);

        // (a) the CALIBRATOR — bounded burn, ceiling conjunct always TRUE,
        //     so its threshold does not move if the conjunct is removed.
        _install(address(new FixedGasEater(CALIBRATOR_BURN_GAS)));
        uint256 tCal = _threshold(
            victim, data, (CALIBRATOR_BURN_GAS * 102) / 100, (CALIBRATOR_BURN_GAS * 125) / 100, observations
        );

        // (b) the UNBOUNDED eater — consumes the WHOLE stipend, so above the
        //     band's floor the ceiling conjunct is FALSE.
        _install(address(new GasEaterReadModule()));
        uint256 tFull = _threshold(victim, data, 7_800_000, 9_000_000, observations);

        emit log_named_uint("T_cal  (bounded burn)", tCal);
        emit log_named_uint("T_full (ceiling burn)", tFull);
        emit log_named_uint("DELTA  (T_full - T_cal)", tFull - tCal);
        emit log_named_uint("starved observations", observations.starved);
        emit log_named_uint("tolerated observations", observations.tolerated);

        // NON-VACUITY: both outcome classes observed, and both bisections ran.
        assertGt(observations.starved, 4, "VACUOUS: the STARVED branch was never observed");
        assertGt(observations.tolerated, 4, "VACUOUS: the TOLERATED branch was never observed");
        assertGt(tFull, tCal, "T_full must exceed T_cal -- the two probes are not ordered");

        assertLe(
            tFull - tCal,
            DELTA_MAX,
            "the starvation threshold for a module "
            "that eats the WHOLE DELEGATION_GAS_CEILING has moved UP relative to a module that "
            "eats a BOUNDED amount. `_requireNotStarved`'s `gasBefore_ - _left < "
            "DELEGATION_GAS_CEILING` conjunct is no longer bounding the starved region -- "
            "THE CEILING CONJUNCT IS GONE. A holder behind an exhausting module is then REFUSED "
            "in a ~2,548-gas window where the implemented contract lets them through, and the "
            "guarantee that a holder escapes by sending more gas is narrowed. "
            "If DELEGATION_GAS_CEILING or CALIBRATOR_BURN_GAS changed, re-measure DELTA_MAX; do not widen it."
        );
    }

    /// @notice The semantic half: one gas unit above the threshold the call
    ///         does not merely stop reverting, it COMMITS — having paid the
    ///         whole ceiling inside the module. That is the ceiling conjunct's
    ///         own rationale ("refusing would only trap principal") stated as a
    ///         test.
    function test_toleratedBranchCommitsAfterTheModuleAteTheCeiling() public {
        (uint256 id, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        bytes memory data = abi.encodeWithSignature("enableAutoRelock(uint256)", id);
        Observations memory observations = Observations(0, 0);

        _install(address(new GasEaterReadModule()));
        uint256 threshold = _threshold(victim, data, 7_800_000, 9_000_000, observations);

        uint256 sidesExecuted;
        assertTrue(_starved(victim, data, threshold, observations), "the threshold itself is not starved");
        ++sidesExecuted;

        uint256 gasBefore = gasleft();
        vm.prank(victim);
        (bool ok, ) = address(veHemi).call{gas: threshold + 1}(data);
        uint256 used = gasBefore - gasleft();
        ++sidesExecuted;

        emit log_named_uint("threshold", threshold);
        emit log_named_uint("gas used at threshold+1", used);
        emit log_named_uint("autoRelockRemaining after", veHemi.autoRelockRemaining(id));
        emit log_named_uint("sides executed", sidesExecuted);

        assertEq(sidesExecuted, 2, "VACUOUS: neither side of the transition was executed");
        assertGt(observations.starved, 4, "VACUOUS: the STARVED branch was never observed");
        assertTrue(ok, "one gas above the starvation threshold the call still fails");
        assertGt(
            veHemi.autoRelockRemaining(id),
            0,
            "the tolerated branch did not COMMIT -- the holder is still trapped "
            "behind the exhausting module, which is the trap the ceiling conjunct exists to avoid"
        );
        assertGe(
            used,
            DELEGATION_GAS_CEILING,
            "the tolerated transaction did not pay DELEGATION_GAS_CEILING, so it "
            "is not the branch under test -- the module did not eat its whole allowance"
        );
    }
}

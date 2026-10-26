// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/**
 * @title THE GOVERNANCE DENOMINATOR LAW, DIRECTED MATRIX
 *
 * @notice  SAFETY (one-sided):
 *              for every past instant `t` and every set `D` of DISTINCT addresses,
 *                  sum_{d in D} getPastVotes(d, t)  <=  getPastTotalSupply(t)
 *
 *          The inequality is one-sided BY DESIGN, and the design is stated in
 *          the source: `getPastTotalSupply`'s own NatSpec
 *          (VeHemiVoteDelegation.sol) says
 *
 *              "This value is the sum of all available votes, which is not
 *               necessarily the sum of all delegated votes. Votes that have not
 *               been delegated are still part of total supply, even though they
 *               would not participate in a vote."
 *
 *          i.e. the ERC20Votes convention. Equality is therefore NOT a law of
 *          the system; it is only a law of the fully-delegated world.
 *
 *          TIGHTNESS (the all-delegated case):
 *              when every live position at `t` is delegated, the residual
 *                  residual(t) = getPastTotalSupply(t) - sum_d getPastVotes(d, t)
 *              must be at most ONE SECOND of the escrow's own aggregate decay:
 *                  residual(t) <= veHemi.totalVeHemiSupplyAt(t-1)
 *                                 - veHemi.totalVeHemiSupplyAt(t)
 *              SAFETY can never see a denominator that is too LARGE. TIGHTNESS
 *              can.
 *
 * @dev     WHY THE MATRIX AND NOT ONLY AN INVARIANT. The interesting instants
 *          are defined RELATIVE TO THE SUBJECT LOCK'S OWN `end` — never
 *          relative to the hour grid or the SIX_DAYS grid. In a lock's final
 *          `((end - 1) mod 3600) + 1` seconds the next hour boundary `H` is at
 *          or after `end`, and both contracts handle a write differently there
 *          (VeHemi skips an unarmed delegation update; the module's checkpoint
 *          legs change). A campaign that samples phases off the hour/SIX_DAYS
 *          grids is STRUCTURALLY unable to land there.
 *
 *          A separate body pins the documented near-expiry skip of
 *          `increaseAmount`.
 */
contract DenominatorLawMatrixTest is Test {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    MockERC20 internal hemi;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant SIX_DAYS = YEAR / 60;
    uint256 internal constant AMT = 1_000_000e18;
    bytes32 internal constant TOPIC_DELEGATION_UPDATE_SKIPPED = keccak256("DelegationUpdateSkipped(uint256)");

    // entry points
    uint256 internal constant EP_CREATE = 0;
    uint256 internal constant EP_INCREASE_AMOUNT = 1;
    uint256 internal constant EP_INCREASE_UNLOCK_TIME = 2;
    uint256 internal constant EP_WITHDRAW = 3;
    uint256 internal constant EP_FORFEIT = 4;
    uint256 internal constant EP_TRANSFER = 5;
    uint256 internal constant EP_ENABLE = 6;
    uint256 internal constant EP_DISABLE = 7;
    uint256 internal constant EP_RETIRE = 8;
    uint256 internal constant ENTRY_POINT_COUNT = 9;

    // phases, ALL defined against the subject lock's own `end`
    uint256 internal constant PH_MIDLIFE = 0;
    uint256 internal constant PH_SIXDAYS = 1; // tau on the SIX_DAYS grid
    uint256 internal constant PH_FINAL_HOUR = 2; // H(tau) <  end  (immediate branch)
    uint256 internal constant PH_NEAR_EXPIRY = 3; // H(tau) >= end  (near-expiry branch)
    uint256 internal constant PHASE_COUNT = 4;

    // ---- aggregate ledger -------------------------------------------------
    uint256 internal cellsExecuted;
    uint256 internal cellsSkipped;
    uint256 internal instantsCompared;
    uint256 internal deferralCells;
    uint256 internal deferralInstants;
    uint256 internal violatingCells;
    uint256 internal violatingInstants;
    int256 internal worstOverall;
    uint256 internal tightnessInstants;
    uint256 internal tightnessViolatingInstants;
    int256 internal tightnessWorst;

    /// @dev Non-vacuity floors. A matrix that skips every interesting cell is
    ///      worth nothing; these make that outcome RED instead of green.
    bool internal checkSafety = true;
    bool internal checkTightness = true;
    uint256 internal firstEntryPoint;
    uint256 internal entryPointEnd = ENTRY_POINT_COUNT;
    /// @dev The `increaseAmount` cell in the near-expiry branch is excluded
    ///      from TIGHTNESS: VeHemi does not forward that update (the documented
    ///      `DelegationUpdateSkipped` behaviour), so the denominator carries
    ///      the added weight and the delegatee does not. Pinned by
    ///      `test_nearExpiryIncreaseAmountIsNotForwarded`.
    bool internal excludeNearExpiryIncrease = true;

    uint256 internal constant MIN_CELLS = 20;
    uint256 internal constant MIN_DEFERRAL_CELLS = 5;
    uint256 internal constant MIN_DEFERRAL_INSTANTS = 200;
    uint256 internal constant MIN_INSTANTS = 3000;

    /// @dev A FRESH world per cell. Deliberately NOT `vm.snapshotState` /
    ///      `vm.revertToState`: the revert also rolls back THIS contract's
    ///      ledger, so a snapshot-driven matrix reports `cellsExecuted == 0`
    ///      and every non-vacuity floor becomes unfalsifiable.
    function _freshWorld() internal {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, owner));
        veHemi = VeHemi(address(proxy));
        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(owner);
    }

    function setUp() public {
        vm.warp(100 * SIX_DAYS + 1800);
        _freshWorld();
    }

    // ---------------------------------------------------------------- utils
    function _nextHourBoundary(uint256 t) internal pure returns (uint256) {
        return (t / 3600) * 3600 + 3600;
    }

    function _mk(address to, uint256 dur, bool transferable_, bool forfeitable_) internal returns (uint256 id) {
        hemi.mint(owner, AMT);
        hemi.approve(address(veHemi), AMT);
        if (transferable_) {
            id = veHemi.createLockFor(AMT, dur, to, true, false);
        } else {
            id = veHemi.createLockFor(AMT, dur, to, false, forfeitable_);
        }
    }

    function _votes(uint256 t) internal view returns (uint256 v) {
        // The delegate universe of this fixture. DISTINCT by construction.
        v = delegation.getPastVotes(alice, t) + delegation.getPastVotes(bob, t) + delegation.getPastVotes(carol, t);
    }

    /// @dev One sampled instant. Returns the SAFETY excess `votes - supply`
    ///      (positive == VIOLATION).
    function _checkSafetyAt(uint256 t) internal returns (int256 excess) {
        uint256 supply = delegation.getPastTotalSupply(t);
        uint256 votes = _votes(t);
        excess = int256(votes) - int256(supply);
        unchecked {
            instantsCompared += 1;
        }
        if (excess > 0) {
            unchecked {
                violatingInstants += 1;
            }
            if (excess > worstOverall) worstOverall = excess;
        }
    }

    /// @dev TIGHTNESS. Only meaningful when every live position is delegated; the
    ///      caller asserts that precondition. The bound is ONE SECOND of the
    ///      escrow's own aggregate decay, so it never references
    ///      `getPastTotalSupply`'s internal time base, measured as the largest
    ///      one-second DROP of `totalVeHemiSupplyAt` in the three seconds
    ///      ending at `t`.
    ///
    ///      WHY A MAX AND NOT `E(t-1) - E(t)`. At an instant where the escrow
    ///      curve JUMPS UP (`createLock`, `increaseAmount`) that single
    ///      difference is negative and the bound collapses to 0, so a correct
    ///      implementation would report a spurious violation at `t == tau`.
    ///      Widening to the nearest clean second in the three preceding it
    ///      removes those and leaves real residuals untouched.
    function _tightnessBound(uint256 t) internal view returns (uint256 bound) {
        uint256 e0 = veHemi.totalVeHemiSupplyAt(t);
        uint256 e1 = veHemi.totalVeHemiSupplyAt(t - 1);
        uint256 e2 = veHemi.totalVeHemiSupplyAt(t - 2);
        uint256 e3 = veHemi.totalVeHemiSupplyAt(t - 3);
        if (e1 > e0) bound = e1 - e0;
        if (e2 > e1 && e2 - e1 > bound) bound = e2 - e1;
        if (e3 > e2 && e3 - e2 > bound) bound = e3 - e2;
    }

    function _checkTightnessAt(uint256 t) internal {
        if (t < 4) return;
        uint256 supply = delegation.getPastTotalSupply(t);
        uint256 votes = _votes(t);
        if (supply < votes) return; // that is SAFETY's business, not TIGHTNESS's
        uint256 residual = supply - votes;
        uint256 bound = _tightnessBound(t);
        unchecked {
            tightnessInstants += 1;
        }
        if (residual > bound) {
            unchecked {
                tightnessViolatingInstants += 1;
            }
            int256 over = int256(residual - bound);
            if (over > tightnessWorst) tightnessWorst = over;
        }
    }

    /// @dev The instant set for one cell: dense around `tau`, dense around
    ///      `end`, and a coarse stride across `[tau, end]` when the window is
    ///      long. `{tau-1, tau, tau+1, ..., end+1}` made tractable.
    function _scanCell(uint256 tau, uint256 end, bool allDelegated, string memory tag)
        internal
        returns (uint256 positives, int256 worst)
    {
        uint256 lo = tau >= 2 ? tau - 2 : 1;
        uint256 hi = end + 1;
        if (hi > block.timestamp) hi = block.timestamp;

        uint256 violatingBefore = violatingInstants;
        int256 worstBefore = worstOverall;

        // dense head: [tau-2, tau+180]
        uint256 headHi = tau + 180;
        if (headHi > hi) headHi = hi;
        for (uint256 t = lo; t <= headHi; ++t) {
            if (checkSafety) _checkSafetyAt(t);
            if (allDelegated && checkTightness) _checkTightnessAt(t);
        }
        // dense tail: [end-180, end+1]
        uint256 tailLo = end >= 180 ? end - 180 : 1;
        if (tailLo < headHi + 1) tailLo = headHi + 1;
        for (uint256 t = tailLo; t <= hi; ++t) {
            if (checkSafety) _checkSafetyAt(t);
            if (allDelegated && checkTightness) _checkTightnessAt(t);
        }
        // coarse stride across the interior
        if (tailLo > headHi + 1) {
            uint256 span = tailLo - headHi - 1;
            uint256 stride = span / 64;
            if (stride == 0) stride = 1;
            for (uint256 t = headHi + 1; t < tailLo; t += stride) {
                if (checkSafety) _checkSafetyAt(t);
                if (allDelegated && checkTightness) _checkTightnessAt(t);
            }
        }

        positives = violatingInstants - violatingBefore;
        worst = worstOverall > worstBefore ? worstOverall : int256(0);
        if (positives > 0) {
            emit log_named_uint(string.concat("  VIOLATION ", tag, " instants"), positives);
            emit log_named_int(string.concat("  VIOLATION ", tag, " worst(wei)"), worstOverall);
        }
    }

    // ------------------------------------------------------------- the grid
    /// @dev The subject lock's `end` for the given phase, and the instant
    ///      `tau` at which the entry point is invoked. `deferral` records
    ///      whether `H(tau) >= end`, i.e. the near-expiry branch.
    function _tauFor(uint256 phase, uint256 end) internal pure returns (uint256 tau, bool deferral) {
        if (phase == PH_MIDLIFE) {
            tau = end - 2 * SIX_DAYS;
        } else if (phase == PH_SIXDAYS) {
            tau = end - SIX_DAYS; // `end` is SIX_DAYS-aligned, so this is too
        } else if (phase == PH_FINAL_HOUR) {
            uint256 endHourStart = (end / 3600) * 3600;
            tau = endHourStart >= 60 ? endHourStart - 60 : 0; // H(tau) == endHourStart < end  when end % 3600 != 0
        } else {
            // THE NEAR-EXPIRY WINDOW, entered at its EARLIEST instant so the
            // `[tau, end]` over-count window is as WIDE as the branch allows:
            // `H(tau) >= end` holds for every `tau >= floor(end/3600)*3600`,
            // and the window is `end % 3600` seconds long (a multiple of
            // 360 s for a SIX_DAYS-aligned `end`: SIX_DAYS mod 3600 = 360).
            uint256 endHourStart = (end / 3600) * 3600;
            tau = endHourStart < end ? endHourStart : end - 3600;
        }
        deferral = tau < end && _nextHourBoundary(tau) >= end;
    }

    function _epName(uint256 ep) internal pure returns (string memory) {
        if (ep == EP_CREATE) return "createLock";
        if (ep == EP_INCREASE_AMOUNT) return "increaseAmount";
        if (ep == EP_INCREASE_UNLOCK_TIME) return "increaseUnlockTime";
        if (ep == EP_WITHDRAW) return "withdraw";
        if (ep == EP_FORFEIT) return "forfeit";
        if (ep == EP_TRANSFER) return "transferFrom";
        if (ep == EP_ENABLE) return "enableAutoRelock";
        if (ep == EP_DISABLE) return "disableAutoRelock";
        return "retireStaleAutoRelock";
    }

    function _phName(uint256 ph) internal pure returns (string memory) {
        if (ph == PH_MIDLIFE) return "midlife";
        if (ph == PH_SIXDAYS) return "sixdays";
        if (ph == PH_FINAL_HOUR) return "finalhour";
        return "nearexpiry";
    }

    // ------------------------------------------------------------ the cells
    function _runCell(uint256 ep, uint256 phase) internal {
        string memory tag = string.concat(_epName(ep), "/", _phName(phase));

        _freshWorld();

        // Everything except the forfeit family is TRANSFERABLE: a
        // non-transferable position has `transferableAfter > now`, which
        // `enableAutoRelock` refuses (`SeedingNotFinalized`) while
        // `lockedSeedingFinalized` is false, and `transferFrom` refuses
        // outright. The flat family needs the remaining term
        // `enableAutoRelock` stores in `autoRelockRemaining` (whole SIX_DAYS
        // buckets from grid(now) to `end`) >= 2*SIX_DAYS at the enable
        // instant, hence the longer duration.
        uint256 id = _mk(
            alice,
            (ep == EP_ENABLE || ep == EP_DISABLE || ep == EP_RETIRE) ? 8 * SIX_DAYS : 4 * SIX_DAYS,
            ep != EP_FORFEIT,
            ep == EP_FORFEIT
        );
        uint256 end = veHemi.getLockedBalance(id).end;

        (uint256 tau, bool deferral) = _tauFor(phase, end);
        if (ep == EP_WITHDRAW) {
            // `withdraw` is legal only at/after `end`; the phase selects how
            // far after, so the earliest phase IS the instant `end` itself.
            if (phase == PH_NEAR_EXPIRY) tau = end;
            else if (phase == PH_FINAL_HOUR) tau = end + 1800;
            else if (phase == PH_SIXDAYS) tau = end + SIX_DAYS;
            else tau = end + 2 * SIX_DAYS;
            deferral = false;
        }
        if (tau <= block.timestamp) {
            unchecked {
                cellsSkipped += 1;
            }
            emit log_named_string("SKIP (tau in the past)", tag);
            return;
        }

        bool ok;
        uint256 endForScan = end;

        if (ep == EP_ENABLE || ep == EP_DISABLE || ep == EP_RETIRE) {
            // The flat family. `enableAutoRelock` needs the remaining term it
            // stores in `autoRelockRemaining` to be >= 2*SIX_DAYS, so the
            // ENABLE cell's own phase is the phase of the enable; the
            // DISABLE/RETIRE cells enable at mid-life first and then act at
            // the phase instant, where the stored `end` is already in the
            // past -- `H >= end` holds trivially, which is why this family is
            // in the near-expiry branch for every phase.
            if (ep == EP_ENABLE) {
                vm.warp(tau);
                vm.prank(alice);
                (ok,) = address(veHemi).call(abi.encodeWithSignature("enableAutoRelock(uint256)", id));
            } else {
                vm.warp(end - 6 * SIX_DAYS);
                vm.prank(alice);
                (ok,) = address(veHemi).call(abi.encodeWithSignature("enableAutoRelock(uint256)", id));
                if (!ok) {
                    unchecked {
                        cellsSkipped += 1;
                    }
                    emit log_named_string("SKIP (enable refused)", tag);
                    return;
                }
                uint256 actAt = tau;
                if (ep == EP_RETIRE) {
                    (bool staleAtOk, bytes memory staleAtReturn) =
                        address(veHemi).staticcall(abi.encodeWithSignature("autoRelockStaleAt(uint256)", id));
                    if (!staleAtOk) {
                        unchecked {
                            cellsSkipped += 1;
                        }
                        emit log_named_string("SKIP (no staleAt)", tag);
                        return;
                    }
                    uint256 staleAt = abi.decode(staleAtReturn, (uint256));
                    if (actAt < staleAt) actAt = staleAt;
                }
                if (actAt <= block.timestamp) actAt = block.timestamp + 1;
                vm.warp(actAt);
                tau = actAt;
                deferral = tau < end && _nextHourBoundary(tau) >= end;
                if (ep == EP_DISABLE) {
                    vm.prank(alice);
                    (ok,) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
                } else {
                    vm.prank(carol); // permissionless
                    (ok,) = address(veHemi).call(abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id));
                }
                endForScan = tau + 3600; // the flat family's window is around tau
            }
        } else if (ep == EP_CREATE) {
            vm.warp(tau);
            hemi.mint(owner, AMT);
            hemi.approve(address(veHemi), AMT);
            (ok,) = address(veHemi).call(
                abi.encodeWithSignature("createLockFor(uint256,uint256,address,bool,bool)", AMT, 4 * SIX_DAYS, bob, true, false)
            );
        } else if (ep == EP_INCREASE_AMOUNT) {
            vm.warp(tau);
            hemi.mint(alice, AMT);
            vm.prank(alice);
            hemi.approve(address(veHemi), AMT);
            vm.prank(alice);
            (ok,) = address(veHemi).call(abi.encodeWithSignature("increaseAmount(uint256,uint256)", id, AMT));
        } else if (ep == EP_INCREASE_UNLOCK_TIME) {
            vm.warp(tau);
            vm.prank(alice);
            (ok,) = address(veHemi).call(abi.encodeWithSignature("increaseUnlockTime(uint256,uint256)", id, 60 * SIX_DAYS));
        } else if (ep == EP_WITHDRAW) {
            vm.warp(tau);
            vm.prank(alice);
            (ok,) = address(veHemi).call(abi.encodeWithSignature("withdraw(uint256)", id));
            endForScan = tau + 3600;
        } else if (ep == EP_FORFEIT) {
            vm.warp(tau);
            (ok,) = address(veHemi).call(abi.encodeWithSignature("forfeit(uint256)", id));
        } else {
            vm.warp(tau);
            vm.prank(alice);
            (ok,) = address(veHemi).call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, id)
            );
        }

        if (!ok) {
            unchecked {
                cellsSkipped += 1;
            }
            emit log_named_string("SKIP (entry point reverted)", tag);
            return;
        }

        unchecked {
            cellsExecuted += 1;
        }
        if (deferral) {
            unchecked {
                deferralCells += 1;
            }
        }

        // Every position in this fixture is delegated (VeHemi self-delegates at
        // mint and every transfer re-delegates), so TIGHTNESS applies.
        {
            uint256 instantsBefore = instantsCompared;
            vm.warp(_nextHourBoundary(endForScan) + 2 hours);
            // `increaseAmount` inside the near-expiry window is not forwarded
            // to the delegatee (documented; see `excludeNearExpiryIncrease`),
            // so this one cell is excluded from TIGHTNESS here and pinned by
            // its own body below.
            (uint256 violatingInstantsInCell,) =
                _scanCell(tau, endForScan, !(excludeNearExpiryIncrease && ep == EP_INCREASE_AMOUNT && deferral), tag);
            if (deferral) {
                unchecked {
                    deferralInstants += instantsCompared - instantsBefore;
                }
            }
            if (violatingInstantsInCell > 0) {
                unchecked {
                    violatingCells += 1;
                }
            }
        }
    }

    // ------------------------------------------------------------------ run
    function _runRange() internal {
        for (uint256 ep = firstEntryPoint; ep < entryPointEnd; ++ep) {
            for (uint256 ph; ph < PHASE_COUNT; ++ph) {
                _runCell(ep, ph);
            }
        }
    }

    function _reportSafety() internal {
        emit log_named_uint("cells executed           ", cellsExecuted);
        emit log_named_uint("cells skipped            ", cellsSkipped);
        emit log_named_uint("deferral-branch cells    ", deferralCells);
        emit log_named_uint("instants compared        ", instantsCompared);
        emit log_named_uint("deferral instants        ", deferralInstants);
        emit log_named_uint("SAFETY violating cells   ", violatingCells);
        emit log_named_uint("SAFETY violating instants", violatingInstants);
        emit log_named_int("SAFETY worst (wei)       ", worstOverall);
    }

    function _reportTightness() internal {
        emit log_named_uint("TIGHTNESS instants          ", tightnessInstants);
        emit log_named_uint("TIGHTNESS violating instants", tightnessViolatingInstants);
        emit log_named_int("TIGHTNESS worst over (wei)  ", tightnessWorst);
    }

    /// @notice SAFETY over the whole 9 x 4 grid.
    function test_safety_pastVotesSumNeverExceedsPastTotalSupply_matrix() public {
        checkSafety = true;
        checkTightness = false;
        _runRange();
        _reportSafety();

        // --- NON-VACUITY FIRST. A matrix that reached nothing must be RED. ---
        assertGe(cellsExecuted, MIN_CELLS, "VACUOUS: too few matrix cells actually executed");
        assertGe(deferralCells, MIN_DEFERRAL_CELLS, "VACUOUS: the H>=end deferral branch was never entered");
        assertGe(instantsCompared, MIN_INSTANTS, "VACUOUS: too few instants compared");
        assertGe(
            deferralInstants, MIN_DEFERRAL_INSTANTS, "VACUOUS: too few instants sampled inside the deferral branch"
        );

        // --- THE LAW ---
        assertEq(violatingInstants, 0, "SAFETY VIOLATED: sum getPastVotes > getPastTotalSupply");
    }

    /// @notice TIGHTNESS over `createLock .. forfeit`. Split from the rest purely for
    ///         the per-body gas budget (the combined body needs > 2^30 gas,
    ///         the `gas_limit` of the default and ci profiles).
    function test_tightness_allDelegatedResidualIsAtMostOneSecondOfDecay_createThroughForfeit() public {
        checkSafety = false;
        checkTightness = true;
        firstEntryPoint = EP_CREATE;
        entryPointEnd = EP_TRANSFER;
        _runRange();
        _reportTightness();
        assertGe(tightnessInstants, 2000, "VACUOUS: TIGHTNESS createLock..forfeit never evaluated");
        assertEq(
            tightnessViolatingInstants,
            0,
            "TIGHTNESS VIOLATED: the denominator exceeds the delegated votes by more than one second of decay"
        );
    }

    /// @notice TIGHTNESS over `transferFrom .. retireStaleAutoRelock`.
    function test_tightness_allDelegatedResidualIsAtMostOneSecondOfDecay_transferThroughRetire() public {
        checkSafety = false;
        checkTightness = true;
        firstEntryPoint = EP_TRANSFER;
        entryPointEnd = ENTRY_POINT_COUNT;
        _runRange();
        _reportTightness();
        assertGe(tightnessInstants, 2000, "VACUOUS: TIGHTNESS transferFrom..retireStaleAutoRelock never evaluated");
        assertEq(
            tightnessViolatingInstants,
            0,
            "TIGHTNESS VIOLATED: the denominator exceeds the delegated votes by more than one second of decay"
        );
    }

    /// @notice INTENDED BEHAVIOUR (IVeHemi NatSpec): the near-expiry skip of
    ///         `increaseAmount`.
    ///
    ///         An `increaseAmount` on an unarmed position in its final
    ///         `((end - 1) mod 3600) + 1` seconds is NOT forwarded to the
    ///         delegation module: the escrow takes the deposit, VeHemi emits
    ///         `DelegationUpdateSkipped(id)`, and the delegatee's record and
    ///         votes are unchanged (IVeHemi's `DelegationUpdateSkipped`
    ///         NatSpec; the same skip exists on the deployed contract). The
    ///         weight the delegatee does not receive is the added amount's
    ///         remaining decay, bounded by `addedSlope * 3600`, and it is zero
    ///         at `end`.
    function test_nearExpiryIncreaseAmountIsNotForwarded() public {
        _freshWorld();
        uint256 id = _mk(alice, 4 * SIX_DAYS, true, false);
        uint256 end = veHemi.getLockedBalance(id).end;
        uint256 window = ((end - 1) % 3600) + 1;
        uint256 tau = end - window; // the first second of the window
        assertTrue(_nextHourBoundary(tau) >= end, "premise: tau is not in the near-expiry window");
        assertTrue(_nextHourBoundary(tau - 1) < end, "premise: tau is not the first second of the window");
        assertTrue(tau > block.timestamp, "premise: tau in the past");

        vm.warp(tau);
        (address delegateeBefore, , , , ) = delegation.delegations(id);
        assertEq(delegateeBefore, alice, "premise: the position is not self-delegated");
        bytes32 recordBefore = _recordHash(id);
        uint256 votesBefore = delegation.getVotes(alice);

        hemi.mint(alice, AMT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), AMT);
        vm.recordLogs();
        veHemi.increaseAmount(id, AMT);
        vm.stopPrank();

        // (1) The skip is announced, once, for this position, by VeHemi.
        assertEq(_countSkipEvents(vm.getRecordedLogs(), id), 1,
            "the near-expiry increaseAmount did not emit DelegationUpdateSkipped once");
        assertEq(uint256(uint128(veHemi.getLockedBalance(id).amount)), 2 * AMT, "the escrow did not take the deposit");

        // (2) The delegatee is unchanged: same record (delegatee, end, bias,
        //     amount, slope), same votes.
        assertEq(_recordHash(id), recordBefore, "the delegation record changed");
        assertEq(delegation.getVotes(alice), votesBefore, "the delegatee's votes changed");

        // (3) The weight left out is the added amount's remaining decay:
        //     positive inside the window, at most `addedSlope * 3600`, zero at `end`.
        vm.warp(_nextHourBoundary(end) + 2 hours);
        uint256 worstSkippedWeight = _worstSkippedWeight(id, tau + 1, end);
        emit log_named_uint("near-expiry window (s)      ", window);
        emit log_named_uint("worst skipped weight        ", worstSkippedWeight);
        assertGt(worstSkippedWeight, 0, "VACUOUS: no weight was left out -- the update was forwarded");
        assertEq(veHemi.balanceOfNFTAt(id, end), 0, "the escrow weight is not zero at end");
        assertEq(delegation.getPastVotes(alice, end), 0, "the delegatee's weight is not zero at end");
    }

    function _recordHash(uint256 id_) internal view returns (bytes32) {
        (address delegatee, uint48 end, uint96 bias, uint96 amount, uint64 slope) = delegation.delegations(id_);
        return keccak256(abi.encode(delegatee, end, bias, amount, slope));
    }

    function _countSkipEvents(Vm.Log[] memory logs_, uint256 id_) internal view returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == address(veHemi) && logs_[i].topics.length > 1
                    && logs_[i].topics[0] == TOPIC_DELEGATION_UPDATE_SKIPPED
            ) {
                assertEq(uint256(logs_[i].topics[1]), id_, "DelegationUpdateSkipped names another position");
                ++n;
            }
        }
    }

    /// @dev Over `[from_, to_]` (60 s stride): the escrow never holds less than
    ///      the delegatee, and both the escrow gap and the denominator residual
    ///      stay within `addedSlope * 3600` (plus one second of the whole lock's
    ///      decay for the denominator, which may be read one second earlier).
    function _worstSkippedWeight(uint256 id_, uint256 from_, uint256 to_) internal view returns (uint256 worst) {
        uint256 bound = (AMT / (4 * YEAR) + 1) * 3600;
        uint256 oneSecond = (2 * AMT) / (4 * YEAR) + 1;
        for (uint256 t = from_; t <= to_; t += 60) {
            uint256 escrow = veHemi.balanceOfNFTAt(id_, t);
            uint256 votes = delegation.getPastVotes(alice, t);
            assertGe(escrow, votes, "the delegatee holds more than the escrow");
            uint256 gap = escrow - votes;
            if (gap > worst) worst = gap;
            assertLe(gap, bound, "the skipped weight exceeds addedSlope * 3600");
            assertLe(delegation.getPastTotalSupply(t) - votes, bound + oneSecond,
                "the denominator residual exceeds addedSlope * 3600");
        }
    }
}

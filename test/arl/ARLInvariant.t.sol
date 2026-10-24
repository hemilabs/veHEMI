// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ARLHandler} from "./ARLHandler.sol";
import {ARLChecks} from "./ARLChecks.sol";

/**
 * @title ARLInvariantBase
 * @notice Deploys `ARLHandler` and `ARLChecks`, places a non-transferable and
 *         a forfeitable position, runs the seeding flow (enables on
 *         non-transferable positions are refused until it is finalized) and
 *         arms the first position, so every fuzz run starts with live
 *         subcurves and one flat position.
 */
abstract contract ARLInvariantBase is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carl = makeAddr("carl");
    address internal dan = makeAddr("dan");
    address internal earl = makeAddr("earl");

    ARLHandler internal handler;
    ARLChecks internal checks;
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;

    function _setUpCommon() internal {
        handler = new ARLHandler(admin, [alice, bob, carl, dan, earl]);
        checks = new ARLChecks(handler);
        veHemi = handler.veHemi();
        delegation = handler.delegation();

        handler.setActorIdx(0);
        handler.createLockedPosition(500 ether, 730 days);
        handler.setActorIdx(1);
        handler.createForfeitablePosition(300 ether, 500 days);
        handler.clearActor();
        handler.seedNow();
        require(veHemi.lockedSeedingFinalized(), "setup: seeding did not finalize");
        handler.arlEnableRaw(0);

        targetContract(address(handler));
        for (uint256 i; i < 5; ++i) targetSender(handler.users(i));

        // Setup-only entry points are not fuzz actions.
        bytes4[] memory excluded = new bytes4[](4);
        excluded[0] = ARLHandler.setActorIdx.selector;
        excluded[1] = ARLHandler.clearActor.selector;
        excluded[2] = ARLHandler.arlEnableRaw.selector;
        excluded[3] = ARLHandler.seedNow.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}

/**
 * @title ARLInvariantTest
 * @notice The auto-relock invariant suite: every `ARLChecks` law, evaluated after
 *         every handler call in one campaign, plus a coverage floor over the
 *         fuzz-reached paths.
 */
contract ARLInvariantTest is ARLInvariantBase {
    /// @dev Number of runs after which a coverage metric that is still zero
    ///      over the whole campaign fails it. The rarest floored metrics are
    ///      reached in roughly one run in six at depth 64, so 64 runs leave a
    ///      healthy campaign a false-failure chance well below 1e-4.
    uint256 internal constant COVERAGE_WARMUP_RUNS = 64;
    string internal constant COVERAGE_PREFIX = "ARL_INVARIANT_COVERAGE_";

    /// @dev `enables` after setUp (which arms one position); the floor counts
    ///      only enables made by fuzz calls.
    uint256 internal enablesAtSetUp;

    function setUp() public {
        _setUpCommon();
        enablesAtSetUp = handler.enables();
        vm.setEnv(string.concat(COVERAGE_PREFIX, "runs"), "0");
        (string[] memory names,) = _coverage();
        for (uint256 i; i < names.length; ++i) vm.setEnv(string.concat(COVERAGE_PREFIX, names[i]), "0");
    }

    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 64
    function invariant_arl_core() public {
        // weight, supply and primitives against the authored ledger
        checks.checkPerPositionWeightMatchesAuthored();
        checks.checkSupplyEqualsAuthoredSum();
        checks.checkFlatAggregateEqualsAuthoredSum();
        checks.checkPrimitivesMatchAuthoredLedger();
        checks.checkMaintainedEndIsPureFunction();
        checks.checkNonTransferableEqualsAuthoredSum();
        checks.checkForfeitableEqualsAuthoredSum();
        checks.checkBreakdownAgreesWithDedicated();
        checks.checkPastSupplyImmutability();
        // the weight steps, in closed form
        checks.checkEnableStepIsExact();
        checks.checkDisableStepIsExact();
        checks.checkRetireStepIsExact();
        checks.checkExtendWhileFlatIsExact();
        // refusals
        checks.checkFlatIsNeverWithdrawable();
        checks.checkGuardProbesAllRefused();
        checks.checkKeeperProbesAllRefused();
        checks.checkHeartbeatMovesStaleClock();
        checks.checkForfeitWindowIsTA();
        // votes and delegation
        checks.checkVotesNeverExceedSupply();
        checks.checkVotingPowerEquality();
        checks.checkPastVotesNeverExceedPastTotalSupply();
        checks.checkDelegationRefreshNeverSilentlyFails();
        checks.checkFlatPositionsStayDelegated();
        checks.checkTransferAlwaysDisarms();
        checks.checkRecordsRouteToTheChosenDelegate();
        checks.checkVoteHoleBounded();
    }

    /// @dev Paths the laws above depend on, counted by fuzz calls only. Not
    ///      floored: the `R < 2 * SIX_DAYS` enable refusal (`shortREnableProbes`),
    ///      which needs an unarmed lock in its last two buckets and is reached
    ///      only a few times per 128 x 64 campaign.
    function _coverage() internal view returns (string[] memory names, uint256[] memory counts) {
        names = new string[](22);
        counts = new uint256[](22);
        names[0] = "enables";                      counts[0] = handler.enables() - enablesAtSetUp;
        names[1] = "disables";                     counts[1] = handler.disables();
        names[2] = "staleRetires";                 counts[2] = handler.staleRetires();
        names[3] = "arlRefreshes";                 counts[3] = handler.arlRefreshes();
        names[4] = "transferDisarms";              counts[4] = handler.transferDisarms();
        names[5] = "extendWhileFlatAccepted";      counts[5] = handler.extendWhileFlatAccepted();
        names[6] = "flatWithdrawProbes";           counts[6] = handler.flatWithdrawProbes();
        names[7] = "doubleEnableProbes";           counts[7] = handler.doubleEnableProbes();
        names[8] = "disableNotEnabledProbes";      counts[8] = handler.disableNotEnabledProbes();
        names[9] = "extendShorterProbes";          counts[9] = handler.extendShorterProbes();
        names[10] = "refreshStrangerProbes";       counts[10] = handler.refreshStrangerProbes();
        names[11] = "refreshNotEnabledProbes";     counts[11] = handler.refreshNotEnabledProbes();
        names[12] = "staleRetireEarlyProbes";      counts[12] = handler.staleRetireEarlyProbes();
        names[13] = "extendTooLongProbes";         counts[13] = handler.extendTooLongProbes();
        names[14] = "forfeitOutOfWindowProbes";    counts[14] = handler.forfeitOutOfWindowProbes();
        names[15] = "forfeitInWindowFlatProbes";   counts[15] = handler.forfeitInWindowFlatProbes();
        names[16] = "boundaryCheckpoints";         counts[16] = handler.boundaryCheckpoints();
        names[17] = "boundaryEnables";             counts[17] = handler.boundaryEnables();
        names[18] = "boundaryExactEndWithdraws";   counts[18] = handler.boundaryExactEndWithdraws();
        names[19] = "boundaryExactEndTransfers";   counts[19] = handler.boundaryExactEndTransfers();
        names[20] = "expiredCheckpointWrites";     counts[20] = handler.expiredCheckpointWrites();
        names[21] = "delegateRoutesChecked";       counts[21] = handler.delegateRoutesChecked();
    }

    /// @notice Coverage floor. Foundry resets all EVM state (the handler's
    ///         counters included) at every run boundary and calls
    ///         `afterInvariant` once per run, so a per-run `> 0` assertion
    ///         would fail a healthy campaign whenever one run happens not to
    ///         draw an action. The counts are summed across runs in process
    ///         environment variables, which the reset does not touch (this
    ///         contract has one campaign, so nothing else writes them), and
    ///         the campaign fails once `COVERAGE_WARMUP_RUNS` runs have passed
    ///         with some path still never exercised.
    function afterInvariant() public {
        string memory runsKey = string.concat(COVERAGE_PREFIX, "runs");
        uint256 runs = vm.envOr(runsKey, uint256(0)) + 1;
        vm.setEnv(runsKey, vm.toString(runs));
        (string[] memory names, uint256[] memory counts) = _coverage();
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(COVERAGE_PREFIX, names[i]);
            uint256 total = vm.envOr(key, uint256(0)) + counts[i];
            vm.setEnv(key, vm.toString(total));
            if (runs >= COVERAGE_WARMUP_RUNS && total == 0) {
                revert(string.concat(
                    "COVERAGE: ", names[i], " was never exercised in ", vm.toString(runs),
                    " runs - every law that depends on it is vacuous"
                ));
            }
        }
    }
}

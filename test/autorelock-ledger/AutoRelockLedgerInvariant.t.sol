// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AutoRelockLedgerInvariantBase} from "./AutoRelockLedgerInvariantBase.sol";

/**
 * @title AutoRelockLedgerInvariantTest
 * @notice The auto-relock invariant suite: every `AutoRelockLedgerChecks` law, evaluated after
 *         every handler call in one campaign, plus a coverage floor over the
 *         fuzz-reached paths.
 */
contract AutoRelockLedgerInvariantTest is AutoRelockLedgerInvariantBase {
    /// @dev Number of runs after which a coverage metric that is still zero
    ///      over the whole campaign fails it. The rarest floored metrics are
    ///      reached in roughly one run in six at depth 64, so 64 runs leave a
    ///      healthy campaign a false-failure chance well below 1e-4.
    uint256 internal constant COVERAGE_WARMUP_RUNS = 64;
    string internal constant COVERAGE_PREFIX = "AUTO_RELOCK_LEDGER_COVERAGE_";

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
    function invariant_autoRelockLedgerLaws() public {
        // weight, supply and primitives against the authored ledger
        checks.checkPerPositionWeightMatchesAuthored();
        checks.checkSupplyEqualsAuthoredSum();
        checks.checkFlatAggregateEqualsAuthoredSum();
        checks.checkPrimitivesMatchAuthoredLedger();
        checks.checkEffectiveLockEndIsGridPlusR();
        checks.checkNonTransferableEqualsAuthoredSum();
        checks.checkForfeitableEqualsAuthoredSum();
        checks.checkBreakdownAgreesWithDedicatedViews();
        checks.checkPastSupplyImmutability();
        // the weight steps, in closed form
        checks.checkEnableStepIsExact();
        checks.checkDisableStepIsExact();
        checks.checkRetireStepIsExact();
        checks.checkExtendWhileFlatIsExact();
        // refusals
        checks.checkFlatIsNeverWithdrawable();
        checks.checkEnableDisableAndShorterExtendRefusals();
        checks.checkRefreshRetireAndTooLongExtendRefusals();
        checks.checkHeartbeatMovesAbandonmentClock();
        checks.checkForfeitWindowIsTransferableAfter();
        // votes and delegation
        checks.checkVotesNeverExceedSupply();
        checks.checkVotingPowerEquality();
        checks.checkPastVotesNeverExceedPastTotalSupply();
        checks.checkNoDelegationUpdateFailedEmitted();
        checks.checkFlatRecordAmountMatchesLedger();
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
        names[0] = "enables";                          counts[0] = handler.enables() - enablesAtSetUp;
        names[1] = "disables";                         counts[1] = handler.disables();
        names[2] = "staleRetires";                     counts[2] = handler.staleRetires();
        names[3] = "heartbeatRefreshes";               counts[3] = handler.heartbeatRefreshes();
        names[4] = "transferDisarms";                  counts[4] = handler.transferDisarms();
        names[5] = "flatExtensions";                   counts[5] = handler.flatExtensions();
        names[6] = "flatWithdrawProbes";               counts[6] = handler.flatWithdrawProbes();
        names[7] = "doubleEnableProbes";               counts[7] = handler.doubleEnableProbes();
        names[8] = "disableNotEnabledProbes";          counts[8] = handler.disableNotEnabledProbes();
        names[9] = "extendShorterProbes";              counts[9] = handler.extendShorterProbes();
        names[10] = "refreshStrangerProbes";           counts[10] = handler.refreshStrangerProbes();
        names[11] = "refreshNotEnabledProbes";         counts[11] = handler.refreshNotEnabledProbes();
        names[12] = "staleRetireEarlyProbes";          counts[12] = handler.staleRetireEarlyProbes();
        names[13] = "extendTooLongProbes";             counts[13] = handler.extendTooLongProbes();
        names[14] = "forfeitOutOfWindowProbes";        counts[14] = handler.forfeitOutOfWindowProbes();
        names[15] = "forfeitInWindowFlatProbes";       counts[15] = handler.forfeitInWindowFlatProbes();
        names[16] = "bucketBoundaryCheckpoints";       counts[16] = handler.bucketBoundaryCheckpoints();
        names[17] = "bucketBoundaryEnables";           counts[17] = handler.bucketBoundaryEnables();
        names[18] = "bucketBoundaryExactEndWithdraws"; counts[18] = handler.bucketBoundaryExactEndWithdraws();
        names[19] = "bucketBoundaryExactEndTransfers"; counts[19] = handler.bucketBoundaryExactEndTransfers();
        names[20] = "expiredCheckpointWrites";         counts[20] = handler.expiredCheckpointWrites();
        names[21] = "delegateRoutesChecked";           counts[21] = handler.delegateRoutesChecked();
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

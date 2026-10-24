// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import "./ArmedTransferModules.sol";

/// @dev A reward distributor that spends a configurable amount of gas per
///      notification (capped by what it is handed) and returns.
contract ConfigurableGasBurnDistributor is IRewardDistributor {
    uint256 public burn;
    uint256 public notificationCount;

    function setBurn(uint256 burn_) external { burn = burn_; }

    function updateRewards(uint256) external override {
        notificationCount += 1;
        uint256 gasAtEntry = gasleft();
        uint256 stop = gasAtEntry > burn ? gasAtEntry - burn : 0;
        uint256 x = 1;
        while (gasleft() > stop + 300) { x = uint256(keccak256(abi.encode(x))); }
    }
}

/// @title  `createLockWithAutoRelock` under a reward distributor that
///         spends its whole gas allowance: a limit the function's NatSpec
///         states, asserted.
///
/// @notice Arm-at-creation notifies the distributor three times before the
///         arming re-delegation (`_depositFor` before and after its booking,
///         then `_enableAutoRelock` before the flag), each under the
///         8,000,000-gas `REWARD_GAS_CEILING`, and that re-delegation needs the
///         removal gas floor (8,176,984 gas) left. Under a distributor that
///         takes the whole ceiling every time the call needs more than
///         3 x 8M + 8.18M = 32.2M, above Hemi's 29.93M transaction cap, so at
///         every gas limit it may be sent with it reverts
///         `DelegationCallStarved`. This is documented on
///         `createLockWithAutoRelock` and `REWARD_GAS_CEILING`: under such a
///         distributor the supported route is `createLock`, then
///         `enableAutoRelock` (two transactions: `createLock` has no floor, and
///         `enableAutoRelock` notifies once before its floor), which this file
///         also tests.
///
///         The armed transfer's fallback removal (the recipient's delegate
///         refuses the move) meets the same floor after two notifications
///         (`_disarmAutoRelock`'s notify-before, then the transfer's re-anchor):
///         2 x 8M + 8.18M plus the transfer's own cost fits the cap, which this
///         file asserts under the same distributor.
///
///         The vote-delegation module sits behind a delegatecall proxy, as the
///         live one does, and the minter has an auto-delegate, so the new
///         position is delegated and the floor applies.
contract CreateArmedDistributorGasTest is AutoRelockTestBase {
    /// @dev Hemi's per-transaction gas cap.
    uint256 internal constant HEMI_TX_CAP = 29_930_000;
    uint256 internal constant REWARD_GAS_CEILING = 8_000_000;
    uint256 internal constant AMOUNT = 1_000 ether;
    uint256 internal constant DURATION = 4 * 365 days;

    address internal constant RECIPIENT = address(0xB0B0B0);
    /// @dev The recipient's auto-delegate, saturated by `_saturate`.
    address internal constant RECIPIENT_DELEGATEE = address(0xDE1E63);
    bytes32 internal constant TOPIC_DELEGATION_UPDATE_FAILED_REASON =
        keccak256("DelegationUpdateFailedReason(uint256,bytes4)");
    bytes32 internal constant TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED =
        keccak256("AutoRelockRetirementUnverified(uint256)");

    function setUp() public override {
        super.setUp();
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(proxy));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(proxy)));
        vm.prank(victim);
        delegation.setAutoDelegate(delegateeA);
    }

    function _createArmed(uint256 gas_) internal returns (bool ok, bytes memory ret) {
        vm.prank(victim);
        (ok, ret) = address(veHemi).call{gas: gas_}(
            abi.encodeCall(veHemi.createLockWithAutoRelock, (AMOUNT, DURATION, true, false))
        );
    }

    /// @dev Armed, booked FLAT at the auto-delegate, and holding its weight.
    function _assertArmedAndDelegated(uint256 id_, string memory what_) internal {
        assertTrue(veHemi.isAutoRelockEnabled(id_), string.concat(what_, ": not armed"));
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id_);
        assertEq(d.delegatee, delegateeA, string.concat(what_, ": not delegated to the auto-delegate"));
        assertTrue(d.slope == 0 && d.bias > 0, string.concat(what_, ": the record is not flat"));
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id_), string.concat(what_, ": the delegatee does not hold the weight"));
    }

    /// @notice THE LIMIT. Distributor installed before the mint; the call at the
    ///         transaction cap reverts `DelegationCallStarved` and mints nothing.
    function test_createArmed_burnAndReturnDistributor_doesNotFitTheTxCap() public {
        veHemi.updateRewardDistributor(new BurnAndReturnDistributor());
        uint256 next = veHemi.nextTokenId();
        uint256 bal = hemi.balanceOf(victim);
        (bool ok, bytes memory ret) = _createArmed(HEMI_TX_CAP);
        assertFalse(ok,
            "the createLockWithAutoRelock NatSpec limit is gone: it fit the tx cap under a burn-and-return distributor");
        assertEq(ret.length, 4, "the revert is not a bare custom error");
        assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "the revert is not the removal gas floor");
        assertEq(veHemi.nextTokenId(), next, "a position was minted");
        assertEq(hemi.balanceOf(victim), bal, "HEMI moved");
    }

    /// @notice THE SUPPORTED ROUTE in the same state: `createLock`, then
    ///         `enableAutoRelock`, each at the transaction cap, both commit
    ///         and the position ends armed and delegated.
    function test_createArmed_burnAndReturnDistributor_createThenEnableCommits() public {
        veHemi.updateRewardDistributor(new BurnAndReturnDistributor());
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call{gas: HEMI_TX_CAP}(
            abi.encodeCall(veHemi.createLock, (AMOUNT, DURATION))
        );
        assertTrue(ok, "createLock does not fit the tx cap under a burn-and-return distributor");
        uint256 id = abi.decode(ret, (uint256));
        assertEq(delegation.delegation(id).delegatee, delegateeA, "createLock did not delegate to the auto-delegate");

        vm.prank(victim);
        uint256 gasBefore = gasleft();
        (ok, ) = address(veHemi).call{gas: HEMI_TX_CAP}(abi.encodeCall(veHemi.enableAutoRelock, (id)));
        uint256 used = gasBefore - gasleft();
        assertTrue(ok, "enableAutoRelock does not fit the tx cap under a burn-and-return distributor");
        // Vacuity: the distributor really took the whole ceiling, twice.
        assertGt(used, 2 * (REWARD_GAS_CEILING - 100_000), "premise: the distributor did not spend its allowance");
        _assertArmedAndDelegated(id, "create then enable");
    }

    /// @notice NOT VACUOUS: the same call at the same cap commits under a cheap
    ///         distributor (notified four times), and under the burn-and-return
    ///         one with a gas limit above Hemi's cap, so the revert asserted
    ///         above is the gas limit and nothing else.
    function test_createArmed_controls_cheapDistributorAndHigherLimitCommit() public {
        uint256 snap = vm.snapshotState();
        ConfigurableGasBurnDistributor cheap = new ConfigurableGasBurnDistributor();
        veHemi.updateRewardDistributor(cheap);
        (bool ok, bytes memory ret) = _createArmed(HEMI_TX_CAP);
        assertTrue(ok, "createLockWithAutoRelock does not fit the tx cap under a cheap distributor");
        assertEq(cheap.notificationCount(), 4, "the cheap distributor was not notified on every leg");
        _assertArmedAndDelegated(abi.decode(ret, (uint256)), "cheap distributor");
        vm.revertToState(snap);

        veHemi.updateRewardDistributor(new BurnAndReturnDistributor());
        (ok, ret) = _createArmed(34_000_000);
        assertTrue(ok, "createLockWithAutoRelock under a burn-and-return distributor fails even above the tx cap");
        _assertArmedAndDelegated(abi.decode(ret, (uint256)), "burn-and-return distributor, 34M");
    }

    /// @notice The threshold stated in the `createLockWithAutoRelock` NatSpec:
    ///         for a minter with no other positions, at the transaction cap
    ///         the call fits while the distributor spends about 6.8 million gas
    ///         per notification or less, and stops fitting above it.
    function test_createArmed_perCallDistributorThresholdIsJustBelowSevenMillion() public {
        ConfigurableGasBurnDistributor distributor = new ConfigurableGasBurnDistributor();
        veHemi.updateRewardDistributor(distributor);
        uint256 lo = 0; // fits
        uint256 hi = REWARD_GAS_CEILING; // does not fit
        distributor.setBurn(lo);
        (bool ok, ) = _tryCreateArmedAtTxCap();
        assertTrue(ok, "premise: does not fit with a free distributor");
        distributor.setBurn(hi);
        (ok, ) = _tryCreateArmedAtTxCap();
        assertFalse(ok, "premise: fits with a distributor at the full ceiling");
        while (hi - lo > 10_000) {
            uint256 mid = (lo + hi) / 2;
            distributor.setBurn(mid);
            (ok, ) = _tryCreateArmedAtTxCap();
            if (ok) lo = mid;
            else hi = mid;
        }
        emit log_named_uint("largest per-call distributor spend that still fits the tx cap", lo);
        assertGt(
            lo,
            6_500_000,
            "the threshold is below 6.5M: a distributor within the ~6.8M per notification stated in the "
            "createLockWithAutoRelock NatSpec no longer fits the tx cap"
        );
        assertLt(
            lo,
            7_000_000,
            "the threshold is at or above 7M: the ~6.8M per notification in the createLockWithAutoRelock NatSpec "
            "no longer describes it"
        );
    }

    /// @notice THE ARMED TRANSFER'S FALLBACK REMOVAL under the burn-and-return
    ///         distributor. The recipient's auto-delegate is slope-saturated, so
    ///         the module refuses the move and VeHemi removes the record behind
    ///         the removal gas floor, after the distributor took its whole
    ///         ceiling twice. At the transaction cap the transfer commits, the
    ///         record is removed (an under-count, never a phantom at the seller's
    ///         delegatee) and nothing is announced.
    function test_armedTransfer_burnAndReturnDistributor_refusedMoveFallsBackToTheRemoval() public {
        (uint256 id, , ) = createLock(victim, AMOUNT, DURATION);
        enable(victim, id);
        assertEq(delegation.delegation(id).delegatee, delegateeA,
            "premise: the armed position is not booked at the auto-delegate");
        vm.warp(block.timestamp + 7200);
        _saturate(RECIPIENT_DELEGATEE);
        vm.prank(RECIPIENT);
        delegation.setAutoDelegate(RECIPIENT_DELEGATEE);
        veHemi.updateRewardDistributor(new BurnAndReturnDistributor());

        vm.recordLogs();
        vm.prank(victim);
        uint256 gasBefore = gasleft();
        (bool ok, ) = address(veHemi).call{gas: HEMI_TX_CAP}(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, RECIPIENT, id)
        );
        uint256 used = gasBefore - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            ok, "the armed transfer's fallback removal does not fit the tx cap under a burn-and-return distributor"
        );
        assertEq(veHemi.ownerOf(id), RECIPIENT, "the position did not change hands");
        assertEq(veHemi.autoRelockRemaining(id), 0, "the transfer did not disarm the position");
        assertEq(delegation.delegation(id).delegatee, address(0), "the fallback removal did not clear the record");
        uint256 refusals;
        uint256 unverified;
        bytes4 reason;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(veHemi) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == TOPIC_DELEGATION_UPDATE_FAILED_REASON) {
                ++refusals;
                reason = abi.decode(logs[i].data, (bytes4));
            } else if (logs[i].topics[0] == TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED) {
                ++unverified;
            }
        }
        // Vacuity: the move really was refused, for the saturation, and the
        // distributor really took its whole ceiling on both notifications.
        assertEq(refusals, 1, "premise: not exactly one refused write (the move)");
        assertEq(reason, VeHemiVoteDelegation.DelegationSlopeOverflow.selector,
            "premise: the move was refused for another reason");
        assertGt(used, 2 * (REWARD_GAS_CEILING - 100_000), "premise: the distributor did not spend its allowance twice");
        assertEq(unverified, 0, "the removal was refused (AutoRelockRetirementUnverified)");
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(delegateeA), 0, "the flat term stayed booked at the seller's delegatee");
    }

    /// @dev Park `delegatee_` half a position's slope below the uint64
    ///      aggregate-slope ceiling with one decaying whale, then prove from
    ///      outside VeHemi that a position of AMOUNT no longer fits there.
    function _saturate(address delegatee_) internal {
        address whale = address(uint160(uint256(keccak256(abi.encode("saturating-whale", delegatee_)))));
        uint256 headroom = (AMOUNT / MAX_TIME) / 2;
        (uint256 whaleId, , ) = createLock(whale, (uint256(type(uint64).max) - headroom) * MAX_TIME, 3 * 365 days);
        delegateTo(whale, whaleId, delegatee_);
        (uint256 saturationCheckId, , ) = createLock(whale, AMOUNT, DURATION);
        vm.prank(whale);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", saturationCheckId, delegatee_)
        );
        require(
            !ok && bytes4(ret) == VeHemiVoteDelegation.DelegationSlopeOverflow.selector,
            "saturation premise gone"
        );
    }

    function _tryCreateArmedAtTxCap() internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        (ok, ret) = _createArmed(HEMI_TX_CAP);
        if (!ok) assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "refused for a reason other than the floor");
        vm.revertToState(snap);
    }
}

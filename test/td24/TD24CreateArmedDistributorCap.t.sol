// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import "./TD24Modules.sol";

/// @dev A reward distributor that spends a configurable amount of gas per
///      notification (capped by what it is handed) and returns.
contract TD24GasBurnDistributor is IRewardDistributor {
    uint256 public burn;
    uint256 public calls;

    function setBurn(uint256 burn_) external { burn = burn_; }

    function updateRewards(uint256) external override {
        calls += 1;
        uint256 g = gasleft();
        uint256 stop = g > burn ? g - burn : 0;
        uint256 x = 1;
        while (gasleft() > stop + 300) { x = uint256(keccak256(abi.encode(x))); }
    }
}

/// @title  `createLockWithAutoRelock` under a reward distributor that
///         spends its whole gas allowance: a DOCUMENTED LIMIT, pinned.
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
///         also pins.
///
///         The armed transfer's fallback removal (the recipient's delegate
///         refuses the move) meets the same floor after two notifications
///         (`_disarmAutoRelock`'s notify-before, then the transfer's re-anchor):
///         2 x 8M + 8.18M plus the transfer's own cost fits the cap, which this
///         file pins under the same distributor.
///
///         The vote-delegation module sits behind a delegatecall proxy, as the
///         live one does, and the minter has an auto-delegate, so the new
///         position is delegated and the floor applies.
contract TD24CreateArmedDistributorCap is J11Base {
    /// @dev Hemi's per-transaction gas cap.
    uint256 internal constant HEMI_TX_CAP = 29_930_000;
    uint256 internal constant CEILING = 8_000_000;
    uint256 internal constant AMOUNT = 1_000 ether;
    uint256 internal constant DURATION = 4 * 365 days;

    address internal constant RECIPIENT = address(0xB0B0B0);
    /// @dev The recipient's auto-delegate, saturated by `_saturate`.
    address internal constant DELE3 = address(0xDE1E63);
    bytes32 internal constant T_DUFR = keccak256("DelegationUpdateFailedReason(uint256,bytes4)");
    bytes32 internal constant T_UNVERIFIED = keccak256("AutoRelockRetirementUnverified(uint256)");

    function setUp() public override {
        super.setUp();
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(p));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(p)));
        vm.prank(victim);
        delegation.setAutoDelegate(dele);
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
        assertEq(d.delegatee, dele, string.concat(what_, ": not delegated to the auto-delegate"));
        assertTrue(d.slope == 0 && d.bias > 0, string.concat(what_, ": the record is not flat"));
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id_), string.concat(what_, ": the delegatee does not hold the weight"));
    }

    /// @notice THE PIN. Distributor installed before the mint; the call at the
    ///         transaction cap reverts `DelegationCallStarved` and mints nothing.
    function test_TD24_createArmed_gasEatingDistributor_doesNotFitTheTxCap() public {
        veHemi.updateRewardDistributor(new TD24GasEaterDistributor());
        uint256 next = veHemi.nextTokenId();
        uint256 bal = hemi.balanceOf(victim);
        (bool ok, bytes memory ret) = _createArmed(HEMI_TX_CAP);
        assertFalse(ok, "documented limit gone: createLockWithAutoRelock fit the tx cap under a gas-eating distributor");
        assertEq(ret.length, 4, "the revert is not a bare custom error");
        assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "the revert is not the removal gas floor");
        assertEq(veHemi.nextTokenId(), next, "a position was minted");
        assertEq(hemi.balanceOf(victim), bal, "HEMI moved");
    }

    /// @notice THE SUPPORTED ROUTE in the same state: `createLock`, then
    ///         `enableAutoRelock`, each at the transaction cap, both commit
    ///         and the position ends armed and delegated.
    function test_TD24_createArmed_gasEatingDistributor_createThenEnableCommits() public {
        veHemi.updateRewardDistributor(new TD24GasEaterDistributor());
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call{gas: HEMI_TX_CAP}(
            abi.encodeCall(veHemi.createLock, (AMOUNT, DURATION))
        );
        assertTrue(ok, "createLock does not fit the tx cap under a gas-eating distributor");
        uint256 id = abi.decode(ret, (uint256));
        assertEq(delegation.delegation(id).delegatee, dele, "createLock did not delegate to the auto-delegate");

        vm.prank(victim);
        uint256 g0 = gasleft();
        (ok, ) = address(veHemi).call{gas: HEMI_TX_CAP}(abi.encodeCall(veHemi.enableAutoRelock, (id)));
        uint256 used = g0 - gasleft();
        assertTrue(ok, "enableAutoRelock does not fit the tx cap under a gas-eating distributor");
        // Vacuity: the distributor really took the whole ceiling, twice.
        assertGt(used, 2 * (CEILING - 100_000), "probe: the distributor did not spend its allowance");
        _assertArmedAndDelegated(id, "create then enable");
    }

    /// @notice NOT VACUOUS: the same call at the same cap commits under a cheap
    ///         distributor (notified four times), and under the gas-eating one
    ///         with a gas limit above Hemi's cap, so the pinned revert is the
    ///         gas limit and nothing else.
    function test_TD24_createArmed_controls_cheapDistributorAndHigherLimitCommit() public {
        uint256 snap = vm.snapshotState();
        TD24GasBurnDistributor cheap = new TD24GasBurnDistributor();
        veHemi.updateRewardDistributor(cheap);
        (bool ok, bytes memory ret) = _createArmed(HEMI_TX_CAP);
        assertTrue(ok, "createLockWithAutoRelock does not fit the tx cap under a cheap distributor");
        assertEq(cheap.calls(), 4, "the cheap distributor was not notified on every leg");
        _assertArmedAndDelegated(abi.decode(ret, (uint256)), "cheap distributor");
        vm.revertToState(snap);

        veHemi.updateRewardDistributor(new TD24GasEaterDistributor());
        (ok, ret) = _createArmed(34_000_000);
        assertTrue(ok, "createLockWithAutoRelock under a gas-eating distributor fails even above the tx cap");
        _assertArmedAndDelegated(abi.decode(ret, (uint256)), "gas-eating distributor, 34M");
    }

    /// @notice The documented threshold: for a minter with no other positions,
    ///         at the transaction cap the call fits while the distributor
    ///         spends about 6.8 million gas per notification or less, and stops
    ///         fitting above it.
    function test_TD24_createArmed_perCallDistributorThresholdIsJustBelowSevenMillion() public {
        TD24GasBurnDistributor d = new TD24GasBurnDistributor();
        veHemi.updateRewardDistributor(d);
        uint256 lo = 0; // fits
        uint256 hi = CEILING; // does not fit
        d.setBurn(lo);
        (bool ok, ) = _probe();
        assertTrue(ok, "probe: does not fit with a free distributor");
        d.setBurn(hi);
        (ok, ) = _probe();
        assertFalse(ok, "probe: fits with a distributor at the full ceiling");
        while (hi - lo > 10_000) {
            uint256 mid = (lo + hi) / 2;
            d.setBurn(mid);
            (ok, ) = _probe();
            if (ok) lo = mid;
            else hi = mid;
        }
        emit log_named_uint("largest per-call distributor spend that still fits the tx cap", lo);
        assertGt(
            lo,
            6_500_000,
            "the threshold is below 6.5M: a distributor within the documented ~6.8M per notification no longer fits the tx cap"
        );
        assertLt(
            lo,
            7_000_000,
            "the threshold is at or above 7M: the documented ~6.8M per notification no longer describes it"
        );
    }

    /// @notice THE ARMED TRANSFER'S FALLBACK REMOVAL under the gas-eating
    ///         distributor. The recipient's auto-delegate is slope-saturated, so
    ///         the module refuses the move and VeHemi removes the record behind
    ///         the removal gas floor, after the distributor took its whole
    ///         ceiling twice. At the transaction cap the transfer commits, the
    ///         record is removed (an under-count, never a phantom at the old
    ///         delegatee) and nothing is announced.
    function test_TD24_armedTransfer_gasEatingDistributor_refusedMoveFallsBackToTheRemoval() public {
        (uint256 id, , ) = createLock(victim, AMOUNT, DURATION);
        enable(victim, id);
        assertEq(delegation.delegation(id).delegatee, dele, "probe: the armed position is not booked at the auto-delegate");
        vm.warp(block.timestamp + 7200);
        _saturate(DELE3);
        vm.prank(RECIPIENT);
        delegation.setAutoDelegate(DELE3);
        veHemi.updateRewardDistributor(new TD24GasEaterDistributor());

        vm.recordLogs();
        vm.prank(victim);
        uint256 g0 = gasleft();
        (bool ok, ) = address(veHemi).call{gas: HEMI_TX_CAP}(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, RECIPIENT, id)
        );
        uint256 used = g0 - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "the armed transfer's fallback removal does not fit the tx cap under a gas-eating distributor");
        assertEq(veHemi.ownerOf(id), RECIPIENT, "the position did not change hands");
        assertEq(veHemi.autoRelockRemaining(id), 0, "the transfer did not disarm the position");
        assertEq(delegation.delegation(id).delegatee, address(0), "the fallback removal did not clear the record");
        uint256 refusals;
        uint256 unverified;
        bytes4 reason;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(veHemi) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == T_DUFR) {
                ++refusals;
                reason = abi.decode(logs[i].data, (bytes4));
            } else if (logs[i].topics[0] == T_UNVERIFIED) {
                ++unverified;
            }
        }
        // Vacuity: the move really was refused, for the saturation, and the
        // distributor really took its whole ceiling on both notifications.
        assertEq(refusals, 1, "probe: not exactly one refused write (the move)");
        assertEq(reason, VeHemiVoteDelegation.DelegationSlopeOverflow.selector, "probe: the move was refused for another reason");
        assertGt(used, 2 * (CEILING - 100_000), "probe: the distributor did not spend its allowance twice");
        assertEq(unverified, 0, "the removal was refused (AutoRelockRetirementUnverified)");
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(dele), 0, "the flat term stayed booked at the old delegatee");
    }

    /// @dev Park `d_` half a position's slope below the uint64 aggregate-slope
    ///      ceiling with one decaying whale, then prove from outside VeHemi that
    ///      a position of AMOUNT no longer fits there.
    function _saturate(address d_) internal {
        address w = address(uint160(uint256(keccak256(abi.encode("saturating-whale", d_)))));
        uint256 headroom = (AMOUNT / MAX_TIME) / 2;
        (uint256 whaleId, , ) = createLock(w, (uint256(type(uint64).max) - headroom) * MAX_TIME, 3 * 365 days);
        delegateTo(w, whaleId, d_);
        (uint256 probeId, , ) = createLock(w, AMOUNT, DURATION);
        vm.prank(w);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", probeId, d_)
        );
        require(
            !ok && bytes4(ret) == VeHemiVoteDelegation.DelegationSlopeOverflow.selector,
            "saturation premise gone"
        );
    }

    function _probe() internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        (ok, ret) = _createArmed(HEMI_TX_CAP);
        if (!ok) assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "refused for a reason other than the floor");
        vm.revertToState(snap);
    }
}

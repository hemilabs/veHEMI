// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import {RevertingVoteDelegation} from "../mocks/RevertingVoteDelegation.sol";
import {OogVoteDelegation} from "../mocks/OogVoteDelegation.sol";
import {CountingDistributor} from "../reward-distributor/DistributorMocks.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import "../module-failure/SlopeOverflowLiar.sol";
import "./ArmedTransferModules.sol";
import {VeHemiAragonAdapter} from "../../src/adapter/VeHemiAragonAdapter.sol";

/// @title  The armed-transfer leg ("move or remove").
///
/// @notice An ARMED position transferred to another account is disarmed by
///         `_disarmAutoRelock` BEFORE the ownership change (no module call),
///         and its flat term is retired AFTER it by one post-transfer
///         re-delegation:
///           1. MOVE to the recipient's resolved delegate; if accepted, read back;
///           2. if refused, REMOVE the record (removal gas floor checked first);
///           3. if that is refused too, announce `AutoRelockRetirementUnverified`.
///         THE LAW (behind an honest module, e.g. the real VVD): after any
///         committed armed transfer the position is never flat while its flag
///         is clear. Votes may be UNDER-counted (the recipient's delegate
///         refused the weight) but never PHANTOM. T4 asserts the hostile
///         exceptions (both writes refused -> announced; no-op removal ->
///         silent).
///
///         Sections:
///           T0  vacuity          T1  outcome matrix (real VVD, saturation)
///           T2  fuzz law         T3  whale        T4  broken / hostile modules
///           T5  29.93M frame     T6  proxied-VVD starvation sweep
///           T7  call counts and reward notifications
///           T7b reward notifications on the refused-move branches
///           T7c reward notifications see the seller
///           T8  event stream     T9  edges
///           T10 transfers that do not disarm (self and unarmed)
///           T11 the removal is always handed the whole ceiling
///           T12 bounded selector copy and strict re-raise
///
///         Names: the seller's delegatee is the position's delegatee before
///         the transfer; the recipient's delegate is the recipient's
///         auto-delegate, or the recipient itself when it has none; `SELF` is
///         a recipient with no auto-delegate, and `SAT` means slope-saturated.
///         grid(t) = floor(t / SIX_DAYS) * SIX_DAYS, the start of t's bucket;
///         R = `autoRelockRemaining(id)`.
contract ArmedTransferMoveOrRemoveTest is AutoRelockTestBase {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant HEADROOM = (PRINCIPAL / MAX_TIME) / 2;
    uint256 internal constant HEMI_TX_CAP = 29_930_000;
    uint256 internal constant DELEGATION_GAS_CEILING = 8_000_000;
    bytes4 internal constant SEL_SLOPE_OVERFLOW = 0xf2b4513c;

    bytes32 internal constant TOPIC_DELEGATION_UPDATE_FAILED = keccak256("DelegationUpdateFailed(uint256)");
    bytes32 internal constant TOPIC_DELEGATION_UPDATE_FAILED_REASON =
        keccak256("DelegationUpdateFailedReason(uint256,bytes4)");
    bytes32 internal constant TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED =
        keccak256("AutoRelockRetirementUnverified(uint256)");
    bytes32 internal constant TOPIC_AUTO_RELOCK_DISABLED = keccak256("AutoRelockDisabled(uint256,uint64)");
    bytes32 internal constant TOPIC_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant TOPIC_DELEGATE_CHANGED = keccak256("DelegateChanged(uint256,address,address)");

    // Recipient columns of the outcome matrix.
    uint8 internal constant SAME = 0;          // recipient's autoDelegate == the seller's delegatee
    uint8 internal constant DIFF_HEALTHY = 1;  // autoDelegate == delegateeB (healthy)
    uint8 internal constant DIFF_SAT = 2;      // autoDelegate == delegateeC (saturated)
    uint8 internal constant SELF_HEALTHY = 3;  // no autoDelegate: the recipient's delegate is the recipient
    uint8 internal constant SELF_SAT = 4;      // no autoDelegate, recipient saturated

    address internal recipient = address(0xB0B0B0);
    address internal operator = address(0x0BE7A7);
    address internal delegateeC = address(0xDE1E63);

    // Non-vacuity counters. `_row` bumps the cell counters AFTER each cell's
    // snapshot is reverted, so they survive it. NOTE: the cell counters count
    // the PREDICTED class of each cell (`_column`'s saturation flag); the
    // observed behaviour is checked by `_assertCorrect` / `_assertUnderCount`.
    uint256 internal saturations;
    uint256 internal correctCells;
    uint256 internal underCountCells;

    // ------------------------------------------------------------------ rig --

    function _whaleOwner(address delegatee_) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("saturating-whale", delegatee_)))));
    }

    /// @dev Park `delegatee_` HEADROOM below the uint64 aggregate-slope ceiling
    ///      with an ordinary decaying whale, then PROVE from outside VeHemi that
    ///      the victim's slope no longer fits.
    function _saturate(address delegatee_) internal {
        address whale = _whaleOwner(delegatee_);
        (uint256 whaleId, , ) = createLock(whale, (uint256(type(uint64).max) - HEADROOM) * MAX_TIME, 3 * 365 days);
        delegateTo(whale, whaleId, delegatee_);
        (uint256 saturationCheckId, , ) = createLock(whale, PRINCIPAL, 4 * 365 days);
        vm.prank(whale);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", saturationCheckId, delegatee_)
        );
        require(!ok && bytes4(ret) == SEL_SLOPE_OVERFLOW, "saturation premise gone");
        ++saturations;
    }

    /// @dev An armed (flat) victim position booked at `sellerDelegatee_`.
    function _armedOn(address sellerDelegatee_) internal returns (uint256 id) {
        (id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        enable(victim, id);
        delegateTo(victim, id, sellerDelegatee_);
        vm.warp(block.timestamp + 7200);
    }

    function _setAutoDelegate(address who_, address to_) internal {
        vm.prank(who_);
        delegation.setAutoDelegate(to_);
    }

    /// @dev Configure the recipient for column `col_`; returns the delegate the
    ///      position should land on and whether it is saturated.
    function _column(uint8 col_, address sellerDelegatee_, bool sellerDelegateeSaturated_)
        internal
        returns (address target, bool targetSaturated)
    {
        if (col_ == SAME) {
            _setAutoDelegate(recipient, sellerDelegatee_);
            return (sellerDelegatee_, sellerDelegateeSaturated_);
        }
        if (col_ == DIFF_HEALTHY) {
            _setAutoDelegate(recipient, delegateeB);
            return (delegateeB, false);
        }
        if (col_ == DIFF_SAT) {
            _saturate(delegateeC);
            _setAutoDelegate(recipient, delegateeC);
            return (delegateeC, true);
        }
        if (col_ == SELF_HEALTHY) return (recipient, false);
        _saturate(recipient);
        return (recipient, true);
    }

    function _transfer(uint256 id_, address from_, address to_, bool byOperator_, uint256 gas_)
        internal
        returns (bool ok, bytes memory ret)
    {
        address caller = from_;
        if (byOperator_) {
            vm.prank(from_);
            veHemi.approve(operator, id_);
            caller = operator;
        }
        vm.prank(caller);
        (ok, ret) = address(veHemi).call{gas: gas_}(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from_, to_, id_)
        );
    }

    function _count(Vm.Log[] memory logs_, address emitter_, bytes32 topic_) internal pure returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic_) ++n;
        }
    }

    function _firstIndex(Vm.Log[] memory logs_, address emitter_, bytes32 topic_) internal pure returns (uint256) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic_) return i;
        }
        return type(uint256).max;
    }

    function _reasons(Vm.Log[] memory logs_) internal view returns (bytes4[] memory out) {
        out = new bytes4[](_count(logs_, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED_REASON));
        uint256 k;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(veHemi) && logs_[i].topics[0] == TOPIC_DELEGATION_UPDATE_FAILED_REASON) {
                out[k++] = abi.decode(logs_[i].data, (bytes4));
            }
        }
    }

    function _isFlat(IVeHemiVoteDelegation.Delegation memory record_) internal pure returns (bool) {
        return record_.slope == 0 && record_.bias > 0;
    }

    /// @dev Far future: every lock in the rig has expired, so any vote left on
    ///      `delegatee_` can only be a flat term with no position behind it.
    function _assertNoPhantomFarFuture(address delegatee_, string memory tag_) internal {
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + MAX_TIME + 4 * SIX_DAYS);
        assertEq(delegation.getVotes(delegatee_), 0, tag_);
        vm.revertToState(snap);
    }

    // ===================================================================
    // T1 -- THE OUTCOME MATRIX (real VVD; saturation reached, not mocked).
    //   the seller's delegatee in {healthy, saturated} x 5 recipient columns
    //   x caller {owner, approved operator} x 4 sub-bucket phases.
    //   CORRECT iff the recipient's delegate can take the weight; otherwise
    //   UNDER-COUNT (record removed). Never phantom, never refused.
    // ===================================================================

    struct Cell {
        address sellerDelegatee;
        address target;
        bool targetSaturated;
        uint256 id;
        uint256 transferAt;
        uint64 remainingAtTransfer;
        uint256 flatBias;
        uint256 sellerDelegateeVotesWithoutTransfer;
        uint256 targetVotesWithoutTransfer;
        uint256 sellerDelegateeVotesAfter;
        uint256 targetVotesAfter;
        uint256 weightAfter;
        uint256 supplyWithoutTransfer;
        uint256 flatWeightWithoutTransfer;
    }

    /// @return correct_ true for a CORRECT cell, false for an UNDER-COUNT cell.
    ///         (Storage counters would be rolled back with the snapshot.)
    function _cell(bool sellerDelegateeSaturated_, uint8 col_, bool byOperator_, uint256 phase_)
        internal
        returns (bool correct_)
    {
        uint256 snap = vm.snapshotState();
        Cell memory c;
        c.sellerDelegatee = delegateeA;
        if (sellerDelegateeSaturated_) _saturate(c.sellerDelegatee);
        (c.target, c.targetSaturated) = _column(col_, c.sellerDelegatee, sellerDelegateeSaturated_);
        c.id = _armedOn(c.sellerDelegatee);
        warpToPhase(phase_);

        c.transferAt = block.timestamp;
        c.remainingAtTransfer = veHemi.autoRelockRemaining(c.id);
        IVeHemiVoteDelegation.Delegation memory pre = delegation.delegation(c.id);
        require(_isFlat(pre) && pre.delegatee == c.sellerDelegatee, "victim is not flat at the seller's delegatee");
        c.flatBias = pre.bias;

        // Votes at transferAt+1 in the world WITHOUT the transfer.
        uint256 s1 = vm.snapshotState();
        vm.warp(c.transferAt + 1);
        c.sellerDelegateeVotesWithoutTransfer = delegation.getVotes(c.sellerDelegatee);
        c.targetVotesWithoutTransfer = delegation.getVotes(c.target);
        c.supplyWithoutTransfer = veHemi.totalVeHemiSupply();
        c.flatWeightWithoutTransfer = veHemi.balanceOfNFT(c.id);
        vm.revertToState(s1);

        vm.recordLogs();
        (bool ok, ) = _transfer(c.id, victim, recipient, byOperator_, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "T1: armed transfer refused");
        assertEq(veHemi.ownerOf(c.id), recipient, "T1: ownership");
        assertEq(veHemi.autoRelockRemaining(c.id), 0, "T1: flag survived");
        assertEq(
            uint256(veHemi.getLockedBalance(c.id).end),
            ((c.transferAt / SIX_DAYS) + uint256(c.remainingAtTransfer) / SIX_DAYS) * SIX_DAYS,
            "T1: end != grid(transferAt) + R"
        );
        // Oracles that do not go through VeHemi's own user point (a disarm
        // that scaled `amount` would pass every check that reads only the
        // point), and the two disarm side effects shared with the other
        // disarm entry points (`disableAutoRelock`, `retireStaleAutoRelock`):
        // the refresh stamp cleared and the `AutoRelockDisabled` payload.
        assertEq(uint256(int256(veHemi.getLockedBalance(c.id).amount)), PRINCIPAL, "T1: principal changed");
        assertEq(uint256(veHemi.autoRelockRefreshedAt(c.id)), 0, "T1: refreshedAt not cleared");
        {
            uint256 disabledIndex = _firstIndex(logs, address(veHemi), TOPIC_AUTO_RELOCK_DISABLED);
            require(disabledIndex != type(uint256).max, "T1: no AutoRelockDisabled");
            assertEq(
                uint256(abi.decode(logs[disabledIndex].data, (uint64))),
                uint256(veHemi.getLockedBalance(c.id).end),
                "T1: AutoRelockDisabled payload != end"
            );
        }
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(c.id);
        assertFalse(_isFlat(d), "T1: PHANTOM -- flat record survived a committed disarm");
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0,
            "T1: Unverified on an honest VVD");
        assertEq(
            veHemi.getUserPoint(c.id, veHemi.userPointEpoch(c.id)).owner,
            recipient,
            "T1: point-history owner is not the recipient"
        );

        vm.warp(c.transferAt + 1);
        c.sellerDelegateeVotesAfter = delegation.getVotes(c.sellerDelegatee);
        c.targetVotesAfter = delegation.getVotes(c.target);
        c.weightAfter = veHemi.balanceOfNFT(c.id);
        {
            uint256 closedFormEnd = ((c.transferAt / SIX_DAYS) + uint256(c.remainingAtTransfer) / SIX_DAYS) * SIX_DAYS;
            uint256 weightTolerance = 2 * (PRINCIPAL / MAX_TIME) + 2;
            assertApproxEqAbs(
                c.weightAfter, (PRINCIPAL / MAX_TIME) * (closedFormEnd - (c.transferAt + 1)), weightTolerance,
                "T1: weight is not the closed-form decaying weight"
            );
            assertApproxEqAbs(
                veHemi.totalVeHemiSupply(), c.supplyWithoutTransfer - c.flatWeightWithoutTransfer + c.weightAfter,
                weightTolerance, "T1: supply delta != the post-transfer weight - the flat weight"
            );
        }
        correct_ = !c.targetSaturated;
        if (correct_) _assertCorrect(c, d, logs);
        else _assertUnderCount(c, d, logs);
        _assertNoPhantomFarFuture(c.sellerDelegatee, "T1: phantom on the seller's delegatee far future");
        _assertNoPhantomFarFuture(c.target, "T1: phantom on the recipient's delegate far future");
        vm.revertToState(snap);
    }

    function _assertCorrect(Cell memory c, IVeHemiVoteDelegation.Delegation memory d, Vm.Log[] memory logs) internal {
        uint256 tol = 2 * (PRINCIPAL / MAX_TIME) + 2;
        assertEq(d.delegatee, c.target, "T1: not moved to the recipient's delegate");
        assertGt(d.slope, 0, "T1: moved record is not decaying");
        assertEq(uint256(d.end), uint256(veHemi.getLockedBalance(c.id).end), "T1: moved record end != lock end");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 0,
            "T1: DelegationUpdateFailed in a correct cell");
        if (c.target == c.sellerDelegatee) {
            assertApproxEqAbs(
                c.sellerDelegateeVotesAfter, c.sellerDelegateeVotesWithoutTransfer - c.flatBias + c.weightAfter, tol,
                "T1: same-delegate votes"
            );
        } else {
            assertEq(c.sellerDelegateeVotesAfter, c.sellerDelegateeVotesWithoutTransfer - c.flatBias,
                "T1: the seller's delegatee kept part of the flat term");
            assertApproxEqAbs(c.targetVotesAfter, c.targetVotesWithoutTransfer + c.weightAfter, tol,
                "T1: the recipient's delegate did not gain the weight");
        }
    }

    function _assertUnderCount(Cell memory c, IVeHemiVoteDelegation.Delegation memory d, Vm.Log[] memory logs) internal {
        assertEq(d.delegatee, address(0), "T1: under-count cell kept a delegatee");
        assertEq(d.bias, 0, "T1: under-count cell kept bias");
        assertEq(d.slope, 0, "T1: under-count cell kept slope");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 1,
            "T1: exactly one DelegationUpdateFailed");
        bytes4[] memory reasons = _reasons(logs);
        assertEq(reasons.length, 1, "T1: exactly one DelegationUpdateFailedReason");
        assertEq(reasons[0], SEL_SLOPE_OVERFLOW, "T1: DelegationUpdateFailedReason is not the overflow selector");
        assertEq(c.sellerDelegateeVotesAfter, c.sellerDelegateeVotesWithoutTransfer - c.flatBias,
            "T1: the seller's delegatee kept part of the flat term");
        if (c.target != c.sellerDelegatee) {
            assertEq(c.targetVotesAfter, c.targetVotesWithoutTransfer, "T1: the saturated recipient's delegate changed");
        }
    }

    function _row(bool sellerDelegateeSaturated_, uint8 col_) internal {
        uint256[4] memory phases = [uint256(0), 1, SIX_DAYS / 2, SIX_DAYS - 1];
        for (uint256 p; p < 4; ++p) {
            for (uint256 k; k < 2; ++k) {
                if (_cell(sellerDelegateeSaturated_, col_, k == 1, phases[p])) ++correctCells;
                else ++underCountCells;
            }
        }
    }

    function test_T1_sellerDelegateeHealthy_same() public { _row(false, SAME); assertEq(correctCells, 8); }
    function test_T1_sellerDelegateeHealthy_diffHealthy() public { _row(false, DIFF_HEALTHY); assertEq(correctCells, 8); }
    function test_T1_sellerDelegateeHealthy_diffSaturated() public { _row(false, DIFF_SAT); assertEq(underCountCells, 8); }
    function test_T1_sellerDelegateeHealthy_selfHealthy() public { _row(false, SELF_HEALTHY); assertEq(correctCells, 8); }
    function test_T1_sellerDelegateeHealthy_selfSaturated() public { _row(false, SELF_SAT); assertEq(underCountCells, 8); }
    function test_T1_sellerDelegateeSaturated_same() public { _row(true, SAME); assertEq(underCountCells, 8); }
    function test_T1_sellerDelegateeSaturated_diffHealthy() public { _row(true, DIFF_HEALTHY); assertEq(correctCells, 8); }
    function test_T1_sellerDelegateeSaturated_diffSaturated() public { _row(true, DIFF_SAT); assertEq(underCountCells, 8); }
    function test_T1_sellerDelegateeSaturated_selfHealthy() public { _row(true, SELF_HEALTHY); assertEq(correctCells, 8); }
    function test_T1_sellerDelegateeSaturated_selfSaturated() public { _row(true, SELF_SAT); assertEq(underCountCells, 8); }

    // ===================================================================
    // T0 -- VACUITY: the premises the matrix depends on are really reached.
    // ===================================================================

    function test_T0_outcomeMatrixPremises() public {
        _saturate(delegateeA);
        _saturate(delegateeC);
        assertEq(saturations, 2, "T0: saturation not reached");
        // An armed victim on a saturated delegate is still FLAT there: the
        // flat booking adds no slope.
        uint256 id = _armedOn(delegateeA);
        assertTrue(_isFlat(delegation.delegation(id)), "T0: armed victim not flat");
        assertEq(delegation.delegation(id).delegatee, delegateeA, "T0: victim not at the seller's delegatee");
        // And disableAutoRelock (strict) REFUSES on the same state -- the
        // contrast with the transfer leg, which never refuses.
        vm.prank(victim);
        (bool ok, ) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
        assertFalse(ok, "T0: strict disable did not refuse on a saturated delegate");
    }

    // ===================================================================
    // T2 -- FUZZ: the law over random phases, durations, columns, callers.
    // ===================================================================

    /// @dev Durations span the whole admissible range [2 * SIX_DAYS, MAX_TIME].
    ///      The arm is in the mint block, where
    ///      R = grid(t + dur) - grid(t) >= 2 * SIX_DAYS for every such dur, so
    ///      the `AutoRelockDurationTooShort` floor admits every draw.
    /// forge-config: default.fuzz.runs = 96
    function testFuzz_T2_neverFlatWhileFlagClear(
        uint256 phase_, uint256 dur_, uint8 col_, bool sellerDelegateeSaturated_, bool byOperator_
    ) public {
        phase_ = bound(phase_, 0, SIX_DAYS - 1);
        dur_ = bound(dur_, 2 * SIX_DAYS, MAX_TIME);
        col_ = uint8(bound(col_, 0, 4));
        address sellerDelegatee = delegateeA;
        if (sellerDelegateeSaturated_) _saturate(sellerDelegatee);
        (address target, bool targetSaturated) = _column(col_, sellerDelegatee, sellerDelegateeSaturated_);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, dur_);
        enable(victim, id);
        delegateTo(victim, id, sellerDelegatee);
        warpToPhase(phase_);

        (bool ok, ) = _transfer(id, victim, recipient, byOperator_, HEMI_TX_CAP);
        assertTrue(ok, "T2: armed transfer refused");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T2: flag survived");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertFalse(_isFlat(d), "T2: PHANTOM");
        if (targetSaturated) assertEq(d.delegatee, address(0), "T2: saturated target, record not removed");
        else assertEq(d.delegatee, target, "T2: healthy target under-counted");
        _assertNoPhantomFarFuture(sellerDelegatee, "T2: phantom on the seller's delegatee");
        _assertNoPhantomFarFuture(target, "T2: phantom on the recipient's delegate");
    }

    // ===================================================================
    // T3 -- WHALE: a single position whose slope alone exceeds uint64.
    // ===================================================================

    function test_T3_whaleUnderCountsNeverPhantom() public {
        uint256 amt = (uint256(type(uint64).max) + 1) * MAX_TIME;
        (uint256 id, , ) = createLock(victim, amt, 4 * 365 days);
        // The mint's decaying booking overflowed and was swallowed.
        assertEq(delegation.delegation(id).delegatee, address(0), "T3: premise -- mint booking not empty");
        enable(victim, id);
        // The owner books it FLAT (a flat booking adds no slope).
        delegateTo(victim, id, delegateeA);
        assertTrue(_isFlat(delegation.delegation(id)), "T3: premise -- whale not flat at delegateeA");
        vm.warp(block.timestamp + 7200);
        _setAutoDelegate(recipient, delegateeB);

        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T3: whale transfer refused");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T3: flag survived");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, address(0), "T3: whale record not removed");
        assertEq(d.bias, 0, "T3: whale record kept bias");
        bytes4[] memory reasons = _reasons(logs);
        assertEq(reasons.length, 1, "T3: one DelegationUpdateFailedReason");
        assertEq(reasons[0], SEL_SLOPE_OVERFLOW, "T3: whale move refused with an unexpected reason");
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0, "T3: Unverified");
        _assertNoPhantomFarFuture(delegateeA, "T3: phantom on delegateeA");
    }

    // ===================================================================
    // T4 -- BROKEN / HOSTILE MODULES installed after arming.
    // ===================================================================

    function _armedFlat() internal returns (uint256 id) {
        id = _armedOn(delegateeA);
    }

    function test_T4_revertingModule_bothRefused_announced() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new RevertingVoteDelegation());
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: principal-carrying transfer refused behind a broken module");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T4: flag survived");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 2,
            "T4: move and removal both swallowed");
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1,
            "T4: both-refused not announced");
    }

    function test_T4_lyingModule_readBackAnnounces() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new LyingVoteDelegation(IVeHemiVoteDelegation(address(delegation))));
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: transfer refused");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 0, "T4: the lie was not accepted");
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1,
            "T4: read-back did not announce the lie");
    }

    /// @dev Stop the liar refusing so the move COMMITS, then let the read-back
    ///      judge a seeded record: a flat one is announced, a decaying one is
    ///      not.
    function test_T4_committedMove_readBackJudgesTheRecord() public {
        uint256 id = _armedFlat();
        SlopeOverflowLiar liar = new SlopeOverflowLiar();
        liar.stopRefusing();
        liar.seed(id, delegateeA, uint96(PRINCIPAL / 2), 0); // FLAT
        veHemi.updateVoteDelegation(liar);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1,
            "T4: flat read-back not announced");
        vm.revertToState(snap);
        liar.seed(id, delegateeA, uint96(PRINCIPAL / 2), uint64(PRINCIPAL / MAX_TIME)); // DECAYING
        vm.recordLogs();
        (ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0,
            "T4: decaying read-back falsely announced");
    }

    /// @dev A known limitation, asserted: a module that refuses the move and
    ///      accepts the removal as a silent no-op leaves ITS OWN record flat,
    ///      and VeHemi cannot see it (the removal "committed"). Expected-silent.
    function test_T4_knownLimitation_rejectMoveNoopRemoval_isSilent() public {
        uint256 id = _armedFlat();
        RejectMoveNoopRemovalModule module = new RejectMoveNoopRemovalModule();
        module.seedFlat(id, delegateeA, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(module);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 1,
            "T4/known limitation: move refusal not reported");
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0,
            "T4/known limitation: silent");
        assertTrue(_isFlat(module.delegation(id)), "T4/known limitation: premise -- module record flat");
    }

    /// @dev Conservative announcement: an EMPTY record behind a module that
    ///      refuses everything still announces (it could not perform the write).
    function test_T4_emptyRecordBehindRevertingModule_conservativeAnnounce() public {
        // Mint while VeHemi points at a reverting module: the real VVD never
        // books the position, so its record there is empty.
        RevertingVoteDelegation revertingModule = new RevertingVoteDelegation();
        IVeHemiVoteDelegation realDelegation = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(revertingModule);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(realDelegation);
        enable(victim, id);
        assertEq(delegation.delegation(id).delegatee, address(0), "T4: premise -- record not empty");
        veHemi.updateVoteDelegation(revertingModule);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1,
            "T4: conservative announcement missing");
    }

    /// @dev Asserted: a module whose `delegation()` returns undecodable data
    ///      (`GarbageModule`, whose `delegate()` returns) makes the read-back
    ///      revert (an ABI decode failure is not caught by try/catch), so an
    ///      ARMED transfer is refused while an UNARMED one -- which never
    ///      reads -- succeeds.
    function test_T4_garbageRead_armedRefused_unarmedSucceeds() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(new GarbageModule());
        (bool okArmed, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        (bool okPlain, ) = _transfer(plain, victim, recipient, false, HEMI_TX_CAP);
        assertFalse(okArmed, "T4: armed transfer behind garbage reads");
        assertTrue(okPlain, "T4: unarmed transfer must not read");
    }

    // ===================================================================
    // T5 -- THE 29.93M PER-TX FRAME (owner and approved operator).
    // ===================================================================

    function test_T5_gasExhaustingModule_executes() public {
        for (uint256 k; k < 2; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 id = _armedFlat();
            veHemi.updateVoteDelegation(new OogVoteDelegation());
            (bool ok, ) = _transfer(id, victim, recipient, k == 1, HEMI_TX_CAP);
            assertTrue(ok, "T5: module-hostile armed transfer does not fit 29.93M");
            assertEq(veHemi.autoRelockRemaining(id), 0);
            vm.revertToState(snap);
        }
    }

    function test_T5_burnAndRevertModule_executes() public {
        for (uint256 k; k < 2; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 id = _armedFlat();
            veHemi.updateVoteDelegation(new BurnAndRevertModule());
            vm.recordLogs();
            (bool ok, ) = _transfer(id, victim, recipient, k == 1, HEMI_TX_CAP);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(ok, "T5: burn-and-revert armed transfer does not fit 29.93M");
            assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1);
            vm.revertToState(snap);
        }
    }

    function test_T5_returndataBomb_executesWithBoundedCopy() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new RevertBombModule(2_000_000));
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T5: returndata bomb blocked the armed transfer");
        bytes4[] memory reasons = _reasons(logs);
        assertEq(reasons.length, 2, "T5: two swallowed calls");
        assertEq(reasons[0], bytes4(0), "T5: zero-filled bomb selector");
    }

    function test_T5_burnAndReturnDistributor_executes() public {
        uint256 id = _armedFlat();
        veHemi.updateRewardDistributor(new BurnAndReturnDistributor());
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok, "T5: distributor-hostile armed transfer does not fit 29.93M");
        assertEq(delegation.delegation(id).delegatee, recipient, "T5: not moved");
    }

    /// @dev A known limitation, asserted: both hostile -> the armed transfer
    ///      cannot execute at 29.93M; the unarmed twin can.
    function test_T5_bothHostile_armedReverts_unarmedExecutes() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(new OogVoteDelegation());
        veHemi.updateRewardDistributor(new BurnAndReturnDistributor());
        (bool okArmed, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        (bool okPlain, ) = _transfer(plain, victim, recipient, false, HEMI_TX_CAP);
        assertFalse(okArmed, "T5: (known limitation) both-hostile armed transfer");
        assertTrue(okPlain, "T5: unarmed twin must execute");
    }

    // ===================================================================
    // T11 -- THE FALLBACK REMOVAL IS ALWAYS HANDED THE WHOLE CEILING.
    //   Swept over gas limits: whenever the transfer commits with a removal,
    //   the module saw (nearly) the full DELEGATION_GAS_CEILING; below the
    //   floor the transfer reverts DelegationCallStarved. Monotone.
    // ===================================================================

    function _sweepRemovalGas(address module_, uint256 minEntry_) internal {
        uint256 id = _armedFlat();
        RemovalGasProbeModule(module_).seedFlat(id, delegateeA, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(module_));
        uint256 commits;
        uint256 starvedReverts;
        bool seenCommit;
        for (uint256 gasLimit = 150_000; gasLimit <= 10_000_000; gasLimit += 50_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _transfer(id, victim, recipient, false, gasLimit);
            if (ok) {
                ++commits;
                seenCommit = true;
                assertEq(RemovalGasProbeModule(module_).removals(), 1, "T11: committed without a removal");
                assertGe(RemovalGasProbeModule(module_).removalGasAtEntry(), minEntry_, "T11: removal STARVED yet committed");
            } else {
                assertFalse(seenCommit, "T11: gas response not monotone");
                if (ret.length >= 4 && bytes4(ret) == VeHemi.DelegationCallStarved.selector) ++starvedReverts;
            }
            vm.revertToState(snap);
        }
        assertGt(commits, 0, "T11: vacuous -- never committed");
        assertGt(starvedReverts, 0, "T11: vacuous -- the floor never fired");
    }

    function test_T11_directModule_removalGetsFullCeiling() public {
        _sweepRemovalGas(address(new RemovalGasProbeModule()), DELEGATION_GAS_CEILING - 2_000);
    }

    /// @dev `ERC1967Proxy` stands in for the live VVD's proxy, an OZ
    ///      4.x `TransparentUpgradeableProxy`. Both forward with
    ///      `delegatecall(gas())`; the TUP's `_beforeFallback` adds the admin
    ///      check (one more SLOAD, cold on the first call), so the module
    ///      behind it gets slightly less of the ceiling (derived: about
    ///      7,874,321 warm / 7,867,923 cold, against 7,867,000 asserted here).
    ///      The removal gas floor depends only on the CALL's 63/64 rule, which
    ///      neither proxy changes.
    function test_T11_proxiedModule_removalGetsFullCeiling() public {
        RemovalGasProbeModule impl = new RemovalGasProbeModule();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        // Behind a delegatecall proxy the module keeps 63/64 of the ceiling.
        _sweepRemovalGas(address(proxy), (DELEGATION_GAS_CEILING * 63) / 64 - 8_000);
    }

    // ===================================================================
    // T6 -- PROXIED REAL VVD, DORMANT SELLER'S DELEGATEE: sweep the caller's gas limit.
    //   Behind a proxy `_requireNotStarved` cannot fire (an OOG callee hands
    //   back ~1/32). Whatever the gas limit: either the transfer reverts, or
    //   it commits with no flat record -- and a HEALTHY recipient is never
    //   under-counted by gas choice.
    // ===================================================================

    function _useProxiedVVD() internal {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(proxy));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(proxy)));
    }

    function _dormantSweep(bool targetSaturated_, uint256 minGas_, uint256 maxGas_, uint256 gasStep_, bool mustCommit_)
        internal
        returns (uint256 commits)
    {
        _useProxiedVVD();
        uint256 id = _armedOn(delegateeA);
        vm.warp(block.timestamp + 200 * SIX_DAYS); // the seller's delegatee untouched for 200 buckets
        veHemi.checkpoint();
        address target = targetSaturated_ ? delegateeC : delegateeB;
        if (targetSaturated_) _saturate(delegateeC);
        _setAutoDelegate(recipient, target);
        for (uint256 gasLimit = minGas_; gasLimit <= maxGas_; gasLimit += gasStep_) {
            uint256 snap = vm.snapshotState();
            (bool ok, ) = _transfer(id, victim, recipient, false, gasLimit);
            if (ok) {
                ++commits;
                IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
                assertEq(veHemi.autoRelockRemaining(id), 0, "T6: flag survived a commit");
                assertFalse(_isFlat(d), "T6: PHANTOM committed at a chosen gas limit");
                if (targetSaturated_) assertEq(d.delegatee, address(0), "T6: saturated cell landed somewhere");
                else assertEq(d.delegatee, target, "T6: HEALTHY recipient under-counted by gas choice");
            }
            vm.revertToState(snap);
        }
        if (mustCommit_) assertGt(commits, 0, "T6: vacuous -- never committed");
    }

    function test_T6_proxied_dormant_healthyRecipient_gas100kTo3M() public {
        _dormantSweep(false, 100_000, 3_000_000, 10_000, true);
    }
    function test_T6_proxied_dormant_healthyRecipient_gas3MTo12M() public {
        _dormantSweep(false, 3_000_000, 12_000_000, 100_000, true);
    }
    /// @dev Below the removal gas floor the fallback removal cannot
    ///      run, so nothing in this band may commit; the law is checked on
    ///      whatever does.
    function test_T6_proxied_dormant_saturatedRecipient_noCommitBelowRemovalFloor() public {
        assertEq(_dormantSweep(true, 100_000, 3_000_000, 10_000, false), 0, "T6: commit below the removal gas floor");
    }
    function test_T6_proxied_dormant_saturatedRecipient_gas3MTo12M() public {
        _dormantSweep(true, 3_000_000, 12_000_000, 25_000, true);
    }

    /// @dev The same sweep against the DIRECT (unproxied) VVD, where the
    ///      tripwire is live: same law.
    function test_T6_direct_dormant_saturatedRecipient() public {
        uint256 id = _armedOn(delegateeA);
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        veHemi.checkpoint();
        _saturate(delegateeC);
        _setAutoDelegate(recipient, delegateeC);
        uint256 commits;
        for (uint256 gasLimit = 100_000; gasLimit <= 12_000_000; gasLimit += 50_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, ) = _transfer(id, victim, recipient, false, gasLimit);
            if (ok) {
                ++commits;
                assertFalse(_isFlat(delegation.delegation(id)), "T6: PHANTOM (direct)");
            }
            vm.revertToState(snap);
        }
        assertGt(commits, 0, "T6: vacuous (direct)");
    }

    // ===================================================================
    // T7 -- CALL COUNTS (no trusted adapter: the adapter reads delegation()).
    // ===================================================================

    function _expectModuleCalls(uint64 autoDelegateReads_, uint64 delegateCalls_, uint64 delegationReads_) internal {
        vm.expectCall(
            address(delegation), abi.encodeWithSelector(IVeHemiVoteDelegation.autoDelegate.selector), autoDelegateReads_
        );
        vm.expectCall(address(delegation), abi.encodeWithSelector(IVeHemiVoteDelegation.delegate.selector), delegateCalls_);
        vm.expectCall(
            address(delegation), abi.encodeWithSelector(IVeHemiVoteDelegation.delegation.selector), delegationReads_
        );
    }

    function test_T7_counts_armedHappy() public {
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeB);
        _expectModuleCalls(1, 1, 1);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
    }

    function test_T7_counts_armedSaturated() public {
        _saturate(delegateeC);
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeC);
        _expectModuleCalls(1, 2, 0);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
    }

    function test_T7_counts_unarmed() public {
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        _expectModuleCalls(1, 1, 0);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
    }

    function test_T7_counts_armedSelfTransfer() public {
        uint256 id = _armedFlat();
        _expectModuleCalls(1, 1, 0);
        (bool ok, ) = _transfer(id, victim, victim, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertGt(veHemi.autoRelockRemaining(id), 0, "T7: self-transfer disarmed");
    }

    /// @dev Exactly two reward notifications on an armed transfer; the FIRST
    ///      sees the flat weight (before the flag clears), the LAST sees the
    ///      post-transfer weight (the re-anchor). One on unarmed / self.
    function test_T7_rewardNotifications_bracketTheDisarm() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        CountingDistributor distributor = new CountingDistributor(address(veHemi));
        veHemi.updateRewardDistributor(distributor);
        uint256 wFlat = veHemi.balanceOfNFT(id);

        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(distributor.notificationCountFor(id), 2, "T7: armed transfer must notify exactly twice");
        assertEq(distributor.weightAtNotification(id, 0), wFlat, "T7: notify-before did not see the flat weight");
        assertEq(
            distributor.weightAtNotification(id, 1), veHemi.balanceOfNFT(id), "T7: re-anchor did not see the new weight"
        );
        assertTrue(distributor.weightAtNotification(id, 1) != wFlat, "T7: premise -- disarm moved no weight");

        (ok, ) = _transfer(plain, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(distributor.notificationCountFor(plain), 1, "T7: unarmed transfer must notify once");

        uint256 id2 = _armedFlat();
        uint256 before2 = distributor.notificationCountFor(id2); // mint + arm notifications
        (ok, ) = _transfer(id2, victim, victim, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(distributor.notificationCountFor(id2) - before2, 1, "T7: self-transfer must notify once");
    }

    // ===================================================================
    // T8 -- EVENT STREAM (no adapter; emitter-filtered).
    // ===================================================================

    function _delegateChangedArgs(Vm.Log memory l_) internal pure returns (uint256 id, address from, address to) {
        id = uint256(l_.topics[1]);
        from = address(uint160(uint256(l_.topics[2])));
        to = address(uint160(uint256(l_.topics[3])));
    }

    function test_T8_stream_happyPath() public {
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeB);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        uint256 disabledIndex = _firstIndex(logs, address(veHemi), TOPIC_AUTO_RELOCK_DISABLED);
        uint256 transferIndex = _firstIndex(logs, address(veHemi), TOPIC_TRANSFER);
        uint256 delegateChangedIndex = _firstIndex(logs, address(delegation), TOPIC_DELEGATE_CHANGED);
        assertLt(disabledIndex, transferIndex, "T8: AutoRelockDisabled must precede Transfer");
        assertLt(transferIndex, delegateChangedIndex, "T8: every delegation write must follow Transfer");
        assertEq(_count(logs, address(delegation), TOPIC_DELEGATE_CHANGED), 1, "T8: exactly one DelegateChanged");
        (uint256 eventTokenId, address from, address to) = _delegateChangedArgs(logs[delegateChangedIndex]);
        assertEq(eventTokenId, id);
        assertEq(from, delegateeA, "T8: from != the seller's delegatee");
        assertEq(to, delegateeB, "T8: to != the recipient's delegate");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 0);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0);
    }

    function test_T8_stream_sameDelegate() public {
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeA);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(delegation), TOPIC_DELEGATE_CHANGED), 1,
            "T8: exactly one DelegateChanged (same column)");
        (, address from, address to) =
            _delegateChangedArgs(logs[_firstIndex(logs, address(delegation), TOPIC_DELEGATE_CHANGED)]);
        assertEq(from, delegateeA);
        assertEq(to, delegateeA);
    }

    function test_T8_stream_underCount() public {
        _saturate(delegateeC);
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeC);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        uint256 transferIndex = _firstIndex(logs, address(veHemi), TOPIC_TRANSFER);
        uint256 delegateChangedIndex = _firstIndex(logs, address(delegation), TOPIC_DELEGATE_CHANGED);
        assertLt(transferIndex, delegateChangedIndex, "T8: a delegation write before Transfer");
        // NOTE: `vm.recordLogs` also returns logs emitted inside the REVERTED
        // move frame (DelegateChanged from the seller's delegatee to the
        // recipient's delegate); a real receipt does not contain them. The
        // committed write is the removal.
        uint256 removals;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(delegation) && logs[i].topics[0] == TOPIC_DELEGATE_CHANGED) {
                (, address from, address to) = _delegateChangedArgs(logs[i]);
                assertEq(from, delegateeA, "T8: from != the seller's delegatee");
                if (to == address(0)) ++removals;
                else assertEq(to, delegateeC, "T8: unexpected move target");
            }
        }
        assertEq(removals, 1, "T8: exactly one removal");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 1);
    }

    // ===================================================================
    // T9 -- EDGES.
    // ===================================================================

    function test_T9_armedWithEmptyRecord_movesCleanly() public {
        RevertingVoteDelegation revertingModule = new RevertingVoteDelegation();
        IVeHemiVoteDelegation realDelegation = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(revertingModule);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(realDelegation);
        enable(victim, id);
        assertEq(delegation.delegation(id).delegatee, address(0), "T9: premise");
        _setAutoDelegate(recipient, delegateeB);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, delegateeB, "T9: empty record not booked at the target");
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0);
    }

    function test_T9_twoTransfersSameHour() public {
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeB);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        vm.warp(block.timestamp + 60);
        (ok, ) = _transfer(id, recipient, charlie, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, charlie, "T9: second hop");
        assertFalse(_isFlat(d));
        _assertNoPhantomFarFuture(delegateeA, "T9: phantom on the first delegate");
        _assertNoPhantomFarFuture(delegateeB, "T9: phantom on the second delegate");
    }

    /// @dev A known limitation: a distributor re-entering the delegation
    ///      module through the permissionless `retireStrandedFlatTerm` in the
    ///      re-anchor (flag clear, record still flat) changes nothing final.
    function test_T9_reentrantDistributor_sameFinalState() public {
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeB);
        uint256 snap = vm.snapshotState();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory recordWithoutReentry = delegation.delegation(id);
        vm.warp(block.timestamp + 1);
        uint256 delegateeAVotesWithoutReentry = delegation.getVotes(delegateeA);
        uint256 delegateeBVotesWithoutReentry = delegation.getVotes(delegateeB);
        vm.revertToState(snap);

        RetireStrandedFlatTermDistributor distributor = new RetireStrandedFlatTermDistributor(address(delegation));
        distributor.setTarget(id);
        veHemi.updateRewardDistributor(distributor);
        (ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(distributor.attempts(), 2, "T9: premise -- notify-before + re-anchor");
        assertEq(distributor.successes(), 1, "T9: premise -- the re-entry did not retire anything");
        IVeHemiVoteDelegation.Delegation memory recordWithReentry = delegation.delegation(id);
        assertEq(recordWithReentry.delegatee, recordWithoutReentry.delegatee);
        assertEq(recordWithReentry.bias, recordWithoutReentry.bias);
        assertEq(recordWithReentry.slope, recordWithoutReentry.slope);
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(delegateeA), delegateeAVotesWithoutReentry,
            "T9: the seller's delegatee's votes differ under re-entry");
        assertEq(delegation.getVotes(delegateeB), delegateeBVotesWithoutReentry,
            "T9: the recipient's delegate's votes differ under re-entry");
    }

    // ===================================================================
    // T10 -- TRANSFERS THAT DO NOT DISARM (SELF AND UNARMED).
    // ===================================================================

    /// @dev An owner's armed SELF-transfer into a saturated autoDelegate stays
    ///      armed and flat: the flat booking adds no slope, so it moves.
    function test_T10_armedSelfTransfer_staysArmedAndFlat() public {
        _saturate(delegateeC);
        uint256 id = _armedFlat();
        uint64 remainingBefore = veHemi.autoRelockRemaining(id);
        _setAutoDelegate(victim, delegateeC);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, victim, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(veHemi.autoRelockRemaining(id), remainingBefore, "T10: self-transfer changed the arm");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertTrue(_isFlat(d), "T10: armed self-transfer is no longer flat");
        assertEq(d.delegatee, delegateeC);
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 0);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_DISABLED), 0);
    }

    function test_T10_unarmedTransferMovesToRecipientDelegateWithoutDisarm() public {
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        _setAutoDelegate(recipient, delegateeB);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, delegateeB);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_DISABLED), 0);
        assertEq(_count(logs, address(delegation), TOPIC_DELEGATE_CHANGED), 1);
    }

    /// @dev An UNARMED transfer into a saturated delegate keeps the BASE
    ///      behaviour: the refused write leaves the decaying record where it
    ///      was (misattributed, weight-correct). The armed/unarmed divergence
    ///      is deliberate: only an ARMED transfer removes the record on a
    ///      refused move (normally flat; a decaying record that a swallowed
    ///      enable left on an armed position is removed too -- see T9).
    function test_T10_unarmedIntoSaturated_keepsDecayingRecord() public {
        _saturate(delegateeC);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        delegateTo(victim, id, delegateeA);
        _setAutoDelegate(recipient, delegateeC);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, delegateeA, "T10: unarmed record moved");
        assertGt(d.slope, 0);
    }

    // ===================================================================
    // DOUBLE REFUSALS, ARMED DECAYING, STALE-RETIRED AND UNREADABLE RECORDS,
    // NOTIFICATION ORDER (T4, T7b, T7c, T9, T10).
    // ===================================================================

    /// @dev The fallback removal must be non-strict (`strict_ = false`): a module that
    ///      refuses BOTH writes with the overflow selector must still let the
    ///      armed transfer commit (and announce), never revert.
    function test_T4_bothRefusedWithOverflowSelector_stillCommits() public {
        uint256 id = _armedFlat();
        SlopeOverflowLiar liar = new SlopeOverflowLiar(); // refusing: every delegate() raises 0xf2b4513c
        liar.seed(id, delegateeA, uint96(PRINCIPAL / 2), 0);
        veHemi.updateVoteDelegation(liar);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: transfer reverted on the overflow selector (removal must be non-strict)");
        bytes4[] memory reasons = _reasons(logs);
        assertEq(reasons.length, 2);
        assertEq(reasons[0], SEL_SLOPE_OVERFLOW);
        assertEq(reasons[1], SEL_SLOPE_OVERFLOW);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1);
    }

    /// @dev Reward notifications on the REFUSED-move branches: still exactly two,
    ///      the first on the flat weight, the last on the post-transfer weight.
    function _assertTwoNotifies(uint256 id_, CountingDistributor distributor_, uint256 wFlat_) internal view {
        assertEq(distributor_.notificationCountFor(id_), 2, "T7b: armed transfer must notify exactly twice");
        assertEq(distributor_.weightAtNotification(id_, 0), wFlat_, "T7b: notify-before did not see the flat weight");
        assertEq(
            distributor_.weightAtNotification(id_, 1),
            veHemi.balanceOfNFT(id_),
            "T7b: re-anchor did not see the new weight"
        );
    }

    function test_T7b_rewardNotifications_refusedMoveBranches() public {
        // (a) real VVD, saturated recipient delegate: move refused, removal accepted.
        uint256 snap = vm.snapshotState();
        _saturate(delegateeC);
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeC);
        CountingDistributor distributor = new CountingDistributor(address(veHemi));
        veHemi.updateRewardDistributor(distributor);
        uint256 wFlat = veHemi.balanceOfNFT(id);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, address(0), "T7b: premise -- not the removal branch");
        _assertTwoNotifies(id, distributor, wFlat);
        vm.revertToState(snap);

        // (b) a module refusing both writes.
        id = _armedFlat();
        MixedFailureModule module = new MixedFailureModule();
        module.seedFlat(id, delegateeA, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(module);
        distributor = new CountingDistributor(address(veHemi));
        veHemi.updateRewardDistributor(distributor);
        wFlat = veHemi.balanceOfNFT(id);
        vm.recordLogs();
        (ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1,
            "T7b: premise -- not the both-refused branch");
        _assertTwoNotifies(id, distributor, wFlat);
    }

    /// @dev An armed position whose VVD record is still DECAYING (the enable's
    ///      re-book was swallowed behind a broken module, then the module was
    ///      repaired): the transfer moves it like any record, or removes it
    ///      when the recipient's delegate refuses -- unlike an UNARMED transfer.
    function _armedWithDecayingRecord() internal returns (uint256 id) {
        (id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        delegateTo(victim, id, delegateeA);
        IVeHemiVoteDelegation realDelegation = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(new RevertingVoteDelegation());
        enable(victim, id);
        veHemi.updateVoteDelegation(realDelegation);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        require(d.delegatee == delegateeA && d.slope > 0 && veHemi.autoRelockRemaining(id) != 0,
            "T9: premise -- not an armed decaying record");
        vm.warp(block.timestamp + 7200);
    }

    /// @dev Votes at t0+1 with and without the transfer (snapshot
    ///      counterfactual, as in T1): the armed DECAYING record's weight leaves
    ///      the seller's delegatee exactly, and lands on the target when it is
    ///      healthy.
    function _armedDecayingRecordCell(bool targetSaturated_) internal {
        address target = targetSaturated_ ? delegateeC : delegateeB;
        if (targetSaturated_) _saturate(delegateeC);
        uint256 id = _armedWithDecayingRecord();
        _setAutoDelegate(recipient, target);
        uint256 t0 = block.timestamp;
        IVeHemiVoteDelegation.Delegation memory pre = delegation.delegation(id);

        uint256 s1 = vm.snapshotState();
        vm.warp(t0 + 1);
        uint256 sellerDelegateeVotesWithoutTransfer = delegation.getVotes(delegateeA);
        uint256 targetVotesWithoutTransfer = delegation.getVotes(target);
        vm.revertToState(s1);

        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 0);
        assertEq(uint256(int256(veHemi.getLockedBalance(id).amount)), PRINCIPAL, "T9: principal changed");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);

        vm.warp(t0 + 1);
        // The seller's delegatee holds ONLY the victim's decaying record in this
        // rig, so the whole of its weight must leave: positive without the
        // transfer, exactly zero with it.
        require(pre.delegatee == delegateeA && sellerDelegateeVotesWithoutTransfer > 0,
            "T9: premise -- the seller's delegatee holds no weight");
        uint256 tol = 2 * (PRINCIPAL / MAX_TIME) + 2;
        assertEq(delegation.getVotes(delegateeA), 0, "T9: decaying weight did not leave the seller's delegatee");
        if (targetSaturated_) {
            assertEq(d.delegatee, address(0), "T9: armed refused move must remove the record");
            assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 1);
            assertEq(delegation.getVotes(target), targetVotesWithoutTransfer, "T9: saturated target changed");
        } else {
            assertEq(d.delegatee, delegateeB, "T9: armed decaying record not moved");
            assertEq(uint256(d.end), uint256(veHemi.getLockedBalance(id).end), "T9: moved record end");
            assertApproxEqAbs(delegation.getVotes(delegateeB), targetVotesWithoutTransfer + veHemi.balanceOfNFT(id), tol,
                "T9: target did not gain the weight");
        }
    }

    function test_T9_armedDecayingRecord_healthyTarget_moves() public { _armedDecayingRecordCell(false); }

    function test_T9_armedDecayingRecord_saturatedTarget_removed() public { _armedDecayingRecordCell(true); }

    /// @dev The move commits and the record cannot be READ (the read-back's
    ///      catch): the transfer commits and announces once.
    function test_T4_committedMove_unreadableRecord_announces() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new ReadRevertingModule());
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: unreadable module refused the armed transfer");
        assertEq(_count(logs, address(veHemi), TOPIC_DELEGATION_UPDATE_FAILED), 0);
        assertEq(_count(logs, address(veHemi), TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED), 1,
            "T4: unreadable read-back not announced");
    }

    /// @dev Mint-and-arm, then transfer in the SAME block.
    function test_T9_createLockWithAutoRelock_thenTransferSameBlock() public {
        hemi.mint(victim, PRINCIPAL);
        vm.prank(victim);
        uint256 id = veHemi.createLockWithAutoRelock(PRINCIPAL, 4 * 365 days, true, false);
        assertGt(veHemi.autoRelockRemaining(id), 0, "T9: premise -- not armed");
        _setAutoDelegate(recipient, delegateeB);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(veHemi.autoRelockRemaining(id), 0);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertFalse(_isFlat(d), "T9: PHANTOM after same-block mint+arm+transfer");
        assertEq(d.delegatee, delegateeB);
        _assertNoPhantomFarFuture(victim, "T9: phantom on the minter's self-delegation");
    }

    /// @dev Asserted: a position disarmed EARLIER by the permissionless
    ///      stale-retire on the seller's saturated delegatee keeps its flat
    ///      record; a later transfer is UNARMED and into a saturated target
    ///      leaves that record where it was. The armed-transfer leg does not
    ///      touch this path.
    function test_T10_staleRetiredFlatRecord_staysOnUnarmedTransferIntoASaturatedDelegate() public {
        _saturate(delegateeA);
        _saturate(delegateeC);
        uint256 id = _armedOn(delegateeA);
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0);
        assertTrue(_isFlat(delegation.delegation(id)), "T10: premise -- the stale retire did not leave the flat record");
        _setAutoDelegate(recipient, delegateeC);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertTrue(_isFlat(d) && d.delegatee == delegateeA, "T10: stale-retired flat record unchanged by an unarmed transfer");
    }

    /// @dev The transfer's reward notifications settle the SELLER's segment:
    ///      both (armed) and the single one (unarmed, here sent by an approved
    ///      operator) run while the seller still owns the token. This catches
    ///      a notification moved after `super.transferFrom`, which T7/T7b
    ///      cannot see (weights do not change across the ERC-721 transfer).
    function test_T7c_rewardNotificationsSeeTheSeller() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        OwnerRecordingDistributor distributor = new OwnerRecordingDistributor(address(veHemi));
        veHemi.updateRewardDistributor(distributor);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(distributor.notificationCountFor(id), 2, "T7c: armed transfer must notify twice");
        assertEq(distributor.ownerAtNotification(id, 0), victim, "T7c: notify-before did not see the seller");
        assertEq(distributor.ownerAtNotification(id, 1), victim, "T7c: re-anchor ran after the ownership change");
        (ok, ) = _transfer(plain, victim, recipient, true, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(distributor.notificationCountFor(plain), 1, "T7c: unarmed transfer must notify once");
        assertEq(distributor.ownerAtNotification(plain, 0), victim, "T7c: unarmed notify did not see the seller");
    }

    // ---- T8 with the REAL Aragon adapter wired --------------------------

    bytes32 internal constant TOPIC_ADAPTER_DELEGATE_CHANGED = keccak256("DelegateChanged(address,address,address)");

    function _wireAdapter() internal returns (address) {
        VeHemiAragonAdapter adapter = new VeHemiAragonAdapter(address(veHemi));
        delegation.setTrustedAdapter(address(adapter));
        return address(adapter);
    }

    function _adapterDelegateChanged(Vm.Log[] memory logs_, address adapter_, address delegator_)
        internal
        pure
        returns (uint256 n, address from, address to)
    {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == adapter_ && logs_[i].topics.length == 4
                && logs_[i].topics[0] == TOPIC_ADAPTER_DELEGATE_CHANGED
                && address(uint160(uint256(logs_[i].topics[1]))) == delegator_) {
                ++n;
                from = address(uint160(uint256(logs_[i].topics[2])));
                to = address(uint160(uint256(logs_[i].topics[3])));
            }
        }
    }

    function test_T8_adapter_happyPath_singlePositionRecipient() public {
        address adapter = _wireAdapter();
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeB);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        (uint256 recipientRelays, address from, address to) = _adapterDelegateChanged(logs, adapter, recipient);
        assertEq(recipientRelays, 1, "T8/adapter: one relay for the recipient");
        assertEq(from, delegateeA);
        assertEq(to, delegateeB);
        (uint256 sellerRelays, , ) = _adapterDelegateChanged(logs, adapter, victim);
        assertEq(sellerRelays, 0, "T8/adapter: a relay attributed to the SELLER");
    }

    function test_T8_adapter_underCount_singlePositionRecipient() public {
        address adapter = _wireAdapter();
        _saturate(delegateeC);
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeC);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        (uint256 recipientRelays, address from, address to) = _adapterDelegateChanged(logs, adapter, recipient);
        assertEq(recipientRelays, 1, "T8/adapter: one relay for the recipient");
        assertEq(from, delegateeA);
        assertEq(to, address(0), "T8/adapter: under-count relay must read (recipient, the seller's delegatee, 0)");
        (uint256 sellerRelays, , ) = _adapterDelegateChanged(logs, adapter, victim);
        assertEq(sellerRelays, 0, "T8/adapter: a relay attributed to the SELLER");
    }

    /// @dev Asserted (the adapter's own mixed-state suppression): a recipient
    ///      whose positions end up with DIFFERENT delegates gets no relay.
    function test_T8_adapter_mixedRecipient_isSilent() public {
        address adapter = _wireAdapter();
        createLock(recipient, PRINCIPAL, 4 * 365 days); // self-delegated
        uint256 id = _armedFlat();
        _setAutoDelegate(recipient, delegateeB);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, delegateeB, "T8/adapter: premise -- moved");
        (uint256 recipientRelays, , ) = _adapterDelegateChanged(logs, adapter, recipient);
        assertEq(recipientRelays, 0, "T8/adapter: mixed recipient relays nothing");
    }

    // ---- T11, fine-grained at the boundary ------------------------------

    /// @dev Find the smallest committing gas limit (coarse), then sweep the
    ///      60k below it in 1k steps: everything there must revert (monotone),
    ///      and at the boundary the removal still gets (nearly) the whole ceiling.
    function test_T11_removalGasBoundary_fineSweep() public {
        uint256 id = _armedFlat();
        RemovalGasProbeModule module = new RemovalGasProbeModule();
        module.seedFlat(id, delegateeA, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(module);
        uint256 firstCommittingGas;
        for (uint256 gasLimit = 8_000_000; gasLimit <= 10_000_000; gasLimit += 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, ) = _transfer(id, victim, recipient, false, gasLimit);
            vm.revertToState(snap);
            if (ok) { firstCommittingGas = gasLimit; break; }
        }
        assertGt(firstCommittingGas, 0, "T11: vacuous -- no commit in range");
        for (uint256 gasLimit = firstCommittingGas - 60_000; gasLimit <= firstCommittingGas; gasLimit += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _transfer(id, victim, recipient, false, gasLimit);
            if (ok) {
                assertGe(
                    module.removalGasAtEntry(),
                    DELEGATION_GAS_CEILING - 2_000,
                    "T11: boundary commit with a short removal"
                );
            } else {
                assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "T11: below the floor must be DelegationCallStarved");
            }
            vm.revertToState(snap);
        }
    }

    // ===================================================================
    // T12 -- BOUNDED SELECTOR COPY (through VeHemi) AND STRICT RE-RAISE.
    // ===================================================================

    function _expectedSelector(bytes memory data_) internal pure returns (bytes4 r) {
        bytes memory selectorBytes = new bytes(4);
        for (uint256 i; i < 4 && i < data_.length; ++i) selectorBytes[i] = data_[i];
        r = bytes4(selectorBytes);
    }

    function test_T12_failureReasonForEveryRevertLength() public {
        uint256[7] memory revertLengths = [uint256(0), 1, 3, 4, 5, 68, 200];
        for (uint256 k; k < revertLengths.length; ++k) {
            uint256 snap = vm.snapshotState();
            (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
            bytes memory data = new bytes(revertLengths[k]);
            for (uint256 i; i < data.length; ++i) data[i] = bytes1(uint8(0xA1 + i));
            RawRevertModule module = new RawRevertModule();
            module.setData(data);
            veHemi.updateVoteDelegation(module);
            vm.recordLogs();
            (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(ok);
            bytes4[] memory reasons = _reasons(logs);
            assertEq(reasons.length, 1);
            assertEq(reasons[0], _expectedSelector(data),
                "T12: DelegationUpdateFailedReason differs from bytes4(revert data)");
            vm.revertToState(snap);
        }
    }

    /// @dev Covers the scratch-word clear (`mstore(0x00, 0)`) in the bounded
    ///      selector copy: the second, SHORTER revert must not report the
    ///      first one's selector.
    function test_T12_failureReason_secondShorterRevertReportsZero() public {
        uint256 id = _armedFlat();
        MixedFailureModule module = new MixedFailureModule();
        module.seedFlat(id, delegateeA, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(module);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        bytes4[] memory reasons = _reasons(logs);
        assertEq(reasons.length, 2);
        assertEq(reasons[0], MixedFailureModule.MoveRefused.selector);
        assertEq(reasons[1], bytes4(0), "T12: stale scratch word reported for an empty revert");
    }

    /// @dev Strict leg on the REAL module: exactly the 4-byte selector.
    function test_T12_strictReraise_realModule_exactBytes() public {
        _saturate(delegateeA);
        uint256 id = _armedOn(delegateeA);
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(SEL_SLOPE_OVERFLOW), "T12: strict re-raise bytes differ");
    }

    /// @dev Strict leg with TRAILING DATA: forwarded byte for byte.
    function test_T12_strictReraise_forwardsWholePayload() public {
        uint256 id = _armedFlat();
        OverflowWithTailModule module = new OverflowWithTailModule();
        module.seedFlat(id, delegateeA, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(module);
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
        assertFalse(ok);
        assertEq(ret, abi.encodePacked(bytes4(0xf2b4513c), uint256(0xbeef), bytes3(0x112233)), "T12: payload truncated");
    }
}

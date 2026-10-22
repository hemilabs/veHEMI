// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import {RevertingVoteDelegation} from "../mocks/RevertingVoteDelegation.sol";
import {OogVoteDelegation} from "../k11/OogVoteDelegation.sol";
import {F09Counter} from "../f09/F09Mocks.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import "../q14/Q14Modules.sol";
import "./TD24Modules.sol";
import {VeHemiAragonAdapter} from "../../src/adapter/VeHemiAragonAdapter.sol";

/// @title  TD24 -- the armed-transfer leg ("move or remove").
///
/// @notice An ARMED position transferred to another account is disarmed by
///         `_disarmAutoRelock` BEFORE the ownership change (no module call),
///         and its flat term is retired AFTER it by one post-transfer
///         re-delegation:
///           1. MOVE to the recipient's resolved delegate; if accepted, read back;
///           2. if refused, REMOVE the record (the removal gas floor first, A1);
///           3. if that is refused too, announce `AutoRelockRetirementUnverified`.
///         THE LAW (behind an honest module, e.g. the real VVD): after any
///         committed armed transfer the position is never flat while its flag
///         is clear. Votes may be UNDER-counted (the recipient's delegate
///         refused the weight) but never PHANTOM. T4 pins the hostile
///         exceptions (both writes refused -> announced; no-op removal ->
///         silent).
///
///         Sections:
///           T0  vacuity          T1  outcome matrix (real VVD, saturation)
///           T2  fuzz law         T3  whale        T4  broken / hostile modules
///           T5  29.93M frame     T6  proxied-VVD starvation sweep (A1)
///           T7  call counts      T8  event stream   T9 edges   T10 unchanged paths
///           H   bounded selector copy and strict re-raise
///           A1  the removal is always handed the whole ceiling
contract TD24TransferDisarm is J11Base {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant HEADROOM = (PRINCIPAL / MAX_TIME) / 2;
    uint256 internal constant HEMI_TX_CAP = 29_930_000;
    uint256 internal constant CEILING = 8_000_000;
    bytes4 internal constant SEL_DSO = 0xf2b4513c;

    bytes32 internal constant T_DUF = keccak256("DelegationUpdateFailed(uint256)");
    bytes32 internal constant T_DUFR = keccak256("DelegationUpdateFailedReason(uint256,bytes4)");
    bytes32 internal constant T_UNVERIFIED = keccak256("AutoRelockRetirementUnverified(uint256)");
    bytes32 internal constant T_DISABLED = keccak256("AutoRelockDisabled(uint256,uint64)");
    bytes32 internal constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant T_DC = keccak256("DelegateChanged(uint256,address,address)");

    // Recipient columns of the outcome matrix.
    uint8 internal constant SAME = 0;          // recipient's autoDelegate == D_old
    uint8 internal constant DIFF_HEALTHY = 1;  // autoDelegate == dele2 (healthy)
    uint8 internal constant DIFF_SAT = 2;      // autoDelegate == dele3 (saturated)
    uint8 internal constant SELF_HEALTHY = 3;  // no autoDelegate: D_new == recipient
    uint8 internal constant SELF_SAT = 4;      // no autoDelegate, recipient saturated

    address internal recipient = address(0xB0B0B0);
    address internal operator = address(0x0BE7A7);
    address internal dele3 = address(0xDE1E63);

    // Non-vacuity counters. `_row` bumps the cell counters AFTER each cell's
    // snapshot is reverted, so they survive it. NOTE: the cell counters count
    // the PREDICTED class of each cell (`_column`'s saturation flag); the
    // observed behaviour is checked by `_assertCorrect` / `_assertUnderCount`.
    uint256 internal saturations;
    uint256 internal correctCells;
    uint256 internal underCountCells;

    // ------------------------------------------------------------------ rig --

    function _whaleOwner(address d_) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("td24-whale", d_)))));
    }

    /// @dev Park `d_` HEADROOM below the uint64 aggregate-slope ceiling with an
    ///      ordinary decaying whale, then PROVE from outside VeHemi that the
    ///      victim's slope no longer fits (the `Q30A2.t.sol` rig).
    function _saturate(address d_) internal {
        address w = _whaleOwner(d_);
        (uint256 whaleId, , ) = createLock(w, (uint256(type(uint64).max) - HEADROOM) * MAX_TIME, 3 * 365 days);
        delegateTo(w, whaleId, d_);
        (uint256 probeId, , ) = createLock(w, PRINCIPAL, 4 * 365 days);
        vm.prank(w);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", probeId, d_)
        );
        require(!ok && bytes4(ret) == SEL_DSO, "TD24: saturation premise gone");
        ++saturations;
    }

    /// @dev An armed (flat) victim position booked at `dOld_`.
    function _armedOn(address dOld_) internal returns (uint256 id) {
        (id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        enable(victim, id);
        delegateTo(victim, id, dOld_);
        vm.warp(block.timestamp + 7200);
    }

    function _setAuto(address who_, address to_) internal {
        vm.prank(who_);
        delegation.setAutoDelegate(to_);
    }

    /// @dev Configure the recipient for column `col_`; returns the delegate the
    ///      position should land on and whether it is saturated.
    function _column(uint8 col_, address dOld_, bool oldSat_) internal returns (address target, bool targetSat) {
        if (col_ == SAME) {
            _setAuto(recipient, dOld_);
            return (dOld_, oldSat_);
        }
        if (col_ == DIFF_HEALTHY) {
            _setAuto(recipient, dele2);
            return (dele2, false);
        }
        if (col_ == DIFF_SAT) {
            _saturate(dele3);
            _setAuto(recipient, dele3);
            return (dele3, true);
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
        out = new bytes4[](_count(logs_, address(veHemi), T_DUFR));
        uint256 k;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(veHemi) && logs_[i].topics[0] == T_DUFR) {
                out[k++] = abi.decode(logs_[i].data, (bytes4));
            }
        }
    }

    function _isFlat(IVeHemiVoteDelegation.Delegation memory d_) internal pure returns (bool) {
        return d_.slope == 0 && d_.bias > 0;
    }

    function _rec(uint256 id_) internal view returns (IVeHemiVoteDelegation.Delegation memory) {
        return IVeHemiVoteDelegation(address(veHemi.voteDelegation())).delegation(id_);
    }

    /// @dev Far future: every lock in the rig has expired, so any vote left on
    ///      `d_` can only be a flat term with no position behind it.
    function _assertNoPhantomFarFuture(address d_, string memory tag_) internal {
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + MAX_TIME + 4 * SIX_DAYS);
        assertEq(delegation.getVotes(d_), 0, tag_);
        vm.revertToState(snap);
    }

    // ===================================================================
    // T1 -- THE OUTCOME MATRIX (real VVD; saturation reached, not mocked).
    //   D_old in {healthy, saturated} x 5 recipient columns
    //   x caller {owner, approved operator} x 4 sub-bucket phases.
    //   CORRECT iff the recipient's delegate can take the weight; otherwise
    //   UNDER-COUNT (record removed). Never phantom, never refused.
    // ===================================================================

    struct Cell {
        address dOld;
        address target;
        bool targetSat;
        uint256 id;
        uint256 t0;
        uint64 r0;
        uint256 flatW;
        uint256 oldNo;
        uint256 newNo;
        uint256 oldAfter;
        uint256 newAfter;
        uint256 w;
        uint256 supplyNo;
        uint256 wFlatNo;
    }

    /// @return correct_ true for a CORRECT cell, false for an UNDER-COUNT cell.
    ///         (Storage counters would be rolled back with the snapshot.)
    function _cell(bool oldSat_, uint8 col_, bool byOperator_, uint256 phase_) internal returns (bool correct_) {
        uint256 snap = vm.snapshotState();
        Cell memory c;
        c.dOld = dele;
        if (oldSat_) _saturate(c.dOld);
        (c.target, c.targetSat) = _column(col_, c.dOld, oldSat_);
        c.id = _armedOn(c.dOld);
        warpToPhase(phase_);

        c.t0 = block.timestamp;
        c.r0 = veHemi.autoRelockRemaining(c.id);
        IVeHemiVoteDelegation.Delegation memory pre = delegation.delegation(c.id);
        require(_isFlat(pre) && pre.delegatee == c.dOld, "TD24: victim is not flat at D_old");
        c.flatW = pre.bias;

        // Votes at t0+1 in the world WITHOUT the transfer.
        uint256 s1 = vm.snapshotState();
        vm.warp(c.t0 + 1);
        c.oldNo = delegation.getVotes(c.dOld);
        c.newNo = delegation.getVotes(c.target);
        c.supplyNo = veHemi.totalVeHemiSupply();
        c.wFlatNo = veHemi.balanceOfNFT(c.id);
        vm.revertToState(s1);

        vm.recordLogs();
        (bool ok, ) = _transfer(c.id, victim, recipient, byOperator_, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "T1: armed transfer refused");
        assertEq(veHemi.ownerOf(c.id), recipient, "T1: ownership");
        assertEq(veHemi.autoRelockRemaining(c.id), 0, "T1: flag survived");
        assertEq(
            uint256(veHemi.getLockedBalance(c.id).end),
            ((c.t0 / SIX_DAYS) + uint256(c.r0) / SIX_DAYS) * SIX_DAYS,
            "T1: end != grid(t0) + R"
        );
        // Oracles that do not go through VeHemi's own user point (a disarm
        // that scaled `amount` would pass every check that reads only the
        // point), and the two disarm side effects shared with the other
        // disarm doors: the stamp cleared and the `AutoRelockDisabled` payload.
        assertEq(uint256(int256(veHemi.getLockedBalance(c.id).amount)), PRINCIPAL, "T1: principal changed");
        assertEq(uint256(veHemi.autoRelockRefreshedAt(c.id)), 0, "T1: refreshedAt not cleared");
        {
            uint256 iDis = _firstIndex(logs, address(veHemi), T_DISABLED);
            require(iDis != type(uint256).max, "T1: no AutoRelockDisabled");
            assertEq(
                uint256(abi.decode(logs[iDis].data, (uint64))),
                uint256(veHemi.getLockedBalance(c.id).end),
                "T1: AutoRelockDisabled payload != end"
            );
        }
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(c.id);
        assertFalse(_isFlat(d), "T1: PHANTOM -- flat record survived a committed disarm");
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0, "T1: Unverified on an honest VVD");
        assertEq(
            veHemi.getUserPoint(c.id, veHemi.userPointEpoch(c.id)).owner,
            recipient,
            "T1: point-history owner is not the recipient"
        );

        vm.warp(c.t0 + 1);
        c.oldAfter = delegation.getVotes(c.dOld);
        c.newAfter = delegation.getVotes(c.target);
        c.w = veHemi.balanceOfNFT(c.id);
        {
            uint256 endCF = ((c.t0 / SIX_DAYS) + uint256(c.r0) / SIX_DAYS) * SIX_DAYS;
            uint256 tolW = 2 * (PRINCIPAL / MAX_TIME) + 2;
            assertApproxEqAbs(c.w, (PRINCIPAL / MAX_TIME) * (endCF - (c.t0 + 1)), tolW, "T1: weight is not the closed-form decaying weight");
            assertApproxEqAbs(veHemi.totalVeHemiSupply(), c.supplyNo - c.wFlatNo + c.w, tolW, "T1: supply delta != w - wFlat");
        }
        correct_ = !c.targetSat;
        if (correct_) _assertCorrect(c, d, logs);
        else _assertUnderCount(c, d, logs);
        _assertNoPhantomFarFuture(c.dOld, "T1: phantom on D_old far future");
        _assertNoPhantomFarFuture(c.target, "T1: phantom on D_new far future");
        vm.revertToState(snap);
    }

    function _assertCorrect(Cell memory c, IVeHemiVoteDelegation.Delegation memory d, Vm.Log[] memory logs) internal {
        uint256 tol = 2 * (PRINCIPAL / MAX_TIME) + 2;
        assertEq(d.delegatee, c.target, "T1: not moved to the recipient's delegate");
        assertGt(d.slope, 0, "T1: moved record is not decaying");
        assertEq(uint256(d.end), uint256(veHemi.getLockedBalance(c.id).end), "T1: moved record end != lock end");
        assertEq(_count(logs, address(veHemi), T_DUF), 0, "T1: DUF in a correct cell");
        if (c.target == c.dOld) {
            assertApproxEqAbs(c.oldAfter, c.oldNo - c.flatW + c.w, tol, "T1: same-delegate votes");
        } else {
            assertEq(c.oldAfter, c.oldNo - c.flatW, "T1: D_old kept part of the flat term");
            assertApproxEqAbs(c.newAfter, c.newNo + c.w, tol, "T1: D_new did not gain the weight");
        }
    }

    function _assertUnderCount(Cell memory c, IVeHemiVoteDelegation.Delegation memory d, Vm.Log[] memory logs) internal {
        assertEq(d.delegatee, address(0), "T1: under-count cell kept a delegatee");
        assertEq(d.bias, 0, "T1: under-count cell kept bias");
        assertEq(d.slope, 0, "T1: under-count cell kept slope");
        assertEq(_count(logs, address(veHemi), T_DUF), 1, "T1: exactly one DUF");
        bytes4[] memory rs = _reasons(logs);
        assertEq(rs.length, 1, "T1: exactly one DUFR");
        assertEq(rs[0], SEL_DSO, "T1: DUFR is not the overflow selector");
        assertEq(c.oldAfter, c.oldNo - c.flatW, "T1: D_old kept part of the flat term");
        if (c.target != c.dOld) assertEq(c.newAfter, c.newNo, "T1: saturated D_new changed");
    }

    function _row(bool oldSat_, uint8 col_) internal {
        uint256[4] memory phases = [uint256(0), 1, SIX_DAYS / 2, SIX_DAYS - 1];
        for (uint256 p; p < 4; ++p) {
            for (uint256 k; k < 2; ++k) {
                if (_cell(oldSat_, col_, k == 1, phases[p])) ++correctCells;
                else ++underCountCells;
            }
        }
    }

    function test_TD24_T1_oldHealthy_same() public { _row(false, SAME); assertEq(correctCells, 8); }
    function test_TD24_T1_oldHealthy_diffHealthy() public { _row(false, DIFF_HEALTHY); assertEq(correctCells, 8); }
    function test_TD24_T1_oldHealthy_diffSaturated() public { _row(false, DIFF_SAT); assertEq(underCountCells, 8); }
    function test_TD24_T1_oldHealthy_selfHealthy() public { _row(false, SELF_HEALTHY); assertEq(correctCells, 8); }
    function test_TD24_T1_oldHealthy_selfSaturated() public { _row(false, SELF_SAT); assertEq(underCountCells, 8); }
    function test_TD24_T1_oldSaturated_same() public { _row(true, SAME); assertEq(underCountCells, 8); }
    function test_TD24_T1_oldSaturated_diffHealthy() public { _row(true, DIFF_HEALTHY); assertEq(correctCells, 8); }
    function test_TD24_T1_oldSaturated_diffSaturated() public { _row(true, DIFF_SAT); assertEq(underCountCells, 8); }
    function test_TD24_T1_oldSaturated_selfHealthy() public { _row(true, SELF_HEALTHY); assertEq(correctCells, 8); }
    function test_TD24_T1_oldSaturated_selfSaturated() public { _row(true, SELF_SAT); assertEq(underCountCells, 8); }

    // ===================================================================
    // T0 -- VACUITY: the premises the matrix depends on are really reached.
    // ===================================================================

    function test_TD24_T0_premises() public {
        _saturate(dele);
        _saturate(dele3);
        assertEq(saturations, 2, "T0: saturation not reached");
        // An armed victim on a saturated delegate is still FLAT there: the
        // flat booking adds no slope.
        uint256 id = _armedOn(dele);
        assertTrue(_isFlat(delegation.delegation(id)), "T0: armed victim not flat");
        assertEq(delegation.delegation(id).delegatee, dele, "T0: victim not at D_old");
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
    function testFuzz_TD24_T2_neverFlatWhileFlagClear(
        uint256 phase_, uint256 dur_, uint8 col_, bool oldSat_, bool byOp_
    ) public {
        phase_ = bound(phase_, 0, SIX_DAYS - 1);
        dur_ = bound(dur_, 2 * SIX_DAYS, MAX_TIME);
        col_ = uint8(bound(col_, 0, 4));
        address dOld = dele;
        if (oldSat_) _saturate(dOld);
        (address target, bool targetSat) = _column(col_, dOld, oldSat_);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, dur_);
        enable(victim, id);
        delegateTo(victim, id, dOld);
        warpToPhase(phase_);

        (bool ok, ) = _transfer(id, victim, recipient, byOp_, HEMI_TX_CAP);
        assertTrue(ok, "T2: armed transfer refused");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T2: flag survived");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertFalse(_isFlat(d), "T2: PHANTOM");
        if (targetSat) assertEq(d.delegatee, address(0), "T2: saturated target, record not removed");
        else assertEq(d.delegatee, target, "T2: healthy target under-counted");
        _assertNoPhantomFarFuture(dOld, "T2: phantom on D_old");
        _assertNoPhantomFarFuture(target, "T2: phantom on D_new");
    }

    // ===================================================================
    // T3 -- WHALE: a single position whose slope alone exceeds uint64.
    // ===================================================================

    function test_TD24_T3_whaleUnderCountsNeverPhantom() public {
        uint256 amt = (uint256(type(uint64).max) + 1) * MAX_TIME;
        (uint256 id, , ) = createLock(victim, amt, 4 * 365 days);
        // The mint's decaying booking overflowed and was swallowed.
        assertEq(delegation.delegation(id).delegatee, address(0), "T3: premise -- mint booking not empty");
        enable(victim, id);
        // The owner books it FLAT (a flat booking adds no slope).
        delegateTo(victim, id, dele);
        assertTrue(_isFlat(delegation.delegation(id)), "T3: premise -- whale not flat at dele");
        vm.warp(block.timestamp + 7200);
        _setAuto(recipient, dele2);

        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T3: whale transfer refused");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T3: flag survived");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, address(0), "T3: whale record not removed");
        assertEq(d.bias, 0, "T3: whale record kept bias");
        bytes4[] memory rs = _reasons(logs);
        assertEq(rs.length, 1, "T3: one DUFR");
        assertEq(rs[0], SEL_DSO, "T3: whale move refused with an unexpected reason");
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0, "T3: Unverified");
        _assertNoPhantomFarFuture(dele, "T3: phantom on dele");
    }

    // ===================================================================
    // T4 -- BROKEN / HOSTILE MODULES installed after arming.
    // ===================================================================

    function _armedFlat() internal returns (uint256 id) {
        id = _armedOn(dele);
    }

    function test_TD24_T4_revertingModule_bothRefused_announced() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new RevertingVoteDelegation());
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: principal-carrying transfer refused behind a broken module");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T4: flag survived");
        assertEq(_count(logs, address(veHemi), T_DUF), 2, "T4: move and removal both swallowed");
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1, "T4: both-refused not announced");
    }

    function test_TD24_T4_lyingModule_readBackAnnounces() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new LyingVoteDelegation(IVeHemiVoteDelegation(address(delegation))));
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: transfer refused");
        assertEq(_count(logs, address(veHemi), T_DUF), 0, "T4: the lie was not accepted");
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1, "T4: read-back did not announce the lie");
    }

    /// @dev DISARM the liar so the move COMMITS, then let the read-back judge
    ///      a seeded record: a flat one is announced, a decaying one is not.
    function test_TD24_T4_committedMove_readBackJudgesTheRecord() public {
        uint256 id = _armedFlat();
        Q14SlopeOverflowLiar m = new Q14SlopeOverflowLiar();
        m.disarm();
        m.seed(id, dele, uint96(PRINCIPAL / 2), 0); // FLAT
        veHemi.updateVoteDelegation(m);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1, "T4: flat read-back not announced");
        vm.revertToState(snap);
        m.seed(id, dele, uint96(PRINCIPAL / 2), uint64(PRINCIPAL / MAX_TIME)); // DECAYING
        vm.recordLogs();
        (ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0, "T4: decaying read-back falsely announced");
    }

    /// @dev A known residual, PINNED: a module that refuses the move and accepts
    ///      the removal as a silent no-op leaves ITS OWN record flat, and
    ///      VeHemi cannot see it (the removal "committed"). Expected-silent.
    function test_TD24_T4_residual_rejectMoveNoopRemoval_isSilent() public {
        uint256 id = _armedFlat();
        TD24RejectMoveNoopRemoval m = new TD24RejectMoveNoopRemoval();
        m.seedFlat(id, dele, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(m);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), T_DUF), 1, "T4/residual: move refusal not reported");
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0, "T4/residual: (pinned) silent");
        assertTrue(_isFlat(m.delegation(id)), "T4/residual: premise -- module record flat");
    }

    /// @dev Conservative announcement: an EMPTY record behind a module that
    ///      refuses everything still announces (it could not perform the write).
    function test_TD24_T4_emptyRecordBehindRevertingModule_conservativeAnnounce() public {
        // Mint while VeHemi points at a reverting module: the real VVD never
        // books the position, so its record there is empty.
        RevertingVoteDelegation bad = new RevertingVoteDelegation();
        IVeHemiVoteDelegation real = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(bad);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(real);
        enable(victim, id);
        assertEq(delegation.delegation(id).delegatee, address(0), "T4: premise -- record not empty");
        veHemi.updateVoteDelegation(bad);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1, "T4: conservative announcement missing");
    }

    /// @dev PINNED (B8): a module whose `delegation()` returns undecodable
    ///      data (`K08Garbage`, whose `delegate()` returns) makes the read-back
    ///      revert (an ABI decode failure is not caught by try/catch), so an
    ///      ARMED transfer is refused while an UNARMED one -- which never
    ///      reads -- succeeds.
    function test_TD24_T4_garbageRead_armedRefused_unarmedSucceeds() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(new K08Garbage());
        (bool okArmed, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        (bool okPlain, ) = _transfer(plain, victim, recipient, false, HEMI_TX_CAP);
        assertFalse(okArmed, "T4/B8: (pinned) armed transfer behind garbage reads");
        assertTrue(okPlain, "T4/B8: unarmed transfer must not read");
    }

    // ===================================================================
    // T5 -- THE 29.93M PER-TX FRAME (owner and approved operator).
    // ===================================================================

    function test_TD24_T5_burnAndReturnModule_executes() public {
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

    function test_TD24_T5_burnAndRevertModule_executes() public {
        for (uint256 k; k < 2; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 id = _armedFlat();
            veHemi.updateVoteDelegation(new TD24BurnAndRevert());
            vm.recordLogs();
            (bool ok, ) = _transfer(id, victim, recipient, k == 1, HEMI_TX_CAP);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(ok, "T5: burn-and-revert armed transfer does not fit 29.93M");
            assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1);
            vm.revertToState(snap);
        }
    }

    function test_TD24_T5_returndataBomb_executesWithH() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new TD24RevertBomb(2_000_000));
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T5: returndata bomb blocked the armed transfer");
        bytes4[] memory rs = _reasons(logs);
        assertEq(rs.length, 2, "T5: two swallowed calls");
        assertEq(rs[0], bytes4(0), "T5: zero-filled bomb selector");
    }

    function test_TD24_T5_gasEatingDistributor_executes() public {
        uint256 id = _armedFlat();
        veHemi.updateRewardDistributor(new TD24GasEaterDistributor());
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok, "T5: distributor-hostile armed transfer does not fit 29.93M");
        assertEq(delegation.delegation(id).delegatee, recipient, "T5: not moved");
    }

    /// @dev A known residual, PINNED: both hostile -> the armed transfer cannot
    ///      execute at 29.93M; the unarmed twin can.
    function test_TD24_T5_bothHostile_armedReverts_unarmedExecutes() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(new OogVoteDelegation());
        veHemi.updateRewardDistributor(new TD24GasEaterDistributor());
        (bool okArmed, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        (bool okPlain, ) = _transfer(plain, victim, recipient, false, HEMI_TX_CAP);
        assertFalse(okArmed, "T5: (pinned residual) both-hostile armed transfer");
        assertTrue(okPlain, "T5: unarmed twin must execute");
    }

    // ===================================================================
    // A1 -- THE FALLBACK REMOVAL IS ALWAYS HANDED THE WHOLE CEILING.
    //   Swept over gas limits: whenever the transfer commits with a removal,
    //   the module saw (nearly) the full DELEGATION_GAS_CEILING; below the
    //   floor the transfer reverts DelegationCallStarved. Monotone.
    // ===================================================================

    function _sweepRemovalGas(address module_, uint256 minEntry_) internal {
        uint256 id = _armedFlat();
        TD24RemovalGasProbe(module_).seedFlat(id, dele, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(module_));
        uint256 commits;
        uint256 starvedReverts;
        bool seenCommit;
        for (uint256 g = 150_000; g <= 10_000_000; g += 50_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _transfer(id, victim, recipient, false, g);
            if (ok) {
                ++commits;
                seenCommit = true;
                assertEq(TD24RemovalGasProbe(module_).removals(), 1, "A1: committed without a removal");
                assertGe(TD24RemovalGasProbe(module_).removalGasAtEntry(), minEntry_, "A1: removal STARVED yet committed");
            } else {
                assertFalse(seenCommit, "A1: gas response not monotone");
                if (ret.length >= 4 && bytes4(ret) == VeHemi.DelegationCallStarved.selector) ++starvedReverts;
            }
            vm.revertToState(snap);
        }
        assertGt(commits, 0, "A1: vacuous -- never committed");
        assertGt(starvedReverts, 0, "A1: vacuous -- the floor never fired");
    }

    function test_TD24_A1_directModule_removalGetsFullCeiling() public {
        _sweepRemovalGas(address(new TD24RemovalGasProbe()), CEILING - 2_000);
    }

    /// @dev `ERC1967Proxy` stands in for the live VVD's proxy, an OZ
    ///      4.x `TransparentUpgradeableProxy`. Both forward with
    ///      `delegatecall(gas())`; the TUP's `_beforeFallback` adds the admin
    ///      check (one more SLOAD, cold on the first call), so the module
    ///      behind it gets slightly less of the ceiling (derived: about
    ///      7,874,321 warm / 7,867,923 cold, against 7,867,000 asserted here).
    ///      The removal gas floor depends only on the CALL's 63/64 rule, which
    ///      neither proxy changes.
    function test_TD24_A1_proxiedModule_removalGetsFullCeiling() public {
        TD24RemovalGasProbe impl = new TD24RemovalGasProbe();
        ERC1967Proxy p = new ERC1967Proxy(address(impl), "");
        // Behind a delegatecall proxy the module keeps 63/64 of the ceiling.
        _sweepRemovalGas(address(p), (CEILING * 63) / 64 - 8_000);
    }

    // ===================================================================
    // T6 -- PROXIED REAL VVD, DORMANT D_old: sweep the caller's gas limit.
    //   Behind a proxy `_requireNotStarved` cannot fire (an OOG callee hands
    //   back ~1/32). Whatever the gas limit: either the transfer reverts, or
    //   it commits with no flat record -- and a HEALTHY recipient is never
    //   under-counted by gas choice.
    // ===================================================================

    function _useProxiedVVD() internal {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(p));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(p)));
    }

    function _dormantSweep(bool targetSat_, uint256 lo_, uint256 hi_, uint256 step_, bool mustCommit_)
        internal
        returns (uint256 commits)
    {
        _useProxiedVVD();
        uint256 id = _armedOn(dele);
        vm.warp(block.timestamp + 200 * SIX_DAYS); // D_old untouched for 200 buckets
        veHemi.checkpoint();
        address target = targetSat_ ? dele3 : dele2;
        if (targetSat_) _saturate(dele3);
        _setAuto(recipient, target);
        for (uint256 g = lo_; g <= hi_; g += step_) {
            uint256 snap = vm.snapshotState();
            (bool ok, ) = _transfer(id, victim, recipient, false, g);
            if (ok) {
                ++commits;
                IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
                assertEq(veHemi.autoRelockRemaining(id), 0, "T6: flag survived a commit");
                assertFalse(_isFlat(d), "T6: PHANTOM committed at a chosen gas limit");
                if (targetSat_) assertEq(d.delegatee, address(0), "T6: saturated cell landed somewhere");
                else assertEq(d.delegatee, target, "T6: HEALTHY recipient under-counted by gas choice");
            }
            vm.revertToState(snap);
        }
        if (mustCommit_) assertGt(commits, 0, "T6: vacuous -- never committed");
    }

    function test_TD24_T6_proxied_dormant_healthyRecipient_lo() public { _dormantSweep(false, 100_000, 3_000_000, 10_000, true); }
    function test_TD24_T6_proxied_dormant_healthyRecipient_hi() public { _dormantSweep(false, 3_000_000, 12_000_000, 100_000, true); }
    /// @dev Below the removal gas floor (A1) the fallback removal cannot
    ///      run, so nothing in this band may commit; the law is checked on
    ///      whatever does.
    function test_TD24_T6_proxied_dormant_saturatedRecipient_lo() public {
        assertEq(_dormantSweep(true, 100_000, 3_000_000, 10_000, false), 0, "T6: commit below the A1 floor");
    }
    function test_TD24_T6_proxied_dormant_saturatedRecipient_hi() public { _dormantSweep(true, 3_000_000, 12_000_000, 25_000, true); }

    /// @dev The same sweep against the DIRECT (unproxied) VVD, where the
    ///      tripwire is live: same law.
    function test_TD24_T6_direct_dormant_saturatedRecipient() public {
        uint256 id = _armedOn(dele);
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        veHemi.checkpoint();
        _saturate(dele3);
        _setAuto(recipient, dele3);
        uint256 commits;
        for (uint256 g = 100_000; g <= 12_000_000; g += 50_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, ) = _transfer(id, victim, recipient, false, g);
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

    function _expectModuleCalls(uint64 autoDel_, uint64 del_, uint64 read_) internal {
        vm.expectCall(address(delegation), abi.encodeWithSelector(IVeHemiVoteDelegation.autoDelegate.selector), autoDel_);
        vm.expectCall(address(delegation), abi.encodeWithSelector(IVeHemiVoteDelegation.delegate.selector), del_);
        vm.expectCall(address(delegation), abi.encodeWithSelector(IVeHemiVoteDelegation.delegation.selector), read_);
    }

    function test_TD24_T7_counts_armedHappy() public {
        uint256 id = _armedFlat();
        _setAuto(recipient, dele2);
        _expectModuleCalls(1, 1, 1);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
    }

    function test_TD24_T7_counts_armedSaturated() public {
        _saturate(dele3);
        uint256 id = _armedFlat();
        _setAuto(recipient, dele3);
        _expectModuleCalls(1, 2, 0);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
    }

    function test_TD24_T7_counts_unarmed() public {
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        _expectModuleCalls(1, 1, 0);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
    }

    function test_TD24_T7_counts_armedSelfTransfer() public {
        uint256 id = _armedFlat();
        _expectModuleCalls(1, 1, 0);
        (bool ok, ) = _transfer(id, victim, victim, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertGt(veHemi.autoRelockRemaining(id), 0, "T7: self-transfer disarmed");
    }

    /// @dev F09: exactly two notifications on an armed transfer; the FIRST
    ///      sees the flat weight (before the flag clears), the LAST sees the
    ///      post-transfer weight (the re-anchor). One on unarmed / self.
    function test_TD24_T7_rewardNotifications_bracketTheDisarm() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        F09Counter c = new F09Counter(address(veHemi));
        veHemi.updateRewardDistributor(c);
        uint256 wFlat = veHemi.balanceOfNFT(id);

        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(c.nSeenFor(id), 2, "T7: armed transfer must notify exactly twice");
        assertEq(c.weightAt(id, 0), wFlat, "T7: notify-before did not see the flat weight");
        assertEq(c.weightAt(id, 1), veHemi.balanceOfNFT(id), "T7: re-anchor did not see the new weight");
        assertTrue(c.weightAt(id, 1) != wFlat, "T7: premise -- disarm moved no weight");

        (ok, ) = _transfer(plain, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(c.nSeenFor(plain), 1, "T7: unarmed transfer must notify once");

        uint256 id2 = _armedFlat();
        uint256 before2 = c.nSeenFor(id2); // mint + arm notifications
        (ok, ) = _transfer(id2, victim, victim, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(c.nSeenFor(id2) - before2, 1, "T7: self-transfer must notify once");
    }

    // ===================================================================
    // T8 -- EVENT STREAM (no adapter; emitter-filtered).
    // ===================================================================

    function _dcArgs(Vm.Log memory l_) internal pure returns (uint256 id, address from, address to) {
        id = uint256(l_.topics[1]);
        from = address(uint160(uint256(l_.topics[2])));
        to = address(uint160(uint256(l_.topics[3])));
    }

    function test_TD24_T8_stream_happyPath() public {
        uint256 id = _armedFlat();
        _setAuto(recipient, dele2);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        uint256 iDis = _firstIndex(logs, address(veHemi), T_DISABLED);
        uint256 iTr = _firstIndex(logs, address(veHemi), T_TRANSFER);
        uint256 iDc = _firstIndex(logs, address(delegation), T_DC);
        assertLt(iDis, iTr, "T8: AutoRelockDisabled must precede Transfer");
        assertLt(iTr, iDc, "T8: every delegation write must follow Transfer");
        assertEq(_count(logs, address(delegation), T_DC), 1, "T8: exactly one DelegateChanged");
        (uint256 dId, address from, address to) = _dcArgs(logs[iDc]);
        assertEq(dId, id);
        assertEq(from, dele, "T8: from != D_old");
        assertEq(to, dele2, "T8: to != D_new");
        assertEq(_count(logs, address(veHemi), T_DUF), 0);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0);
    }

    function test_TD24_T8_stream_sameDelegate() public {
        uint256 id = _armedFlat();
        _setAuto(recipient, dele);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(delegation), T_DC), 1, "T8: exactly one DelegateChanged (same column)");
        (, address from, address to) = _dcArgs(logs[_firstIndex(logs, address(delegation), T_DC)]);
        assertEq(from, dele);
        assertEq(to, dele);
    }

    function test_TD24_T8_stream_underCount() public {
        _saturate(dele3);
        uint256 id = _armedFlat();
        _setAuto(recipient, dele3);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        uint256 iTr = _firstIndex(logs, address(veHemi), T_TRANSFER);
        uint256 iDc = _firstIndex(logs, address(delegation), T_DC);
        assertLt(iTr, iDc, "T8: a delegation write before Transfer");
        // NOTE: `vm.recordLogs` also returns logs emitted inside the REVERTED
        // move frame (DelegateChanged(id, D_old, D_new)); a real receipt does
        // not contain them. The committed write is the removal.
        uint256 removals;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(delegation) && logs[i].topics[0] == T_DC) {
                (, address from, address to) = _dcArgs(logs[i]);
                assertEq(from, dele, "T8: from != D_old");
                if (to == address(0)) ++removals;
                else assertEq(to, dele3, "T8: unexpected move target");
            }
        }
        assertEq(removals, 1, "T8: exactly one removal");
        assertEq(_count(logs, address(veHemi), T_DUF), 1);
    }

    // ===================================================================
    // T9 -- EDGES.
    // ===================================================================

    function test_TD24_T9_armedWithEmptyRecord_movesCleanly() public {
        RevertingVoteDelegation bad = new RevertingVoteDelegation();
        IVeHemiVoteDelegation real = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(bad);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        veHemi.updateVoteDelegation(real);
        enable(victim, id);
        assertEq(delegation.delegation(id).delegatee, address(0), "T9: premise");
        _setAuto(recipient, dele2);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, dele2, "T9: empty record not booked at the target");
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0);
    }

    function test_TD24_T9_twoTransfersSameHour() public {
        uint256 id = _armedFlat();
        _setAuto(recipient, dele2);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        vm.warp(block.timestamp + 60);
        (ok, ) = _transfer(id, recipient, charlie, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, charlie, "T9: second hop");
        assertFalse(_isFlat(d));
        _assertNoPhantomFarFuture(dele, "T9: phantom on the first delegate");
        _assertNoPhantomFarFuture(dele2, "T9: phantom on the second delegate");
    }

    /// @dev A known residual: a distributor re-entering the delegation module
    ///      through the permissionless `retireStrandedFlatTerm` during the
    ///      re-anchor (flag clear, record still flat) changes nothing final.
    function test_TD24_T9_reentrantDistributor_sameFinalState() public {
        uint256 id = _armedFlat();
        _setAuto(recipient, dele2);
        uint256 snap = vm.snapshotState();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory plainRec = delegation.delegation(id);
        vm.warp(block.timestamp + 1);
        uint256 v1 = delegation.getVotes(dele);
        uint256 v2 = delegation.getVotes(dele2);
        vm.revertToState(snap);

        TD24ReentrantDistributor r = new TD24ReentrantDistributor(address(delegation));
        r.setTarget(id);
        veHemi.updateRewardDistributor(r);
        (ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(r.attempts(), 2, "T9: premise -- notify-before + re-anchor");
        assertEq(r.successes(), 1, "T9: premise -- the re-entry did not retire anything");
        IVeHemiVoteDelegation.Delegation memory reRec = delegation.delegation(id);
        assertEq(reRec.delegatee, plainRec.delegatee);
        assertEq(reRec.bias, plainRec.bias);
        assertEq(reRec.slope, plainRec.slope);
        vm.warp(block.timestamp + 1);
        assertEq(delegation.getVotes(dele), v1, "T9: D_old votes differ under re-entry");
        assertEq(delegation.getVotes(dele2), v2, "T9: D_new votes differ under re-entry");
    }

    // ===================================================================
    // T10 -- UNCHANGED PATHS.
    // ===================================================================

    /// @dev An owner's armed SELF-transfer into a saturated autoDelegate stays
    ///      armed and flat: the flat booking adds no slope, so it moves.
    function test_TD24_T10_armedSelfTransfer_staysArmedAndFlat() public {
        _saturate(dele3);
        uint256 id = _armedFlat();
        uint64 r0 = veHemi.autoRelockRemaining(id);
        _setAuto(victim, dele3);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, victim, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(veHemi.autoRelockRemaining(id), r0, "T10: self-transfer changed the arm");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertTrue(_isFlat(d), "T10: armed self-transfer is no longer flat");
        assertEq(d.delegatee, dele3);
        assertEq(_count(logs, address(veHemi), T_DUF), 0);
        assertEq(_count(logs, address(veHemi), T_DISABLED), 0);
    }

    function test_TD24_T10_unarmedTransfer_unchanged() public {
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        _setAuto(recipient, dele2);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, dele2);
        assertEq(_count(logs, address(veHemi), T_DISABLED), 0);
        assertEq(_count(logs, address(delegation), T_DC), 1);
    }

    /// @dev An UNARMED transfer into a saturated delegate keeps the BASE
    ///      behaviour: the refused write leaves the decaying record where it
    ///      was (misattributed, weight-correct). The armed/unarmed divergence
    ///      is deliberate: only an ARMED transfer removes the record on a
    ///      refused move (normally flat; a stale decaying record left by a
    ///      swallowed enable is removed too -- see T9).
    function test_TD24_T10_unarmedIntoSaturated_keepsDecayingRecord() public {
        _saturate(dele3);
        (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        delegateTo(victim, id, dele);
        _setAuto(recipient, dele3);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertEq(d.delegatee, dele, "T10: unarmed record moved");
        assertGt(d.slope, 0);
    }

    // ===================================================================
    // FURTHER CASES (T4, T7b, T7c, T9, T10).
    // ===================================================================

    /// @dev The fallback removal must be non-strict (`strict_ = false`): a module that
    ///      refuses BOTH writes with the overflow selector must still let the
    ///      armed transfer commit (and announce), never revert.
    function test_TD24_T4_bothRefusedWithOverflowSelector_stillCommits() public {
        uint256 id = _armedFlat();
        Q14SlopeOverflowLiar m = new Q14SlopeOverflowLiar(); // armed: every delegate() raises 0xf2b4513c
        m.seed(id, dele, uint96(PRINCIPAL / 2), 0);
        veHemi.updateVoteDelegation(m);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: transfer reverted on the overflow selector (removal must be non-strict)");
        bytes4[] memory rs = _reasons(logs);
        assertEq(rs.length, 2);
        assertEq(rs[0], SEL_DSO);
        assertEq(rs[1], SEL_DSO);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1);
    }

    /// @dev F09 on the REFUSED-move branches: still exactly two notifications,
    ///      the first on the flat weight, the last on the post-transfer weight.
    function _assertTwoNotifies(uint256 id_, F09Counter c_, uint256 wFlat_) internal view {
        assertEq(c_.nSeenFor(id_), 2, "T7b: armed transfer must notify exactly twice");
        assertEq(c_.weightAt(id_, 0), wFlat_, "T7b: notify-before did not see the flat weight");
        assertEq(c_.weightAt(id_, 1), veHemi.balanceOfNFT(id_), "T7b: re-anchor did not see the new weight");
    }

    function test_TD24_T7b_rewardNotifications_refusedMoveBranches() public {
        // (a) real VVD, saturated recipient delegate: move refused, removal accepted.
        uint256 snap = vm.snapshotState();
        _saturate(dele3);
        uint256 id = _armedFlat();
        _setAuto(recipient, dele3);
        F09Counter c = new F09Counter(address(veHemi));
        veHemi.updateRewardDistributor(c);
        uint256 wFlat = veHemi.balanceOfNFT(id);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, address(0), "T7b: premise -- not the removal branch");
        _assertTwoNotifies(id, c, wFlat);
        vm.revertToState(snap);

        // (b) a module refusing both writes.
        id = _armedFlat();
        TD24MixedFailure m = new TD24MixedFailure();
        m.seedFlat(id, dele, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(m);
        c = new F09Counter(address(veHemi));
        veHemi.updateRewardDistributor(c);
        wFlat = veHemi.balanceOfNFT(id);
        vm.recordLogs();
        (ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1, "T7b: premise -- not the both-refused branch");
        _assertTwoNotifies(id, c, wFlat);
    }

    /// @dev An armed position whose VVD record is still DECAYING (the enable's
    ///      re-book was swallowed behind a broken module, then the module was
    ///      repaired): the transfer moves it like any record, or removes it
    ///      when the recipient's delegate refuses -- unlike an UNARMED transfer.
    function _armedWithStaleDecayingRecord() internal returns (uint256 id) {
        (id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        delegateTo(victim, id, dele);
        IVeHemiVoteDelegation real = IVeHemiVoteDelegation(address(delegation));
        veHemi.updateVoteDelegation(new RevertingVoteDelegation());
        enable(victim, id);
        veHemi.updateVoteDelegation(real);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        require(d.delegatee == dele && d.slope > 0 && veHemi.autoRelockRemaining(id) != 0, "TD24: stale-decaying premise");
        vm.warp(block.timestamp + 7200);
    }

    /// @dev Votes at t0+1 with and without the transfer (snapshot
    ///      counterfactual, as in T1): the stale DECAYING record's weight leaves
    ///      D_old exactly, and lands on the target when it is healthy.
    function _staleDecayingCell(bool targetSat_) internal {
        address target = targetSat_ ? dele3 : dele2;
        if (targetSat_) _saturate(dele3);
        uint256 id = _armedWithStaleDecayingRecord();
        _setAuto(recipient, target);
        uint256 t0 = block.timestamp;
        IVeHemiVoteDelegation.Delegation memory pre = delegation.delegation(id);

        uint256 s1 = vm.snapshotState();
        vm.warp(t0 + 1);
        uint256 oldNo = delegation.getVotes(dele);
        uint256 newNo = delegation.getVotes(target);
        vm.revertToState(s1);

        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 0);
        assertEq(uint256(int256(veHemi.getLockedBalance(id).amount)), PRINCIPAL, "T9: principal changed");
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);

        vm.warp(t0 + 1);
        // D_old holds ONLY the victim's stale record in this rig, so the
        // whole of its weight must leave: positive without the transfer,
        // exactly zero with it.
        require(pre.delegatee == dele && oldNo > 0, "TD24: stale-decaying premise (D_old weight)");
        uint256 tol = 2 * (PRINCIPAL / MAX_TIME) + 2;
        assertEq(delegation.getVotes(dele), 0, "T9: stale weight did not leave D_old");
        if (targetSat_) {
            assertEq(d.delegatee, address(0), "T9: armed refused move must remove the record");
            assertEq(_count(logs, address(veHemi), T_DUF), 1);
            assertEq(delegation.getVotes(target), newNo, "T9: saturated target changed");
        } else {
            assertEq(d.delegatee, dele2, "T9: stale decaying record not moved");
            assertEq(uint256(d.end), uint256(veHemi.getLockedBalance(id).end), "T9: moved record end");
            assertApproxEqAbs(delegation.getVotes(dele2), newNo + veHemi.balanceOfNFT(id), tol, "T9: target did not gain the weight");
        }
    }

    function test_TD24_T9_staleDecayingRecord_healthyTarget_moves() public { _staleDecayingCell(false); }

    function test_TD24_T9_staleDecayingRecord_saturatedTarget_removed() public { _staleDecayingCell(true); }

    /// @dev The move commits and the record cannot be READ (the read-back's
    ///      catch): the transfer commits and announces once.
    function test_TD24_T4_committedMove_unreadableRecord_announces() public {
        uint256 id = _armedFlat();
        veHemi.updateVoteDelegation(new TD24WriteOkReadReverts());
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "T4: unreadable module refused the armed transfer");
        assertEq(_count(logs, address(veHemi), T_DUF), 0);
        assertEq(_count(logs, address(veHemi), T_UNVERIFIED), 1, "T4: unreadable read-back not announced");
    }

    /// @dev Mint-and-arm, then transfer in the SAME block.
    function test_TD24_T9_createLockWithAutoRelock_thenTransferSameBlock() public {
        hemi.mint(victim, PRINCIPAL);
        vm.prank(victim);
        uint256 id = veHemi.createLockWithAutoRelock(PRINCIPAL, 4 * 365 days, true, false);
        assertGt(veHemi.autoRelockRemaining(id), 0, "T9: premise -- not armed");
        _setAuto(recipient, dele2);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(veHemi.autoRelockRemaining(id), 0);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertFalse(_isFlat(d), "T9: PHANTOM after same-block mint+arm+transfer");
        assertEq(d.delegatee, dele2);
        _assertNoPhantomFarFuture(victim, "T9: phantom on the minter's self-delegation");
    }

    /// @dev PINNED: a position disarmed EARLIER by the permissionless
    ///      stale-retire on a saturated D_old keeps its flat record; a later
    ///      transfer is UNARMED and into a saturated target leaves that record
    ///      where it was. The armed-transfer leg does not touch this path.
    function test_TD24_T10_staleRetiredPhantom_thenTransfer_pinned() public {
        _saturate(dele);
        _saturate(dele3);
        uint256 id = _armedOn(dele);
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0);
        assertTrue(_isFlat(delegation.delegation(id)), "T10: premise -- Q30-P1 flat record not left");
        _setAuto(recipient, dele3);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        assertTrue(_isFlat(d) && d.delegatee == dele, "T10: (pinned) Q30-P1 record unchanged by an unarmed transfer");
    }

    /// @dev The transfer's reward notifications settle the SELLER's segment:
    ///      both (armed) and the single one (unarmed, here sent by an approved
    ///      operator) run while the seller still owns the token. This catches
    ///      a notification moved after `super.transferFrom`, which T7/T7b
    ///      cannot see (weights do not change across the ERC-721 transfer).
    function test_TD24_T7c_rewardNotificationsSeeTheSeller() public {
        uint256 id = _armedFlat();
        (uint256 plain, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        TD24OwnerRecordingDistributor r = new TD24OwnerRecordingDistributor(address(veHemi));
        veHemi.updateRewardDistributor(r);
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(r.n(id), 2, "T7c: armed transfer must notify twice");
        assertEq(r.ownerAt(id, 0), victim, "T7c: notify-before did not see the seller");
        assertEq(r.ownerAt(id, 1), victim, "T7c: re-anchor ran after the ownership change");
        (ok, ) = _transfer(plain, victim, recipient, true, HEMI_TX_CAP);
        assertTrue(ok);
        assertEq(r.n(plain), 1, "T7c: unarmed transfer must notify once");
        assertEq(r.ownerAt(plain, 0), victim, "T7c: unarmed notify did not see the seller");
    }

    // ---- T8 with the REAL Aragon adapter wired --------------------------

    bytes32 internal constant T_ADAPTER_DC = keccak256("DelegateChanged(address,address,address)");

    function _wireAdapter() internal returns (address) {
        VeHemiAragonAdapter ad = new VeHemiAragonAdapter(address(veHemi));
        delegation.setTrustedAdapter(address(ad));
        return address(ad);
    }

    function _adapterDCs(Vm.Log[] memory logs_, address adapter_, address delegator_)
        internal
        pure
        returns (uint256 n, address from, address to)
    {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == adapter_ && logs_[i].topics.length == 4 && logs_[i].topics[0] == T_ADAPTER_DC
                && address(uint160(uint256(logs_[i].topics[1]))) == delegator_) {
                ++n;
                from = address(uint160(uint256(logs_[i].topics[2])));
                to = address(uint160(uint256(logs_[i].topics[3])));
            }
        }
    }

    function test_TD24_T8_adapter_happyPath_singlePositionRecipient() public {
        address ad = _wireAdapter();
        uint256 id = _armedFlat();
        _setAuto(recipient, dele2);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        (uint256 n, address from, address to) = _adapterDCs(logs, ad, recipient);
        assertEq(n, 1, "T8/adapter: one relay for the recipient");
        assertEq(from, dele);
        assertEq(to, dele2);
        (uint256 nSeller, , ) = _adapterDCs(logs, ad, victim);
        assertEq(nSeller, 0, "T8/adapter: a relay attributed to the SELLER");
    }

    function test_TD24_T8_adapter_underCount_singlePositionRecipient() public {
        address ad = _wireAdapter();
        _saturate(dele3);
        uint256 id = _armedFlat();
        _setAuto(recipient, dele3);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        (uint256 n, address from, address to) = _adapterDCs(logs, ad, recipient);
        assertEq(n, 1, "T8/adapter: one relay for the recipient");
        assertEq(from, dele);
        assertEq(to, address(0), "T8/adapter: under-count relay must read (recipient, D_old, 0)");
        (uint256 nSeller, , ) = _adapterDCs(logs, ad, victim);
        assertEq(nSeller, 0, "T8/adapter: a relay attributed to the SELLER");
    }

    /// @dev PINNED (the adapter's own mixed-state suppression): a recipient
    ///      whose positions end up with DIFFERENT delegates gets no relay.
    function test_TD24_T8_adapter_mixedRecipient_isSilent() public {
        address ad = _wireAdapter();
        createLock(recipient, PRINCIPAL, 4 * 365 days); // self-delegated
        uint256 id = _armedFlat();
        _setAuto(recipient, dele2);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(delegation.delegation(id).delegatee, dele2, "T8/adapter: premise -- moved");
        (uint256 n, , ) = _adapterDCs(logs, ad, recipient);
        assertEq(n, 0, "T8/adapter: (pinned) mixed recipient relays nothing");
    }

    // ---- A1, fine-grained at the boundary -------------------------------

    /// @dev Find the smallest committing gas limit (coarse), then sweep the
    ///      60k below it in 1k steps: everything there must revert (monotone),
    ///      and at the boundary the removal still gets (nearly) the whole ceiling.
    function test_TD24_A1_boundary_fineSweep() public {
        uint256 id = _armedFlat();
        TD24RemovalGasProbe m = new TD24RemovalGasProbe();
        m.seedFlat(id, dele, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(m);
        uint256 gFirst;
        for (uint256 g = 8_000_000; g <= 10_000_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, ) = _transfer(id, victim, recipient, false, g);
            vm.revertToState(snap);
            if (ok) { gFirst = g; break; }
        }
        assertGt(gFirst, 0, "A1: vacuous -- no commit in range");
        for (uint256 g = gFirst - 60_000; g <= gFirst; g += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _transfer(id, victim, recipient, false, g);
            if (ok) {
                assertGe(m.removalGasAtEntry(), CEILING - 2_000, "A1: boundary commit with a short removal");
            } else {
                assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector, "A1: below the floor must be DelegationCallStarved");
            }
            vm.revertToState(snap);
        }
    }

    // ===================================================================
    // H -- BOUNDED SELECTOR COPY (through VeHemi) AND STRICT RE-RAISE.
    // ===================================================================

    function _expectedSelector(bytes memory data_) internal pure returns (bytes4 r) {
        bytes memory w = new bytes(4);
        for (uint256 i; i < 4 && i < data_.length; ++i) w[i] = data_[i];
        r = bytes4(w);
    }

    function test_TD24_H_reasonForEveryRevertLength() public {
        uint256[7] memory lens = [uint256(0), 1, 3, 4, 5, 68, 200];
        for (uint256 k; k < lens.length; ++k) {
            uint256 snap = vm.snapshotState();
            (uint256 id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
            bytes memory data = new bytes(lens[k]);
            for (uint256 i; i < data.length; ++i) data[i] = bytes1(uint8(0xA1 + i));
            TD24RawRevert m = new TD24RawRevert();
            m.setData(data);
            veHemi.updateVoteDelegation(m);
            vm.recordLogs();
            (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(ok);
            bytes4[] memory rs = _reasons(logs);
            assertEq(rs.length, 1);
            assertEq(rs[0], _expectedSelector(data), "H: DUFR differs from bytes4(revert data)");
            vm.revertToState(snap);
        }
    }

    /// @dev Pins the scratch-word clear (`mstore(0x00, 0)`) in the bounded
    ///      selector copy: the second, SHORTER revert must not report the
    ///      first one's selector.
    function test_TD24_H_secondShorterRevert_reportsZero() public {
        uint256 id = _armedFlat();
        TD24MixedFailure m = new TD24MixedFailure();
        m.seedFlat(id, dele, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(m);
        vm.recordLogs();
        (bool ok, ) = _transfer(id, victim, recipient, false, HEMI_TX_CAP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        bytes4[] memory rs = _reasons(logs);
        assertEq(rs.length, 2);
        assertEq(rs[0], TD24MixedFailure.MoveRefused.selector);
        assertEq(rs[1], bytes4(0), "H: stale scratch word reported for an empty revert");
    }

    /// @dev Strict leg on the REAL module: exactly the 4-byte selector.
    function test_TD24_H_strictReraise_realModule_exactBytes() public {
        _saturate(dele);
        uint256 id = _armedOn(dele);
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(SEL_DSO), "H: strict re-raise bytes differ");
    }

    /// @dev Strict leg with TRAILING DATA: forwarded byte for byte.
    function test_TD24_H_strictReraise_forwardsWholePayload() public {
        uint256 id = _armedFlat();
        TD24OverflowWithTail m = new TD24OverflowWithTail();
        m.seedFlat(id, dele, uint96(PRINCIPAL / 2));
        veHemi.updateVoteDelegation(m);
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
        assertFalse(ok);
        assertEq(ret, abi.encodePacked(bytes4(0xf2b4513c), uint256(0xbeef), bytes3(0x112233)), "H: payload truncated");
    }
}

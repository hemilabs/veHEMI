// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ===========================================================================
// THE REWARD-DISTRIBUTOR HOOK DURING A FLAT LIFE.
//
// `RewardTwinBase` is the harness: two universes (M holds a manually-extended
// twin, X the auto-relock candidate), distributor doubles, and the analytic
// truths. `RewardFlatLifeBase` holds the six measurement bodies F1-F6; it is
// abstract, and test/reward-distributor/RewardBracket.t.sol instantiates it and
// supplies the assertions.
//
//   * `enableAutoRelock(id)` DERIVES the frozen duration
//     R = floor((lock.end - grid(now)) / SIX_DAYS) * SIX_DAYS (whole buckets,
//     `R >= 2*SIX_DAYS`), so every R in this suite is read back from the
//     contract, not chosen by the test.
//   * The flat level is the bucket mean, `slope * (R - SIX_DAYS/2)`; the
//     integrals use the level read back from the contract.
//   * `_endAutoRelock` serves both `disableAutoRelock` and the permissionless
//     `retireStaleAutoRelock`.
// ===========================================================================

import "../TwinOracle.sol";
import "./DistributorMocks.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

/// @dev Harness only: the two universes, the counters, the analytic truths.
///      Kept separate from RewardFlatLifeBase so another suite can reuse it without
///      inheriting -- and silently re-running -- the six measurement bodies.
abstract contract RewardTwinBase is TwinOracle {
    uint256 internal constant AMT = 1000e18;
    uint256 internal constant N = 6;

    CountingDistributor internal counterM;
    CountingDistributor internal counterX;
    TrapezoidIntegratorDistributor internal integratorM;
    TrapezoidIntegratorDistributor internal integratorX;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal manualIndex;
    uint256 internal candidateIndex;

    // candidate drive plan
    uint256 internal enableAt;
    uint256 internal disableAt;
    bool internal enabled;
    bool internal disabled;

    // The F1 cadence matrix, ROW BY ROW, in storage rather than in locals:
    // RewardBracketTest asserts every row (`_checkCadence`) and eight more
    // stack slots in `test_F1_cadence_matrix` is stack-too-deep.
    // Index: 0 createLock, 1 increaseAmount, 2 increaseUnlockTime,
    // 3 enableAutoRelock, 4 increaseUnlockTime@FLAT, 5 transferFrom,
    // 6 disableAutoRelock, 7 withdraw.
    uint256[8] internal cadence;

    /// @dev The frozen duration `enableAutoRelock` DERIVED, read back out of
    ///      `autoRelockRemaining` in the enable block. `truthCandidate`'s
    ///      phase-3 restored end is computed from it.
    uint256 internal derivedR;

    /// @dev The flat weight level the contract produced, read in the enable
    ///      block (the bucket mean: s*(2N-1)*S/2). The truth integral is
    ///      computed from the OBSERVED level.
    uint256 internal observedFlatWeight;

    function _deployDistributors() internal {
        counterM = new CountingDistributor(address(M.ve));
        counterX = new CountingDistributor(address(X.ve));
        integratorM = new TrapezoidIntegratorDistributor(address(M.ve));
        integratorX = new TrapezoidIntegratorDistributor(address(X.ve));
    }

    function _useCounter() internal {
        M.ve.updateRewardDistributor(IRewardDistributor(address(counterM)));
        X.ve.updateRewardDistributor(IRewardDistributor(address(counterX)));
    }

    function _useIntegrator() internal {
        M.ve.updateRewardDistributor(IRewardDistributor(address(integratorM)));
        X.ve.updateRewardDistributor(IRewardDistributor(address(integratorX)));
    }

    function _driveCandidate(uint256 ts) internal override {
        if (enableAt == 0) return;
        if (!enabled && ts >= enableAt) {
            enabled = true;
            require(ts == enableAt, "enable did not land on the requested instant");
            vm.prank(bob);
            // ONE ARGUMENT. The contract derives R from lock.end and grid(now).
            X.ve.enableAutoRelock(positions[candidateIndex].tokenId);
            derivedR = uint256(X.ve.autoRelockRemaining(positions[candidateIndex].tokenId));
            observedFlatWeight = X.ve.balanceOfNFT(positions[candidateIndex].tokenId);
        }
        if (enabled && !disabled && disableAt != 0 && ts >= disableAt) {
            disabled = true;
            require(ts == disableAt, "disable did not land on the requested instant");
            vm.prank(bob);
            X.ve.disableAutoRelock(positions[candidateIndex].tokenId);
        }
    }

    function slope() internal pure returns (uint256) {
        return AMT / MAX_TIME;
    }

    // ---------------------------------------------------------------- helpers
    /// @dev The analytic TRUTH for a manual twin over `buckets` whole buckets,
    ///      each bucket decaying linearly from s*N*S down to s*(N-1)*S:
    ///          ∫ = buckets * s * S^2 * (N - 1/2)
    function truthManual(uint256 buckets) internal pure returns (uint256) {
        return (buckets * slope() * SIX_DAYS * (2 * N - 1) * SIX_DAYS) / 2;
    }

    /// @dev The analytic TRUTH for the candidate's shape: decay from t0 to
    ///      `enableOffset`, flat at the OBSERVED level from `enableOffset` to
    ///      `disableOffset`, then decay to the restored end from
    ///      `disableOffset` to `integrationEndOffset`. All offsets are seconds from t0; the
    ///      position's end at t0 is N*S. Exact integer arithmetic. The restored
    ///      end is `grid(disable) + derivedR`, with `derivedR` read back from
    ///      the contract.
    function truthCandidate(uint256 enableOffset, uint256 disableOffset, uint256 integrationEndOffset)
        internal
        view
        returns (uint256)
    {
        uint256 s = slope();
        uint256 acc;
        // phase 1: decay, end0 = N*S
        acc += s * (N * SIX_DAYS * enableOffset - (enableOffset * enableOffset) / 2);
        // phase 2: flat at the level the contract produced (`observedFlatWeight`)
        acc += observedFlatWeight * (disableOffset - enableOffset);
        // phase 3: decay to the restored end, grid(disableOffset) + derivedR
        uint256 restoredEnd = (disableOffset / SIX_DAYS) * SIX_DAYS + derivedR;
        acc += s
            * (restoredEnd * (integrationEndOffset - disableOffset) - (integrationEndOffset * integrationEndOffset - disableOffset * disableOffset) / 2);
        return acc;
    }

    /// @dev `actual - expected` in basis points of `expected`; 0 when `expected`
    ///      is 0.
    function _deviationBpsOrZero(uint256 actual, uint256 expected) internal pure returns (int256) {
        if (expected == 0) return 0;
        return (int256(actual) - int256(expected)) * 10_000 / int256(expected);
    }

}

/// @dev The six measurement bodies. ABSTRACT: only RewardBracketTest
///      instantiates them, and its overrides of the `_check*` hooks supply the
///      assertions.
abstract contract RewardFlatLifeBase is RewardTwinBase {
    function _checkManualExtenderAccrual(uint256, uint256) internal virtual {}

    // =====================================================================
    // F1 — THE CADENCE MATRIX.
    //      Which weight-changing user entry points notify the distributor?
    // =====================================================================
    function test_F1_cadence_matrix() public {
        setUpTwinOracle();
        _deployDistributors();
        _useCounter();

        uint256 before_;
        // createLock
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        cadence[0] = counterX.notificationCountFor(id);
        emit log_named_uint("F1 createLock            ", counterX.notificationCountFor(id));
        assertGt(counterX.notificationCountFor(id), 0, "createLock must notify");

        // increaseAmount
        before_ = counterX.notificationCountFor(id);
        X.hemi.mint(bob, AMT);
        vm.startPrank(bob);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(id, AMT);
        vm.stopPrank();
        cadence[1] = counterX.notificationCountFor(id) - before_;
        emit log_named_uint("F1 increaseAmount        ", counterX.notificationCountFor(id) - before_);
        assertGt(counterX.notificationCountFor(id) - before_, 0, "increaseAmount must notify");

        // increaseUnlockTime
        before_ = counterX.notificationCountFor(id);
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 2) * SIX_DAYS);
        cadence[2] = counterX.notificationCountFor(id) - before_;
        emit log_named_uint("F1 increaseUnlockTime    ", counterX.notificationCountFor(id) - before_);
        assertGt(counterX.notificationCountFor(id) - before_, 0, "increaseUnlockTime must notify");

        // enableAutoRelock
        before_ = counterX.notificationCountFor(id);
        vm.prank(bob);
        X.ve.enableAutoRelock(id);
        uint256 enableCalls = counterX.notificationCountFor(id) - before_;
        cadence[3] = enableCalls;
        emit log_named_uint("F1 enableAutoRelock      ", enableCalls);

        // increaseUnlockTime WHILE FLAT
        before_ = counterX.notificationCountFor(id);
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 3) * SIX_DAYS);
        cadence[4] = counterX.notificationCountFor(id) - before_;
        emit log_named_uint("F1 increaseUnlockTime@FLAT", counterX.notificationCountFor(id) - before_);
        assertGt(counterX.notificationCountFor(id) - before_, 0, "increaseUnlockTime@flat must notify");

        // disableAutoRelock: measured BEFORE the transfer, because a transfer
        // AUTO-DISABLES an armed position -- there would be nothing left to
        // disable afterwards.
        before_ = counterX.notificationCountFor(id);
        vm.prank(bob);
        X.ve.disableAutoRelock(id);
        uint256 disableCalls = counterX.notificationCountFor(id) - before_;
        cadence[6] = disableCalls;
        emit log_named_uint("F1 disableAutoRelock     ", disableCalls);

        // transferFrom (now of the decaying position bob still owns)
        before_ = counterX.notificationCountFor(id);
        vm.prank(bob);
        X.ve.transferFrom(bob, alice, id);
        cadence[5] = counterX.notificationCountFor(id) - before_;
        emit log_named_uint("F1 transferFrom          ", counterX.notificationCountFor(id) - before_);
        assertGt(counterX.notificationCountFor(id) - before_, 0, "transferFrom must notify");

        // withdraw
        vm.warp(block.timestamp + 20 * SIX_DAYS);
        vm.roll(block.number + 1000);
        before_ = counterX.notificationCountFor(id);
        vm.prank(alice);
        X.ve.withdraw(id);
        cadence[7] = counterX.notificationCountFor(id) - before_;
        emit log_named_uint("F1 withdraw              ", counterX.notificationCountFor(id) - before_);
        assertGt(counterX.notificationCountFor(id) - before_, 0, "withdraw must notify");

        _checkEnableDisableNotifications(enableCalls, disableCalls);
        _checkCadence();
    }

    /// @dev Overridden by RewardBracketTest. Report-only here.
    function _checkCadence() internal virtual {}

    /// @dev Overridden by RewardBracketTest. Report-only here.
    function _checkEnableDisableNotifications(uint256, uint256) internal virtual {}

    // =====================================================================
    // F2 — Hook calls over 12 buckets: twin vs flat candidate.
    // =====================================================================
    function test_F2_flatPositionSendsNoNotificationsWhileTheTwinNotifiesEveryBucket() public {
        setUpTwinOracle();
        _deployDistributors();
        _useCounter();
        (manualIndex, candidateIndex) = spawnPair(alice, bob, AMT, N, Cadence.NEVER);
        // Enable BEFORE the measurement window opens. What is being counted is
        // the notifications issued DURING a flat life, not the ones the enable
        // transaction itself issues (those are F1's subject).
        vm.prank(bob);
        X.ve.enableAutoRelock(positions[candidateIndex].tokenId);
        enabled = true;
        enableAt = 0;

        uint256 mCalls0 = counterM.notificationCountFor(positions[manualIndex].tokenId);
        uint256 xCalls0 = counterX.notificationCountFor(positions[candidateIndex].tokenId);

        sweep(13, 3);

        uint256 mCalls = counterM.notificationCountFor(positions[manualIndex].tokenId) - mCalls0;
        uint256 xCalls = counterX.notificationCountFor(positions[candidateIndex].tokenId) - xCalls0;
        emit log_named_uint("F2 manual hook calls / 12 buckets", mCalls);
        emit log_named_uint("F2 flat   hook calls / 12 buckets", xCalls);
        assertEq(mCalls % 12, 0, "the manual twin notifies a whole number of times per bucket");
        assertGe(mCalls, 12, "the manual twin notifies at least once per bucket");
        emit log_string("F2 a flat position sends NO TRANSACTION, so VeHemi cannot notify on its behalf.");
        _checkFlatLifeNotifications(xCalls);
    }

    function _checkFlatLifeNotifications(uint256) internal virtual {}

    // =====================================================================
    // F3 — WHAT THE MISSING NOTIFICATIONS COST. Shape A: enable ON a bucket
    //      boundary, 12 buckets flat, disable ON a boundary.
    // =====================================================================
    function test_F3_shapeA_boundary_enable() public {
        _measureShape(0, 12 * SIX_DAYS, "F3/A");
    }

    // =====================================================================
    // F4 — Shape B: enable MID-BUCKET and disable MID-BUCKET. At the
    //      bucket-mean level BOTH ends are discontinuities (see
    //      RewardBracketTest's note on F3/A).
    // =====================================================================
    function test_F4_shapeB_midbucket() public {
        _measureShape(3600, 9 * SIX_DAYS + SIX_DAYS / 2, "F4/B");
    }

    function _measureShape(uint256 enableOffset, uint256 disableOffset, string memory tag) internal {
        setUpTwinOracle();
        _deployDistributors();
        _useIntegrator();
        (manualIndex, candidateIndex) = spawnPair(alice, bob, AMT, N, Cadence.NEVER);
        uint256 idM = positions[manualIndex].tokenId;
        uint256 idX = positions[candidateIndex].tokenId;

        // Open the window with a REAL, contract-issued notification at t0 in
        // BOTH universes. 1 wei adds 0 to the slope (1/MAX_TIME == 0).
        _topUpOneWei(M, alice, idM);
        _topUpOneWei(X, bob, idX);

        enableAt = t0 + enableOffset;
        disableAt = t0 + disableOffset;

        sweep(14, 1);

        uint256 tEnd = t0 + 14 * SIX_DAYS;
        vm.warp(tEnd);
        vm.roll(block.number + 1);
        _topUpOneWei(M, alice, idM);
        _topUpOneWei(X, bob, idX);

        uint256 manualAccrued = integratorM.accrued(idM);
        uint256 flatAccrued = integratorX.accrued(idX);
        uint256 manualTruth = truthManual(14);
        uint256 flatTruth = truthCandidate(enableOffset, disableOffset, 14 * SIX_DAYS);

        emit log_named_string("shape", tag);
        emit log_named_uint("  manual accrued (wei-s)", manualAccrued);
        emit log_named_uint("  manual TRUTH   (wei-s)", manualTruth);
        emit log_named_int("  manual error bps      ", _deviationBpsOrZero(manualAccrued, manualTruth));
        emit log_named_uint("  flat   accrued (wei-s)", flatAccrued);
        emit log_named_uint("  flat   TRUTH   (wei-s)", flatTruth);
        emit log_named_int("  flat   error bps      ", _deviationBpsOrZero(flatAccrued, flatTruth));
        emit log_named_int("  TRUTH  flat vs manual bps", _deviationBpsOrZero(flatTruth, manualTruth));
        emit log_named_int("  flat   vs manual accrued bps", _deviationBpsOrZero(flatAccrued, manualAccrued));
        emit log_named_uint("  manual hook calls", integratorM.calls());
        emit log_named_uint("  flat   hook calls", integratorX.calls());
        emit log_named_uint("  flat level observed  ", observedFlatWeight);
        emit log_named_uint("  derived R (seconds)  ", derivedR);
        _checkShape(tag, manualAccrued, flatAccrued, flatTruth);
    }

    function _checkShape(string memory tag, uint256 manualAccrued, uint256 flatAccrued, uint256 flatTruth)
        internal
        virtual
    {}

    function _topUpOneWei(Stack memory s, address who, uint256 id) internal {
        s.hemi.mint(who, 1);
        vm.startPrank(who);
        s.hemi.approve(address(s.ve), type(uint256).max);
        s.ve.increaseAmount(id, 1);
        vm.stopPrank();
    }

    // =====================================================================
    // F6 — INTEGRAL EQUIVALENCE OVER A PURE FLAT WINDOW: the
    //      bucket-mean flat level accrues exactly the manual twin's
    //      integral.
    // =====================================================================
    function test_F6_flat_window_integral_equivalence() public {
        setUpTwinOracle();
        _deployDistributors();
        _useIntegrator();
        (manualIndex, candidateIndex) = spawnPair(alice, bob, AMT, N, Cadence.NEVER);
        uint256 idM = positions[manualIndex].tokenId;
        uint256 idX = positions[candidateIndex].tokenId;
        _topUpOneWei(M, alice, idM);
        _topUpOneWei(X, bob, idX);

        enableAt = t0;
        disableAt = 0; // never

        sweep(12, 1);
        uint256 tEnd = t0 + 12 * SIX_DAYS;
        vm.warp(tEnd);
        vm.roll(block.number + 1);
        _topUpOneWei(M, alice, idM);
        _topUpOneWei(X, bob, idX);

        uint256 manualAccrued = integratorM.accrued(idM);
        uint256 flatAccrued = integratorX.accrued(idX);
        uint256 manualTruth = truthManual(12);
        uint256 flatTruth = observedFlatWeight * 12 * SIX_DAYS;

        emit log_named_uint("F6 manual accrued      ", manualAccrued);
        emit log_named_uint("F6 manual TRUTH        ", manualTruth);
        emit log_named_int("F6 manual error bps    ", _deviationBpsOrZero(manualAccrued, manualTruth));
        emit log_named_uint("F6 flat accrued        ", flatAccrued);
        emit log_named_uint("F6 flat TRUTH          ", flatTruth);
        emit log_named_int("F6 flat error bps      ", _deviationBpsOrZero(flatAccrued, flatTruth));
        emit log_named_uint("F6 flat level          ", observedFlatWeight);
        emit log_named_int("F6 TRUTH flat vs manual", _deviationBpsOrZero(flatTruth, manualTruth));
        emit log_named_int("F6 ACCRUED flat vs manual", _deviationBpsOrZero(flatAccrued, manualAccrued));
        emit log_named_uint("F6 manual hook calls   ", integratorM.calls());
        emit log_named_uint("F6 flat hook calls     ", integratorX.calls());
        _checkFlatWindowEquivalence(manualAccrued, manualTruth, flatAccrued, flatTruth);
    }

    function _checkFlatWindowEquivalence(uint256, uint256, uint256, uint256) internal virtual {}

    // =====================================================================
    // F5 — THE MANUAL TWIN ALONE, no auto-relock anywhere: with
    //      `_depositFor` bracketed, a manual extender's accrual is exact
    //      (RewardBracketTest asserts equality).
    // =====================================================================
    function test_F5_manual_extender_accrual_is_exact() public {
        setUpTwinOracle();
        _deployDistributors();
        _useIntegrator();
        manualIndex = spawn(false, alice, AMT, N, Cadence.MANUAL, false, false);
        uint256 idM = positions[manualIndex].tokenId;
        _topUpOneWei(M, alice, idM);

        sweep(14, 1);
        vm.warp(t0 + 14 * SIX_DAYS);
        vm.roll(block.number + 1);
        _topUpOneWei(M, alice, idM);

        uint256 manualAccrued = integratorM.accrued(idM);
        uint256 manualTruth = truthManual(14);
        emit log_named_uint("F5 manual accrued      ", manualAccrued);
        emit log_named_uint("F5 manual TRUTH        ", manualTruth);
        emit log_named_int("F5 accrued vs TRUTH bps", _deviationBpsOrZero(manualAccrued, manualTruth));
        _checkManualExtenderAccrual(manualAccrued, manualTruth);
    }
}

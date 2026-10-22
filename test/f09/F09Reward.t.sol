// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ===========================================================================
// F09 -- THE REWARD-DISTRIBUTOR HOOK DURING A FLAT LIFE.
//
// `F09Base` is the harness: two universes (M holds a manually-extended twin,
// X the auto-relock candidate), distributor doubles, and the analytic truths.
// `F09Reward` holds the six measurement bodies F1-F6; it is abstract, and
// test/f09/F09Gate.t.sol instantiates it and supplies the assertions.
//
//   * `enableAutoRelock(id)` DERIVES the frozen duration
//     R = floor((lock.end - grid(now)) / SIX_DAYS) * SIX_DAYS (whole buckets,
//     `R >= 2*SIX_DAYS`), so every R in this suite is read back from the
//     contract, not chosen by the test.
//   * The flat level is V-MEAN, `slope * (R - SIX_DAYS/2)`; the integrals use
//     the level read back from the contract.
//   * `_endAutoRelock` serves both `disableAutoRelock` and the permissionless
//     `retireStaleAutoRelock`.
// ===========================================================================

import "../TwinOracle.sol";
import "./F09Mocks.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

/// @dev Harness only: the two universes, the counters, the analytic truths.
///      Kept separate from F09Reward so another suite can reuse it without
///      inheriting -- and silently re-running -- the six measurement bodies.
abstract contract F09Base is TwinOracle {
    uint256 internal constant AMT = 1000e18;
    uint256 internal constant N = 6;

    F09Counter internal cntM;
    F09Counter internal cntX;
    F09SegmentIntegrator internal segM;
    F09SegmentIntegrator internal segX;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal mi;
    uint256 internal xi;

    // candidate drive plan
    uint256 internal enableAt;
    uint256 internal disableAt;
    bool internal enabled;
    bool internal disabled;

    // The F1 cadence matrix, ROW BY ROW, in storage rather than in locals:
    // the gate asserts every row (`_recordCadence`) and eight more stack slots
    // in `test_F1_cadence_matrix` is stack-too-deep.
    // Index: 0 createLock, 1 increaseAmount, 2 increaseUnlockTime,
    // 3 enableAutoRelock, 4 increaseUnlockTime@FLAT, 5 transferFrom,
    // 6 disableAutoRelock, 7 withdraw.
    uint256[8] internal cadence;

    /// @dev The frozen duration `enableAutoRelock` DERIVED, read back out of
    ///      `autoRelockRemaining` in the enable block. `truthCandidate`'s
    ///      phase-3 restored end is computed from it.
    uint256 internal derivedR;

    /// @dev The flat weight level the contract produced, read in the enable
    ///      block (V-MEAN: s*(2N-1)*S/2). The truth integral is computed from
    ///      the OBSERVED level.
    uint256 internal flatW;

    function _install() internal {
        cntM = new F09Counter(address(M.ve));
        cntX = new F09Counter(address(X.ve));
        segM = new F09SegmentIntegrator(address(M.ve));
        segX = new F09SegmentIntegrator(address(X.ve));
    }

    function _useCounter() internal {
        M.ve.updateRewardDistributor(IRewardDistributor(address(cntM)));
        X.ve.updateRewardDistributor(IRewardDistributor(address(cntX)));
    }

    function _useIntegrator() internal {
        M.ve.updateRewardDistributor(IRewardDistributor(address(segM)));
        X.ve.updateRewardDistributor(IRewardDistributor(address(segX)));
    }

    function _driveCandidate(uint256 ts) internal override {
        if (enableAt == 0) return;
        if (!enabled && ts >= enableAt) {
            enabled = true;
            require(ts == enableAt, "F09: enable did not land on the requested instant");
            vm.prank(bob);
            // ONE ARGUMENT. The contract derives R from lock.end and grid(now).
            X.ve.enableAutoRelock(positions[xi].tokenId);
            derivedR = uint256(X.ve.autoRelockRemaining(positions[xi].tokenId));
            flatW = X.ve.balanceOfNFT(positions[xi].tokenId);
        }
        if (enabled && !disabled && disableAt != 0 && ts >= disableAt) {
            disabled = true;
            require(ts == disableAt, "F09: disable did not land on the requested instant");
            vm.prank(bob);
            X.ve.disableAutoRelock(positions[xi].tokenId);
        }
    }

    function slope() internal pure returns (uint256) {
        return AMT / MAX_TIME;
    }

    // ---------------------------------------------------------------- helpers
    /// @dev The analytic TRUTH for a manual twin over `b` whole buckets, each
    ///      bucket decaying linearly from s*N*S down to s*(N-1)*S:
    ///          ∫ = b * s * S^2 * (N - 1/2)
    function truthManual(uint256 b) internal pure returns (uint256) {
        return (b * slope() * SIX_DAYS * (2 * N - 1) * SIX_DAYS) / 2;
    }

    /// @dev The analytic TRUTH for the candidate's shape: decay from t0 to
    ///      `enOff`, flat at the OBSERVED level from `enOff` to `disOff`, then
    ///      decay to the restored end from `disOff` to `T`. All offsets are
    ///      seconds from t0; the position's end at t0 is N*S. Exact integer
    ///      arithmetic. The restored end is `grid(disable) + derivedR`, with
    ///      `derivedR` read back from the contract.
    function truthCandidate(uint256 enOff, uint256 disOff, uint256 T) internal view returns (uint256) {
        uint256 s = slope();
        uint256 acc;
        // phase 1: decay, end0 = N*S
        acc += s * (N * SIX_DAYS * enOff - (enOff * enOff) / 2);
        // phase 2: flat at the level THIS BUILD produced
        acc += flatW * (disOff - enOff);
        // phase 3: decay to the restored end E = grid(disOff) + derivedR
        uint256 E = (disOff / SIX_DAYS) * SIX_DAYS + derivedR;
        acc += s * (E * (T - disOff) - (T * T - disOff * disOff) / 2);
        return acc;
    }

    function bps(uint256 a, uint256 b) internal pure returns (int256) {
        if (b == 0) return 0;
        return (int256(a) - int256(b)) * 10_000 / int256(b);
    }

}

/// @dev The six measurement bodies. ABSTRACT: only F09Gate instantiates them,
///      and its overrides of the `_record*` hooks supply the assertions.
abstract contract F09Reward is F09Base {
    function _recordF5(uint256 aM, uint256 tM) internal virtual {
        assertLt(aM, tM, "F5 baseline: notify-BEFORE under-credits a manual extender");
    }

    // =====================================================================
    // F1 — THE CADENCE MATRIX.
    //      Which weight-changing user entry points notify the distributor?
    // =====================================================================
    function test_F1_cadence_matrix() public {
        setUpTwinOracle();
        _install();
        _useCounter();

        uint256 before_;
        // createLock
        uint256 xa = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[xa].tokenId;
        cadence[0] = cntX.callsFor(id);
        emit log_named_uint("F1 createLock            ", cntX.callsFor(id));
        assertGt(cntX.callsFor(id), 0, "createLock must notify");

        // increaseAmount
        before_ = cntX.callsFor(id);
        X.hemi.mint(bob, AMT);
        vm.startPrank(bob);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(id, AMT);
        vm.stopPrank();
        cadence[1] = cntX.callsFor(id) - before_;
        emit log_named_uint("F1 increaseAmount        ", cntX.callsFor(id) - before_);
        assertGt(cntX.callsFor(id) - before_, 0, "increaseAmount must notify");

        // increaseUnlockTime
        before_ = cntX.callsFor(id);
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 2) * SIX_DAYS);
        cadence[2] = cntX.callsFor(id) - before_;
        emit log_named_uint("F1 increaseUnlockTime    ", cntX.callsFor(id) - before_);
        assertGt(cntX.callsFor(id) - before_, 0, "increaseUnlockTime must notify");

        // enableAutoRelock
        before_ = cntX.callsFor(id);
        vm.prank(bob);
        X.ve.enableAutoRelock(id);
        uint256 enCalls = cntX.callsFor(id) - before_;
        cadence[3] = enCalls;
        emit log_named_uint("F1 enableAutoRelock      ", enCalls);

        // increaseUnlockTime WHILE FLAT
        before_ = cntX.callsFor(id);
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 3) * SIX_DAYS);
        cadence[4] = cntX.callsFor(id) - before_;
        emit log_named_uint("F1 increaseUnlockTime@FLAT", cntX.callsFor(id) - before_);
        assertGt(cntX.callsFor(id) - before_, 0, "increaseUnlockTime@flat must notify");

        // disableAutoRelock: measured BEFORE the transfer, because a transfer
        // AUTO-DISABLES an armed position -- there would be nothing left to
        // disable afterwards.
        before_ = cntX.callsFor(id);
        vm.prank(bob);
        X.ve.disableAutoRelock(id);
        uint256 disCalls = cntX.callsFor(id) - before_;
        cadence[6] = disCalls;
        emit log_named_uint("F1 disableAutoRelock     ", disCalls);

        // transferFrom (now of the decaying position bob still owns)
        before_ = cntX.callsFor(id);
        vm.prank(bob);
        X.ve.transferFrom(bob, alice, id);
        cadence[5] = cntX.callsFor(id) - before_;
        emit log_named_uint("F1 transferFrom          ", cntX.callsFor(id) - before_);
        assertGt(cntX.callsFor(id) - before_, 0, "transferFrom must notify");

        // withdraw
        vm.warp(block.timestamp + 20 * SIX_DAYS);
        vm.roll(block.number + 1000);
        before_ = cntX.callsFor(id);
        vm.prank(alice);
        X.ve.withdraw(id);
        cadence[7] = cntX.callsFor(id) - before_;
        emit log_named_uint("F1 withdraw              ", cntX.callsFor(id) - before_);
        assertGt(cntX.callsFor(id) - before_, 0, "withdraw must notify");

        emit log_string(
            enCalls == 0 && disCalls == 0
                ? "F1 VERDICT: 7 of 9 weight-changing entry points notify; enable/disable do NOT."
                : "F1 VERDICT: enable/disable DO notify (F09 P2 present)."
        );
        _recordMatrix(enCalls, disCalls);
        _recordCadence();
    }

    /// @dev Overridden by the GATE. Report-only here.
    function _recordCadence() internal virtual {}

    /// @dev Overridden by the GATE. Report-only here.
    function _recordMatrix(uint256, uint256) internal virtual {}

    // =====================================================================
    // F2 — Hook calls over 12 epochs: twin vs flat candidate.
    // =====================================================================
    function test_F2_flat_life_cadence_gap() public {
        setUpTwinOracle();
        _install();
        _useCounter();
        (mi, xi) = spawnPair(alice, bob, AMT, N, Cadence.NEVER);
        // Enable BEFORE the measurement window opens. What is being counted is
        // the notifications issued DURING a flat life, not the ones the enable
        // transaction itself issues (those are F1's subject).
        vm.prank(bob);
        X.ve.enableAutoRelock(positions[xi].tokenId);
        enabled = true;
        enableAt = 0;

        uint256 mCalls0 = cntM.callsFor(positions[mi].tokenId);
        uint256 xCalls0 = cntX.callsFor(positions[xi].tokenId);

        sweep(13, 3);

        uint256 mCalls = cntM.callsFor(positions[mi].tokenId) - mCalls0;
        uint256 xCalls = cntX.callsFor(positions[xi].tokenId) - xCalls0;
        emit log_named_uint("F2 twin  hook calls / 12 epochs", mCalls);
        emit log_named_uint("F2 flat  hook calls / 12 epochs", xCalls);
        assertEq(mCalls % 12, 0, "twin notifies a whole number of times per epoch");
        assertGe(mCalls, 12, "twin notifies at least once per epoch");
        emit log_string("F2 a flat position sends NO TRANSACTION, so no build can notify from one.");
        _recordGap(xCalls);
    }

    function _recordGap(uint256) internal virtual {}

    // =====================================================================
    // F3 — WHAT THE GAP COSTS. Shape A: enable ON a bucket boundary, 12
    //      buckets flat, disable ON a boundary.
    // =====================================================================
    function test_F3_shapeA_boundary_enable() public {
        _shape(0, 12 * SIX_DAYS, "F3/A");
    }

    // =====================================================================
    // F4 — Shape B: enable MID-BUCKET and disable MID-BUCKET. Under V-MEAN
    //      BOTH ends are discontinuities (see the gate's note on F3/A).
    // =====================================================================
    function test_F4_shapeB_midbucket() public {
        _shape(3600, 9 * SIX_DAYS + SIX_DAYS / 2, "F4/B");
    }

    function _shape(uint256 enOff, uint256 disOff, string memory tag) internal {
        setUpTwinOracle();
        _install();
        _useIntegrator();
        (mi, xi) = spawnPair(alice, bob, AMT, N, Cadence.NEVER);
        uint256 idM = positions[mi].tokenId;
        uint256 idX = positions[xi].tokenId;

        // Open the window with a REAL, contract-issued notification at t0 in
        // BOTH universes. 1 wei adds 0 to the slope (1/MAX_TIME == 0).
        _oneWei(M, alice, idM);
        _oneWei(X, bob, idX);

        enableAt = t0 + enOff;
        disableAt = t0 + disOff;

        sweep(14, 1);

        uint256 tEnd = t0 + 14 * SIX_DAYS;
        vm.warp(tEnd);
        vm.roll(block.number + 1);
        _oneWei(M, alice, idM);
        _oneWei(X, bob, idX);

        uint256 aM = segM.accrued(idM);
        uint256 aX = segX.accrued(idX);
        uint256 tM = truthManual(14);
        uint256 tX = truthCandidate(enOff, disOff, 14 * SIX_DAYS);

        emit log_named_string("shape", tag);
        emit log_named_uint("  twin   accrued (wei-s)", aM);
        emit log_named_uint("  twin   TRUTH   (wei-s)", tM);
        emit log_named_int("  twin   error bps      ", bps(aM, tM));
        emit log_named_uint("  cand   accrued (wei-s)", aX);
        emit log_named_uint("  cand   TRUTH   (wei-s)", tX);
        emit log_named_int("  cand   error bps      ", bps(aX, tX));
        emit log_named_int("  TRUTH  cand vs twin bps", bps(tX, tM));
        emit log_named_int("  cand   vs twin accrued bps", bps(aX, aM));
        emit log_named_uint("  twin   hook calls", segM.calls());
        emit log_named_uint("  cand   hook calls", segX.calls());
        emit log_named_uint("  flat level observed  ", flatW);
        emit log_named_uint("  derived R (seconds)  ", derivedR);
        _recordShape(tag, aM, aX, tX);
    }

    /// @dev tag, twin accrued, candidate accrued, candidate TRUTH.
    function _recordShape(string memory, uint256, uint256, uint256) internal virtual {}

    function _oneWei(Stack memory s, address who, uint256 id) internal {
        s.hemi.mint(who, 1);
        vm.startPrank(who);
        s.hemi.approve(address(s.ve), type(uint256).max);
        s.ve.increaseAmount(id, 1);
        vm.stopPrank();
    }

    // =====================================================================
    // F6 — INTEGRAL EQUIVALENCE OVER A PURE FLAT WINDOW: the V-MEAN flat
    //      level accrues exactly the manual twin's integral.
    // =====================================================================
    function test_F6_flat_window_integral_equivalence() public {
        setUpTwinOracle();
        _install();
        _useIntegrator();
        (mi, xi) = spawnPair(alice, bob, AMT, N, Cadence.NEVER);
        uint256 idM = positions[mi].tokenId;
        uint256 idX = positions[xi].tokenId;
        _oneWei(M, alice, idM);
        _oneWei(X, bob, idX);

        enableAt = t0;
        disableAt = 0; // never

        sweep(12, 1);
        uint256 tEnd = t0 + 12 * SIX_DAYS;
        vm.warp(tEnd);
        vm.roll(block.number + 1);
        _oneWei(M, alice, idM);
        _oneWei(X, bob, idX);

        uint256 aM = segM.accrued(idM);
        uint256 aX = segX.accrued(idX);
        uint256 tM = truthManual(12);
        uint256 tX = flatW * 12 * SIX_DAYS;

        emit log_named_uint("F6 twin accrued      ", aM);
        emit log_named_uint("F6 twin TRUTH        ", tM);
        emit log_named_int("F6 twin error bps    ", bps(aM, tM));
        emit log_named_uint("F6 cand accrued      ", aX);
        emit log_named_uint("F6 cand TRUTH        ", tX);
        emit log_named_int("F6 cand error bps    ", bps(aX, tX));
        emit log_named_uint("F6 flat level        ", flatW);
        emit log_named_int("F6 TRUTH cand vs twin", bps(tX, tM));
        emit log_named_int("F6 ACCRUED cand vs tw", bps(aX, aM));
        emit log_named_uint("F6 twin hook calls   ", segM.calls());
        emit log_named_uint("F6 cand hook calls   ", segX.calls());
        _recordF6(aM, tM, aX, tX);
    }

    function _recordF6(uint256, uint256, uint256, uint256) internal virtual {}

    // =====================================================================
    // F5 — THE MANUAL TWIN ALONE, no auto-relock anywhere: with
    //      `_depositFor` bracketed, a manual extender's accrual is exact (the
    //      gate asserts equality; the body name describes the unbracketed
    //      behaviour).
    // =====================================================================
    function test_F5_notify_before_undercredits_the_twin() public {
        setUpTwinOracle();
        _install();
        _useIntegrator();
        mi = spawn(false, alice, AMT, N, Cadence.MANUAL, false, false);
        uint256 idM = positions[mi].tokenId;
        _oneWei(M, alice, idM);

        sweep(14, 1);
        vm.warp(t0 + 14 * SIX_DAYS);
        vm.roll(block.number + 1);
        _oneWei(M, alice, idM);

        uint256 aM = segM.accrued(idM);
        uint256 tM = truthManual(14);
        uint256 vLower = 14 * slope() * (N - 1) * SIX_DAYS * SIX_DAYS;
        emit log_named_uint("F5 twin accrued        ", aM);
        emit log_named_uint("F5 twin TRUTH          ", tM);
        emit log_named_uint("F5 V-LOWER level       ", vLower);
        emit log_named_int("F5 accrued vs TRUTH bps", bps(aM, tM));
        emit log_named_int("F5 accrued vs VLOWER bp", bps(aM, vLower));
        _recordF5(aM, tM);
    }
}

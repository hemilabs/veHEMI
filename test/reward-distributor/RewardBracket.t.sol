// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ===========================================================================
// The reward-distributor bracket, asserted.
//
// Every weight-changing entry point notifies the distributor BEFORE the weight
// moves (observing w-) and AFTER it has settled (observing w+), except
// `transferFrom` of an unarmed position and `withdraw`, which notify once.
// `enableAutoRelock`, `disableAutoRelock` and `retireStaleAutoRelock` (both
// through `_endAutoRelock`) and the flat `increaseAmount` / `increaseUnlockTime`
// paths are all bracketed; a reverting distributor is swallowed on every site;
// a re-entrant one cannot re-enter. Accruals are checked against analytic
// integrals (bucket-mean flat level `slope * (R - SIX_DAYS/2)`).
// ===========================================================================

import "./RewardFlatLifeBase.sol";
import {IVeHemi} from "../../src/interfaces/IVeHemi.sol";
import {RevertingRewardDistributor} from "../mocks/RevertingRewardDistributor.sol";

contract RewardBracketTest is RewardFlatLifeBase {
    // ------------------------------------------------------------ F1 .. F6
    // The six measurement bodies of RewardFlatLifeBase only log; the
    // overrides below hold their assertions.

    function _checkEnableDisableNotifications(uint256 enableCalls, uint256 disableCalls) internal override {
        assertEq(enableCalls, 2, "F1: enableAutoRelock must notify TWICE (bracketed)");
        assertEq(disableCalls, 2, "F1: disableAutoRelock must notify TWICE (bracketed)");
    }

    // THE FULL CADENCE MATRIX, ASSERTED ROW BY ROW.
    //
    // Every site that moves the weight brackets it, so the whole matrix is 2
    // except the two that cannot be bracketed and are not supposed to be:
    //   * `transferFrom` of an UNARMED position moves no weight at all -- it
    //     moves an OWNER. One. (An ARMED non-self transfer disarms and so
    //     notifies TWICE, bracketing the weight change; that row is
    //     `test_T7_rewardNotifications_bracketTheDisarm` in
    //     `ArmedTransferMoveOrRemove.t.sol`.
    //     cadence[5] below transfers an already-disarmed position.)
    //   * `withdraw` ends the position; there is no `w+` to re-anchor on, and
    //     the token is burned before the call would return. One.
    // Exact counts, not `> 0`: with a notify-AFTER present, deleting
    // `_depositFor`'s HEAD notify still leaves one call.
    function _checkCadence() internal override {
        assertEq(cadence[0], 2, "F1: createLock must notify TWICE (bracketed)");
        assertEq(cadence[1], 2, "F1: increaseAmount must notify TWICE (bracketed)");
        assertEq(cadence[2], 2, "F1: increaseUnlockTime must notify TWICE (bracketed)");
        assertEq(cadence[3], 2, "F1: enableAutoRelock must notify TWICE (bracketed)");
        assertEq(cadence[4], 2, "F1: increaseUnlockTime@FLAT must notify TWICE (bracketed)");
        assertEq(cadence[5], 1, "F1: transferFrom notifies ONCE (it moves no weight)");
        assertEq(cadence[6], 2, "F1: disableAutoRelock must notify TWICE (bracketed)");
        assertEq(cadence[7], 1, "F1: withdraw notifies ONCE (there is no w+ to re-anchor on)");
    }

    function _checkFlatLifeNotifications(uint256 xCalls) internal override {
        // A flat position sends no transaction, so nothing in VeHemi can
        // notify on its behalf. The notify-AFTER sites add no calls here --
        // they make ZERO calls here CORRECT.
        assertEq(xCalls, 0, "F2: a flat life issues zero notifications");
    }

    function _checkShape(string memory, uint256, uint256 flatAccrued, uint256 flatTruth) internal override {
        // The bucket-mean flat level `s*(N - 1/2)*S` coincides with the
        // decaying weight only at the MIDPOINT of a bucket. A boundary-aligned
        // enable therefore steps DOWN by `s*S/2` and a boundary-aligned disable
        // steps UP by the same amount: both shapes are two-sided
        // discontinuities, so exactness needs the notify-AFTER sites too.
        assertEq(flatAccrued, flatTruth, "F3/F4: the flat position's accrual == the true integral");
    }

    // F5: with `_depositFor` bracketed, a manual extender is credited EXACTLY
    // (an equality convicts both under- and over-crediting).
    function _checkManualExtenderAccrual(uint256 manualAccrued, uint256 manualTruth) internal override {
        assertEq(manualAccrued, manualTruth, "F5: a manual extender is credited EXACTLY (bracketed _depositFor)");
    }

    function _checkFlatWindowEquivalence(
        uint256 manualAccrued,
        uint256 manualTruth,
        uint256 flatAccrued,
        uint256 flatTruth
    ) internal override {
        assertEq(flatAccrued, flatTruth, "F6: the flat position's accrual is exact over a pure flat window");
        // At the bucket-mean level a flat position's reward accrual is
        // identical to the manual twin's TRUE integral, to the wei.
        assertEq(_deviationBpsOrZero(flatTruth, manualTruth), int256(0),
            "F6: the bucket-mean flat level is integral-exact vs the twin");
        assertEq(flatTruth, manualTruth, "F6: bucket-mean flat integral == twin integral, to the wei");
        // With `_depositFor` bracketed the twin's ACCRUAL and the twin's TRUTH
        // coincide, so the flat candidate and the manual twin accrue
        // IDENTICALLY, and both accrue EXACTLY.
        assertEq(manualAccrued, manualTruth, "F6: the twin's ACCRUAL is exact too (bracketed _depositFor)");
        assertEq(manualAccrued, flatAccrued,
            "F6: flat and manual accrue IDENTICALLY (bucket-mean level, bracketed _depositFor)");
    }

    // ==================================================================== J1
    // THE BRACKET IS AN ORDERING CLAIM, NOT A COUNTING CLAIM.
    //
    // The notify-AFTER must sit after `_checkpoint`, not merely after the
    // `locked[]` write: `balanceOfNFT` reads the user-point history, so a
    // notify placed between the two still reports the OLD weight. Two calls
    // that both report `w-` pass every count assertion; this asserts what
    // each call observes.
    // ==================================================================== */
    function test_J1_enable_bracket_observes_both_sides_of_the_step() public {
        setUpTwinOracle();
        _deployDistributors();
        _useCounter();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;

        // Move off the boundary so w- is unambiguous and so the step to the
        // bucket-mean level is not the degenerate half-bucket case.
        vm.warp(t0 + 3600);
        vm.roll(block.number + 300);

        uint256 wBefore = X.ve.balanceOfNFT(id);
        uint256 countBefore = counterX.notificationCountFor(id);

        vm.prank(bob);
        X.ve.enableAutoRelock(id);

        uint256 notifications = counterX.notificationCountFor(id) - countBefore;
        assertEq(notifications, 2, "J1: enableAutoRelock issues exactly two notifications");

        uint256 observedBefore = counterX.weightAtNotification(id, countBefore);
        uint256 observedAfter = counterX.weightAtNotification(id, countBefore + 1);
        emit log_named_uint("J1 w- observed by notify-BEFORE", observedBefore);
        emit log_named_uint("J1 w+ observed by notify-AFTER ", observedAfter);
        emit log_named_uint("J1 w- read by the test         ", wBefore);
        emit log_named_uint("J1 flat level now              ", X.ve.balanceOfNFT(id));

        // The ONE-ARGUMENT ABI derives R. Assert what it derived.
        uint256 remaining = uint256(X.ve.autoRelockRemaining(id));
        assertEq(remaining, N * SIX_DAYS, "J1: one-arg enable derives R = N whole buckets from grid(now)");

        // BEFORE must see the OLD, decaying weight.
        assertEq(observedBefore, wBefore, "J1: notify-BEFORE must observe w- (the pre-enable weight)");
        // AFTER must see the NEW, flat weight — i.e. it must sit after
        // _checkpoint, because balanceOfNFT reads the user-point history.
        assertEq(observedAfter, meanLevelOf(AMT, N), "J1: notify-AFTER must observe the bucket-mean flat level");
        assertEq(observedAfter, X.ve.balanceOfNFT(id), "J1: notify-AFTER's sample is the settled weight");
        // ...and the two must actually differ, or the bracket buys nothing.
        assertTrue(observedBefore != observedAfter, "J1: the bracket must straddle a real discontinuity");
        // Same block, so the segment the distributor closes has zero width.
        assertEq(
            counterX.timeOfNotification(id, countBefore),
            counterX.timeOfNotification(id, countBefore + 1),
            "J1: both calls in the same block"
        );
    }

    // ==================================================================== J2
    // Same claim for the DOWNWARD step at disable.
    // ==================================================================== */
    function test_J2_disable_bracket_observes_both_sides_of_the_step() public {
        setUpTwinOracle();
        _deployDistributors();
        _useCounter();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        vm.prank(bob);
        X.ve.enableAutoRelock(id);

        vm.warp(t0 + 2 * SIX_DAYS + 3600);
        vm.roll(block.number + 900);

        uint256 wFlat = X.ve.balanceOfNFT(id);
        uint256 countBefore = counterX.notificationCountFor(id);

        vm.prank(bob);
        X.ve.disableAutoRelock(id);

        assertEq(counterX.notificationCountFor(id) - countBefore, 2,
            "J2: disableAutoRelock issues exactly two notifications");
        uint256 observedBefore = counterX.weightAtNotification(id, countBefore);
        uint256 observedAfter = counterX.weightAtNotification(id, countBefore + 1);
        emit log_named_uint("J2 w- (flat) observed by notify-BEFORE", observedBefore);
        emit log_named_uint("J2 w+ (decaying) observed by notify-AFTER", observedAfter);

        assertEq(observedBefore, wFlat, "J2: notify-BEFORE must observe the flat level");
        assertEq(observedAfter, X.ve.balanceOfNFT(id), "J2: notify-AFTER must observe the restored decaying weight");
        assertTrue(observedBefore != observedAfter, "J2: the bracket must straddle a real discontinuity");
        // The restored end is the floor-snap of grid(now) + R.
        uint256 restoredEnd = uint256(X.ve.getLockedBalance(id).end);
        assertEq(restoredEnd, (block.timestamp / SIX_DAYS) * SIX_DAYS + N * SIX_DAYS, "J2: restored end");
        assertEq(observedAfter, slope() * (restoredEnd - block.timestamp), "J2: notify-AFTER sees the restored decay");
    }

    // ==================================================================== J3
    // `_endAutoRelock` HAS TWO ENTRY POINTS: `disableAutoRelock` and the
    // permissionless `retireStaleAutoRelock`. If the two hooks were moved out
    // of `_endAutoRelock` into `disableAutoRelock`, F1/J2 would stay green and
    // the retire path would silently lose both.
    // ==================================================================== */
    function test_J3_retireStaleAutoRelock_is_bracketed_too() public {
        setUpTwinOracle();
        _deployDistributors();
        _useCounter();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        vm.prank(bob);
        X.ve.enableAutoRelock(id);

        uint256 staleAt = X.ve.autoRelockStaleAt(id);
        vm.warp(staleAt);
        vm.roll(block.number + 10_000);

        uint256 wFlat = X.ve.balanceOfNFT(id);
        uint256 countBefore = counterX.notificationCountFor(id);

        // A total stranger.
        vm.prank(address(0xDEAD));
        X.ve.retireStaleAutoRelock(id);

        assertEq(counterX.notificationCountFor(id) - countBefore, 2,
            "J3: retireStaleAutoRelock must notify TWICE, like disable");
        uint256 observedBefore = counterX.weightAtNotification(id, countBefore);
        uint256 observedAfter = counterX.weightAtNotification(id, countBefore + 1);
        assertEq(observedBefore, wFlat, "J3: notify-BEFORE must observe the flat level");
        assertEq(observedAfter, X.ve.balanceOfNFT(id), "J3: notify-AFTER must observe the restored decaying weight");
        assertTrue(observedBefore != observedAfter, "J3: the retire bracket must straddle a real discontinuity");
        emit log_named_uint("J3 stale-retire w-", observedBefore);
        emit log_named_uint("J3 stale-retire w+", observedAfter);
    }

    // ==================================================================== J4
    // THE REVERT MUST STAY SWALLOWED on the enable / disable / retire sites.
    //
    // `test_createLock_succeedsWhenRewardDistributorReverts` and
    // `test_increaseAmount_succeedsWhenRewardDistributorReverts`
    // (test/VeHemi.t.sol) cover the try/catch for `_depositFor`'s head site.
    // The notify-AFTER sites here run AFTER all state is settled, so an
    // unswallowed revert would roll back a completed enable / disable. Two
    // `RewardUpdateFailed` logs per call are also an independent witness of
    // the call COUNT that does not go through a mock's storage.
    // ==================================================================== */
    function test_J4_broken_distributor_cannot_block_enable_disable_or_retire() public {
        setUpTwinOracle();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        X.ve.updateRewardDistributor(IRewardDistributor(address(new RevertingRewardDistributor())));

        vm.recordLogs();
        vm.prank(bob);
        X.ve.enableAutoRelock(id); // must NOT revert
        assertEq(_countRewardUpdateFailed(id), 2, "J4: enable emits RewardUpdateFailed twice");
        assertTrue(X.ve.isAutoRelockEnabled(id), "J4: enable survived a reverting distributor");

        vm.warp(t0 + 2 * SIX_DAYS + 3600);
        vm.roll(block.number + 900);

        vm.recordLogs();
        vm.prank(bob);
        X.ve.disableAutoRelock(id); // must NOT revert
        assertEq(_countRewardUpdateFailed(id), 2, "J4: disable emits RewardUpdateFailed twice");
        assertFalse(X.ve.isAutoRelockEnabled(id), "J4: disable survived a reverting distributor");

        // and the permissionless path
        vm.prank(bob);
        X.ve.enableAutoRelock(id);
        vm.warp(X.ve.autoRelockStaleAt(id));
        vm.roll(block.number + 10_000);
        vm.recordLogs();
        vm.prank(address(0xDEAD));
        X.ve.retireStaleAutoRelock(id);
        assertEq(_countRewardUpdateFailed(id), 2, "J4: retire emits RewardUpdateFailed twice");
        assertFalse(X.ve.isAutoRelockEnabled(id), "J4: retire survived a reverting distributor");
    }

    function _countRewardUpdateFailed(uint256 id) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IVeHemi.RewardUpdateFailed.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(X.ve)) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != topic) continue;
            if (uint256(logs[i].topics[1]) != id) continue;
            ++n;
        }
    }

    // ==================================================================== J5
    // THE FLAT DEPOSIT PATHS ARE BRACKETED.
    //
    // The J1/J2/J3 claim at the two sites `_depositFor` serves on a FLAT
    // position (`increaseUnlockTime`, `increaseAmount`): TWO notifications;
    // the first observes `w-`; the second observes `w+`; they differ; same
    // block. Both weight steps are also asserted by value, so the bracket cannot
    // be credited for a step that stopped happening.
    // ==================================================================== */
    function test_J5_flat_increase_paths_are_bracketed() public {
        setUpTwinOracle();
        _deployDistributors();
        _useCounter();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        vm.prank(bob);
        X.ve.enableAutoRelock(id);

        // --- increaseUnlockTime on a FLAT position -------------------------
        vm.warp(t0 + SIX_DAYS + 3600);
        vm.roll(block.number + 400);
        uint256 weightBeforeExtension = X.ve.balanceOfNFT(id);
        uint256 countBeforeExtension = counterX.notificationCountFor(id);
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 3) * SIX_DAYS);
        uint256 weightAfterExtension = X.ve.balanceOfNFT(id);

        emit log_named_uint("J5 flat increaseUnlockTime step (wei)", weightAfterExtension - weightBeforeExtension);
        assertGt(weightAfterExtension, weightBeforeExtension,
            "J5: flat increaseUnlockTime really does step the weight UP");
        assertEq(weightAfterExtension - weightBeforeExtension, 12_499_999_999_999_625_160,
            "J5: the flat increaseUnlockTime step, to the wei");
        assertEq(counterX.notificationCountFor(id) - countBeforeExtension, 2,
            "J5: flat increaseUnlockTime must notify TWICE (bracketed)");
        assertEq(counterX.weightAtNotification(id, countBeforeExtension), weightBeforeExtension,
            "J5: notify-BEFORE must observe w- (the pre-step flat level)");
        assertEq(counterX.weightAtNotification(id, countBeforeExtension + 1), weightAfterExtension,
            "J5: notify-AFTER must observe w+ (the raised flat level)");
        assertEq(
            counterX.timeOfNotification(id, countBeforeExtension),
            counterX.timeOfNotification(id, countBeforeExtension + 1),
            "J5: both calls in the same block"
        );

        // --- increaseAmount on a FLAT position -----------------------------
        uint256 weightBeforeTopUp = X.ve.balanceOfNFT(id);
        uint256 countBeforeTopUp = counterX.notificationCountFor(id);
        X.hemi.mint(bob, AMT);
        vm.startPrank(bob);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(id, AMT);
        vm.stopPrank();
        uint256 weightAfterTopUp = X.ve.balanceOfNFT(id);

        emit log_named_uint("J5 flat increaseAmount step (wei)", weightAfterTopUp - weightBeforeTopUp);
        assertGt(weightAfterTopUp, weightBeforeTopUp, "J5: flat increaseAmount really does step the weight UP");
        assertEq(weightAfterTopUp - weightBeforeTopUp, 35_416_666_666_665_604_620,
            "J5: the flat increaseAmount step, to the wei");
        assertEq(counterX.notificationCountFor(id) - countBeforeTopUp, 2,
            "J5: flat increaseAmount must notify TWICE (bracketed)");
        assertEq(counterX.weightAtNotification(id, countBeforeTopUp), weightBeforeTopUp,
            "J5: notify-BEFORE must observe w- (the pre-step flat level)");
        assertEq(counterX.weightAtNotification(id, countBeforeTopUp + 1), weightAfterTopUp,
            "J5: notify-AFTER must observe w+ (the raised flat level)");
        assertEq(
            counterX.timeOfNotification(id, countBeforeTopUp),
            counterX.timeOfNotification(id, countBeforeTopUp + 1),
            "J5: both calls in the same block"
        );
    }

    // ==================================================================== J6
    // THE WEI-EXACT INTEGRAL. J5 counts; this one costs.
    //
    // A PURE FLAT WINDOW with two steps inside it. The weight is piecewise
    // CONSTANT, so the truth is a sum of rectangles and every level is read
    // back out of the contract.
    //
    // With only a head notification, the trapezoid integrator would
    // interpolate `(L1+L2)/2` across the whole next segment instead of `L2`;
    // the error `(L2-L1)/2 * dt` is unbounded because a flat position sends no
    // other transaction (F2: zero notifications over a flat life).
    // ==================================================================== */
    function test_J6_flat_step_integral_is_wei_exact() public {
        setUpTwinOracle();
        _deployDistributors();
        _useIntegrator();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        vm.prank(bob);
        X.ve.enableAutoRelock(id);

        // Open the measurement window with a REAL, contract-issued
        // notification. 1 wei adds 0 to the slope, so it moves no level.
        vm.warp(t0 + SIX_DAYS);
        vm.roll(block.number + 100);
        _topUpOneWei(X, bob, id);
        uint256 accruedBefore = integratorX.accrued(id);
        uint256 windowStart = block.timestamp;
        uint256 L1 = X.ve.balanceOfNFT(id);

        // step 1: raise R
        vm.warp(windowStart + 3 * SIX_DAYS + 3600);
        vm.roll(block.number + 500);
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 3) * SIX_DAYS);
        uint256 extendedAt = block.timestamp;
        uint256 L2 = X.ve.balanceOfNFT(id);

        // step 2: raise the slope
        vm.warp(extendedAt + 2 * SIX_DAYS + 777);
        vm.roll(block.number + 500);
        X.hemi.mint(bob, AMT);
        vm.startPrank(bob);
        X.hemi.approve(address(X.ve), type(uint256).max);
        X.ve.increaseAmount(id, AMT);
        vm.stopPrank();
        uint256 toppedUpAt = block.timestamp;
        uint256 L3 = X.ve.balanceOfNFT(id);

        // close the window
        vm.warp(toppedUpAt + 4 * SIX_DAYS);
        vm.roll(block.number + 500);
        _topUpOneWei(X, bob, id);
        uint256 windowEnd = block.timestamp;

        assertGt(L2, L1, "J6: step 1 must raise the flat level");
        assertGt(L3, L2, "J6: step 2 must raise the flat level");
        assertEq(X.ve.balanceOfNFT(id), L3, "J6: the window's last segment is flat at L3");

        uint256 truth =
            L1 * (extendedAt - windowStart) + L2 * (toppedUpAt - extendedAt) + L3 * (windowEnd - toppedUpAt);
        uint256 accrued = integratorX.accrued(id) - accruedBefore;
        emit log_named_uint("J6 flat level L1     ", L1);
        emit log_named_uint("J6 flat level L2     ", L2);
        emit log_named_uint("J6 flat level L3     ", L3);
        emit log_named_uint("J6 accrued  (wei-s)  ", accrued);
        emit log_named_uint("J6 TRUTH    (wei-s)  ", truth);
        emit log_named_int("J6 error bps          ", _deviationBpsOrZero(accrued, truth));
        emit log_named_uint("J6 hook calls since deployment", integratorX.calls());
        assertEq(accrued, truth, "J6: flat-step accrual == the true integral, to the wei");
    }

    // ==================================================================== J7
    // THE EVENT-LOG WITNESS for the flat deposit paths.
    //
    // Reaches the same call COUNT through an observable that does not go
    // through a mock's storage, and proves the notify-AFTER site in
    // `_depositFor` keeps the swallow: an external call placed AFTER all state
    // is settled must not be able to roll back a completed deposit.
    // ==================================================================== */
    function test_J7_broken_distributor_cannot_block_flat_increase_paths() public {
        setUpTwinOracle();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;
        vm.prank(bob);
        X.ve.enableAutoRelock(id);
        X.ve.updateRewardDistributor(IRewardDistributor(address(new RevertingRewardDistributor())));

        vm.warp(t0 + SIX_DAYS + 3600);
        vm.roll(block.number + 400);
        uint256 remainingBefore = uint256(X.ve.autoRelockRemaining(id));
        uint256 weightBeforeExtension = X.ve.balanceOfNFT(id);

        vm.recordLogs();
        vm.prank(bob);
        X.ve.increaseUnlockTime(id, (N + 3) * SIX_DAYS); // must NOT revert
        assertEq(_countRewardUpdateFailed(id), 2, "J7: flat increaseUnlockTime emits RewardUpdateFailed twice");
        assertGt(uint256(X.ve.autoRelockRemaining(id)), remainingBefore,
            "J7: the extension survived a reverting distributor");
        assertGt(X.ve.balanceOfNFT(id), weightBeforeExtension, "J7: and the weight really moved");

        uint256 weightBeforeTopUp = X.ve.balanceOfNFT(id);
        X.hemi.mint(bob, AMT);
        vm.prank(bob);
        X.hemi.approve(address(X.ve), type(uint256).max);
        vm.recordLogs();
        vm.prank(bob);
        X.ve.increaseAmount(id, AMT); // must NOT revert
        assertEq(_countRewardUpdateFailed(id), 2, "J7: flat increaseAmount emits RewardUpdateFailed twice");
        assertGt(X.ve.balanceOfNFT(id), weightBeforeTopUp, "J7: the top-up survived a reverting distributor");
        assertTrue(X.ve.isAutoRelockEnabled(id), "J7: the position is still flat");
    }

    // ==================================================================== J8
    // SAFETY: each notify-AFTER site is an external call made AFTER state is
    // settled. Prove a hostile distributor cannot re-enter, cannot block, and
    // cannot corrupt.
    // ==================================================================== */
    function test_J8_hostile_distributor_cannot_reenter_or_block() public {
        setUpTwinOracle();
        uint256 positionIndex = spawn(true, bob, AMT, N, Cadence.NEVER, false, false);
        uint256 id = positions[positionIndex].tokenId;

        ReentrantDistributor hostileDistributor = new ReentrantDistributor(address(X.ve));
        X.ve.updateRewardDistributor(IRewardDistributor(address(hostileDistributor)));
        hostileDistributor.setReentry(abi.encodeWithSignature("disableAutoRelock(uint256)", id));

        vm.prank(bob);
        X.ve.enableAutoRelock(id); // must NOT revert
        uint256 reached = hostileDistributor.attempts();
        assertTrue(X.ve.isAutoRelockEnabled(id), "J8: enable survived the hostile hook");
        assertEq(reached, 1, "J8: the hostile hook was actually reached from enable");
        assertFalse(hostileDistributor.lastInnerOk(), "J8: re-entry into VeHemi was refused");
        uint256 weightUnderHostileHook = X.ve.balanceOfNFT(id);

        // Same position shape, benign distributor: identical state.
        X.ve.updateRewardDistributor(IRewardDistributor(address(0)));
        uint256 otherPositionIndex = spawn(true, alice, AMT, N, Cadence.NEVER, false, false);
        uint256 id2 = positions[otherPositionIndex].tokenId;
        vm.prank(alice);
        X.ve.enableAutoRelock(id2);
        assertEq(weightUnderHostileHook, X.ve.balanceOfNFT(id2), "J8: hostile hook did not perturb the weight");
        emit log_named_uint("J8 reentry attempts from enable", reached);
    }
}

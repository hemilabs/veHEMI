// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../../src/adapter/VeHemiAragonAdapter.sol";

/// @title  The removal gas floor, and retirement behind a broken module.
///
/// @notice Every call that books or retires an auto-relock flat term checks
///         `REMOVAL_GAS_FLOOR` before it calls the delegation module
///         (`VeHemi.sol::_reDelegate`). Behind a delegatecall proxy -- how the
///         live module is deployed -- a module that runs out of gas hands
///         VeHemi back about 1/32 of the frame, above the starvation tripwire,
///         so without the floor a caller-chosen (or an unpadded estimated) gas
///         limit could commit the outer call with the re-booking swallowed: a
///         flat term that never expires, or an armed position whose votes are
///         not counted.
///
///         Each sweep below finds the smallest gas limit g* at which the call
///         commits, then checks around it that:
///           * below g* the call reverts with `DelegationCallStarved` (it never
///             commits with the re-booking swallowed);
///           * at and above g* it commits EXACTLY: the delegatee's votes equal
///             the positions' weight and a retired term is no longer flat;
///           * g* is above the floor, the behaviour is monotone in the gas
///             limit, and an `eth_estimateGas`-style search (geth's algorithm:
///             one run at the cap, the optimistic probe, then bisection to a
///             1.5% error) returns a limit at which the call commits exactly.
///         Each runs against the module called directly and behind an ERC1967
///         proxy, with the delegatee's checkpoints fresh or dormant.
contract RemovalGasFloorTest is AutoRelockTestBase {
    uint256 internal constant REMOVAL_GAS_FLOOR = 8_176_984; // VeHemi's private constant: 8M + 8M/63 + 50k
    uint256 internal constant GAS_LIMIT_CAP = 29_000_000;    // below Hemi's 30M block gas limit

    enum Op { Disable, Retire, Enable, IncreaseAmountArmed, IncreaseUnlockTimeArmed, CreateArmed }

    struct Case {
        address caller;
        bytes data;
        uint256 id;           // 0 for CreateArmed (the id is read after the call)
        address delegatee;
        uint256[] others;     // other positions delegated to `delegatee`
    }

    function _useProxiedVVD() internal {
        VeHemiVoteDelegation impl = new VeHemiVoteDelegation(address(veHemi));
        ERC1967Proxy p = new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize()"));
        delegation = VeHemiVoteDelegation(address(p));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(p)));
    }

    function _flatDelegated(address who_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, 1_000 ether, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, delegateeA);
        vm.warp(block.timestamp + 7200);
    }

    /// @dev Keep the GLOBAL curve fresh while the delegatee's checkpoints age:
    ///      `checkpoint()` writes VeHemi only, never the delegation module.
    function _ageDelegatee(uint256 buckets_) internal {
        for (uint256 b = 0; b < buckets_; ++b) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();
        }
    }

    function _prepare(Op op_, uint256 dormancy_, uint256 coDelegators_) internal returns (Case memory c) {
        c.delegatee = delegateeA;
        c.others = new uint256[](coDelegators_);
        for (uint256 k = 0; k < coDelegators_; ++k) {
            (uint256 otherId, , ) = createLock(stranger, 20 ether, (20 + k * 10) * SIX_DAYS);
            delegateTo(stranger, otherId, delegateeA);
            c.others[k] = otherId;
        }
        if (op_ == Op.CreateArmed) {
            c.caller = attacker;
            c.delegatee = attacker; // a new position delegates to its owner by default
            c.data = abi.encodeCall(veHemi.createLockWithAutoRelock, (1_000 ether, 4 * 365 days, true, false));
            _ageDelegatee(dormancy_);
            return c;
        }
        if (op_ == Op.Enable) {
            (c.id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
            delegateTo(attacker, c.id, delegateeA);
            vm.warp(block.timestamp + 7200);
            _ageDelegatee(dormancy_);
            c.caller = attacker;
            c.data = abi.encodeCall(veHemi.enableAutoRelock, (c.id));
            return c;
        }
        if (op_ == Op.Retire) {
            c.id = _flatDelegated(victim);
            vm.warp(veHemi.autoRelockStaleAt(c.id) - 1);
            veHemi.checkpoint();
            vm.warp(veHemi.autoRelockStaleAt(c.id));
            c.caller = stranger;
            c.data = abi.encodeCall(veHemi.retireStaleAutoRelock, (c.id));
            return c;
        }
        if (op_ == Op.IncreaseUnlockTimeArmed) {
            (c.id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
            enable(attacker, c.id);
            delegateTo(attacker, c.id, delegateeA);
            vm.warp(block.timestamp + 7200);
            _ageDelegatee(dormancy_);
            c.caller = attacker;
            c.data = abi.encodeCall(veHemi.increaseUnlockTime, (c.id, 4 * 365 days));
            return c;
        }
        c.id = _flatDelegated(attacker);
        _ageDelegatee(dormancy_);
        c.caller = attacker;
        c.data = op_ == Op.Disable
            ? abi.encodeCall(veHemi.disableAutoRelock, (c.id))
            : abi.encodeCall(veHemi.increaseAmount, (c.id, 1 ether));
    }

    function _call(Case memory c_, uint256 g_) internal returns (bool ok, bytes memory ret) {
        vm.prank(c_.caller);
        (ok, ret) = address(veHemi).call{gas: g_}(c_.data);
    }

    function _commitsAt(Case memory c_, uint256 g_, uint256 snap_) internal returns (bool ok) {
        (ok, ) = _call(c_, g_);
        vm.revertToState(snap_);
    }

    /// @dev The committed state is exact: the delegatee's booked votes equal the
    ///      weight of every position delegated to it, and the position's record
    ///      has the shape its flag says (flat iff armed).
    function _assertExact(Op op_, Case memory c_, string memory what_) internal {
        uint256 id = op_ == Op.CreateArmed ? veHemi.nextTokenId() - 1 : c_.id;
        bool armed = veHemi.isAutoRelockEnabled(id);
        assertEq(armed, op_ != Op.Disable && op_ != Op.Retire, string.concat(what_, ": wrong flag"));
        IVeHemiVoteDelegation.Delegation memory record = delegation.delegation(id);
        bool flat = record.slope == 0 && record.bias > 0;
        assertEq(flat, armed, string.concat(what_, ": record shape disagrees with the flag (phantom or vote hole)"));
        vm.warp(block.timestamp + 2);
        uint256 delegatedWeight = veHemi.balanceOfNFT(id);
        for (uint256 k = 0; k < c_.others.length; ++k) delegatedWeight += veHemi.balanceOfNFT(c_.others[k]);
        assertEq(delegation.getVotes(c_.delegatee), delegatedWeight,
            string.concat(what_, ": delegatee votes != positions' weight"));
    }

    /// @dev geth/op-geth `eth/gasestimator`: run at the cap; lo = used - 1; probe
    ///      (used + 2300) * 64/63; bisect while (hi - lo) / hi >= 1.5%; return hi.
    ///      `used` here is measured inside the EVM, so it is the gas before the
    ///      refund: lo sits about the refund above geth's and this search is at
    ///      least as generous as geth's; on these floored paths the floor revert
    ///      drives the bisection, so the difference does not matter.
    function _estimate(Case memory c_, uint256 snap_) internal returns (uint256 hi) {
        uint256 gasBefore = gasleft();
        (bool ok, ) = _call(c_, GAS_LIMIT_CAP);
        uint256 used = gasBefore - gasleft();
        vm.revertToState(snap_);
        assertTrue(ok, "estimator: the call fails at the cap");
        uint256 lo = used - 1;
        hi = GAS_LIMIT_CAP;
        uint256 optimisticLimit = ((used + 2_300) * 64) / 63;
        if (optimisticLimit < hi) {
            if (_commitsAt(c_, optimisticLimit, snap_)) hi = optimisticLimit;
            else lo = optimisticLimit;
        }
        while (lo + 1 < hi) {
            if ((hi - lo) * 1_000 < hi * 15) break;
            uint256 mid = (hi + lo) / 2;
            if (mid > lo * 2) mid = lo * 2;
            if (_commitsAt(c_, mid, snap_)) hi = mid;
            else lo = mid;
        }
    }

    function _sweep(Op op_, bool proxied_, uint256 dormancy_, uint256 coDelegators_, string memory what_) internal {
        if (proxied_) _useProxiedVVD();
        Case memory c = _prepare(op_, dormancy_, coDelegators_);
        uint256 snap = vm.snapshotState();

        // g*: the smallest gas limit at which the call commits.
        uint256 lo = 100_000;
        uint256 hi = GAS_LIMIT_CAP;
        assertTrue(_commitsAt(c, hi, snap), string.concat(what_, ": does not commit at the cap"));
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_commitsAt(c, mid, snap)) hi = mid;
            else lo = mid;
        }
        uint256 gStar = hi;
        emit log_named_uint(string.concat(what_, ": smallest committing gas limit"), gStar);
        assertGt(gStar, REMOVAL_GAS_FLOOR, string.concat(what_, ": committed below the removal gas floor"));

        uint256 committed;
        uint256 refused;
        for (uint256 g = gStar - 50_000; g <= gStar + 250_000; g += 5_000) {
            (bool ok, bytes memory ret) = _call(c, g);
            assertEq(ok, g >= gStar, string.concat(what_, ": not monotone in the gas limit"));
            if (ok) {
                ++committed;
                _assertExact(op_, c, what_);
            } else {
                ++refused;
                assertEq(bytes4(ret), VeHemi.DelegationCallStarved.selector,
                    string.concat(what_, ": refused below g* for another reason"));
            }
            vm.revertToState(snap);
        }
        assertGt(committed, 0, string.concat(what_, ": vacuous, never committed"));
        assertGt(refused, 0, string.concat(what_, ": vacuous, never refused"));

        uint256[3] memory generousLimits = [
            gStar + 1_000_000, gStar + 5_000_000 < GAS_LIMIT_CAP ? gStar + 5_000_000 : GAS_LIMIT_CAP, GAS_LIMIT_CAP
        ];
        for (uint256 i = 0; i < generousLimits.length; ++i) {
            (bool ok, ) = _call(c, generousLimits[i]);
            assertTrue(ok, string.concat(what_, ": refused at a generous limit"));
            _assertExact(op_, c, what_);
            vm.revertToState(snap);
        }

        uint256 estimatedLimit = _estimate(c, snap);
        emit log_named_uint(string.concat(what_, ": emulated eth_estimateGas"), estimatedLimit);
        (bool estimatedOk, ) = _call(c, estimatedLimit);
        assertTrue(estimatedOk, string.concat(what_, ": refused at the estimated limit"));
        _assertExact(op_, c, string.concat(what_, " at the estimated limit"));
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------
    // Retiring a flat term: disableAutoRelock (owner) and the permissionless
    // retireStaleAutoRelock. A stale position's delegatee is dormant for at
    // least STALE_FLAT_BUCKETS buckets by construction (a heartbeat never
    // writes the delegation module).
    // ------------------------------------------------------------------
    function test_floor_disable_direct() public { _sweep(Op.Disable, false, 0, 0, "disable/direct"); }
    function test_floor_disable_proxied() public { _sweep(Op.Disable, true, 0, 0, "disable/proxied"); }
    function test_floor_disable_proxied_dormant30() public { _sweep(Op.Disable, true, 30, 0, "disable/proxied/dormant30"); }
    function test_floor_disable_proxied_dormant200_coDelegators() public {
        _sweep(Op.Disable, true, 200, 6, "disable/proxied/dormant200+6");
    }
    function test_floor_retireStale_direct() public { _sweep(Op.Retire, false, 0, 0, "retire/direct"); }
    function test_floor_retireStale_proxied() public { _sweep(Op.Retire, true, 0, 0, "retire/proxied"); }

    // ------------------------------------------------------------------
    // Booking a flat term: enableAutoRelock, the arm leg of
    // createLockWithAutoRelock, and increases on an armed position.
    // ------------------------------------------------------------------
    function test_floor_enable_direct() public { _sweep(Op.Enable, false, 0, 0, "enable/direct"); }
    function test_floor_enable_proxied() public { _sweep(Op.Enable, true, 0, 0, "enable/proxied"); }
    function test_floor_enable_proxied_dormant30() public { _sweep(Op.Enable, true, 30, 0, "enable/proxied/dormant30"); }
    function test_floor_createLockWithAutoRelock_proxied() public {
        _sweep(Op.CreateArmed, true, 0, 0, "createLockWithAutoRelock/proxied");
    }
    function test_floor_increaseAmountArmed_proxied_dormant30() public {
        _sweep(Op.IncreaseAmountArmed, true, 30, 0, "increaseAmount(armed)/proxied/dormant30");
    }
    function test_floor_increaseUnlockTimeArmed_proxied_dormant30() public {
        _sweep(Op.IncreaseUnlockTimeArmed, true, 30, 0, "increaseUnlockTime(armed)/proxied/dormant30");
    }

    /// @notice With the Aragon adapter wired (its `notifyDelegateChanged` walks
    ///         the owner's positions at the end of every delegation write), a
    ///         disable by an owner of three positions behaves the same.
    function test_floor_disable_proxied_withAdapter_threePositions() public {
        _useProxiedVVD();
        delegation.setTrustedAdapter(address(new VeHemiAragonAdapter(address(veHemi))));
        createLock(attacker, 50 ether, 2 * 365 days);
        createLock(attacker, 50 ether, 3 * 365 days);
        _sweep(Op.Disable, false, 0, 0, "disable/proxied/adapter/3 positions");
    }

    /// @notice CONTROL: an UNARMED re-booking keeps the replaced
    ///         implementation's behaviour -- it is not subject to the floor.
    function test_floor_unarmedIncreaseAmount_isNotFloored() public {
        _useProxiedVVD();
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 4 * 365 days);
        delegateTo(attacker, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        vm.prank(attacker);
        (bool ok, ) = address(veHemi).call{gas: 2_000_000}(abi.encodeCall(veHemi.increaseAmount, (id, 1 ether)));
        assertTrue(ok, "an unarmed increaseAmount must not need the removal gas floor");
        vm.warp(block.timestamp + 2);
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id), "unarmed re-booking mis-booked");
    }

    // ------------------------------------------------------------------
    // Liveness: the honest paths still work at the default gas budget.
    // ------------------------------------------------------------------
    function test_honestPathsUnaffected() public {
        uint256 id = _flatDelegated(attacker);
        disable(attacker, id);
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id), "disable mis-booked");
        assertEq(veHemi.autoRelockRemaining(id), 0, "flag survived disable");

        uint256 id2 = _flatDelegated(victim);
        vm.warp(veHemi.autoRelockStaleAt(id2));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id2);
        assertEq(veHemi.autoRelockRemaining(id2), 0, "flag survived retire");

        vm.startPrank(attacker);
        uint256 createdId = veHemi.createLock(500 ether, 4 * 365 days);
        vm.stopPrank();
        assertGt(veHemi.balanceOfNFT(createdId), 0, "createLock broke");
    }

    // ------------------------------------------------------------------
    // Vacuity control: `_flatDelegated` really books a flat term at `delegateeA`.
    // ------------------------------------------------------------------
    function test_vacuity_theFlatTermIsReallyBooked() public {
        uint256 id = _flatDelegated(attacker);
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        uint256 flatVotes = delegation.getVotes(delegateeA);
        assertGt(flatVotes, 900 ether, "premise: no flat term booked at the delegatee");
        // and it is FLAT: 200 buckets later it has not moved at all.
        vm.warp(block.timestamp + 200 * SIX_DAYS);
        veHemi.checkpoint();
        assertEq(delegation.getVotes(delegateeA), flatVotes, "premise: the term is not flat");
    }

    // ------------------------------------------------------------------
    // A module that accepts `delegate` and does nothing cannot make a
    // retirement commit silently: the read-back announces it with
    // AutoRelockRetirementUnverified, and the exit stays open.
    // ------------------------------------------------------------------
    function test_lyingModuleRetirementCommitsAndIsAnnounced() public {
        uint256 id = _flatDelegated(attacker);
        uint256 flatVotes = delegation.getVotes(delegateeA);
        assertGt(flatVotes, 0, "premise: no flat term booked");
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        vm.recordLogs();
        vm.prank(attacker);
        (bool ok, ) = address(veHemi).call(abi.encodeWithSignature("disableAutoRelock(uint256)", id));
        assertTrue(ok, "the exit must not be closed by a module the contract cannot trust");
        assertEq(veHemi.autoRelockRemaining(id), 0, "the flag survived a committed retirement");
        // VACUITY: the lie really did leave the flat term standing.
        assertEq(delegation.getVotes(delegateeA), flatVotes, "premise: the lying module did not actually lie");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool announced;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("AutoRelockRetirementUnverified(uint256)")) announced = true;
        }
        assertTrue(announced, "a LYING module committed a retirement SILENTLY");
    }

    // ------------------------------------------------------------------
    // Remediation: with no owner action the principal still comes home;
    // replacing the lying module before withdraw retires the term for real.
    // ------------------------------------------------------------------
    function test_lyingModule_principalReturnsWithoutOwner_andReplacementBeforeWithdrawRetiresTheFlatTerm() public {
        IVeHemiVoteDelegation realDelegation = IVeHemiVoteDelegation(address(delegation));

        // (a) NO OWNER ACTION.
        uint256 idA = _flatDelegated(attacker);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        disable(attacker, idA);
        assertEq(veHemi.autoRelockRemaining(idA), 0, "the exit is still closed");
        vm.warp(veHemi.getLockedBalance(idA).end + 1);
        uint256 beforeA = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(idA);
        assertEq(hemi.balanceOf(attacker) - beforeA, 1_000 ether,
            "principal trapped behind a lying module with no owner-independent exit");

        // (b) THE MODULE IS REPLACED BEFORE WITHDRAW. `delegateeB`, not `delegateeA`,
        //     because leg (a) deliberately left a permanent phantom on `delegateeA`.
        veHemi.updateVoteDelegation(realDelegation);
        (uint256 idB, , ) = createLock(victim, 1_000 ether, 4 * 365 days);
        enable(victim, idB);
        delegateTo(victim, idB, delegateeB);
        vm.warp(block.timestamp + 7200);
        uint256 flatVotes = delegation.getVotes(delegateeB);
        assertGt(flatVotes, 0, "premise: nothing booked at delegateeB");
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        disable(victim, idB);
        assertEq(delegation.getVotes(delegateeB), flatVotes, "premise: the lie did not strand the term");
        veHemi.updateVoteDelegation(realDelegation);
        vm.warp(veHemi.getLockedBalance(idB).end + 1);
        uint256 beforeB = hemi.balanceOf(victim);
        vm.prank(victim);
        veHemi.withdraw(idB);
        assertEq(hemi.balanceOf(victim) - beforeB, 1_000 ether, "recovery: principal not returned");
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        assertEq(delegation.getVotes(delegateeB), 0,
            "recovery: repairing the module before withdraw did NOT retire the flat term");
    }

    // ------------------------------------------------------------------
    // The announcement lands more than a whole SIX_DAYS bucket before the
    // earliest withdraw (`autoRelockRemaining` >= 2 * SIX_DAYS), swept across
    // the bucket phase.
    // ------------------------------------------------------------------
    function test_unverifiedCommitPrecedesWithdrawByAWholeBucket() public {
        uint256 worst = type(uint256).max;
        for (uint256 phase = 0; phase < SIX_DAYS; phase += SIX_DAYS / 24) {
            uint256 snap = vm.snapshotState();
            // duration 3 buckets, enabled one bucket in, so `autoRelockRemaining`
            // lands on its MINIMUM legal value of 2 * SIX_DAYS at every phase --
            // the worst case for the gap this body bounds.
            (uint256 id, , ) = createLock(attacker, 1_000 ether, 3 * SIX_DAYS);
            warpToPhase(phase);
            enable(attacker, id);
            delegateTo(attacker, id, delegateeA);
            veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
            disable(attacker, id);
            uint256 gap = uint256(veHemi.getLockedBalance(id).end) - block.timestamp;
            if (gap < worst) worst = gap;
            vm.revertToState(snap);
        }
        emit log_named_uint("  worst-case announce->withdraw gap (s)", worst);
        assertGt(worst, SIX_DAYS, "the remediation window is NOT a whole bucket");
    }
}

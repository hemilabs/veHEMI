// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "./SlopeOverflowLiar.sol";

/// @title  The strict re-raise of `DelegationSlopeOverflow()`.
///
/// @notice When the delegation module refuses the retirement leg with
///         `DelegationSlopeOverflow()` (`0xf2b4513c`), the HOLDER's
///         `disableAutoRelock` re-raises it instead of committing with the flat
///         term still standing (law A). The PERMISSIONLESS
///         `retireStaleAutoRelock` keeps the swallow, so the flag always clears
///         within one abandonment horizon without the owner (law B).
///
///           P  the premises: the selector literal; `withdraw` is flag-gated;
///              the abandonment horizon; the permissionless leg is permissionless.
///           R  law A under the REAL module, saturated at the `uint64`
///              aggregate-slope ceiling; the holder still recovers at once.
///           T  an adversarial module that answers `0xf2b4513c` to every write:
///              the principal still comes home without the owner, and one
///              owner transaction (a module swap) also untraps it.
contract SlopeOverflowReRaiseTest is AutoRelockTestBase {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant CALL_GAS_LIMIT = 30_000_000;

    bytes32 internal constant TOPIC_DELEGATION_UPDATE_FAILED = keccak256("DelegationUpdateFailed(uint256)");

    bytes4 internal constant SEL_SLOPE_OVERFLOW = bytes4(keccak256("DelegationSlopeOverflow()"));

    address internal delegateeC = address(0xDE1E63);

    // ------------------------------------------------------------------ rig --

    function _call(address who_, bytes memory data_) internal returns (bool ok, bytes memory ret) {
        vm.prank(who_);
        (ok, ret) = address(veHemi).call{gas: CALL_GAS_LIMIT}(data_);
    }

    function _disable(address who_, uint256 id_) internal returns (bool ok, bytes memory ret) {
        return _call(who_, abi.encodeWithSignature("disableAutoRelock(uint256)", id_));
    }

    function _retireStale(address who_, uint256 id_) internal returns (bool ok, bytes memory ret) {
        return _call(who_, abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id_));
    }

    function _hasTopic(Vm.Log[] memory logs_, bytes32 topic_) internal pure returns (bool) {
        for (uint256 i; i < logs_.length; ++i) if (logs_[i].topics[0] == topic_) return true;
        return false;
    }

    function _flatDelegated(address who_, address to_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, to_);
        vm.warp(block.timestamp + 7200);
    }

    /// @dev THE REAL MODULE, refusing a CORRECT call. No mock: park `delegateeA` one
    ///      victim-slope below the `uint64` aggregate ceiling with an ORDINARY
    ///      decaying delegation, then hand back the victim's FLAT position.
    function _saturate(uint256 headroom_) internal returns (uint256 victimId) {
        uint256 slopeCeiling = uint256(type(uint64).max);
        (uint256 whaleId, , ) = createLock(stranger, (slopeCeiling - headroom_) * MAX_TIME, 3 * 365 days);
        delegateTo(stranger, whaleId, delegateeA);
        victimId = _flatDelegated(victim, delegateeA);
        // PROVE the ceiling is actually reached, from OUTSIDE VeHemi's catch.
        (uint256 saturationCheckId, , ) = createLock(stranger, PRINCIPAL, 4 * 365 days);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", saturationCheckId, delegateeA)
        );
        require(!ok && bytes4(ret) == SEL_SLOPE_OVERFLOW, "saturation premise GONE");
    }

    /// @dev The ADVERSARIAL shape: a module that answers `0xf2b4513c` to the
    ///      retirement leg (`SlopeOverflowLiar`).
    function _installLiar(uint256 id_) internal returns (SlopeOverflowLiar module) {
        module = new SlopeOverflowLiar();
        module.seed(id_, delegateeA, uint96(PRINCIPAL / 2), uint64(PRINCIPAL / MAX_TIME));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(module)));
        // NON-VACUITY: the module really does raise THE selector.
        (bool ok, bytes memory ret) = address(module).call(
            abi.encodeWithSignature("delegate(uint256,address)", id_, delegateeA)
        );
        require(!ok && bytes4(ret) == SEL_SLOPE_OVERFLOW, "liar does not raise the selector");
    }

    /// @dev EVERY OWNER-INDEPENDENT ROUTE, IN ORDER, WITH THE ROUTE REPORTED.
    ///      0 = none. 1 = plain disable. 2 = escape hatch then disable.
    ///      3 = permissionless `retireStaleAutoRelock` after the abandonment horizon.
    function _clearFlagWithoutOwner(uint256 id_, address holder_) internal returns (uint256 route) {
        if (veHemi.autoRelockRemaining(id_) == 0) return 1;
        (bool disabled, ) = _disable(holder_, id_);
        if (disabled && veHemi.autoRelockRemaining(id_) == 0) return 1;

        // THE ESCAPE HATCH: `vvd.delegate` is `onlyAuthorized`, so the HOLDER
        // can move the FLAT term to an unsaturated delegatee with no owner.
        // IT MUST TARGET THE MODULE `VeHemi` IS ACTUALLY POINTING AT -- calling
        // the ORIGINAL proxy after a pointer swap writes a record `VeHemi` will
        // never read, which would make this route look available when it is
        // not.
        address liveModule = address(veHemi.voteDelegation());
        vm.prank(holder_);
        (bool moved, ) = liveModule.call(
            abi.encodeWithSignature("delegate(uint256,address)", id_, delegateeC)
        );
        emit log_named_uint("  route2: escape-hatch move ok", moved ? 1 : 0);
        if (moved) {
            (bool disabledAfterMove, ) = _disable(holder_, id_);
            if (disabledAfterMove && veHemi.autoRelockRemaining(id_) == 0) return 2;
        }

        // THE PERMISSIONLESS REMEDY. Anyone may call it once the position is
        // stale: `autoRelockRefreshedAt + STALE_FLAT_BUCKETS * SIX_DAYS`.
        uint256 staleAt = veHemi.autoRelockStaleAt(id_);
        emit log_named_uint("  route3: seconds until stale", staleAt > block.timestamp ? staleAt - block.timestamp : 0);
        if (block.timestamp < staleAt) vm.warp(staleAt);
        (bool retired, ) = _retireStale(stranger, id_);
        emit log_named_uint("  route3: retireStaleAutoRelock ok", retired ? 1 : 0);
        if (retired && veHemi.autoRelockRemaining(id_) == 0) return 3;
        return 0;
    }

    function _withdrawAll(uint256 id_, address holder_) internal returns (uint256) {
        uint256 withdrawAt = uint256(veHemi.getLockedBalance(id_).end) + 1;
        if (block.timestamp < withdrawAt) vm.warp(withdrawAt);
        uint256 before = hemi.balanceOf(holder_);
        (bool ok, ) = _call(holder_, abi.encodeWithSignature("withdraw(uint256)", id_));
        emit log_named_uint("  withdraw ok", ok ? 1 : 0);
        return hemi.balanceOf(holder_) - before;
    }

    // =====================================================================
    // P — THE PREMISES.
    // =====================================================================

    /// @notice The selector literal `VeHemi` hard-codes, recomputed here.
    function test_P1_slopeOverflowSelectorMatchesTheLiteral() public pure {
        assertEq(SEL_SLOPE_OVERFLOW, bytes4(0xf2b4513c), "P1: selector literal is stale");
    }

    /// @notice The three facts the trap and its cure rest on, read from the
    ///         contract's own state.
    function test_P2_withdrawIsFlagGatedAndAStrangerRetiresAtTheStaleDeadline() public {
        uint256 id = _flatDelegated(victim, delegateeA);

        // (1) `withdraw` is FLAG-GATED.
        uint256 withdrawAt = uint256(veHemi.getLockedBalance(id).end) + 1;
        vm.warp(withdrawAt);
        assertGt(veHemi.autoRelockRemaining(id), 0, "P2: flag not set");
        (bool withdrew, ) = _call(victim, abi.encodeWithSignature("withdraw(uint256)", id));
        assertFalse(withdrew, "P2: withdraw is NOT flag-gated -- the trap cannot exist");

        // (2) the abandonment horizon is `STALE_FLAT_BUCKETS * SIX_DAYS` from the last
        //     refresh.
        uint256 staleAt = veHemi.autoRelockStaleAt(id);
        assertEq(
            staleAt - uint256(veHemi.autoRelockRefreshedAt(id)),
            veHemi.STALE_FLAT_BUCKETS() * SIX_DAYS,
            "P2: abandonment horizon is not 60 buckets"
        );
        emit log_named_uint("P2 abandonment horizon (s)", staleAt - uint256(veHemi.autoRelockRefreshedAt(id)));

        // (3) the permissionless leg really is permissionless.
        vm.warp(staleAt);
        (bool retired, ) = _retireStale(stranger, id);
        assertTrue(retired, "P2: a STRANGER could not retire a stale position");
        assertEq(veHemi.autoRelockRemaining(id), 0, "P2: flag survived the retirement");
    }

    // =====================================================================
    // R — LAW (A): a COMMITTED holder retirement must not leave a flat term
    //     standing.
    // =====================================================================

    function test_R1_holderDisableNeverCommitsAStrandedFlatTerm() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        vm.recordLogs();
        (bool committed, ) = _disable(victim, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        IVeHemiVoteDelegation.Delegation memory record = delegation.delegation(id);
        bool flagCleared = veHemi.autoRelockRemaining(id) == 0;
        bool stillFlat = (record.slope == 0 && record.bias > 0);

        emit log_named_uint("R1 disable committed", committed ? 1 : 0);
        emit log_named_uint("R1 flag cleared", flagCleared ? 1 : 0);
        emit log_named_uint("R1 record still FLAT", stillFlat ? 1 : 0);
        emit log_named_uint("R1 record.bias", record.bias);
        emit log_named_uint("R1 swallowed", _hasTopic(logs, TOPIC_DELEGATION_UPDATE_FAILED) ? 1 : 0);
        assertFalse(flagCleared && stillFlat, "R1: COMMITTED with the flat term STILL STANDING");
    }

    /// @notice And the refusal carries the module's OWN selector.
    function test_R2_theRefusalCarriesTheSelector() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        (bool ok, bytes memory ret) = _disable(victim, id);
        emit log_named_uint("R2 disable ok", ok ? 1 : 0);
        assertFalse(ok, "R2: disable did not re-revert");
        assertEq(bytes4(ret), SEL_SLOPE_OVERFLOW, "R2: wrong revert data bubbled");
    }

    /// @notice Law (B) under the REAL module: the escape hatch (moving the flat
    ///         term to another delegatee) is ceiling-immune, so the holder
    ///         recovers with no owner action and NO waiting.
    function test_R3_realModule_holderRecoversWithNoOwnerAndNoWait() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        uint256 t0 = block.timestamp;
        uint256 route = _clearFlagWithoutOwner(id, victim);
        uint256 waited = block.timestamp - t0;
        emit log_named_uint("R3 route", route);
        emit log_named_uint("R3 seconds waited to clear the flag", waited);
        assertGt(route, 0, "R3: NO owner-independent route cleared the flag");
        assertLt(waited, 3600, "R3: the holder had to WAIT -- the escape hatch did not work");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "R3: principal did not come home");
    }

    // =====================================================================
    // T — THE ADVERSARIAL MODULE, AND WHAT UNTRAPS IT.
    // =====================================================================

    /// @notice A module that answers `0xf2b4513c` to the retirement leg. The
    ///         holder is refused, but the PERMISSIONLESS leg still swallows,
    ///         so the principal comes home with no owner action.
    function test_T1_adversarialSelector_ownerIndependentRecovery() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        _installLiar(id);
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        uint256 t0 = block.timestamp;
        uint256 route = _clearFlagWithoutOwner(id, victim);
        emit log_named_uint("T1 route", route);
        emit log_named_uint("T1 seconds waited", block.timestamp - t0);
        emit log_named_uint("T1 flag after", veHemi.autoRelockRemaining(id));
        uint256 recovered = route == 0 ? 0 : _withdrawAll(id, victim);
        emit log_named_uint("T1 recovered", recovered);
        assertEq(recovered, PRINCIPAL, "T1: PRINCIPAL TRAPPED -- no owner-independent route exists");
    }

    /// @notice ONE owner transaction — `updateVoteDelegation` to a module
    ///         that accepts the retirement leg (here `SilentFreezeModule`,
    ///         whose `delegate` is a no-op) — and the holder's own
    ///         `disableAutoRelock` + `withdraw` work again.
    function test_T2_oneOwnerTxUntrapsIt() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        _installLiar(id);
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        // the holder alone, FIRST.
        (bool disabledBefore, ) = _disable(victim, id);
        emit log_named_uint("T2 holder disable BEFORE the swap", disabledBefore ? 1 : 0);
        emit log_named_uint("T2 trapped before the swap", veHemi.autoRelockRemaining(id) != 0 ? 1 : 0);

        // ONE owner transaction. `SilentFreezeModule` is the MINIMUM shape: it
        // answers every read with the same flat-looking record (delegatee
        // 0xdead, bias 1, slope 0) and accepts every `delegate` as a silent
        // no-op. So `_reDelegate` sends the write (to 0xdead) and it RETURNS:
        // there is no refusal to re-raise, and the read-back of the still-flat
        // record only announces `AutoRelockRetirementUnverified` (it does not
        // revert). It HAS CODE, so `updateVoteDelegation` admits it.
        SilentFreezeModule replacement = new SilentFreezeModule();
        assertGt(
            address(replacement).code.length, 0, "T2: replacement is codeless (updateVoteDelegation would refuse it)"
        );
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(replacement)));

        if (veHemi.autoRelockRemaining(id) != 0) {
            (bool disabledAfter, ) = _disable(victim, id);
            emit log_named_uint("T2 holder disable AFTER the swap", disabledAfter ? 1 : 0);
            emit log_named_uint("T2 owner txs needed", 1);
            assertTrue(disabledAfter, "T2: the module swap did NOT restore disableAutoRelock");
        } else {
            emit log_named_uint("T2 owner txs needed", 0);
        }
        assertEq(veHemi.autoRelockRemaining(id), 0, "T2: flag survived the swap");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "T2: principal still trapped after the swap");
    }

    /// @notice Re-installing the OLD, REAL `VeHemiVoteDelegation` also works,
    ///         because the liar never touched its storage.
    function test_T3_reinstallingTheOriginalModuleAlsoUntrapsIt() public {
        address original = address(delegation);
        uint256 id = _flatDelegated(victim, delegateeA);
        _installLiar(id);
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        (bool disabledBefore, ) = _disable(victim, id);
        emit log_named_uint("T3 disable under the liar", disabledBefore ? 1 : 0);

        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(original));
        if (veHemi.autoRelockRemaining(id) != 0) {
            (bool disabledAfter, ) = _disable(victim, id);
            emit log_named_uint("T3 disable after re-install", disabledAfter ? 1 : 0);
            assertTrue(disabledAfter, "T3: re-installing the original module did not restore the path");
        }
        assertEq(veHemi.autoRelockRemaining(id), 0, "T3: flag survived the re-install");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "T3: principal not recovered");
    }

    /// @notice The permissionless leg still clears the flag under the
    ///         adversarial module (it swallows; only the holder's leg re-raises).
    function test_T4_permissionlessRetireClearsTheFlag() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        _installLiar(id);
        vm.warp(veHemi.autoRelockStaleAt(id));
        (bool retired, ) = _retireStale(stranger, id);
        emit log_named_uint("T4 retire ok", retired ? 1 : 0);
        emit log_named_uint("T4 flag after", veHemi.autoRelockRemaining(id));
        assertTrue(retired, "T4: the PERMISSIONLESS remedy is closed by the re-revert");
        assertEq(veHemi.autoRelockRemaining(id), 0, "T4: flag survived");
    }

    /// @notice BOUNDED-TIME LAW (B): under the adversarial module the flag
    ///         clears within `STALE_FLAT_BUCKETS * SIX_DAYS` of the last
    ///         refresh WITHOUT the owner.
    function test_T5_flagClearsWithoutTheOwnerAtTheStaleDeadline() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        _installLiar(id);
        uint256 deadline = veHemi.autoRelockStaleAt(id);
        vm.warp(deadline);
        (bool retired, ) = _retireStale(stranger, id);
        if (!retired) { (retired, ) = _disable(victim, id); }
        emit log_named_uint("T5 cleared by deadline", veHemi.autoRelockRemaining(id) == 0 ? 1 : 0);
        assertEq(
            veHemi.autoRelockRemaining(id),
            0,
            "T5: law (B) is NOT bounded in time -- the owner is the only cure"
        );
    }

    /// @notice THE ESCAPE HATCH HAS NO BAD TARGET. A flat delta carries
    ///         `slope: 0` and books no expiration bucket, so the move is
    ///         admitted even TO THE SATURATED DELEGATEE ITSELF. There is no
    ///         delegatee choice for which the holder's own cure fails.
    function test_T6_escapeHatchWorksEvenToTheSaturatedDelegatee() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        uint256 storedEnd = veHemi.getLockedBalance(id).end;
        vm.warp(storedEnd + 30 * SIX_DAYS);
        assertGt(block.timestamp, veHemi.getLockedBalance(id).end, "T6: end is not past");
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, delegateeA)
        );
        emit log_named_uint("T6 move to the SATURATED delegatee ok", ok ? 1 : 0);
        if (!ok && ret.length >= 4) emit log_named_bytes32("T6 revert", bytes32(bytes4(ret)));
        assertTrue(ok, "T6: the escape hatch is NOT ceiling-immune");
    }

    /// @notice `retireStaleAutoRelock` is permissionless but UNPAID, so nobody
    ///         is incentivised to call it. The HOLDER can, which makes law (B)
    ///         self-serviceable rather than dependent on a keeper.
    function test_T7_theHolderCanCallThePermissionlessLegThemselves() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        _installLiar(id);
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(victim);
        uint256 gasBefore = gasleft();
        (bool retired, ) = address(veHemi).call{gas: CALL_GAS_LIMIT}(
            abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id)
        );
        emit log_named_uint("T7 holder self-retire ok", retired ? 1 : 0);
        emit log_named_uint("T7 gas", gasBefore - gasleft());
        assertTrue(retired, "T7: the holder cannot self-serve the permissionless remedy");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "T7: principal not recovered");
    }
}

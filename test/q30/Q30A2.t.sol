// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "../q14/Q14Modules.sol";

/// @title  Q30A2 — the strict re-raise of `DelegationSlopeOverflow()`.
///
/// @notice When the delegation module refuses the retirement leg with
///         `DelegationSlopeOverflow()` (`0xf2b4513c`), the HOLDER's
///         `disableAutoRelock` re-raises it instead of committing with the flat
///         term still standing (law A). The PERMISSIONLESS
///         `retireStaleAutoRelock` keeps the swallow, so the flag always clears
///         within one stale window without the owner (law B).
///
///           V  the premises: the selector literal; `withdraw` is flag-gated;
///              the stale window; the permissionless leg is permissionless.
///           R  law A under the REAL module, saturated at the `uint64`
///              aggregate-slope ceiling; the holder still recovers at once.
///           T  an adversarial module that answers `0xf2b4513c` to every write:
///              the principal still comes home without the owner, and one
///              owner transaction (a module swap) also untraps it.
contract Q30A2 is J11Base {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant BIG_GAS = 30_000_000;

    bytes32 internal constant TOPIC_SWALLOWED = keccak256("DelegationUpdateFailed(uint256)");

    bytes4 internal constant SEL_SLOPE_OVERFLOW = bytes4(keccak256("DelegationSlopeOverflow()"));

    address internal dele3 = address(0xDE1E63);

    // ------------------------------------------------------------------ rig --

    function _call(address who_, bytes memory data_) internal returns (bool ok, bytes memory ret) {
        vm.prank(who_);
        (ok, ret) = address(veHemi).call{gas: BIG_GAS}(data_);
    }

    function _disable(address who_, uint256 id_) internal returns (bool ok, bytes memory ret) {
        return _call(who_, abi.encodeWithSignature("disableAutoRelock(uint256)", id_));
    }

    function _retire(address who_, uint256 id_) internal returns (bool ok, bytes memory ret) {
        return _call(who_, abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id_));
    }

    function _has(Vm.Log[] memory logs_, bytes32 topic_) internal pure returns (bool) {
        for (uint256 i; i < logs_.length; ++i) if (logs_[i].topics[0] == topic_) return true;
        return false;
    }

    function _flatDelegated(address who_, address to_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, to_);
        vm.warp(block.timestamp + 7200);
    }

    /// @dev THE REAL MODULE, refusing a CORRECT call. No mock: park `dele` one
    ///      victim-slope below the `uint64` aggregate ceiling with an ORDINARY
    ///      decaying delegation, then hand back the victim's FLAT position.
    function _saturate(uint256 headroom_) internal returns (uint256 victimId) {
        uint256 slopeCeil = uint256(type(uint64).max);
        (uint256 whaleId, , ) = createLock(stranger, (slopeCeil - headroom_) * MAX_TIME, 3 * 365 days);
        delegateTo(stranger, whaleId, dele);
        victimId = _flatDelegated(victim, dele);
        // PROVE the ceiling is actually reached, from OUTSIDE VeHemi's catch.
        (uint256 probeId, , ) = createLock(stranger, PRINCIPAL, 4 * 365 days);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", probeId, dele)
        );
        require(!ok && bytes4(ret) == SEL_SLOPE_OVERFLOW, "Q30: saturation premise GONE");
    }

    /// @dev The ADVERSARIAL shape: a module that answers `0xf2b4513c` to the
    ///      retirement leg (`Q14SlopeOverflowLiar`).
    function _installLiar(uint256 id_) internal returns (Q14SlopeOverflowLiar m) {
        m = new Q14SlopeOverflowLiar();
        m.seed(id_, dele, uint96(PRINCIPAL / 2), uint64(PRINCIPAL / MAX_TIME));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(m)));
        // NON-VACUITY: the module really does raise THE selector.
        (bool ok, bytes memory ret) = address(m).call(
            abi.encodeWithSignature("delegate(uint256,address)", id_, dele)
        );
        require(!ok && bytes4(ret) == SEL_SLOPE_OVERFLOW, "Q30: liar does not raise the selector");
    }

    /// @dev EVERY OWNER-INDEPENDENT ROUTE, IN ORDER, WITH THE ROUTE REPORTED.
    ///      0 = none. 1 = plain disable. 2 = escape hatch then disable.
    ///      3 = permissionless `retireStaleAutoRelock` after the stale window.
    function _clearFlagWithoutOwner(uint256 id_, address holder_) internal returns (uint256 route) {
        if (veHemi.autoRelockRemaining(id_) == 0) return 1;
        (bool d1, ) = _disable(holder_, id_);
        if (d1 && veHemi.autoRelockRemaining(id_) == 0) return 1;

        // THE ESCAPE HATCH: `vvd.delegate` is `onlyAuthorized`, so the HOLDER
        // can move the FLAT term to an unsaturated delegatee with no owner.
        // IT MUST TARGET THE MODULE `VeHemi` IS ACTUALLY POINTING AT -- calling
        // the ORIGINAL proxy after a pointer swap writes a record `VeHemi` will
        // never read, which would make this route look available when it is
        // not.
        address liveModule = address(veHemi.voteDelegation());
        vm.prank(holder_);
        (bool moved, ) = liveModule.call(
            abi.encodeWithSignature("delegate(uint256,address)", id_, dele3)
        );
        emit log_named_uint("  route2: escape-hatch move ok", moved ? 1 : 0);
        if (moved) {
            (bool d2, ) = _disable(holder_, id_);
            if (d2 && veHemi.autoRelockRemaining(id_) == 0) return 2;
        }

        // THE PERMISSIONLESS REMEDY. Anyone may call it once the position is
        // stale: `autoRelockRefreshedAt + STALE_FLAT_BUCKETS * SIX_DAYS`.
        uint256 staleAt = veHemi.autoRelockStaleAt(id_);
        emit log_named_uint("  route3: seconds until stale", staleAt > block.timestamp ? staleAt - block.timestamp : 0);
        if (block.timestamp < staleAt) vm.warp(staleAt);
        (bool r, ) = _retire(stranger, id_);
        emit log_named_uint("  route3: retireStaleAutoRelock ok", r ? 1 : 0);
        if (r && veHemi.autoRelockRemaining(id_) == 0) return 3;
        return 0;
    }

    function _withdrawAll(uint256 id_, address holder_) internal returns (uint256) {
        uint256 target = uint256(veHemi.getLockedBalance(id_).end) + 1;
        if (block.timestamp < target) vm.warp(target);
        uint256 before = hemi.balanceOf(holder_);
        (bool ok, ) = _call(holder_, abi.encodeWithSignature("withdraw(uint256)", id_));
        emit log_named_uint("  withdraw ok", ok ? 1 : 0);
        return hemi.balanceOf(holder_) - before;
    }

    // =====================================================================
    // V — THE PREMISES.
    // =====================================================================

    /// @notice The selector literal `VeHemi` hard-codes, recomputed here.
    function test_Q30_V1_selectorPin() public pure {
        assertEq(SEL_SLOPE_OVERFLOW, bytes4(0xf2b4513c), "Q30/V1: selector literal is stale");
    }

    /// @notice The three facts the trap and its cure rest on, read from this
    ///         tree's own state.
    function test_Q30_V2_theThreeShippedLinesThatComposeTheTrap() public {
        uint256 id = _flatDelegated(victim, dele);

        // (1) `withdraw` is FLAG-GATED.
        uint256 target = uint256(veHemi.getLockedBalance(id).end) + 1;
        vm.warp(target);
        assertGt(veHemi.autoRelockRemaining(id), 0, "Q30/V2: flag not set");
        (bool w, ) = _call(victim, abi.encodeWithSignature("withdraw(uint256)", id));
        assertFalse(w, "Q30/V2: withdraw is NOT flag-gated -- the trap cannot exist");

        // (2) the stale window is `STALE_FLAT_BUCKETS * SIX_DAYS` from the last
        //     refresh.
        uint256 staleAt = veHemi.autoRelockStaleAt(id);
        assertEq(
            staleAt - uint256(veHemi.autoRelockRefreshedAt(id)),
            veHemi.STALE_FLAT_BUCKETS() * SIX_DAYS,
            "Q30/V2: stale window is not 60 buckets"
        );
        emit log_named_uint("Q30/V2 stale window (s)", staleAt - uint256(veHemi.autoRelockRefreshedAt(id)));

        // (3) the permissionless leg really is permissionless.
        vm.warp(staleAt);
        (bool r, ) = _retire(stranger, id);
        assertTrue(r, "Q30/V2: a STRANGER could not retire a stale position");
        assertEq(veHemi.autoRelockRemaining(id), 0, "Q30/V2: flag survived the retirement");
    }

    // =====================================================================
    // R — LAW (A): a COMMITTED holder retirement must not leave a flat term
    //     standing.
    // =====================================================================

    function test_Q30_R1_holderDisableNeverCommitsAStrandedFlatTerm() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        vm.recordLogs();
        (bool committed, ) = _disable(victim, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
        bool flagCleared = veHemi.autoRelockRemaining(id) == 0;
        bool stillFlat = (d.slope == 0 && d.bias > 0);

        emit log_named_uint("Q30/R1 disable committed", committed ? 1 : 0);
        emit log_named_uint("Q30/R1 flag cleared", flagCleared ? 1 : 0);
        emit log_named_uint("Q30/R1 record still FLAT", stillFlat ? 1 : 0);
        emit log_named_uint("Q30/R1 record.bias", d.bias);
        emit log_named_uint("Q30/R1 swallowed", _has(logs, TOPIC_SWALLOWED) ? 1 : 0);
        assertFalse(flagCleared && stillFlat, "Q30/R1: COMMITTED with the flat term STILL STANDING");
    }

    /// @notice And the refusal carries the module's OWN selector.
    function test_Q30_R2_theRefusalCarriesTheSelector() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        (bool ok, bytes memory ret) = _disable(victim, id);
        emit log_named_uint("Q30/R2 disable ok", ok ? 1 : 0);
        assertFalse(ok, "Q30/R2: disable did not re-revert");
        assertEq(bytes4(ret), SEL_SLOPE_OVERFLOW, "Q30/R2: wrong revert data bubbled");
    }

    /// @notice Law (B) under the REAL module: the escape hatch (moving the flat
    ///         term to another delegatee) is ceiling-immune, so the holder
    ///         recovers with no owner action and NO waiting.
    function test_Q30_R3_realModule_holderRecoversWithNoOwnerAndNoWait() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        uint256 t0 = block.timestamp;
        uint256 route = _clearFlagWithoutOwner(id, victim);
        uint256 waited = block.timestamp - t0;
        emit log_named_uint("Q30/R3 route", route);
        emit log_named_uint("Q30/R3 seconds waited to clear the flag", waited);
        assertGt(route, 0, "Q30/R3: NO owner-independent route cleared the flag");
        assertLt(waited, 3600, "Q30/R3: the holder had to WAIT -- the escape hatch did not work");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "Q30/R3: principal did not come home");
    }

    // =====================================================================
    // T — THE ADVERSARIAL MODULE, AND WHAT UNTRAPS IT.
    // =====================================================================

    /// @notice A module that answers `0xf2b4513c` to the retirement leg. The
    ///         holder is refused, but the PERMISSIONLESS leg still swallows,
    ///         so the principal comes home with no owner action.
    function test_Q30_T1_adversarialSelector_ownerIndependentRecovery() public {
        uint256 id = _flatDelegated(victim, dele);
        _installLiar(id);
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        uint256 t0 = block.timestamp;
        uint256 route = _clearFlagWithoutOwner(id, victim);
        emit log_named_uint("Q30/T1 route", route);
        emit log_named_uint("Q30/T1 seconds waited", block.timestamp - t0);
        emit log_named_uint("Q30/T1 flag after", veHemi.autoRelockRemaining(id));
        uint256 got = route == 0 ? 0 : _withdrawAll(id, victim);
        emit log_named_uint("Q30/T1 recovered", got);
        assertEq(got, PRINCIPAL, "Q30/T1: PRINCIPAL TRAPPED -- no owner-independent route exists");
    }

    /// @notice ONE owner transaction — `updateVoteDelegation` to ANY module
    ///         that answers `delegation(id)` with `delegatee == 0` — and the
    ///         holder's own `disableAutoRelock` + `withdraw` work again.
    function test_Q30_T2_oneOwnerTxUntrapsIt() public {
        uint256 id = _flatDelegated(victim, dele);
        _installLiar(id);
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        // the holder alone, FIRST.
        (bool d0, ) = _disable(victim, id);
        emit log_named_uint("Q30/T2 holder disable BEFORE the swap", d0 ? 1 : 0);
        emit log_named_uint("Q30/T2 trapped before the swap", veHemi.autoRelockRemaining(id) != 0 ? 1 : 0);

        // ONE owner transaction. `K08SilentFreeze` is the MINIMUM shape: it
        // answers every read with a ZERO record, so `_reDelegate` skips the
        // write entirely. It HAS CODE, so `updateVoteDelegation` admits it.
        K08SilentFreeze fresh = new K08SilentFreeze();
        assertGt(address(fresh).code.length, 0, "Q30/T2: replacement is codeless (A1 would refuse)");
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(fresh)));

        if (veHemi.autoRelockRemaining(id) != 0) {
            (bool d1, ) = _disable(victim, id);
            emit log_named_uint("Q30/T2 holder disable AFTER the swap", d1 ? 1 : 0);
            emit log_named_uint("Q30/T2 owner txs needed", 1);
            assertTrue(d1, "Q30/T2: the module swap did NOT restore disableAutoRelock");
        } else {
            emit log_named_uint("Q30/T2 owner txs needed", 0);
        }
        assertEq(veHemi.autoRelockRemaining(id), 0, "Q30/T2: flag survived the swap");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "Q30/T2: principal still trapped after the swap");
    }

    /// @notice Re-installing the OLD, REAL `VeHemiVoteDelegation` also works,
    ///         because the liar never touched its storage.
    function test_Q30_T3_reinstallingTheOriginalModuleAlsoUntrapsIt() public {
        address original = address(delegation);
        uint256 id = _flatDelegated(victim, dele);
        _installLiar(id);
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        (bool d0, ) = _disable(victim, id);
        emit log_named_uint("Q30/T3 disable under the liar", d0 ? 1 : 0);

        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(original));
        if (veHemi.autoRelockRemaining(id) != 0) {
            (bool d1, ) = _disable(victim, id);
            emit log_named_uint("Q30/T3 disable after re-install", d1 ? 1 : 0);
            assertTrue(d1, "Q30/T3: re-installing the original module did not restore the path");
        }
        assertEq(veHemi.autoRelockRemaining(id), 0, "Q30/T3: flag survived the re-install");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "Q30/T3: principal not recovered");
    }

    /// @notice The permissionless leg still clears the flag under the
    ///         adversarial module (it swallows; only the holder's leg re-raises).
    function test_Q30_T4_permissionlessRetireStillClearsTheFlag() public {
        uint256 id = _flatDelegated(victim, dele);
        _installLiar(id);
        vm.warp(veHemi.autoRelockStaleAt(id));
        (bool r, ) = _retire(stranger, id);
        emit log_named_uint("Q30/T4 retire ok", r ? 1 : 0);
        emit log_named_uint("Q30/T4 flag after", veHemi.autoRelockRemaining(id));
        assertTrue(r, "Q30/T4: the PERMISSIONLESS remedy is closed by the re-revert");
        assertEq(veHemi.autoRelockRemaining(id), 0, "Q30/T4: flag survived");
    }

    /// @notice BOUNDED-TIME LAW (B): for EVERY module shape the flag clears
    ///         within `STALE_FLAT_BUCKETS * SIX_DAYS` of the last refresh
    ///         WITHOUT the owner.
    function test_Q30_T5_lawB_boundedTime() public {
        uint256 id = _flatDelegated(victim, dele);
        _installLiar(id);
        uint256 deadline = veHemi.autoRelockStaleAt(id);
        vm.warp(deadline);
        (bool r, ) = _retire(stranger, id);
        if (!r) { (r, ) = _disable(victim, id); }
        emit log_named_uint("Q30/T5 cleared by deadline", veHemi.autoRelockRemaining(id) == 0 ? 1 : 0);
        assertEq(
            veHemi.autoRelockRemaining(id),
            0,
            "Q30/T5: law (B) is NOT bounded in time -- the owner is the only cure"
        );
    }

    /// @notice THE ESCAPE HATCH HAS NO BAD TARGET. A flat delta carries
    ///         `slope: 0` and books no expiration bucket, so the move is
    ///         admitted even TO THE SATURATED DELEGATEE ITSELF. There is no
    ///         delegatee choice for which the holder's own cure fails.
    function test_Q30_T6_escapeHatchWorksEvenToTheSaturatedDelegatee() public {
        uint256 id = _saturate(uint256(PRINCIPAL / MAX_TIME) / 2);
        uint256 frozenEnd = veHemi.getLockedBalance(id).end;
        vm.warp(frozenEnd + 30 * SIX_DAYS);
        assertGt(block.timestamp, veHemi.getLockedBalance(id).end, "Q30/T6: end is not past");
        vm.prank(victim);
        (bool ok, bytes memory ret) = address(delegation).call(
            abi.encodeWithSignature("delegate(uint256,address)", id, dele)
        );
        emit log_named_uint("Q30/T6 move to the SATURATED delegatee ok", ok ? 1 : 0);
        if (!ok && ret.length >= 4) emit log_named_bytes32("Q30/T6 revert", bytes32(bytes4(ret)));
        assertTrue(ok, "Q30/T6: the escape hatch is NOT ceiling-immune");
    }

    /// @notice `retireStaleAutoRelock` is permissionless but UNPAID, so nobody
    ///         is incentivised to call it. The HOLDER can, which makes law (B)
    ///         self-serviceable rather than dependent on a keeper.
    function test_Q30_T7_theHolderCanCallThePermissionlessLegThemselves() public {
        uint256 id = _flatDelegated(victim, dele);
        _installLiar(id);
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(victim);
        uint256 g0 = gasleft();
        (bool r, ) = address(veHemi).call{gas: BIG_GAS}(
            abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id)
        );
        emit log_named_uint("Q30/T7 holder self-retire ok", r ? 1 : 0);
        emit log_named_uint("Q30/T7 gas", g0 - gasleft());
        assertTrue(r, "Q30/T7: the holder cannot self-serve the permissionless remedy");
        assertEq(_withdrawAll(id, victim), PRINCIPAL, "Q30/T7: principal not recovered");
    }
}

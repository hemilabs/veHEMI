// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {RevertingVoteDelegation} from "../mocks/RevertingVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import "./BrokenModules.sol";

/// @title  A broken delegation module cannot trap principal, over a
///         matrix of broken-module shapes.
///
/// @notice `FlatPositionGriefingTest.test_C5_brokenDelegationCannotLockFunds`
///         and `StarvedAndUnreadableModulesTest.test_H4_...` instantiate
///         "broken" with ONE shape (`RevertingVoteDelegation`, which reverts
///         on reads as well as writes). This matrix adds the shapes VeHemi
///         CAN read (write-reverting, lying, stale, silent-freeze, gas-eating
///         on write or read, mute). The cells are the shapes B1..B9 of
///         BrokenModules.sol except B8 (below); B0 is the control: the
///         healthy, real module, on which the same apparatus must see the
///         flat term retired and the principal returned.
///
///         B8 (`GarbageModule`: `delegation()` returns undecodable data) is
///         not a cell. Its read reverts the caller, so the holder's disable
///         cannot commit and law (A) cannot hold while it is installed; it is
///         tested in `ArmedTransferMoveOrRemoveTest`
///         (`test_T4_garbageRead_armedRefused_unarmedSucceeds`) and in
///         test/guards/AutoRelockGuards.t.sol
///         (`test_undecodableModule_locksArmedPrincipalUntilTheOwnerReplacesIt`).
///
/// @dev    Two laws, asserted for EVERY cell:
///
///           (A) NO SILENT PHANTOM — the installed module never reaches the
///               REAL module, so the flat term stays booked there; the
///               holder's disable must still COMMIT and must ANNOUNCE
///               (`AutoRelockRetirementUnverified`) in the same transaction.
///           (B) NO TRAPPED PRINCIPAL — the holder, with NO owner action of
///               any kind (no `updateVoteDelegation`, no upgrade), recovers
///               100 % of the principal in bounded time.
contract BrokenModuleMatrixTest is AutoRelockTestBase {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant CALL_GAS_LIMIT = 30_000_000;

    bytes32 internal constant TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED =
        keccak256("AutoRelockRetirementUnverified(uint256)");

    // ------------------------------------------------------------------
    // apparatus
    // ------------------------------------------------------------------

    /// @dev A DELEGATED, auto-relocked position with its flat term genuinely
    ///      booked at `delegateeA` in the REAL module. `delegation` (the test base's
    ///      handle) always reads the REAL module, never the mock installed in
    ///      VeHemi, so `delegation.getVotes(delegateeA)` measures the phantom
    ///      directly.
    function _flatDelegated(address who_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, delegateeA);
        vm.warp(block.timestamp + 7200);
        assertGt(delegation.getVotes(delegateeA), 0, "premise: no flat term booked");
    }

    function _install(address module_) internal {
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(module_));
    }

    function _call(address who_, bytes memory data_) internal returns (bool ok) {
        vm.prank(who_);
        (ok, ) = address(veHemi).call{gas: CALL_GAS_LIMIT}(data_);
    }

    function _disable(address who_, uint256 id_) internal returns (bool) {
        return _call(who_, abi.encodeWithSignature("disableAutoRelock(uint256)", id_));
    }

    function _retireStale(address who_, uint256 id_) internal returns (bool) {
        return _call(who_, abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id_));
    }

    /// @dev EVERY owner-independent exit this contract offers, tried in order.
    ///      No `updateVoteDelegation`, no upgrade, no `forfeitAdmin`.
    ///      Returns true if `autoRelockRemaining` reached 0.
    function _ownerIndependentExit(uint256 id_, address holder_) internal returns (bool) {
        if (veHemi.autoRelockRemaining(id_) == 0) return true;
        if (_disable(holder_, id_) && veHemi.autoRelockRemaining(id_) == 0) return true;

        // the permissionless keeper remedy, once the abandonment horizon opens
        uint256 staleAt = veHemi.autoRelockStaleAt(id_);
        if (block.timestamp < staleAt) vm.warp(staleAt);
        if (_retireStale(stranger, id_) && veHemi.autoRelockRemaining(id_) == 0) return true;

        return veHemi.autoRelockRemaining(id_) == 0;
    }

    /// @dev (B). Returns the HEMI the holder actually got back, with no owner
    ///      action anywhere in the sequence. 0 means trapped.
    function _recoverPrincipal(uint256 id_, address holder_) internal returns (uint256) {
        if (!_ownerIndependentExit(id_, holder_)) return 0;
        uint256 withdrawAt = uint256(veHemi.getLockedBalance(id_).end) + 1;
        if (block.timestamp < withdrawAt) vm.warp(withdrawAt);
        // amortise the global curve the way a live chain does, so `withdraw`
        // is not paying for years of un-checkpointed buckets in one call.
        for (uint256 i = 0; i < 8; ++i) { try veHemi.checkpoint() {} catch {} }
        uint256 before = hemi.balanceOf(holder_);
        // withdraw may itself route through the broken module; sweep a few
        // horizons so a bounded quarantine is not mistaken for a trap.
        for (uint256 i = 0; i < 6; ++i) {
            if (_call(holder_, abi.encodeWithSignature("withdraw(uint256)", id_))) break;
            vm.warp(block.timestamp + 10 * SIX_DAYS);
        }
        return hemi.balanceOf(holder_) - before;
    }

    /// @dev (A). True when the transaction that COMMITTED the retirement also
    ///      announced that it could not verify it.
    function _announced(Vm.Log[] memory logs_) internal pure returns (bool) {
        for (uint256 i = 0; i < logs_.length; ++i) {
            if (logs_[i].topics[0] == TOPIC_AUTO_RELOCK_RETIREMENT_UNVERIFIED) return true;
        }
        return false;
    }

    /// @dev The full cell. Runs the exit under `module_`, then asserts BOTH
    ///      halves of the law.
    function _cell(string memory name_, address module_, bool seedReadable_) internal {
        uint256 id = _flatDelegated(attacker);
        uint256 booked = delegation.getVotes(delegateeA);
        _install(module_);
        if (seedReadable_) {
            // give the readable shapes the record they are meant to serve:
            // the position's OWN flat booking, so the post-condition sees a
            // truthful "still flat".
            (bool ok, ) = module_.call(
                abi.encodeWithSignature("seedFlat(uint256,address,uint96)", id, delegateeA, uint96(booked)));
            if (!ok) {
                (ok, ) = module_.call(
                    abi.encodeWithSignature("freezeAt(uint256,address,uint96)", id, delegateeA, uint96(booked)));
            }
            assertTrue(ok, "premise: could not seed the readable module");
        }
        vm.warp(block.timestamp + 40 * SIX_DAYS);

        vm.recordLogs();
        bool committed = _disable(attacker, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // (A) the disable commits, the REAL module still books the flat term
        //     (the installed module never reached it), and the transaction
        //     says so.
        assertTrue(committed, string.concat("(A) ", name_, ": the holder's disable was refused"));
        assertEq(veHemi.autoRelockRemaining(id), 0, string.concat("(A) ", name_, ": disable left the flag set"));
        assertEq(delegation.getVotes(delegateeA), booked,
            string.concat("(A) ", name_, ": the real module's booking moved"));
        assertTrue(_announced(logs),
            string.concat("(A) ", name_, ": SILENT phantom -- retirement committed unverified with no event"));

        // (B) the principal comes home without the owner.
        uint256 recovered = _recoverPrincipal(id, attacker);
        emit log_named_uint(string.concat("  ", name_, " recovered"), recovered);
        emit log_named_uint(string.concat("  ", name_, " residual phantom"), delegation.getVotes(delegateeA));
        assertEq(recovered, PRINCIPAL,
            string.concat("(B) ", name_, ": PRINCIPAL TRAPPED -- no owner-independent exit"));
    }

    // ==================================================================
    // THE CELLS
    // ==================================================================

    /// B1 — reverts on everything (`RevertingVoteDelegation`).
    function test_B1_revertsOnEverything() public {
        _cell("B1 revert-all", address(new RevertingVoteDelegation()), false);
    }

    /// B2 — reverts on WRITE, succeeds on READ: the read-back sees a
    ///      still-flat record, which B1 never reaches.
    function test_B2_writeFailsReadSucceeds() public {
        _cell("B2 read-ok/write-revert", address(new WriteRevertingModule()), true);
    }

    /// B3 — succeeds and LIES. `delegate` is a silent no-op; every read is
    ///      proxied to the REAL module, so the record read back is the real,
    ///      still-flat one.
    function test_B3_succeedsAndLies() public {
        _cell("B3 lying", address(new LyingVoteDelegation(IVeHemiVoteDelegation(address(delegation)))), false);
    }

    /// B4 — succeeds and returns STALE. An ordinary cache-invalidation bug:
    ///      the write lands, the read serves the pre-write snapshot.
    function test_B4_succeedsAndReturnsStale() public {
        _cell("B4 stale-read", address(new StaleReaderModule()), true);
    }

    /// B5 — never reverts anywhere and reports a flat record for EVERY id
    ///      (one `onlyOwner` call installs it).
    function test_B5_silentFreeze() public {
        _cell("B5 silent-freeze", address(new SilentFreezeModule()), false);
    }

    /// B6 — out-of-gas on the WRITE (it consumes the whole ceiling, so it
    ///      is treated as broken, not starved).
    function test_B6_outOfGasOnWrite() public {
        _cell("B6 oog-write", address(new GasEaterWriteModule()), true);
    }

    /// B7 — out-of-gas on the READ. `_reDelegate`'s own read starves before a
    ///      write is ever attempted.
    function test_B7_outOfGasOnRead() public {
        _cell("B7 oog-read", address(new GasEaterReadModule()), false);
    }

    /// B9 — MUTE. Every selector reverts with empty returndata.
    function test_B9_mute() public {
        _cell("B9 mute", address(new MuteModule()), false);
    }

    // ==================================================================
    // VACUITY — the apparatus must be able to say GREEN for the right reason
    // ==================================================================

    /// @dev The healthy module: the flat term is REALLY retired, the phantom
    ///      is REALLY zero, and the principal comes back. If this body is red
    ///      every cell above is measuring the harness, not the contract.
    function test_B0_vacuity_healthyModuleRetiresForReal() public {
        uint256 id = _flatDelegated(attacker);
        uint256 booked = delegation.getVotes(delegateeA);
        assertGt(booked, 0, "vacuity: nothing booked");
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        assertTrue(_disable(attacker, id), "vacuity: honest disable refused");
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        assertEq(delegation.getVotes(delegateeA), veHemi.balanceOfNFT(id), "vacuity: honest retirement mis-booked");
        assertEq(_recoverPrincipal(id, attacker), PRINCIPAL, "vacuity: honest principal not returned");
    }
}

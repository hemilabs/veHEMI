// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {RevertingVoteDelegation} from "../mocks/RevertingVoteDelegation.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import "./K08Modules.sol";

/// @title  A broken delegation module cannot trap principal, over a
///         matrix of broken-module shapes.
///
/// @notice `test_F21_C5_brokenDelegationCannotLockFunds` and `test_J17_H5_...`
///         instantiate "broken" with ONE shape (`RevertingVoteDelegation`,
///         which reverts on reads as well as writes). This matrix adds the
///         shapes VeHemi CAN read (half-broken, lying, stale, silent-freeze,
///         gas-eating on write or read, mute).
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
contract K08Matrix is J11Base {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant BIG_GAS = 30_000_000;

    bytes32 internal constant TOPIC_UNVERIFIED =
        keccak256("AutoRelockRetirementUnverified(uint256)");
    bytes32 internal constant TOPIC_SWALLOWED =
        keccak256("DelegationUpdateFailed(uint256)");

    // ------------------------------------------------------------------
    // apparatus
    // ------------------------------------------------------------------

    /// @dev A DELEGATED, auto-relocked position with its flat term genuinely
    ///      booked at `dele` in the REAL module. `delegation` (the test base's
    ///      handle) always reads the REAL module, never the mock installed in
    ///      VeHemi, so `delegation.getVotes(dele)` measures the phantom
    ///      directly.
    function _flatDelegated(address who_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, dele);
        vm.warp(block.timestamp + 7200);
        assertGt(delegation.getVotes(dele), 0, "probe: no flat term booked");
    }

    function _install(address module_) internal {
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(module_));
    }

    function _call(address who_, bytes memory data_) internal returns (bool ok) {
        vm.prank(who_);
        (ok, ) = address(veHemi).call{gas: BIG_GAS}(data_);
    }

    function _disable(address who_, uint256 id_) internal returns (bool) {
        return _call(who_, abi.encodeWithSignature("disableAutoRelock(uint256)", id_));
    }

    function _retire(address who_, uint256 id_) internal returns (bool) {
        return _call(who_, abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id_));
    }

    /// @dev EVERY owner-independent exit this contract offers, tried in order.
    ///      No `updateVoteDelegation`, no upgrade, no `forfeitAdmin`.
    ///      Returns true if `autoRelockRemaining` reached 0.
    function _ownerIndependentExit(uint256 id_, address holder_) internal returns (bool) {
        if (veHemi.autoRelockRemaining(id_) == 0) return true;
        if (_disable(holder_, id_) && veHemi.autoRelockRemaining(id_) == 0) return true;

        // the permissionless keeper remedy, once the heartbeat horizon opens
        uint256 staleAt = veHemi.autoRelockStaleAt(id_);
        if (block.timestamp < staleAt) vm.warp(staleAt);
        if (_retire(stranger, id_) && veHemi.autoRelockRemaining(id_) == 0) return true;

        return veHemi.autoRelockRemaining(id_) == 0;
    }

    /// @dev (B). Returns the HEMI the holder actually got back, with no owner
    ///      action anywhere in the sequence. 0 means trapped.
    function _recoverPrincipal(uint256 id_, address holder_) internal returns (uint256) {
        if (!_ownerIndependentExit(id_, holder_)) return 0;
        uint256 target = uint256(veHemi.getLockedBalance(id_).end) + 1;
        if (block.timestamp < target) vm.warp(target);
        // amortise the global curve the way a live chain does, so `withdraw`
        // is not paying for years of un-checkpointed buckets in one call.
        for (uint256 c = 0; c < 8; ++c) { try veHemi.checkpoint() {} catch {} }
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
            if (logs_[i].topics[0] == TOPIC_UNVERIFIED) return true;
        }
        return false;
    }

    /// @dev The full cell. Runs the exit under `module_`, then asserts BOTH
    ///      halves of the law.
    function _cell(string memory name_, address module_, bool seedReadable_) internal {
        uint256 id = _flatDelegated(attacker);
        uint256 booked = delegation.getVotes(dele);
        _install(module_);
        if (seedReadable_) {
            // give the readable shapes the record they are meant to serve:
            // the position's OWN flat booking, so the post-condition sees a
            // truthful "still flat".
            (bool ok, ) = module_.call(
                abi.encodeWithSignature("seedFlat(uint256,address,uint96)", id, dele, uint96(booked)));
            if (!ok) {
                (ok, ) = module_.call(
                    abi.encodeWithSignature("freezeAt(uint256,address,uint96)", id, dele, uint96(booked)));
            }
            assertTrue(ok, "probe: could not seed the readable module");
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
        assertEq(delegation.getVotes(dele), booked, string.concat("probe ", name_, ": the real module's booking moved"));
        assertTrue(_announced(logs),
            string.concat("(A) ", name_, ": SILENT phantom -- retirement committed unverified with no event"));

        // (B) the principal comes home without the owner.
        uint256 got = _recoverPrincipal(id, attacker);
        emit log_named_uint(string.concat("  ", name_, " recovered"), got);
        emit log_named_uint(string.concat("  ", name_, " residual phantom"), delegation.getVotes(dele));
        assertEq(got, PRINCIPAL,
            string.concat("(B) ", name_, ": PRINCIPAL TRAPPED -- no owner-independent exit"));
    }

    // ==================================================================
    // THE CELLS
    // ==================================================================

    /// B1 — reverts on everything (`RevertingVoteDelegation`).
    function test_K08_B1_revertsOnEverything() public {
        _cell("B1 revert-all", address(new RevertingVoteDelegation()), false);
    }

    /// B2 — reverts on WRITE, succeeds on READ: the read-back sees a
    ///      still-flat record, which B1 never reaches.
    function test_K08_B2_writeFailsReadSucceeds() public {
        _cell("B2 read-ok/write-revert", address(new K08HalfBroken()), true);
    }

    /// B3 — succeeds and LIES. `delegate` is a silent no-op; every read is
    ///      proxied to the REAL module, so the record read back is the real,
    ///      still-flat one.
    function test_K08_B3_succeedsAndLies() public {
        _cell("B3 lying", address(new LyingVoteDelegation(IVeHemiVoteDelegation(address(delegation)))), false);
    }

    /// B4 — succeeds and returns STALE. An ordinary cache-invalidation bug:
    ///      the write lands, the read serves the pre-write snapshot.
    function test_K08_B4_succeedsAndReturnsStale() public {
        _cell("B4 stale-read", address(new K08StaleReader()), true);
    }

    /// B5 — never reverts anywhere and reports a flat record for EVERY id
    ///      (one `onlyOwner` call installs it).
    function test_K08_B5_silentFreeze() public {
        _cell("B5 silent-freeze", address(new K08SilentFreeze()), false);
    }

    /// B6 — out-of-gas on the WRITE (it consumes the whole ceiling, so it
    ///      is treated as broken, not starved).
    function test_K08_B6_outOfGasOnWrite() public {
        _cell("B6 oog-write", address(new K08GasEaterWrite()), true);
    }

    /// B7 — out-of-gas on the READ. `_reDelegate`'s own read starves before a
    ///      write is ever attempted.
    function test_K08_B7_outOfGasOnRead() public {
        _cell("B7 oog-read", address(new K08GasEaterRead()), false);
    }

    /// B9 — MUTE. Every selector reverts with empty returndata.
    function test_K08_B9_mute() public {
        _cell("B9 mute", address(new K08Mute()), false);
    }

    // ==================================================================
    // VACUITY — the apparatus must be able to say GREEN for the right reason
    // ==================================================================

    /// @dev The healthy module: the flat term is REALLY retired, the phantom
    ///      is REALLY zero, and the principal comes back. If this body is red
    ///      every cell above is measuring the harness, not the contract.
    function test_K08_B0_vacuity_healthyModuleRetiresForReal() public {
        uint256 id = _flatDelegated(attacker);
        uint256 booked = delegation.getVotes(dele);
        assertGt(booked, 0, "vacuity: nothing booked");
        vm.warp(block.timestamp + 40 * SIX_DAYS);
        assertTrue(_disable(attacker, id), "vacuity: honest disable refused");
        vm.warp(((block.timestamp / 1 hours) + 2) * 1 hours);
        assertEq(delegation.getVotes(dele), veHemi.balanceOfNFT(id), "vacuity: honest retirement mis-booked");
        assertEq(_recoverPrincipal(id, attacker), PRINCIPAL, "vacuity: honest principal not returned");
    }
}

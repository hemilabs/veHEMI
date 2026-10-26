// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @title  `updateVoteDelegation` REQUIRES `code.length > 0`.
///
/// @notice A codeless module would make every `voteDelegation.delegation(id)`
///         read in VeHemi decode zero bytes and revert, so `disableAutoRelock`,
///         `withdraw` and `createLock` would all fail and principal would be
///         trapped. The setter refuses such an address with
///         `VoteDelegationHasNoCode()`.
///
///           R  the trap scenario: the install is refused and the position's
///              principal comes home in full;
///           G  the guard: a codeless address and a precompile are refused,
///              with the exact selector;
///           N  no legitimate path broken: a real module still installs, and
///              the access check still runs first.
contract CodelessModuleRefusedTest is AutoRelockTestBase {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant CALL_GAS_LIMIT = 30_000_000;

    /// @dev A codeless address. `address(0)` is EXCLUDED on purpose: it is
    ///      refused earlier by the `AddressIsNull` check, so it
    ///      does not reach the code-length check.
    address internal constant EOA_MODULE = address(0xE0A);

    // ------------------------------------------------------------- rig -----

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

    /// @dev Every owner-independent exit this contract offers, tried in
    ///      order.
    function _ownerIndependentExit(uint256 id_, address holder_) internal returns (bool) {
        if (veHemi.autoRelockRemaining(id_) == 0) return true;
        if (_disable(holder_, id_) && veHemi.autoRelockRemaining(id_) == 0) return true;
        uint256 staleAt = veHemi.autoRelockStaleAt(id_);
        if (block.timestamp < staleAt) vm.warp(staleAt);
        if (_retireStale(stranger, id_) && veHemi.autoRelockRemaining(id_) == 0) return true;
        return veHemi.autoRelockRemaining(id_) == 0;
    }

    function _recoverPrincipal(uint256 id_, address holder_) internal returns (uint256) {
        if (!_ownerIndependentExit(id_, holder_)) return 0;
        uint256 withdrawAt = uint256(veHemi.getLockedBalance(id_).end) + 1;
        if (block.timestamp < withdrawAt) vm.warp(withdrawAt);
        for (uint256 i; i < 8; ++i) { try veHemi.checkpoint() {} catch {} }
        uint256 before = hemi.balanceOf(holder_);
        for (uint256 i; i < 6; ++i) {
            if (_call(holder_, abi.encodeWithSignature("withdraw(uint256)", id_))) break;
            vm.warp(block.timestamp + 10 * SIX_DAYS);
        }
        return hemi.balanceOf(holder_) - before;
    }

    function _flatDelegated(address who_, address to_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, to_);
        vm.warp(block.timestamp + 7200);
    }

    /// @dev `true` iff VeHemi ACCEPTED `module_`.
    function _tryInstall(address module_) internal returns (bool ok) {
        (ok, ) = address(veHemi).call(
            abi.encodeWithSignature("updateVoteDelegation(address)", module_)
        );
    }

    // ==================================================================
    // R — THE TRAP SCENARIO.
    // ==================================================================

    /// @notice An owner tries to install an EOA as the module. The install is
    ///         REFUSED, the pointer never moves, `createLock` still works, and
    ///         the flat, delegated position walks out with 100%. (Were the
    ///         install accepted, `disableAutoRelock`, `withdraw` and
    ///         `createLock` would all revert and `recovered` would be 0.)
    function test_R_codelessModuleInstallIsRefused_principalComesHome() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        address moduleBefore = address(veHemi.voteDelegation());

        bool accepted = _tryInstall(EOA_MODULE);
        emit log_named_uint("R codeless module ACCEPTED", accepted ? 1 : 0);
        emit log_named_address("R module after", address(veHemi.voteDelegation()));

        if (!accepted) {
            assertEq(address(veHemi.voteDelegation()), moduleBefore, "R: pointer moved on a refused set");
        }

        // The `createLock` leg (`_depositFor` -> `_reDelegate` ->
        // `voteDelegation.delegation(id)`), which a codeless module would break.
        //
        // 100 ether, NOT 1: `MIN_LOCK_AMOUNT` is 10 HEMI, so a 1-ether probe
        // would revert `AmountTooSmall` BEFORE it reaches `_delegate`.
        vm.prank(stranger);   // funded + approved in AutoRelockTestBase.setUp
        (bool createOk, ) = address(veHemi).call{gas: CALL_GAS_LIMIT}(
            abi.encodeWithSignature("createLock(uint256,uint256)", uint256(100 ether), uint256(4 * 365 days))
        );
        emit log_named_uint("R createLock survived", createOk ? 1 : 0);
        // non-vacuity: the SAME call on a healthy module must succeed
        if (!accepted) assertTrue(createOk, "R: createLock failed on a HEALTHY module -- probe is vacuous");

        uint256 recovered = _recoverPrincipal(id, victim);
        emit log_named_uint("R recovered", recovered);
        assertEq(recovered, PRINCIPAL, "R: PRINCIPAL TRAPPED behind a codeless module");
    }

    // ==================================================================
    // G — THE GUARD.
    // ==================================================================

    /// @notice A codeless address is refused at set time, with
    ///         `VoteDelegationHasNoCode()`, and the pointer does not move.
    function test_G_codelessModuleIsRefusedAtSetTime() public {
        assertEq(EOA_MODULE.code.length, 0, "premise: EOA_MODULE has code");
        address moduleBefore = address(veHemi.voteDelegation());
        vm.expectRevert(VeHemi.VoteDelegationHasNoCode.selector);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(EOA_MODULE));
        assertEq(address(veHemi.voteDelegation()), moduleBefore, "G: pointer moved on a refused set");
    }

    /// @notice A precompile also has `code.length == 0` and would drop every
    ///         relay identically. Same guard, second shape.
    function test_G_precompileIsRefusedToo() public {
        assertEq(address(0x01).code.length, 0, "premise: ecrecover has code");
        vm.expectRevert(VeHemi.VoteDelegationHasNoCode.selector);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(0x01)));
    }

    // ==================================================================
    // N — NO LEGITIMATE PATH BROKEN.
    // ==================================================================

    /// @notice The ONLY legitimate argument — a deployed contract — still
    ///         installs, and a position delegated through it still works.
    function test_N_contractModuleInstalls() public {
        address realDelegation = address(delegation);
        assertGt(realDelegation.code.length, 0, "premise: the real module has no code");
        assertTrue(_tryInstall(realDelegation), "N: a REAL module was refused");
        assertEq(address(veHemi.voteDelegation()), realDelegation, "N: pointer did not land");
        uint256 id = _flatDelegated(victim, delegateeA);
        assertGt(delegation.getVotes(delegateeA), 0, "N: delegation broken after re-install");
        assertEq(_recoverPrincipal(id, victim), PRINCIPAL, "N: principal lost");
    }

    /// @notice Non-owner is still refused FIRST, with the ownership error —
    ///         the code-length guard must not reorder the access check.
    function test_N_ownerCheckRunsFirst() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(EOA_MODULE));
    }
}

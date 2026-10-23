// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @title `VeHemiVoteDelegation::retireStrandedFlatTerm` exists, is
///        permissionless, and cures a stranded flat term.
///
/// @notice A retirement whose re-delegation VeHemi could not complete leaves the
///         VVD record FLAT (slope 0, bias > 0) while VeHemi reports the position
///         unarmed: a phantom that votes for ever. `retireStrandedFlatTerm` is
///         the permissionless remedy. This body asserts, with no control branch,
///         that the entry point answers with its own refusal on a position that
///         is not stranded, that a stranger's call succeeds on one that is, and
///         that the phantom is then gone while the principal stays locked.
///
/// @dev    The entry point is reached through a low-level `.call()` with a
///         hard-coded signature, not a typed call, so that a missing function
///         shows up as a red body with a legible message rather than a build
///         failure. `test/s26/S26Guard.t.sol` covers the function's guard.
contract F3R3g is J11Base {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant BIG_GAS = 30_000_000;

    /// @dev The entry point's own refusal. Computed from the signature rather
    ///      than imported, so that a missing function leaves this file
    ///      compiling (see the NatSpec above).
    bytes4 internal constant SEL_NOT_RETRYABLE = bytes4(keccak256("FlatTermNotRetryable()"));

    function _rec(string memory k_, uint256 v_) internal {
        emit log_named_uint(string.concat("OBS ", k_), v_);
    }

    function _call(address who_, address to_, bytes memory d_) internal returns (bool ok, bytes memory ret) {
        vm.prank(who_);
        (ok, ret) = to_.call{gas: BIG_GAS}(d_);
    }

    /// @dev The incoherent state `retireStrandedFlatTerm` exists to cure:
    ///      `VeHemi` says the position's auto-relock is retired, and VVD's own
    ///      record is still FLAT (slope 0, bias > 0) -- a phantom that votes for
    ///      ever. Built by retiring through a module that accepts `delegate` and
    ///      does nothing (`LyingVoteDelegation`); the state is ASSERTED in (a),
    ///      so this body cannot pass because the fixture failed to set up.
    function _armStrandedFlatTerm() internal returns (uint256 id) {
        (id, , ) = createLock(victim, PRINCIPAL, 4 * 365 days);
        enable(victim, id);
        delegateTo(victim, id, dele);
        vm.warp(block.timestamp + 7200);

        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        vm.warp(veHemi.autoRelockStaleAt(id));
        _call(stranger, address(veHemi), abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id));
        veHemi.updateVoteDelegation(delegation);
    }

    // =====================================================================

    /// @notice *** THE ENTRY POINT MUST EXIST, AND IT MUST CURE. ***
    ///
    ///         Four requirements, in order, each with its own sentence:
    ///           (a) the fixture really is in the stranded state (non-vacuity);
    ///           (b) `retireStrandedFlatTerm(uint256)` ANSWERS -- probed on an
    ///               id that is not stranded, it must refuse with its OWN
    ///               error (`FlatTermNotRetryable`) and not with the empty
    ///               revert data of a function that is not there;
    ///           (c) called by a STRANGER on the stranded position it SUCCEEDS
    ///               (it is permissionless: the remedy must not need the owner);
    ///           (d) and the phantom is actually GONE afterwards, with the
    ///               principal still locked.
    ///
    ///         (a) and (d) stop (b) from degenerating into a selector-shaped
    ///         tautology: a body that only asks "does something answer at this
    ///         selector?" is satisfied by a stub.
    function test_F3_R1_theStrandedFlatTermEntryPointExistsAndCuresThePhantom() public {
        uint256 id = _armStrandedFlatTerm();

        // ---- (a) NON-VACUITY: the phantom must be real before we cure it.
        IVeHemiVoteDelegation.Delegation memory d0 = delegation.delegation(id);
        uint256 remaining = veHemi.autoRelockRemaining(id);
        uint256 before_ = delegation.getVotes(dele);
        _rec("armed-slope", uint256(d0.slope));
        _rec("armed-bias", uint256(d0.bias));
        _rec("armed-autoRelockRemaining", remaining);
        _rec("votes-before", before_);
        assertEq(remaining, 0, "VACUOUS: VeHemi still reports auto-relock time, so nothing is stranded");
        assertEq(uint256(d0.slope), 0, "VACUOUS: the VVD record is not flat, so there is no phantom to retire");
        assertGt(uint256(d0.bias), 0, "VACUOUS: the VVD record carries no bias, so there is no phantom to retire");
        assertGt(before_, 0, "VACUOUS: the delegatee has no votes to lose, so `moved` would be 0 -> 0");

        // ---- (b) *** PRESENCE, ASSERTED AND NOT BRANCHED ON. ***
        // Probed on an id that is NOT stranded: a present function refuses
        // with `FlatTermNotRetryable()` (4 bytes of selector); an ABSENT
        // function reverts with EMPTY data, because VVD declares no fallback.
        (bool probeOk, bytes memory probeRet) = address(delegation).call(
            abi.encodeWithSignature("retireStrandedFlatTerm(uint256)", uint256(9_999_999)));
        bytes4 probeSel = probeRet.length >= 4
            ? bytes4(probeRet[0]) | (bytes4(probeRet[1]) >> 8) | (bytes4(probeRet[2]) >> 16) | (bytes4(probeRet[3]) >> 24)
            : bytes4(0);
        _rec("probe-ok", probeOk ? 1 : 0);
        _rec("probe-returndata-len", probeRet.length);
        _rec("probe-answers-with-its-own-error", probeSel == SEL_NOT_RETRYABLE ? 1 : 0);
        assertFalse(probeOk,
            "`retireStrandedFlatTerm` ACCEPTED a position that is not stranded -- its FlatTermNotRetryable guard is gone");
        assertGt(probeRet.length, 0,
            "*** `retireStrandedFlatTerm(uint256)` IS NOT ON THIS CONTRACT. *** The call returned EMPTY revert data, which is what a missing function looks like.");
        assertEq(probeSel, SEL_NOT_RETRYABLE,
            "something answers at this selector but it is not `FlatTermNotRetryable()` -- the entry point has been replaced, not merely guarded");

        // ---- (c) PERMISSIONLESS: a STRANGER, not the owner, not the holder.
        (bool ok, ) = _call(stranger, address(delegation),
            abi.encodeWithSignature("retireStrandedFlatTerm(uint256)", id));
        _rec("stranger-cure-succeeded", ok ? 1 : 0);
        assertTrue(ok,
            "a stranger could not retire the stranded flat term -- the permissionless remedy does not answer to the public it exists for");

        // ---- (d) THE PHANTOM IS GONE, AND THE PRINCIPAL IS NOT.
        vm.warp(block.timestamp + 2);
        uint256 after_ = delegation.getVotes(dele);
        IVeHemiVoteDelegation.Delegation memory d1 = delegation.delegation(id);
        uint256 principal = uint256(uint128(veHemi.getLockedBalance(id).amount));
        _rec("votes-after", after_);
        _rec("record-still-flat", (d1.slope == 0 && d1.bias > 0) ? 1 : 0);
        _rec("principal-still-locked", principal);
        assertFalse(d1.slope == 0 && d1.bias > 0,
            "the entry point returned success and the VVD record is STILL FLAT -- it answered without doing its job");
        assertTrue(after_ != before_,
            "the entry point returned success and the delegatee's votes did not move -- the phantom is still voting");
        assertGt(principal, 0,
            "the cure destroyed the position it was supposed to repair");
    }
}

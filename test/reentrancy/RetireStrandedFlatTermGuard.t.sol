// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../AutoRelockTestBase.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @dev A trusted adapter that RE-ENTERS `VeHemiVoteDelegation` from the
///      `notifyDelegateChanged` relay and records what happened. It calls
///      `writeNewCheckpointForExpiredDelegations` — a PERMISSIONLESS,
///      `nonReentrant` entry point — so the nested call needs no authority of
///      its own and the only thing that can refuse it is the transient guard.
///      VVD wraps every relay in `try … {} catch {}`, so whatever this
///      contract does cannot fail the outer transaction; the observation has
///      to be recorded HERE and read afterwards.
contract ReentrantRelayAdapter {
    address public immutable vvd;
    address public nestedCallDelegatee;
    uint256 public relayCalls;        // how many times the relay fired
    bytes4  public lastSelector;      // what the nested call answered
    bool    public lastOk;

    bytes4 internal constant SEL_WRITE_CHECKPOINT_FOR_EXPIRED_DELEGATIONS =
        bytes4(keccak256("writeNewCheckpointForExpiredDelegations(address)"));

    constructor(address vvd_, address nestedCallDelegatee_) {
        vvd = vvd_;
        nestedCallDelegatee = nestedCallDelegatee_;
    }

    function notifyVotesChanged(address, uint256, uint256) external {}

    function notifyDelegateChanged(address, address, address) external {
        ++relayCalls;
        (bool ok, bytes memory ret) =
            vvd.call(abi.encodeWithSelector(SEL_WRITE_CHECKPOINT_FOR_EXPIRED_DELEGATIONS, nestedCallDelegatee));
        lastOk = ok;
        lastSelector = ret.length >= 4
            ? bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24)
            : bytes4(0);
    }
}

/// @title `retireStrandedFlatTerm` CARRIES THE GUARD EVERY OTHER
///        STATE-WRITING VVD ENTRY POINT CARRIES, AND CURES THE STRANDED TERM.
///
/// @notice `retireStrandedFlatTerm` is permissionless and `nonReentrant`, like
///         `delegate`, `delegateBySig` and
///         `writeNewCheckpointForExpiredDelegations`. G1 re-enters VVD from the
///         adapter relay it fires and requires the transient guard's refusal.
///         G2 checks the guard costs no function: the stranded flat term is
///         retired and the position's current decaying weight is booked at
///         the record's own delegatee.
contract RetireStrandedFlatTermGuardTest is AutoRelockTestBase {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant CALL_GAS_LIMIT = 30_000_000;
    bytes4  internal constant SEL_REENTRANT      = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    bytes4  internal constant SEL_NO_EXPIRATIONS = bytes4(keccak256("NoExpirations()"));

    function _logObservation(string memory key_, uint256 value_) internal {
        emit log_named_uint(string.concat("observed ", key_), value_);
    }

    function _selectorName(bytes4 selector_) internal pure returns (string memory) {
        if (selector_ == SEL_REENTRANT) return "ReentrancyGuardReentrantCall";
        if (selector_ == SEL_NO_EXPIRATIONS) return "NoExpirations";
        if (selector_ == bytes4(0)) return "(empty)";
        return "other";
    }

    function _call(address who_, address to_, bytes memory data_) internal returns (bool ok, bytes memory ret) {
        vm.prank(who_);
        (ok, ret) = to_.call{gas: CALL_GAS_LIMIT}(data_);
    }

    function _flatDelegated(address who_, address to_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, to_);
        vm.warp(block.timestamp + 7200);
    }

    function _strandFlatTerm(uint256 id_) internal returns (bool stranded) {
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        vm.warp(veHemi.autoRelockStaleAt(id_));
        _call(stranger, address(veHemi), abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id_));
        veHemi.updateVoteDelegation(delegation);
        IVeHemiVoteDelegation.Delegation memory record = delegation.delegation(id_);
        stranded = veHemi.autoRelockRemaining(id_) == 0 && record.slope == 0 && record.bias > 0;
    }

    // =====================================================================

    /// @notice G1. A stranger calls `retireStrandedFlatTerm`; the relay
    ///         re-enters VVD through a trusted adapter. With the guard the
    ///         nested call is REFUSED (`ReentrancyGuardReentrantCall`); without
    ///         it the nested call would RUN and answer on its own merits.
    function test_G1_retireStrandedFlatTermCarriesTheGuard() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        bool stranded = _strandFlatTerm(id);
        _logObservation("stranded", stranded ? 1 : 0);
        assertTrue(stranded, "G1: the fixture did not strand the flat term");

        ReentrantRelayAdapter adapter = new ReentrantRelayAdapter(address(delegation), delegateeA);
        vm.prank(veHemi.owner());
        delegation.setTrustedAdapter(address(adapter));

        vm.prank(stranger);
        delegation.retireStrandedFlatTerm(id);

        emit log_named_uint  ("G1 relay fired (notifyDelegateChanged)", adapter.relayCalls());
        emit log_named_string("G1 NESTED call answered", _selectorName(adapter.lastSelector()));
        _logObservation("relay-fired", adapter.relayCalls());
        _logObservation("reentry-refused-by-the-guard", adapter.lastSelector() == SEL_REENTRANT ? 1 : 0);
        _logObservation("reentry-ran", (adapter.relayCalls() > 0 && adapter.lastSelector() != SEL_REENTRANT) ? 1 : 0);

        // NON-VACUITY: the re-entry must actually have been ATTEMPTED, or this
        // body proves nothing about the guard either way.
        assertGt(adapter.relayCalls(), 0,
            "G1 VACUOUS: the relay never fired, so nothing re-entered and the guard was never tested");
        assertEq(adapter.lastSelector(), SEL_REENTRANT,
            "G1: `retireStrandedFlatTerm` reached the adapter WITHOUT the transient guard set -- missing `nonReentrant`");
    }

    /// @notice G2. The guard must not change what the entry point DOES in the
    ///         ordinary case, in the test base's default configuration (no
    ///         trusted adapter): the flat term is retired and `delegateeA` holds
    ///         exactly the position's current (decaying) escrow weight.
    function test_G2_theGuardCostsNoFunction() public {
        uint256 id = _flatDelegated(victim, delegateeA);
        assertTrue(_strandFlatTerm(id), "G2: the fixture did not strand the flat term");

        uint256 before_ = delegation.getVotes(delegateeA);
        uint256 gasBefore = gasleft();
        vm.prank(stranger);
        delegation.retireStrandedFlatTerm(id);
        uint256 used = gasBefore - gasleft();
        vm.warp(block.timestamp + 2);
        uint256 after_ = delegation.getVotes(delegateeA);
        IVeHemiVoteDelegation.Delegation memory record = delegation.delegation(id);

        emit log_named_uint("G2 getVotes(delegateeA) BEFORE", before_);
        emit log_named_uint("G2 getVotes(delegateeA) AFTER ", after_);
        _logObservation("cure-gas", used);

        assertFalse(record.slope == 0 && record.bias > 0, "G2: the record is STILL FLAT after the cure");
        assertEq(record.delegatee, delegateeA, "G2: the cure moved the record off its own delegatee");
        assertEq(after_, veHemi.balanceOfNFT(id), "G2: delegateeA does not hold exactly the position's escrow weight");
        assertGt(after_, 0, "G2 VACUOUS: the position has no weight left");
        assertGt(uint256(uint128(veHemi.getLockedBalance(id).amount)), 0,
            "G2: the cure destroyed the position");
    }
}

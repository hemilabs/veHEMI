// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {LyingVoteDelegation} from "../mocks/LyingVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @dev A trusted adapter that RE-ENTERS `VeHemiVoteDelegation` from the
///      `notifyDelegateChanged` relay and records what happened. It probes
///      `writeNewCheckpointForExpiredDelegations` — a PERMISSIONLESS,
///      `nonReentrant` entry point — so the probe needs no authority of its
///      own and the only thing that can refuse it is the transient guard.
///      VVD wraps every relay in `try … {} catch {}`, so whatever this
///      contract does cannot fail the outer transaction; the observation has
///      to be recorded HERE and read afterwards.
contract S26ReentrantAdapter {
    address public immutable vvd;
    address public probeDelegatee;
    uint256 public reenters;          // how many times the relay fired
    bytes4  public lastSelector;      // what the nested call answered
    bool    public lastOk;

    bytes4 internal constant SEL_WNCFED =
        bytes4(keccak256("writeNewCheckpointForExpiredDelegations(address)"));

    constructor(address vvd_, address probeDelegatee_) {
        vvd = vvd_;
        probeDelegatee = probeDelegatee_;
    }

    function notifyVotesChanged(address, uint256, uint256) external {}

    function notifyDelegateChanged(address, address, address) external {
        ++reenters;
        (bool ok, bytes memory ret) =
            vvd.call(abi.encodeWithSelector(SEL_WNCFED, probeDelegatee));
        lastOk = ok;
        lastSelector = ret.length >= 4
            ? bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24)
            : bytes4(0);
    }
}

/// @title S26 — `retireStrandedFlatTerm` CARRIES THE GUARD EVERY OTHER
///        STATE-WRITING VVD ENTRY POINT CARRIES, AND CURES THE STRANDED TERM.
///
/// @notice `retireStrandedFlatTerm` is permissionless and `nonReentrant`, like
///         `delegate`, `delegateBySig` and
///         `writeNewCheckpointForExpiredDelegations`. G1 re-enters VVD from the
///         adapter relay it fires and requires the transient guard's refusal.
///         G2 checks the guard costs no function: the stranded flat term is
///         retired and the position's current decaying weight is booked at
///         the record's own delegatee.
contract S26Guard is J11Base {
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant BIG_GAS = 30_000_000;
    bytes4  internal constant SEL_REENTRANT     = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    bytes4  internal constant SEL_NO_EXPIRATION = bytes4(keccak256("NoExpirations()"));

    function _rec(string memory k_, uint256 v_) internal {
        emit log_named_uint(string.concat("S26/OBS ", k_), v_);
    }

    function _selStr(bytes4 s_) internal pure returns (string memory) {
        if (s_ == SEL_REENTRANT) return "ReentrancyGuardReentrantCall";
        if (s_ == SEL_NO_EXPIRATION) return "NoExpirations";
        if (s_ == bytes4(0)) return "(empty)";
        return "other";
    }

    function _call(address who_, address to_, bytes memory d_) internal returns (bool ok, bytes memory ret) {
        vm.prank(who_);
        (ok, ret) = to_.call{gas: BIG_GAS}(d_);
    }

    function _flatDelegated(address who_, address to_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, PRINCIPAL, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, to_);
        vm.warp(block.timestamp + 7200);
    }

    function _arm(uint256 id_) internal returns (bool armed) {
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new LyingVoteDelegation(delegation))));
        vm.warp(veHemi.autoRelockStaleAt(id_));
        _call(stranger, address(veHemi), abi.encodeWithSignature("retireStaleAutoRelock(uint256)", id_));
        veHemi.updateVoteDelegation(delegation);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id_);
        armed = veHemi.autoRelockRemaining(id_) == 0 && d.slope == 0 && d.bias > 0;
    }

    // =====================================================================

    /// @notice G1. A stranger calls `retireStrandedFlatTerm`; the relay
    ///         re-enters VVD through a trusted adapter. With the guard the
    ///         nested call is REFUSED (`ReentrancyGuardReentrantCall`); without
    ///         it the nested call would RUN and answer on its own merits.
    function test_S26_G1_retireStrandedFlatTermCarriesTheGuard() public {
        uint256 id = _flatDelegated(victim, dele);
        bool armed = _arm(id);
        _rec("armed", armed ? 1 : 0);
        assertTrue(armed, "S26/G1: the fixture did not arm");

        S26ReentrantAdapter adp = new S26ReentrantAdapter(address(delegation), dele);
        vm.prank(veHemi.owner());
        delegation.setTrustedAdapter(address(adp));

        vm.prank(stranger);
        delegation.retireStrandedFlatTerm(id);

        emit log_named_uint  ("S26/G1 relay fired (notifyDelegateChanged)", adp.reenters());
        emit log_named_string("S26/G1 NESTED call answered", _selStr(adp.lastSelector()));
        _rec("relay-fired", adp.reenters());
        _rec("reentry-refused-by-the-guard", adp.lastSelector() == SEL_REENTRANT ? 1 : 0);
        _rec("reentry-ran", (adp.reenters() > 0 && adp.lastSelector() != SEL_REENTRANT) ? 1 : 0);

        // NON-VACUITY: the re-entry must actually have been ATTEMPTED, or this
        // body proves nothing about the guard either way.
        assertGt(adp.reenters(), 0,
            "S26/G1 VACUOUS: the relay never fired, so nothing re-entered and the guard was never tested");
        assertEq(adp.lastSelector(), SEL_REENTRANT,
            "S26/G1: `retireStrandedFlatTerm` reached the adapter WITHOUT the transient guard set -- missing `nonReentrant`");
    }

    /// @notice G2. The guard must not change what the entry point DOES in the
    ///         ordinary case, through the tree's own adapter-free
    ///         configuration: the flat term is retired and `dele` holds exactly
    ///         the position's current (decaying) escrow weight.
    function test_S26_G2_theGuardCostsNoFunction() public {
        uint256 id = _flatDelegated(victim, dele);
        assertTrue(_arm(id), "S26/G2: the fixture did not arm");

        uint256 before_ = delegation.getVotes(dele);
        uint256 g0 = gasleft();
        vm.prank(stranger);
        delegation.retireStrandedFlatTerm(id);
        uint256 used = g0 - gasleft();
        vm.warp(block.timestamp + 2);
        uint256 after_ = delegation.getVotes(dele);
        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);

        emit log_named_uint("S26/G2 getVotes(dele) BEFORE", before_);
        emit log_named_uint("S26/G2 getVotes(dele) AFTER ", after_);
        _rec("cure-gas", used);

        assertFalse(d.slope == 0 && d.bias > 0, "S26/G2: the record is STILL FLAT after the cure");
        assertEq(d.delegatee, dele, "S26/G2: the cure moved the record off its own delegatee");
        assertEq(after_, veHemi.balanceOfNFT(id), "S26/G2: dele does not hold exactly the position's escrow weight");
        assertGt(after_, 0, "S26/G2 VACUOUS: the position has no weight left");
        assertGt(uint256(uint128(veHemi.getLockedBalance(id).amount)), 0,
            "S26/G2: the cure destroyed the position");
    }
}

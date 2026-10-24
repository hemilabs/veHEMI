// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

// =====================================================================
// THE MODULES
// =====================================================================

/// @notice The silent bypass. `delegation()` ANSWERS while the module still
///         holds a record and REVERTS once `delegate()` has cleared it — an
///         ordinary "unknown key reverts" getter convention. `delegate()`
///         itself is a LIE: it clears this module's own record and does
///         nothing whatever to the real delegatee's aggregate, so the flat
///         term stands. `_reDelegate` therefore SUCCEEDS (no
///         `DelegationUpdateFailed`) and `_requireFlatTermRetired` cannot
///         read the record: the phantom stands, and its only signal is
///         `AutoRelockRetirementUnverified`.
contract LyingUnreadableVoteDelegation is IVeHemiVoteDelegation {
    IVeHemiVoteDelegation public immutable REAL;
    uint256 private immutable ID;
    address private immutable DELEGATEE;
    mapping(uint256 => bool) public cleared;

    error NoSuchDelegation();

    constructor(IVeHemiVoteDelegation real_, uint256 id_, address delegatee_) {
        REAL = real_; ID = id_; DELEGATEE = delegatee_;
    }

    function delegate(uint256 id_, address) external override {
        cleared[id_] = true; // the lie: recorded here, nowhere that matters
    }

    function delegation(uint256 id_) external view override returns (Delegation memory d) {
        if (cleared[id_]) revert NoSuchDelegation();
        if (id_ == ID) { d.delegatee = DELEGATEE; return d; }
        return REAL.delegation(id_);
    }

    function autoDelegate(address a_) external view override returns (address) { return REAL.autoDelegate(a_); }
    function getVotes(address a_) external view override returns (uint256) { return REAL.getVotes(a_); }
    function getPastVotes(address a_, uint256 t_) external view override returns (uint256) {
        return REAL.getPastVotes(a_, t_);
    }
    function clearAutoDelegate() external override {}
    function setAutoDelegate(address) external pure override {}
    function refreshVotingPower(address) external override {}
    function refreshVotingPowerBatch(address[] calldata) external override {}
    function importDelegationsFromLegacy(IVeHemiVoteDelegation, uint256[] calldata) external pure override {}
    function importAutoDelegatesFromLegacy(IVeHemiVoteDelegation, address[] calldata) external pure override {}
    function finalizeMigration() external pure override {}
    function migrationFinalized() external pure override returns (bool) { return false; }
}

/// @notice A reward distributor with a switch: it RECORDS normally, and when
///         `eat` is set it consumes EVERY unit of gas it is handed — the
///         starvation signature at the `_updateReward` catch. The recording
///         leg is the control for the starving one.
contract StarvableRewardDistributor is IRewardDistributor {
    mapping(uint256 => uint256) public callsForToken;
    bool public eat;

    function setEat(bool v_) external { eat = v_; }

    function updateRewards(uint256 tokenId_) external override {
        callsForToken[tokenId_] += 1;
        if (eat) {
            uint256 x = 1;
            while (true) { x = uint256(keccak256(abi.encode(x))); } // burns the whole allowance
        }
    }
}

/// @notice A SELF-CONTAINED delegation module whose `autoDelegate` READ
///         consumes every unit of gas it is handed — the starvation signature
///         at the auto-delegate read, whose catch in `_resolveAutoDelegate`
///         emits NO event and falls back to the caller's OWN address. It
///         records what `VeHemi` asks it to delegate so the substitution is
///         observable; `eat` is switchable so the healthy leg is the control.
contract GasEatingAutoDelegate is IVeHemiVoteDelegation {
    address private immutable WHO;
    address private immutable TARGET;
    bool public eat = true;
    mapping(uint256 => address) public booked;

    constructor(address who_, address target_) { WHO = who_; TARGET = target_; }

    function setEat(bool v_) external { eat = v_; }

    function autoDelegate(address a_) external view override returns (address) {
        if (a_ == WHO) {
            if (eat) {
                uint256 x = 1;
                while (true) { x = uint256(keccak256(abi.encode(x))); }
            }
            return TARGET;
        }
        return address(0);
    }

    function delegate(uint256 id_, address to_) external override { booked[id_] = to_; }

    function delegation(uint256 id_) external view override returns (Delegation memory d) {
        d.delegatee = booked[id_];
    }

    function getVotes(address) external pure override returns (uint256) { return 0; }
    function getPastVotes(address, uint256) external pure override returns (uint256) { return 0; }
    function clearAutoDelegate() external override {}
    function setAutoDelegate(address) external pure override {}
    function refreshVotingPower(address) external override {}
    function refreshVotingPowerBatch(address[] calldata) external override {}
    function importDelegationsFromLegacy(IVeHemiVoteDelegation, uint256[] calldata) external pure override {}
    function importAutoDelegatesFromLegacy(IVeHemiVoteDelegation, address[] calldata) external pure override {}
    function finalizeMigration() external pure override {}
    function migrationFinalized() external pure override returns (bool) { return false; }
}

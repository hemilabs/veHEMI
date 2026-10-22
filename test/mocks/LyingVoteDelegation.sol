// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @notice A delegation module that LIES: every read is forwarded to the real
///         module, and `delegate` is accepted and does nothing. It models a
///         write that is accepted and ignored (for example a version-skewed
///         module): the call succeeds, so only VeHemi's retirement read-back
///         can notice that a flat term was not retired.
contract LyingVoteDelegation is IVeHemiVoteDelegation {
    IVeHemiVoteDelegation public immutable REAL;

    constructor(IVeHemiVoteDelegation real_) { REAL = real_; }

    function delegate(uint256, address) external override {
        // the lie: accepted, recorded nowhere.
    }

    function delegation(uint256 id_) external view override returns (Delegation memory) {
        return REAL.delegation(id_);
    }

    function autoDelegate(address a_) external view override returns (address) {
        return REAL.autoDelegate(a_);
    }

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

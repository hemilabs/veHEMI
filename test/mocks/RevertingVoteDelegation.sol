// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @notice Vote delegation that reverts on every state-mutating and state-reading entry point
///         used by VeHemi. Used to prove that VeHemi's try/catch wrappers around _reDelegate,
///         _delegate, and _resolveAutoDelegate keep core operations working when the
///         delegation contract is broken.
contract RevertingVoteDelegation is IVeHemiVoteDelegation {
    error AlwaysReverts();

    function delegate(uint256, address) external pure override {
        revert AlwaysReverts();
    }

    function delegation(uint256) external pure override returns (Delegation memory) {
        revert AlwaysReverts();
    }

    function autoDelegate(address) external pure override returns (address) {
        revert AlwaysReverts();
    }

    function getVotes(address) external pure override returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function clearAutoDelegate() external override {}

    function setAutoDelegate(address) external pure override {
        revert AlwaysReverts();
    }

    function refreshVotingPower(address) external override {}

    function refreshVotingPowerBatch(address[] calldata) external override {}

    function importDelegationsFromLegacy(
        IVeHemiVoteDelegation, uint256[] calldata
    ) external pure override {
        revert AlwaysReverts();
    }

    function importAutoDelegatesFromLegacy(
        IVeHemiVoteDelegation, address[] calldata
    ) external pure override {
        revert AlwaysReverts();
    }

    function finalizeMigration() external pure override {
        revert AlwaysReverts();
    }

    function migrationFinalized() external pure override returns (bool) {
        return false;
    }
}

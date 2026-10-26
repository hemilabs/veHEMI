// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @notice Vote delegation whose `delegate`, `delegation` and `autoDelegate` burn ALL the
///         gas they are given and then return (they never revert). Used to prove that a
///         module that fails by exhaustion -- consuming VeHemi's whole delegation gas
///         ceiling -- is treated as broken, not starved, so core operations (withdraw,
///         disable, forfeit, transfer) still complete when enough gas is sent.
contract OogVoteDelegation is IVeHemiVoteDelegation {
    function _burnAll() private view { uint256 x=1; while (gasleft() > 200) { x = uint256(keccak256(abi.encode(x))); } }

    error UnsupportedEntryPoint(); // the migration and setter entry points VeHemi never calls

    function delegate(uint256, address) external view override {
        _burnAll();
    }

    function delegation(uint256) external view override returns (Delegation memory d) {
        _burnAll();
        return d;
    }

    function autoDelegate(address) external view override returns (address) {
        _burnAll();
        return address(0);
    }

    function getVotes(address) external pure override returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function clearAutoDelegate() external override {}

    function setAutoDelegate(address) external pure override {
        revert UnsupportedEntryPoint();
    }

    function refreshVotingPower(address) external override {}

    function refreshVotingPowerBatch(address[] calldata) external override {}

    function importDelegationsFromLegacy(
        IVeHemiVoteDelegation, uint256[] calldata
    ) external pure override {
        revert UnsupportedEntryPoint();
    }

    function importAutoDelegatesFromLegacy(
        IVeHemiVoteDelegation, address[] calldata
    ) external pure override {
        revert UnsupportedEntryPoint();
    }

    function finalizeMigration() external pure override {
        revert UnsupportedEntryPoint();
    }

    function migrationFinalized() external pure override returns (bool) {
        return false;
    }
}

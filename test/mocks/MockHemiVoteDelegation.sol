// Mock for IHemiVoteDelegation
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

contract MockHemiVoteDelegation is IVeHemiVoteDelegation {
    mapping(uint256 => Delegation) public delegations;

    function delegate(uint256 delegator_, address delegatee_) external override {
        delegations[delegator_] = Delegation({
            delegatee: delegatee_,
            end: uint48(block.timestamp + 1 days),
            bias: 0,
            amount: 0,
            slope: 0
        });
    }

    function getVotes(address) external pure override returns (uint256) {
        return 0;
    }
    function getPastVotes(address, uint256) external pure override returns (uint256) {
        return 0;
    }
    function delegation(uint256 tokenId_) external view override returns (Delegation memory) {
        return delegations[tokenId_];
    }

    function autoDelegate(address) external pure override returns (address) {
        return address(0);
    }

    function refreshVotingPower(address) external override {}

    function refreshVotingPowerBatch(address[] calldata) external override {}
}

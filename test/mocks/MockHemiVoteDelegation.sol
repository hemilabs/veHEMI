// Mock for IHemiVoteDelegation
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IHemiVoteDelegation} from "../../src/interfaces/IHemiVoteDelegation.sol";

contract MockHemiVoteDelegation is IHemiVoteDelegation {
    mapping(uint256 => Delegation) public delegations;
    event Delegated(uint256 indexed delegator, uint256 indexed delegatee);

    function delegate(uint256 delegator_, uint256 delegatee_) external override {
        delegations[delegator_] = Delegation({
            delegatee: delegatee_,
            firstDelegationTimestamp: uint48(block.timestamp),
            end: uint48(block.timestamp + 1 days),
            bias: 0,
            amount: 0,
            slope: 0
        });
        emit Delegated(delegator_, delegatee_);
    }

    function getVotes(uint256) external pure override returns (uint256) {
        return 0;
    }
    function getPastVotes(uint256, uint256) external pure override returns (uint256) {
        return 0;
    }
    function delegation(uint256 tokenId_) external view override returns (Delegation memory) {
        return delegations[tokenId_];
    }
}

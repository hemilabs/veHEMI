// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IHemiVoteDelegation} from "../interfaces/IHemiVoteDelegation.sol";

abstract contract DelegationStorageV1 is IHemiVoteDelegation {
    mapping(uint256 delegator => IHemiVoteDelegation.Delegation delegate) public delegations;
    mapping(uint256 delegatee => IHemiVoteDelegation.DelegateCheckpoint[])
        public delegateCheckpoints;

    /// @notice Mapping from delegate to weekly rounded time of expiry to the aggregated values at time of expiration.
    mapping(uint256 delegate => mapping(uint256 week => Expiration)) public expiredDelegations;
}

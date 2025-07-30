// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../interfaces/IVeHemiVoteDelegation.sol";

abstract contract VeHemiDelegationStorageV1 is IVeHemiVoteDelegation {
    mapping(uint256 delegator => IVeHemiVoteDelegation.Delegation delegate) public delegations;
    mapping(address delegatee => IVeHemiVoteDelegation.DelegateCheckpoint[])
        public delegateCheckpoints;

    /// @notice Mapping from delegate to SIX_DAYS rounded time of expiry to the aggregated values at time of expiration.
    mapping(address delegatee => mapping(uint256 sixDays => Expiration)) public expiredDelegations;
    /// @notice Nonces needed for delegations by signature
    mapping(address signer => uint256 nonce) public nonces;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../interfaces/IVeHemiVoteDelegation.sol";

abstract contract VeHemDelegationStorageV1 is IVeHemiVoteDelegation {
    mapping(uint256 delegator => IVeHemiVoteDelegation.Delegation delegate) public delegations;
    mapping(uint256 delegatee => IVeHemiVoteDelegation.DelegateCheckpoint[])
        public delegateCheckpoints;

    /// @notice Mapping from delegate to weekly rounded time of expiry to the aggregated values at time of expiration.
    mapping(uint256 delegate => mapping(uint256 week => Expiration)) public expiredDelegations;
    /// @notice Nonces needed for delegations by signature
    mapping(address signer => uint256 nonce) public nonces;
}

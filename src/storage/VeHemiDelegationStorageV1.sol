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

    /// @notice Auto-delegate target for each account. When set via delegateAllFor,
    ///         new veHEMI positions created for this account will be automatically
    ///         delegated to this address instead of self-delegating.
    mapping(address owner => address delegatee) public autoDelegate;

    /// @notice The trusted adapter contract that can call delegateAllFor on behalf of users.
    ///         Set via setTrustedAdapter by the VeHemi owner.
    address public trustedAdapter;

    /// @dev Reserved storage slots for future upgrades.
    ///      6 slots used (4 mappings + autoDelegate mapping + trustedAdapter address).
    ///      Reserve 44 to bring total to 50, following OpenZeppelin convention.
    uint256[44] private __gap;
}

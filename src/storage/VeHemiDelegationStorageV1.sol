// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../interfaces/IVeHemiVoteDelegation.sol";

/// @dev FROZEN — do not add, remove, or reorder fields. VeHemiDelegationStorageV2
///      starts immediately after slot 3 (nonces). Any modification here shifts
///      V2's storage layout and corrupts the proxy on upgrade.
///
///      No storage gap: future storage contracts extend this one via the chain
///      pattern (V2 is V1), so V2's own gap serves future expansions.
abstract contract VeHemiDelegationStorageV1 is IVeHemiVoteDelegation {
    // --- State (slots 0–3) ---
    mapping(uint256 delegator => IVeHemiVoteDelegation.Delegation delegate) public delegations;
    mapping(address delegatee => IVeHemiVoteDelegation.DelegateCheckpoint[])
        public delegateCheckpoints;

    /// @notice Mapping from delegate to SIX_DAYS rounded time of expiry to the aggregated values at time of expiration.
    mapping(address delegatee => mapping(uint256 sixDays => Expiration)) public expiredDelegations;
    /// @notice Nonces needed for delegations by signature
    mapping(address signer => uint256 nonce) public nonces;
}

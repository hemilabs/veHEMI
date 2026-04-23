// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiDelegationStorageV1} from "./VeHemiDelegationStorageV1.sol";

/**
 * @title VeHemiDelegationStorageV2
 * @notice Storage extension for VeHemiVoteDelegation V2 (Aragon adapter support).
 *
 * @dev Chain-inherits VeHemiDelegationStorageV1 to enforce V1-before-V2 slot
 *      ordering at the inheritance level. `VeHemiVoteDelegation` inherits only
 *      this contract, which transitively includes V1. This mirrors the pattern
 *      already used by VeHemi/VeHemiStorageV1/V2 in this repo.
 *
 *      V2 additions (Aragon adapter support):
 *        - `autoDelegate`: per-account delegatee applied when new veHEMI
 *          positions are created for that owner, so freshly-minted positions
 *          delegate automatically instead of self-delegating.
 *        - `trustedAdapter`: the sole address permitted to call
 *          `delegateAllFor` on behalf of users. Set by the VeHemi owner.
 *
 *      The storage gap lives here rather than in V1: under the chain pattern
 *      only the most-derived storage contract needs a gap. Once V2 is
 *      deployed this gap is permanently reserved — a future V3 would
 *      chain-inherit V2 (`V3 is V2`) and append NEW fields AFTER slot 49,
 *      declaring its own `__gapV3`. V2's slots stay frozen.
 */
abstract contract VeHemiDelegationStorageV2 is VeHemiDelegationStorageV1 {
    // --- State (slots 4–5) ---

    /// @notice Auto-delegate target for each account. When set via delegateAllFor,
    ///         new veHEMI positions created for this account will be automatically
    ///         delegated to this address instead of self-delegating.
    mapping(address owner => address delegatee) public autoDelegate;

    /// @notice The trusted adapter contract that can call delegateAllFor on behalf of users.
    ///         Set via setTrustedAdapter by the VeHemi owner.
    address public trustedAdapter;

    /// @dev Reserved storage slots for future upgrades.
    ///      Storage layout (relative to V2 start):
    ///        Slot 0: autoDelegate (mapping base)
    ///        Slot 1: trustedAdapter (address)
    ///        Slots 2–45: __gapV2[44]
    ///      Total reserved (V1 + V2): 50 slots (4 V1 + 2 V2 + 44 gap).
    ///
    ///      Unlike `VeHemiStorageV2` (which carries two `__reservedSlotN`
    ///      entries ahead of its named fields), V2 here adds only two fields
    ///      and the trailing gap supplies ample runway — pre-field reservation
    ///      would be pure ceremony. A future V3 chain-inheriting this contract
    ///      should declare its own new fields AFTER slot 49 (absolute) plus a
    ///      fresh `__gapV3`, leaving every slot in this contract frozen.
    uint256[44] private __gapV2;
}

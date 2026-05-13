// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiDelegationStorageV2} from "./VeHemiDelegationStorageV2.sol";

/**
 * @title VeHemiDelegationStorageV3
 * @notice Storage extension for VeHemiVoteDelegation V3 (migration tooling).
 *
 * @dev Chain-inherits V2 to preserve all prior slot positions.
 *      `VeHemiVoteDelegation` now inherits V3, which transitively pulls in
 *      V2 and V1. V1 (slots 0–3) and V2 (slots 4–5 plus __gapV2[44] at
 *      slots 6–49) remain BYTE-IDENTICAL — V3's new field lands at the
 *      first slot AFTER V2's reserved range.
 *
 *      V3 additions (HIGH-2 mitigation — `updateVoteDelegation` migration tooling):
 *        - `migrationFinalized`: one-way latch flipped by `finalizeMigration()`.
 *          While `false`, the VeHemi owner may call `importDelegationsFromLegacy`
 *          and `importAutoDelegatesFromLegacy` to seed this contract from a
 *          legacy VVD before `veHemi.updateVoteDelegation` swaps the pointer.
 *          Once `true`, those import paths revert permanently, sealing the
 *          contract against further admin-side state injection.
 *
 *      Storage layout (relative to V3 start at slot 50):
 *        Slot 50: migrationFinalized (bool — packs alone for simplicity)
 *        Slots 51–99: __gapV3[49]
 *      Total reserved (V1 + V2 + V3): 100 slots (4 V1 + 2 V2 + 44 V2-gap
 *      + 1 V3 + 49 V3-gap).
 *
 *      A future V4 chain-inheriting this contract must declare its new
 *      fields AFTER slot 99 (absolute) plus a fresh `__gapV4`, leaving
 *      every slot in this contract frozen.
 */
abstract contract VeHemiDelegationStorageV3 is VeHemiDelegationStorageV2 {
    // --- State (slot 50) ---

    /// @notice One-way latch sealing the legacy-import functions.
    ///         Initially `false`; flipped to `true` exactly once by
    ///         `finalizeMigration()`. After this flip the import paths
    ///         revert with `MigrationFinalized` and cannot be re-opened
    ///         by any caller (including the owner) — preventing
    ///         post-migration state injection that would corrupt
    ///         `getPastVotes` history for snapshots taken after finalize.
    bool public migrationFinalized;

    /// @dev Reserved storage slots for future V4+ upgrades. See contract
    ///      NatSpec for the chain-inheritance contract.
    uint256[49] private __gapV3;
}

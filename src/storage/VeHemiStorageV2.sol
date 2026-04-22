// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiStorageV1} from "./VeHemiStorageV1.sol";

/**
 * @title VeHemiStorageV2
 * @notice Storage extension for VeHemi V2 (non-transferrable position weight tracking via locked
 *         and forfeitable subcurves).
 *
 * @dev Inherits VeHemiStorageV1 to enforce the V1-before-V2 slot ordering at the
 *      inheritance level. VeHemi inherits only VeHemiStorageV2, which transitively
 *      includes V1. This is the standard upgradeable-storage chain pattern used by
 *      OpenZeppelin, Aave, Synthetix, Pendle, and Compound — it removes the risk of
 *      a future edit to VeHemi's base list accidentally reordering V1 and V2.
 *
 *      Design decisions:
 *        - `lockedGlobalPointHistory` tracks aggregate (bias, slope) for
 *          non-transferrable positions only, using a minimal 2-slot `LockedPoint`
 *          struct (vs 3-slot `Point`). Saves ~20,000 gas per SSTORE.
 *        - `lockedSlopeChanges` mirrors `slopeChanges` for the locked-only subset.
 *        - `lockedSeedingFinalized` gates all locked-curve logic in `_checkpoint`.
 *          Before finalization, `_checkpoint` skips locked tracking entirely.
 *        - Slots 0-1 (V2-relative) are reserved for future use (preserves storage
 *          layout for any field that should logically sit between the V1 boundary
 *          and the subcurve state — e.g., a future V3 extension).
 *        - A storage gap is reserved for future extensions.
 */
abstract contract VeHemiStorageV2 is VeHemiStorageV1 {
    /// @dev Reserved slot for future extensions (preserves storage layout).
    uint256 private __reservedSlot0;

    /// @dev Reserved slot for future extensions (preserves storage layout).
    uint256 private __reservedSlot1;

    /// @notice Reduced-size point for locked-only global curve.
    /// @dev 2 storage slots: {bias, slope} in slot N, {timestamp, blockNumber} in slot N+1.
    struct LockedPoint {
        int128 bias;
        int128 slope;
        uint64 timestamp;
        uint64 blockNumber;
    }

    /// @notice Slope changes for non-transferrable positions only.
    ///         time -> signed slope delta (mirrors slopeChanges).
    mapping(uint256 => int128) public lockedSlopeChanges;

    /// @notice Global point history for non-transferrable positions only.
    ///         epoch -> LockedPoint (shares epoch counter with globalPointHistory).
    mapping(uint256 => LockedPoint) internal lockedGlobalPointHistory;

    /// @notice Whether locked position seeding is complete.
    /// @dev When false, _checkpoint skips locked-only and forfeitable tracking.
    bool public lockedSeedingFinalized;

    /// @notice Slope changes for forfeitable (non-transferrable) positions only.
    ///         time -> signed slope delta (mirrors lockedSlopeChanges for the forfeitable subset).
    mapping(uint256 => int128) public forfeitableSlopeChanges;

    /// @notice Global point history for forfeitable (non-transferrable) positions only.
    ///         epoch -> LockedPoint (shares epoch counter with globalPointHistory).
    mapping(uint256 => LockedPoint) internal forfeitableGlobalPointHistory;

    /// @dev Reserved storage slots for future upgrades.
    ///      Storage layout (relative to V2 start):
    ///        Slot 0: __reservedSlot0
    ///        Slot 1: __reservedSlot1
    ///        Slot 2: lockedSlopeChanges (mapping base)
    ///        Slot 3: lockedGlobalPointHistory (mapping base)
    ///        Slot 4: lockedSeedingFinalized (bool)
    ///        Slot 5: forfeitableSlopeChanges (mapping base)
    ///        Slot 6: forfeitableGlobalPointHistory (mapping base)
    ///      Total named slots: 7. Gap: 50 - 7 = 43.
    uint256[43] private __gapV2;
}

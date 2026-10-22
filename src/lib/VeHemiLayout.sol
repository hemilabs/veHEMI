// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IVeHemi} from "../interfaces/IVeHemi.sol";
import {VeHemiStorageV2} from "../storage/VeHemiStorageV2.sol";

/// @notice Slot-0-anchored mirror of VeHemi's storage layout (slots 0..113).
/// @dev DELEGATECALL libraries execute in VeHemi's storage context but cannot
///      inherit `VeHemiStorageV3` (libraries may not inherit). This struct
///      reproduces the layout exactly so library code can address every state
///      variable without threading storage-pointer parameters (which cost
///      stack slots that `_checkpoint`-class bodies do not have).
///
///      *** THIS STRUCT IS A SECOND SOURCE OF TRUTH FOR THE PROXY LAYOUT. ***
///      It must match VeHemi's compiled storage layout member for member --
///      label, slot, offset and type, array lengths and integer widths
///      included. `VeHemiLayoutProbe` exists so that the compiler reports this
///      struct's layout for that comparison.
///
///      THE MIRROR MUST BE TOTAL. Every VeHemi state variable appears here,
///      `__gapV3` included, even though no library reads a gap. That is what
///      lets the comparison demand exact equality with no allowlist, so a field
///      appended to VeHemi and forgotten here fails it rather than diverging
///      silently. Listing `__gapV3` changes no code: it is the last member.
struct VeHemiLayout {
    uint256 totalLocked; //                                                     slot 0
    uint256 epoch; //                                                           slot 1
    uint256 nextTokenId; //                                                     slot 2
    address voteDelegation; //                                                  slot 3
    address rewardDistributor; //                                               slot 4
    address forfeitAdmin; //                                                    slot 5
    mapping(uint256 => IVeHemi.Point) globalPointHistory; //                     slot 6
    mapping(uint256 => IVeHemi.UserPoint[1000000000]) userPointHistory; //       slot 7
    mapping(uint256 => uint256) userPointEpoch; //                              slot 8
    mapping(uint256 => int128) slopeChanges; //                                 slot 9
    mapping(uint256 => IVeHemi.LockedBalance) locked; //                        slot 10
    mapping(uint256 => address) provider; //                                    slot 11
    mapping(uint256 => uint256) transferableAfter; //                           slot 12
    mapping(uint256 => bool) forfeitable; //                                    slot 13
    uint256 __reservedSlot0; //                                                 slot 14
    uint256 __reservedSlot1; //                                                 slot 15
    mapping(uint256 => int128) lockedSlopeChanges; //                           slot 16
    mapping(uint256 => VeHemiStorageV2.LockedPoint) lockedGlobalPointHistory; // slot 17
    bool lockedSeedingFinalized; //                                             slot 18
    mapping(uint256 => int128) forfeitableSlopeChanges; //                      slot 19
    mapping(uint256 => VeHemiStorageV2.LockedPoint) forfeitableGlobalPointHistory; // slot 20
    bool seedingStarted; //                                        slot 21 offset 0
    uint64 seedingStartedAt; //                                    slot 21 offset 1
    uint256 seedingTargetId; //                                                 slot 22
    VeHemiStorageV2.SeedingProgress _seedingProgress; //                         slots 23-26
    uint256[37] __gapV2; //                                                     slots 27-63
    mapping(uint256 => uint64) autoRelockRemaining; //                          slot 64  (V3)
    mapping(uint256 => uint64) autoRelockRefreshedAt; //                        slot 65  (V3)
    uint256[48] __gapV3; //                                                     slots 66-113
}

library VeHemiLayoutLib {
    function layout() internal pure returns (VeHemiLayout storage l) {
        assembly {
            l.slot := 0
        }
    }
}

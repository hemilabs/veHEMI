// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiLayout} from "./VeHemiLayout.sol";

/// @notice Compile-only probe whose single state variable is the DELEGATECALL
///         libraries' storage mirror, anchored at slot 0 exactly as the
///         libraries anchor it.
/// @dev Its compiled storage layout gives the compiler's slot and offset for
///      every `VeHemiLayout` member, for comparison against VeHemi's compiled
///      storage layout. Never deployed.
contract VeHemiLayoutProbe {
    VeHemiLayout internal mirror;
}

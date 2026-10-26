// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @notice Single definition of the time grid shared by VeHemi and every
///         DELEGATECALL library that reproduces its curve math.
/// @dev VeHemi's own `YEAR`, `SIX_DAYS`, `MAX_TIME`, `MULTIPLIER` and
///      `MIN_LOCK_AMOUNT` are defined from these. With curve math executing in
///      libraries the constants MUST be identical on both sides -- a divergent
///      `SIX_DAYS` in a library silently indexes a different slope-change
///      grid. Internal constants are inlined at compile time, so sharing them
///      costs no bytecode.
library VeHemiTime {
    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant SIX_DAYS = YEAR / (12 * 5);
    uint256 internal constant MAX_TIME = 4 * YEAR;
    uint256 internal constant MULTIPLIER = 1 ether;
    uint256 internal constant MIN_LOCK_AMOUNT = 10e18;
}

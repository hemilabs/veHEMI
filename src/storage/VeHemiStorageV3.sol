// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiStorageV2} from "./VeHemiStorageV2.sol";

/**
 * @title VeHemiStorageV3
 * @notice Storage extension for VeHemi V3 (auto-relock).
 *
 * @dev Chain-inherits V2 so V1 (slots 0-13) and V2 (slots 14-26 plus
 *      `__gapV2[37]` at slots 27-63) stay BYTE-IDENTICAL; V3's first field
 *      lands at ABSOLUTE SLOT 64, after V2's gap. The deployed V2 layout has 26
 *      top-level entries and this one has 29: none removed, 3 appended, nothing
 *      moved. Storage layout (absolute):
 *        Slot 64:      autoRelockRemaining (mapping base)
 *        Slot 65:      autoRelockRefreshedAt (mapping base)
 *        Slots 66-113: __gapV3[48]
 *      `VeHemiLayout` mirrors this layout for the DELEGATECALL libraries and
 *      must change with it.
 *
 *      Auto-relock is a SEPARATE FLAG, never a sentinel written into
 *      `lock.end`: `LockedBalance` keeps its two members, and `lock.end` keeps
 *      its meaning (the stored end, which MAY fall into the past while
 *      auto-relock is enabled). `autoRelockRemaining[tokenId]` is R, the FROZEN
 *      remaining lock duration in SECONDS. `0` means auto-relock is disabled;
 *      any non-zero value means the position is flat AND alive, whatever
 *      `locked[tokenId].end` says.
 */
abstract contract VeHemiStorageV3 is VeHemiStorageV2 {
    // --- State (slot 64) ---

    /// @notice tokenId -> frozen remaining lock duration in seconds (R).
    ///         0 == auto-relock disabled (position decays normally).
    ///         != 0 == position is FLAT (slope 0, weight constant at the
    ///         bucket-mean `slope_real * (R - SIX_DAYS/2)`, NOT
    ///         `slope_real * R`, which overstates it by 2000/435/21 bps at
    ///         R = 3/12/240 buckets) and ALIVE, even if `locked[tokenId].end` is
    ///         in the past.
    /// @dev THE SINGLE SOURCE OF LIVENESS for a flat position. SEVEN "end > now"
    ///      guards consult this, not a fabricated date:
    ///      `VeHemiVoteDelegation.sol::importDelegationsFromLegacy`,
    ///      `VeHemiVoteDelegation.sol::delegateAllFor`,
    ///      `VeHemiVoteDelegation.sol::_getNormalizedLockedInfo`,
    ///      `VeHemi.sol::_delegate`, `VeHemi.sol::withdraw`,
    ///      `VeHemi.sol::increaseAmount` and `VeHemi.sol::increaseUnlockTime`.
    ///      `withdraw` is the most consequential -- without it a flat position
    ///      is simultaneously at full weight and fully liquid. The delegation
    ///      module reads `autoRelockRemaining(id) != 0` itself, so a change to
    ///      R's encoding must change that module too.
    ///
    ///      R is a whole number of SIX_DAYS buckets: enabling sets it to
    ///      `end - grid(now)` (`end` is on the grid), `increaseUnlockTime` to
    ///      `newEnd - grid(now)` (at most MAX_TIME), and a disarm restores
    ///      `end = grid(now) + R`. Each enable/disable episode therefore extends
    ///      `end` by `grid(t_disable) - grid(t_enable)`, which differs from the
    ///      flat time by less than one SIX_DAYS either way; over any sequence of
    ///      episodes the total extension stays below the wall-clock time from
    ///      the first enable to the last disable plus one SIX_DAYS. That is not
    ///      fund-affecting: every second of `end` so obtained is backed by
    ///      lock-up already served, `increaseUnlockTime` reaches the same
    ///      ceiling directly, R is capped at MAX_TIME, and no principal moves.
    mapping(uint256 tokenId => uint64 remaining) public autoRelockRemaining;

    /// @notice tokenId -> the last owner-authenticated heartbeat of an
    ///         auto-relock position; 0 while auto-relock is disabled. Anyone may
    ///         call `retireStaleAutoRelock` from
    ///         `autoRelockRefreshedAt + STALE_FLAT_BUCKETS * SIX_DAYS` on.
    /// @dev Set by `VeHemi.sol::_enableAutoRelock` (reached from
    ///      `enableAutoRelock` and `createLockWithAutoRelock`) and by
    ///      `refreshAutoRelock` ONLY; cleared by `VeHemi.sol::_disarmAutoRelock`
    ///      and `VeHemi.sol::_withdraw`. Deliberately NOT written by
    ///      `increaseAmount` or `increaseUnlockTime`: the heartbeat is the
    ///      explicit owner call.
    mapping(uint256 tokenId => uint64 refreshedAt) public autoRelockRefreshedAt;

    /// @dev Reserved storage slots for future V4+ upgrades.
    uint256[48] private __gapV3;
}

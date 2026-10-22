// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiDelegationStorageV3} from "./VeHemiDelegationStorageV3.sol";
import {IVeHemiVoteDelegationAutoRelock} from "../interfaces/IVeHemiVoteDelegation.sol";

/**
 * @title VeHemiDelegationStorageV4
 * @notice Storage extension for VeHemiVoteDelegation V4 (auto-relock: the booking time of
 *         each delegation record and the upgrade-hour window).
 *
 * @dev Chain-inherits V3 exactly as V3's NatSpec prescribes: new fields land
 *      AFTER slot 99 (absolute), so V1 (slots 0-3), V2 (4-5 + __gapV2[44] at
 *      6-49) and V3 (50 + __gapV3[49] at 51-99) stay BYTE-IDENTICAL. This is
 *      a pure APPEND: the deployed implementation's storage layout (9 entries)
 *      is a strict prefix of this one, and the three appended entries land at
 *      absolute slots 100, 101 and 102. It also inherits
 *      `IVeHemiVoteDelegationAutoRelock`, whose `delegationBookedAt` and
 *      `legacyDatingUntil` getters the public variables below implement.
 *
 *      `delegationBookedAt` is the only per-token record of when a booking takes
 *      effect (checkpoint timestamps are per delegatee). No control flow in
 *      `VeHemiVoteDelegation` reads it -- both legs of a write are dated at the
 *      same instant, so a record is always retired against the value in effect
 *      -- but its getter is public ABI, so its dating must not change. Its
 *      meaning:
 *
 *        LIVE contribution of tokenId read at time t
 *          = delegations[tokenId], at its delegatee, iff delegationBookedAt[tokenId] <= t;
 *          otherwise the record it replaced, at that record's delegatee.
 *        (Exact for a booking, except after an in-window rollback and a
 *        re-forward, see the mapping below; for a removal see the next
 *        paragraph: the old delegatee still counts the token at ts, and inside
 *        the window until the window's end.)
 *
 *      Outside the upgrade-hour window a booking in block time ts stamps ts + 1
 *      and dates both legs at ts + 1, so the token never contributes zero: in its
 *      booking block it still counts at its OLD delegatee. Inside the window both
 *      legs are dated at the window's end. The address(0) cleanup (withdraw,
 *      forfeit, an armed transfer whose move was refused) deletes the record and
 *      its stamp at ts; the removal lands at ts + 1 (at the window's end inside
 *      the window), so the old delegatee counts the token through ts (until the
 *      window's end inside it), except that the removal of an already-expired
 *      decaying record counts 0, is booked at the next hour boundary and changes
 *      no vote.
 *
 *      MIGRATION. A pre-V4 record has `delegationBookedAt == 0`, which reads as
 *      already in effect. That is correct for every record the replaced
 *      implementation booked before the upgrade hour. Those it booked earlier in
 *      the upgrade hour sit only in the pending element until that hour's
 *      boundary B, which is exactly where the upgrade-hour window ends when the
 *      upgrade arms it (an upgrade without the arm ends it at the boundary after
 *      its first `_delegate`: B or a later one), and writes until then are dated
 *      at the window's end too. No backfill is required.
 */
abstract contract VeHemiDelegationStorageV4 is VeHemiDelegationStorageV3, IVeHemiVoteDelegationAutoRelock {
    // --- State (slot 100) ---

    /// @notice The instant at which `delegations[tokenId]` takes effect in its
    ///         delegatee's checkpoint history. It is `block.timestamp + 1` of
    ///         the booking transaction -- NOT the next hour boundary -- except
    ///         inside this proxy's upgrade-hour window (`legacyDatingUntil`),
    ///         where it is the window's end, an hour boundary.
    ///         `VeHemiVoteDelegation.sol::_delegate` writes it on a booking and
    ///         deletes it, together with the record, when VeHemi clears a
    ///         position to address(0) (withdraw, forfeit, or an armed transfer
    ///         whose move was refused).
    ///         Zero means "already in effect" (never delegated, cleared by such
    ///         an address(0) cleanup, which itself takes effect at
    ///         `block.timestamp + 1` or at the window's end, or written by a
    ///         pre-V4 implementation -- except a record the
    ///         hour-boundary-dating implementation this one replaces wrote
    ///         earlier in the upgrade hour, which takes effect only at that
    ///         hour's boundary). After an in-window rollback and a re-forward,
    ///         a stamp written before the rollback can outlive the replaced
    ///         implementation's later rebooking or burn of that id (that
    ///         implementation never writes this slot); it is exact again from
    ///         the id's next booking.
    mapping(uint256 tokenId => uint64 bookedAt) public delegationBookedAt;

    // --- State (slot 101) ---

    /// @notice End of this proxy's UPGRADE-HOUR WINDOW (an hour boundary).
    ///         While the next hour boundary is at or before it, every delegation write is
    ///         dated at that boundary and every vote event is read there -- the dating of
    ///         the hour-boundary implementation this one replaces
    ///         (`VeHemiVoteDelegation.sol::_imm`).
    ///         0 = upgraded from that implementation and never armed (or a fresh proxy before
    ///             `initialize`): window OPEN until the first `_delegate`, which closes it at
    ///             the next boundary;
    ///         1 = fresh deployment, no window (constructor / `initialize`);
    ///         otherwise written by `VeHemiVoteDelegation.sol::armLegacyDatingWindow` inside
    ///         the upgrade's `ProxyAdmin.upgradeAndCall`, or by that first `_delegate`.
    /// @dev    Non-zero for good once written (a window boundary, or sentinel 1). A later
    ///         implementation MUST keep this slot declared (or rename it
    ///         `__deprecatedLegacyDatingUntil`, which
    ///         `test/StorageLayoutOnchainAnchor.t.sol` refuses once it is re-anchored on
    ///         this implementation, until that test is amended) and MUST NEVER reuse slot
    ///         101: it holds a non-zero value on every proxy that ran this implementation.
    uint64 public legacyDatingUntil;

    /// @dev Reserved storage slots for future V5+ upgrades. Slots 102-149.
    uint256[48] private __gapV4;
}

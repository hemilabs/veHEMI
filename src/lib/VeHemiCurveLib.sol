// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IVeHemi} from "../interfaces/IVeHemi.sol";
import {VeHemiStorageV2} from "../storage/VeHemiStorageV2.sol";
import {VeHemiLayout, VeHemiLayoutLib} from "./VeHemiLayout.sol";
import {VeHemiTime} from "./VeHemiTime.sol";

/// @notice External (DELEGATECALL) library holding VeHemi's checkpoint core.
/// @dev `checkpoint` is `external`, so VeHemi reaches it by DELEGATECALL and it
///      reads and writes VeHemi's storage through the slot-0 `VeHemiLayout`
///      mirror.
library VeHemiCurveLib {
    /// @dev Maximum SIX_DAYS buckets a single `checkpoint` catch-up may cover.
    ///      MUST be used by BOTH the loop bound and the truncation clamp -- an
    ///      uncoupled literal silently turns the clamp into dead code. It must
    ///      also stay above MAX_TIME in buckets (240); see the clamp.
    ///      LIVENESS (accepted): every caught-up bucket writes the global point,
    ///      and both subcurve points once seeding is finalized. After hundreds
    ///      of buckets with no checkpointing call to VeHemi the catch-up no
    ///      longer fits in a transaction, and as nothing persists a partial
    ///      catch-up, every lock change, transfer and withdrawal reverts out of
    ///      gas until an upgrade (views keep working). `VeHemi.checkpoint()` is
    ///      permissionless; calling it periodically keeps the catch-up short.
    uint256 private constant CATCHUP_LIMIT = 300;

    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;


    bytes32 private constant ERC721_OWNERS_SLOT =
        bytes32(uint256(0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300) + 2);

    function L() private pure returns (VeHemiLayout storage l) {
        assembly {
            l.slot := 0
        }
    }

    function _ownerOf(uint256 tokenId_) private view returns (address o) {
        bytes32 base = ERC721_OWNERS_SLOT;
        assembly {
            mstore(0x00, tokenId_)
            mstore(0x20, base)
            o := sload(keccak256(0x00, 0x40))
        }
    }

    function checkpoint(
        uint256 tokenId_,
        IVeHemi.LockedBalance memory oldLocked_,
        IVeHemi.LockedBalance memory newLocked_
    ) external {
        IVeHemi.Point memory _oldUserPoint;
        IVeHemi.Point memory _newUserPoint;
        // V2: Curve membership flags (packed into uint8 for stack depth).
        // Bits: [newFlags:4..7][oldFlags:0..3]. Each nibble: 0=transferable, 1=locked, 2=locked+forfeitable.
        // oldFlags: what the position WAS (determines subcurve removal)
        // newFlags: what the position IS NOW (determines subcurve addition)
        uint8 _curveFlags;
        // V2: Subcurve-specific bias deltas (differ from global when transferableAfter < lock.end)
        int128 _oldSubcurveBias;
        int128 _newSubcurveBias;

        // --- Phase A: Compute old/new user points, determine locked/forfeitable status ---
        //
        // Auto-relock (flat) sides, one storage slot for both:
        //   NEW side  <- the storage flag `autoRelockRemaining[tokenId_]`, which
        //                every caller writes BEFORE invoking the checkpoint.
        //   OLD side  <- the LAST PUBLISHED USER POINT, never recomputed. A point
        //                is flat iff (slope == 0 && bias > 0). A decaying point
        //                never matches (its bias is slope * (end - now), 0 when
        //                slope is 0), and a flat one always does: every position
        //                has amount >= MAX_TIME, so slope >= 1 and the flat bias
        //                is > 0 (live V1 positions go down to 2.625e11 wei,
        //                slope 2,079; every post-V2 mint is >= MIN_LOCK_AMOUNT).
        //
        // Flat bits live in the two spare bits of `_curveFlags` (the 0/1/2
        // subcurve nibbles use only bits 0-1 of each nibble):
        //   0x04 = OLD side is flat,  0x40 = NEW side is flat.
        if (tokenId_ != 0) {
            {
                uint256 _ue = L().userPointEpoch[tokenId_];
                if (_ue != 0) {
                    // STORAGE pointer, not a memory copy: `Point.bias` and
                    // `Point.slope` share slot 0, so the discriminator costs
                    // ONE cold SLOAD; a memory copy would read all three slots.
                    IVeHemi.Point storage _prev = L().userPointHistory[tokenId_][_ue].point;
                    int128 _prevBias = _prev.bias;
                    if (_prev.slope == 0 && _prevBias > 0) {
                        _curveFlags |= 0x04;
                        // The SUBCURVE keeps decaying while the global weight
                        // is flat, so the old side carries the real slope for
                        // the subcurve unwind. Every consumer that needs it to
                        // be zero is gated on the 0x04 bit.
                        _oldUserPoint.slope = oldLocked_.amount / VeHemiTime.MAX_TIME.toInt256().toInt128();
                        // PROPAGATE the flat weight. It must NOT be recomputed
                        // from `locked[]`: `oldLocked_.end` is a stored value
                        // that MAY already be in the past.
                        _oldUserPoint.bias = _prevBias;
                    }
                }
            }

            if ((_curveFlags & 0x04) == 0 && oldLocked_.end > block.timestamp && oldLocked_.amount > 0) {
                _oldUserPoint.slope = oldLocked_.amount / VeHemiTime.MAX_TIME.toInt256().toInt128();
                _oldUserPoint.bias =
                    _oldUserPoint.slope *
                    (oldLocked_.end - block.timestamp).toInt256().toInt128();
            }

            uint64 _R = L().autoRelockRemaining[tokenId_];
            if (_R != 0 && newLocked_.amount > 0) {
                // FLAT: the global curve gets no slope for this side (Phase C),
                // so the decay walk never touches its weight.
                _curveFlags |= 0x40;
                // Real slope for the subcurve legs; zeroed again in Phase D
                // before the user point is written (stored flat discriminator).
                _newUserPoint.slope = newLocked_.amount / VeHemiTime.MAX_TIME.toInt256().toInt128();
                // The bucket-mean weight slope * (R - SIX_DAYS/2). SIX_DAYS =
                // 525,960 is even, so SIX_DAYS/2 is exact. `enableAutoRelock`
                // enforces R >= 2 * SIX_DAYS and R only grows while armed, so
                // R - SIX_DAYS/2 >= 3 * SIX_DAYS/2 > 0 cannot underflow.
                _newUserPoint.bias =
                    (newLocked_.amount / VeHemiTime.MAX_TIME.toInt256().toInt128()) *
                    (uint256(_R) - VeHemiTime.SIX_DAYS / 2).toInt256().toInt128();
            } else if (newLocked_.end > block.timestamp && newLocked_.amount > 0) {
                _newUserPoint.slope = newLocked_.amount / VeHemiTime.MAX_TIME.toInt256().toInt128();
                _newUserPoint.bias =
                    _newUserPoint.slope *
                    (newLocked_.end - block.timestamp).toInt256().toInt128();
            }

            if (L().lockedSeedingFinalized && L().transferableAfter[tokenId_] != 0) {
                uint256 _ta = L().transferableAfter[tokenId_];
                bool _isForfeitable = L().forfeitable[tokenId_];

                // Old flags: position was in subcurves if it had active locked data
                // AND was still within the non-transferability window at the old state.
                // We use the old lock's end to determine if the position was previously tracked.
                if ((oldLocked_.end > 0 || (_curveFlags & 0x04) != 0) && oldLocked_.amount > 0 && _ta > block.timestamp) {
                    _curveFlags |= _isForfeitable ? 2 : 1; // old flags in low nibble
                }
                // New flags: position is currently in subcurves if transferableAfter > now
                if (_ta > block.timestamp) {
                    _curveFlags |= (_isForfeitable ? 2 : 1) << 4; // new flags in high nibble
                }

                // AUTO-RELOCK IS INVISIBLE TO THE SUBCURVES. `lock.end >=
                // transferableAfter` for life (`EndBelowTransferableAfter` at
                // every end write), so the subcurve's effective end
                // `min(lock.end, _ta)` is ALWAYS `_ta`, flat or not, and the
                // subcurve is a plain decay to zero at `_ta`.
                //
                // MASK WITH 0x03. Bit 2 (0x04) of the low nibble is the
                // FLATNESS bit, not a membership code; an unmasked `!= 0` here
                // would compute `_ta - block.timestamp` for a flat position
                // whose `_ta` has already passed and underflow.
                if ((_curveFlags & 0x03) != 0) {
                    _oldSubcurveBias =
                        _oldUserPoint.slope * (_ta - block.timestamp).toInt256().toInt128();
                }
                if (((_curveFlags >> 4) & 0x03) != 0) {
                    _newSubcurveBias =
                        _newUserPoint.slope * (_ta - block.timestamp).toInt256().toInt128();
                }
            }
        }

        IVeHemi.Point memory _lastPoint = IVeHemi.Point({
            bias: 0,
            slope: 0,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64(),
            amount: 0,
            fixedBias: 0
        });

        // --- Phases B + C + epoch write ---
        // _epoch and subcurve points scoped here to manage stack depth.
        uint256 _writtenEpoch;
        {
            uint256 _epoch = L().epoch;
            if (_epoch > 0) {
                _lastPoint = L().globalPointHistory[_epoch];
            }

            // V2: Load locked + forfeitable points (only after seeding is finalized)
            VeHemiStorageV2.LockedPoint memory _lastLockedPoint;
            VeHemiStorageV2.LockedPoint memory _lastForfeitablePoint;
            if (_epoch > 0 && L().lockedSeedingFinalized) {
                _lastLockedPoint = L().lockedGlobalPointHistory[_epoch];
                _lastForfeitablePoint = L().forfeitableGlobalPointHistory[_epoch];
            }

            // --- Phase B: Catchup loop — fill history at SIX_DAYS boundaries ---
            {
                uint256 _lastCheckpoint = _lastPoint.timestamp;
                IVeHemi.Point memory _initialLastPoint = IVeHemi.Point({
                    bias: _lastPoint.bias,
                    slope: _lastPoint.slope,
                    timestamp: _lastPoint.timestamp,
                    blockNumber: _lastPoint.blockNumber,
                    amount: _lastPoint.amount,
                    fixedBias: 0
                });
                uint256 _blockSlope;
                if (block.timestamp > _lastPoint.timestamp) {
                    _blockSlope =
                        (VeHemiTime.MULTIPLIER * (block.number - _lastPoint.blockNumber)) /
                        (block.timestamp - _lastPoint.timestamp);
                }

                uint256 t_i = (_lastCheckpoint / VeHemiTime.SIX_DAYS) * VeHemiTime.SIX_DAYS;
                for (uint256 i; i < CATCHUP_LIMIT; ++i) {
                    t_i += VeHemiTime.SIX_DAYS;
                    int128 d_slope;
                    bool _atBoundary = (t_i <= block.timestamp);
                    if (!_atBoundary) {
                        t_i = block.timestamp;
                    } else if (i + 1 == CATCHUP_LIMIT && t_i < block.timestamp) {
                        // TRUNCATION CLAMP. The gap exceeds CATCHUP_LIMIT
                        // buckets, so the loop cannot reach `now`. Without this
                        // branch the head Point would be written with a STALE
                        // timestamp and every later read would re-decay a
                        // correct bias across the phantom gap, corrupting
                        // totalVeHemiSupply(), BOTH subcurves, supplyBreakdown()
                        // and historical totalVeHemiSupplyAt() -- the last of
                        // which is the governance quorum denominator.
                        //
                        // Stamp the head at `now` instead. `_atBoundary` is forced
                        // false so the clamped instant reads no slope-change
                        // bucket: the intermediate retirements are skipped either
                        // way, and consuming only the last one would make the
                        // outcome depend on whether `block.timestamp` collides
                        // with a grid key.
                        //
                        // SOUND ONLY WHILE every live retirement lies within
                        // MAX_TIME of the head (240 of the 300 iterations), so
                        // all of them are consumed before the clamp. That holds
                        // because `lock.end <= now + MAX_TIME` at every write --
                        // INCLUDING under auto-relock, because
                        // `increaseUnlockTime` caps R at MAX_TIME and a disarm
                        // restores `grid(now) + R`.
                        t_i = block.timestamp;
                        _atBoundary = false;
                    } else {
                        d_slope = L().slopeChanges[t_i];
                    }

                    // Global curve decay
                    int128 _dt = (t_i - _lastCheckpoint).toInt256().toInt128();
                    _lastPoint.bias -= _lastPoint.slope * _dt;
                    _lastPoint.slope += d_slope;
                    if (_lastPoint.bias < 0) {
                        _lastPoint.bias = 0;
                    }
                    if (_lastPoint.slope < 0) {
                        _lastPoint.slope = 0;
                    }

                    // V2: Locked + forfeitable curve decay (parallel tracking)
                    // Slope changes read inline (no temp vars) to avoid stack-too-deep.
                    if (L().lockedSeedingFinalized) {
                        _lastLockedPoint.bias -= _lastLockedPoint.slope * _dt;
                        if (_atBoundary) _lastLockedPoint.slope += L().lockedSlopeChanges[t_i];
                        if (_lastLockedPoint.bias < 0) _lastLockedPoint.bias = 0;
                        if (_lastLockedPoint.slope < 0) _lastLockedPoint.slope = 0;
                        _lastLockedPoint.timestamp = t_i.toUint64();

                        _lastForfeitablePoint.bias -= _lastForfeitablePoint.slope * _dt;
                        if (_atBoundary) _lastForfeitablePoint.slope += L().forfeitableSlopeChanges[t_i];
                        if (_lastForfeitablePoint.bias < 0) _lastForfeitablePoint.bias = 0;
                        if (_lastForfeitablePoint.slope < 0) _lastForfeitablePoint.slope = 0;
                        _lastForfeitablePoint.timestamp = t_i.toUint64();
                    }

                    _lastCheckpoint = t_i;
                    _lastPoint.timestamp = t_i.toUint64();
                    _lastPoint.blockNumber = (_initialLastPoint.blockNumber +
                        (_blockSlope * (t_i - _initialLastPoint.timestamp)) /
                        VeHemiTime.MULTIPLIER).toUint64();
                    _epoch += 1;
                    if (t_i == block.timestamp) {
                        _lastPoint.blockNumber = block.number.toUint64();
                        if (L().lockedSeedingFinalized) {
                            _lastLockedPoint.blockNumber = block.number.toUint64();
                            _lastForfeitablePoint.blockNumber = block.number.toUint64();
                        }
                        break;
                    } else {
                        L().globalPointHistory[_epoch] = _lastPoint;
                        if (L().lockedSeedingFinalized) {
                            _lastLockedPoint.blockNumber = _lastPoint.blockNumber;
                            L().lockedGlobalPointHistory[_epoch] = _lastLockedPoint;
                            _lastForfeitablePoint.blockNumber = _lastPoint.blockNumber;
                            L().forfeitableGlobalPointHistory[_epoch] = _lastForfeitablePoint;
                        }
                    }
                }
            }

            // --- Phase C: Apply user delta to global + locked + forfeitable points ---
            // V2: Subcurve deltas use separate old/new flags and subcurve-specific biases.
            //     oldFlags (low nibble of _curveFlags): determines removal from subcurves
            //     newFlags (high nibble of _curveFlags): determines addition to subcurves
            //     Subcurve biases use transferableAfter as the effective end.
            if (tokenId_ != 0) {
                // A flat side contributes NO slope and NO bias to the decaying
                // global curve. The global constant-weight aggregate lives in
                // the global point's `amount` instead: only user points use
                // that field otherwise, it is packed into a slot every appended
                // epoch rewrites anyway, and it rides through the Phase-B walk
                // untouched -- the "does not decay" semantics a flat position
                // needs. `Point.fixedBias` is NOT used for it: that would be a
                // whole extra slot per appended epoch.
                _lastPoint.slope +=
                    ((_curveFlags & 0x40) != 0 ? int128(0) : _newUserPoint.slope) -
                    ((_curveFlags & 0x04) != 0 ? int128(0) : _oldUserPoint.slope);
                _lastPoint.bias +=
                    ((_curveFlags & 0x40) != 0 ? int128(0) : _newUserPoint.bias) -
                    ((_curveFlags & 0x04) != 0 ? int128(0) : _oldUserPoint.bias);
                if (_lastPoint.slope < 0) {
                    _lastPoint.slope = 0;
                }
                if (_lastPoint.bias < 0) {
                    _lastPoint.bias = 0;
                }
                if ((_curveFlags & 0x44) != 0) {
                    int256 _flat = int256(uint256(_lastPoint.amount)) +
                        ((_curveFlags & 0x40) != 0 ? int256(_newUserPoint.bias) : int256(0)) -
                        ((_curveFlags & 0x04) != 0 ? int256(_oldUserPoint.bias) : int256(0));
                    _lastPoint.amount = (_flat < 0 ? uint256(0) : uint256(_flat)).toUint128();
                }

                // V2: Locked curve — apply old removal + new addition separately
                uint8 _oldFlags = _curveFlags & 0x0F;
                uint8 _newFlags = (_curveFlags >> 4) & 0x0F;
                if ((_oldFlags & 0x03) >= 1 || (_newFlags & 0x03) >= 1) {
                    // Slope delta is same as global (slope = amount/MAX_TIME, independent of end)
                    // Bias delta uses subcurve-specific values (bounded by transferableAfter)
                    // No flat routing: the subcurve takes the real slope and the
                    // decaying bias on BOTH sides.
                    int128 _slopeDelta;
                    if ((_newFlags & 0x03) >= 1) _slopeDelta += _newUserPoint.slope;
                    if ((_oldFlags & 0x03) >= 1) _slopeDelta -= _oldUserPoint.slope;
                    _lastLockedPoint.slope += _slopeDelta;
                    _lastLockedPoint.bias +=
                        ((_newFlags & 0x03) == 0 ? int128(0) : _newSubcurveBias) -
                        ((_oldFlags & 0x03) == 0 ? int128(0) : _oldSubcurveBias);
                    if (_lastLockedPoint.slope < 0) _lastLockedPoint.slope = 0;
                    if (_lastLockedPoint.bias < 0) _lastLockedPoint.bias = 0;

                    // Forfeitable curve — same logic, only for flags == 2.
                    // Every comparison MUST mask with 0x03: bit 2 (0x04) of each
                    // nibble is the flatness bit, so a flat forfeitable position
                    // has a nibble of 6, and an unmasked `== 2` would leave the
                    // forfeitable subcurve unaware of it.
                    if ((_oldFlags & 0x03) == 2 || (_newFlags & 0x03) == 2) {
                        int128 _forfSlopeDelta;
                        if ((_newFlags & 0x03) == 2) _forfSlopeDelta += _newUserPoint.slope;
                        if ((_oldFlags & 0x03) == 2) _forfSlopeDelta -= _oldUserPoint.slope;
                        _lastForfeitablePoint.slope += _forfSlopeDelta;
                        _lastForfeitablePoint.bias +=
                            ((_newFlags & 0x03) != 2 ? int128(0) : _newSubcurveBias) -
                            ((_oldFlags & 0x03) != 2 ? int128(0) : _oldSubcurveBias);
                        if (_lastForfeitablePoint.slope < 0) _lastForfeitablePoint.slope = 0;
                        if (_lastForfeitablePoint.bias < 0) _lastForfeitablePoint.bias = 0;
                    }
                }
            }

            // Write global + locked + forfeitable points (same overwrite-vs-append logic)
            if (_epoch != 1 && L().globalPointHistory[_epoch - 1].timestamp == block.timestamp) {
                _writtenEpoch = _epoch - 1;
                L().globalPointHistory[_writtenEpoch] = _lastPoint;
                if (L().lockedSeedingFinalized) {
                    L().lockedGlobalPointHistory[_writtenEpoch] = _lastLockedPoint;
                    L().forfeitableGlobalPointHistory[_writtenEpoch] = _lastForfeitablePoint;
                }
            } else {
                _writtenEpoch = _epoch;
                L().epoch = _epoch;
                L().globalPointHistory[_epoch] = _lastPoint;
                if (L().lockedSeedingFinalized) {
                    L().lockedGlobalPointHistory[_epoch] = _lastLockedPoint;
                    L().forfeitableGlobalPointHistory[_epoch] = _lastForfeitablePoint;
                }
            }
        }

        // --- Phase D: Schedule slope changes + write user point ---
        if (tokenId_ != 0) {
            _scheduleSlopeChanges(tokenId_, oldLocked_, newLocked_, _oldUserPoint, _newUserPoint, _curveFlags);

            // The STORED user point must keep `slope == 0` for a flat position:
            // that pair (`slope == 0 && bias > 0`) IS the flat discriminator
            // Phase A reads back on the next touch, and the one
            // `VeHemiVoteDelegation` reads through `getUserPoint`. The real
            // slope above exists only for the subcurve legs, which have
            // already run inside `_scheduleSlopeChanges`.
            if ((_curveFlags & 0x40) != 0) _newUserPoint.slope = 0;
            _newUserPoint.timestamp = block.timestamp.toUint64();
            _newUserPoint.blockNumber = block.number.toUint64();
            _newUserPoint.amount = L().locked[tokenId_].amount.toUint256().toUint128();
            uint256 _userEpoch = L().userPointEpoch[tokenId_];
            if (
                _userEpoch == 0 ||
                L().userPointHistory[tokenId_][_userEpoch].point.timestamp != block.timestamp
            ) {
                L().userPointEpoch[tokenId_] = ++_userEpoch;
            }

            L().userPointHistory[tokenId_][_userEpoch].point = _newUserPoint;
            L().userPointHistory[tokenId_][_userEpoch].owner = _ownerOf(tokenId_);
        }
        emit IVeHemi.Checkpoint(_writtenEpoch, tokenId_, oldLocked_, newLocked_);
    }

    /**
     * @dev Schedules slope changes for global, locked, and forfeitable curves.
     *      Extracted from `checkpoint` to manage stack depth (Phase D). Each
     *      curve's cancel/schedule pair is delegated to `_adjustSlopeChange`
     *      via a `mapping storage` parameter so the global, locked, and
     *      forfeitable retire-then-schedule logic shares one bytecode body.
     *
     *      V2: For subcurves, the effective endpoint is `transferableAfter`
     *      (<= lock.end for life): the subcurve slope change fires at
     *      transferableAfter (when the position exits the subcurve), not at
     *      lock.end, whether the lock was extended or is auto-relocking.
     *
     *      Flag encoding (per nibble): 0 = transferable (global only, no subcurves),
     *                                  1 = non-transferable (global + locked subcurve),
     *                                  2 = non-transferable + forfeitable (all three curves).
     *      Bit 2 of each nibble is the auto-relock flatness bit (see `checkpoint`).
     *      The packing uses: `[newFlags:4..7][oldFlags:0..3]`. Old flags describe what
     *      subcurves the position WAS tracked in (what to unwind); new flags describe
     *      what subcurves it is tracked in NOW (what to apply). The transitions are
     *      monotonically non-increasing over a position's lifetime:
     *        - 2 → removed by the burn in `forfeit`, the only burn before
     *          `transferableAfter` (the new side has zero weight; the flags are
     *          deleted after this checkpoint). A `withdraw` needs
     *          `lock.end <= block.timestamp` and `lock.end >= transferableAfter`,
     *          so the position has already made the transition below.
     *        - 1 or 2 → 0 when `block.timestamp >= transferableAfter` (subcurve exit,
     *          global weight retained until lock.end)
     *
     * @param curveFlags_ Packed old/new flags: [newFlags:4..7][oldFlags:0..3]
     */
    function _scheduleSlopeChanges(
        uint256 tokenId_,
        IVeHemi.LockedBalance memory oldLocked_,
        IVeHemi.LockedBalance memory newLocked_,
        IVeHemi.Point memory _oldUserPoint,
        IVeHemi.Point memory _newUserPoint,
        uint8 curveFlags_
    ) private {
        // A FLAT side has NO global retirement bucket: its weight is constant
        // until auto-relock is disabled. Passing `inCurve_ == false` for a flat
        // side is what makes ENABLE cancel the outgoing slope without
        // re-scheduling it, and what makes DISABLE schedule the restored slope
        // even when the restored end equals the stored `lock.end` (e.g. a
        // disable in the bucket auto-relock was enabled in).
        bool _oldLive = (curveFlags_ & 0x04) == 0;
        bool _newLive = (curveFlags_ & 0x40) == 0;
        uint8 _oldFlags = curveFlags_ & 0x0F;
        uint8 _newFlags = (curveFlags_ >> 4) & 0x0F;

        // Global slope-changes — every live DECAYING position participates.
        // Out-of-range ends (`end <= block.timestamp`) are skipped by the
        // helper's internal gates, matching the prior behavior.
        _adjustSlopeChange(
            L().slopeChanges,
            oldLocked_.end, newLocked_.end,
            _oldUserPoint.slope, _newUserPoint.slope,
            _oldLive, _newLive
        );

        // Subcurves are bounded by transferableAfter. Compute effective
        // ends only when at least one side of the transition participates
        // in any subcurve — the SLOAD of `transferableAfter[tokenId_]` is
        // wasted work if both flags are 0 (pure transferable lock).
        if ((_oldFlags & 0x03) >= 1 || (_newFlags & 0x03) >= 1) {
            // ONE endpoint for both sides -- `transferableAfter`, frozen at mint
            // and <= `lock.end` for life -- so cancel and schedule fold into a
            // SINGLE SSTORE. The flatness gates (`_oldLive` / `_newLive`) are
            // deliberately NOT consulted: an auto-relock position still decays
            // out of its subcurves on schedule.
            uint256 _ta = L().transferableAfter[tokenId_];
            _adjustSlopeChange(
                L().lockedSlopeChanges,
                _ta, _ta,
                _oldUserPoint.slope, _newUserPoint.slope,
                (_oldFlags & 0x03) >= 1, (_newFlags & 0x03) >= 1
            );
            _adjustSlopeChange(
                L().forfeitableSlopeChanges,
                _ta, _ta,
                _oldUserPoint.slope, _newUserPoint.slope,
                (_oldFlags & 0x03) == 2, (_newFlags & 0x03) == 2
            );
        }
    }

    /// @dev Adjusts slope-change entries for ONE curve at one or two
    ///      endpoints. Cancels the old retirement at `oldEnd_` (if
    ///      `oldInCurve_` and the bucket hasn't passed) and schedules the
    ///      new retirement at `newEnd_` (if `newInCurve_` and the bucket
    ///      is still in the future). When the old and new endpoints
    ///      collide, the cancel and schedule fold into a single SSTORE.
    ///
    ///      `mapping storage` parameter compiles to slot-offset access (no
    ///      extra SLOAD vs inline) and lets the global + locked +
    ///      forfeitable curves share one bytecode body.
    /// @param slopeChanges_ Slope-change mapping for the curve.
    /// @param oldEnd_ Old retirement timestamp (0 if the position had no
    ///        prior contribution to this curve).
    /// @param newEnd_ New retirement timestamp (0 if the position is
    ///        leaving this curve).
    /// @param oldSlope_ Slope being retired at `oldEnd_`.
    /// @param newSlope_ Slope being scheduled at `newEnd_`.
    /// @param oldInCurve_ Whether the position previously participated in
    ///        this curve.
    /// @param newInCurve_ Whether the position now participates in this
    ///        curve.
    function _adjustSlopeChange(
        mapping(uint256 => int128) storage slopeChanges_,
        uint256 oldEnd_,
        uint256 newEnd_,
        int128 oldSlope_,
        int128 newSlope_,
        bool oldInCurve_,
        bool newInCurve_
    ) private {
        // Cancel old retirement (and fold a same-end schedule into the
        // same SSTORE when endpoints collide).
        if (oldInCurve_ && oldEnd_ > block.timestamp) {
            int128 _delta = oldSlope_;
            if (newInCurve_ && newEnd_ == oldEnd_) {
                _delta -= newSlope_;
            }
            // Skip the no-op SSTORE when the fold cancels out (every transfer
            // reaches `checkpoint(id, lock, lock)`): semantically `x += 0`.
            if (_delta != 0) {
                slopeChanges_[oldEnd_] += _delta;
            }
        }

        // Schedule the new retirement at a still-future endpoint. The only
        // case that must be skipped is the one the cancel branch above already
        // folded in: the position WAS in this curve and the endpoint is
        // unchanged. (A `newEnd_ > oldEnd_` guard would also drop the schedule
        // for a position entering the curve at or before its old end, such as
        // a disable whose restored end equals the stored end.)
        if (newInCurve_ && newEnd_ > block.timestamp && !(oldInCurve_ && newEnd_ == oldEnd_)) {
            slopeChanges_[newEnd_] -= newSlope_;
        }
    }

}

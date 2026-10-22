// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IVeHemi} from "../interfaces/IVeHemi.sol";
import {VeHemiStorageV2} from "../storage/VeHemiStorageV2.sol";
import {VeHemiLayout} from "./VeHemiLayout.sol";
import {VeHemiTime} from "./VeHemiTime.sol";

/// @notice External (DELEGATECALL) library holding VeHemi's read-only supply
///         and balance projection machinery. Executes in VeHemi's storage
///         context via the slot-0-anchored `VeHemiLayout` mirror.
library VeHemiSupplyLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    function _s() private pure returns (VeHemiLayout storage l) {
        assembly {
            l.slot := 0
        }
    }

    function balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256, address) {
        VeHemiLayout storage $ = _s();
        uint256 _epoch = _getPastUserPointIndex($, tokenId_, timestamp_);
        if (_epoch == 0) return (0, address(0));
        IVeHemi.UserPoint memory _lastUserPoint = $.userPointHistory[tokenId_][_epoch];
        _lastUserPoint.point.bias -=
            _lastUserPoint.point.slope *
            (timestamp_ - _lastUserPoint.point.timestamp).toInt256().toInt128();
        if (_lastUserPoint.point.bias < 0) {
            _lastUserPoint.point.bias = 0;
        }
        return (_lastUserPoint.point.bias.toUint256(), _lastUserPoint.owner);
    }

    function _getPastGlobalPointIndex(
        VeHemiLayout storage $,
        uint256 epoch_,
        uint256 timestamp_
    ) private view returns (uint256) {
        if (epoch_ == 0) return 0;
        if ($.globalPointHistory[epoch_].timestamp <= timestamp_) return (epoch_);
        if ($.globalPointHistory[1].timestamp > timestamp_) return 0;

        uint256 _lower;
        uint256 _upper = epoch_;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2;
            IVeHemi.Point memory _globalPoint = $.globalPointHistory[_center];
            if (_globalPoint.timestamp == timestamp_) {
                return _center;
            } else if (_globalPoint.timestamp < timestamp_) {
                _lower = _center;
            } else {
                _upper = _center - 1;
            }
        }
        return _lower;
    }

    function _getPastUserPointIndex(
        VeHemiLayout storage $,
        uint256 tokenId_,
        uint256 timestamp_
    ) private view returns (uint256) {
        uint256 _userEpoch = $.userPointEpoch[tokenId_];
        if (_userEpoch == 0) return 0;
        IVeHemi.Point memory _lastPoint = $.userPointHistory[tokenId_][_userEpoch].point;
        if (_lastPoint.timestamp <= timestamp_) return (_userEpoch);
        if ($.userPointHistory[tokenId_][1].point.timestamp > timestamp_) return 0;

        uint256 _lower;
        uint256 _upper = _userEpoch;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2;
            IVeHemi.Point memory _userPoint = $.userPointHistory[tokenId_][_center].point;
            if (_userPoint.timestamp == timestamp_) {
                return _center;
            } else if (_userPoint.timestamp < timestamp_) {
                _lower = _center;
            } else {
                _upper = _center - 1;
            }
        }
        return _lower;
    }

    function _walkCurve(
        int128 bias_,
        int128 slope_,
        uint256 ts_,
        uint256 timestamp_,
        mapping(uint256 => int128) storage slopeChanges_
    ) private view returns (uint256) {
        uint256 t_i = (ts_ / VeHemiTime.SIX_DAYS) * VeHemiTime.SIX_DAYS;
        for (uint256 i; i < 255; ++i) {
            t_i += VeHemiTime.SIX_DAYS;
            int128 dSlope = 0;
            if (t_i >= timestamp_) {
                t_i = timestamp_;
            } else {
                dSlope = slopeChanges_[t_i];
            }
            bias_ -= slope_ * (t_i - ts_).toInt256().toInt128();
            if (t_i == timestamp_) {
                break;
            }
            slope_ += dSlope;
            if (slope_ < 0) slope_ = 0;
            ts_ = t_i;
        }

        if (bias_ < 0) bias_ = 0;
        return bias_.toUint256();
    }

    function _subcurveSupplyAtFromPoint(
        VeHemiLayout storage $,
        VeHemiStorageV2.LockedPoint memory point_,
        uint256 timestamp_,
        bool isForfeitable_
    ) private view returns (uint256) {
        return
            _walkCurve(
                point_.bias,
                point_.slope,
                point_.timestamp,
                timestamp_,
                isForfeitable_ ? $.forfeitableSlopeChanges : $.lockedSlopeChanges
            );
    }

    function supplyAt(uint256 timestamp_) external view returns (uint256) {
        VeHemiLayout storage $ = _s();
        uint256 _epoch = _getPastGlobalPointIndex($, $.epoch, timestamp_);
        if (_epoch == 0) return 0;
        IVeHemi.Point memory _point = $.globalPointHistory[_epoch];
        // On a GLOBAL point `amount` is the aggregate CONSTANT weight of every
        // auto-relock position. It is not part of (bias, slope), so it is
        // added after the walk and never decays; historical reads are exact
        // because every appended epoch carries the value in force at it.
        return
            _walkCurve(_point.bias, _point.slope, _point.timestamp, timestamp_, $.slopeChanges) +
            _point.amount;
    }

    function subcurveSupplyAt(uint256 timestamp_, bool isForfeitable_) external view returns (uint256) {
        VeHemiLayout storage $ = _s();
        uint256 _epoch = _getPastGlobalPointIndex($, $.epoch, timestamp_);
        if (_epoch == 0) return 0;
        VeHemiStorageV2.LockedPoint memory _point = isForfeitable_
            ? $.forfeitableGlobalPointHistory[_epoch]
            : $.lockedGlobalPointHistory[_epoch];
        if (_point.timestamp == 0) return 0;
        return _subcurveSupplyAtFromPoint($, _point, timestamp_, isForfeitable_);
    }

    function supplyBreakdown()
        external
        view
        returns (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable)
    {
        VeHemiLayout storage $ = _s();
        uint256 _epoch = _getPastGlobalPointIndex($, $.epoch, block.timestamp);
        if (_epoch == 0) return (0, 0, 0, 0);
        IVeHemi.Point memory _gp = $.globalPointHistory[_epoch];
        total =
            _walkCurve(_gp.bias, _gp.slope, _gp.timestamp, block.timestamp, $.slopeChanges) +
            _gp.amount;

        VeHemiStorageV2.LockedPoint memory _lp = $.lockedGlobalPointHistory[_epoch];
        if (_lp.timestamp != 0) {
            locked_ = _subcurveSupplyAtFromPoint($, _lp, block.timestamp, false);
        }

        VeHemiStorageV2.LockedPoint memory _rp = $.forfeitableGlobalPointHistory[_epoch];
        if (_rp.timestamp != 0) {
            forfeitable_ = _subcurveSupplyAtFromPoint($, _rp, block.timestamp, true);
        }

        // `locked_` and `forfeitable_` are returned RAW, identical to
        // `nonTransferableTotalVeHemiSupply` / `forfeitableTotalVeHemiSupply`.
        // `forfeitable_ <= locked_` is structural: the forfeitable subcurve
        // takes the locked one's per-event deltas over a subset of its members
        // (`VeHemiCurveLib.sol::checkpoint`, Phase C) and both clamp at zero at
        // the same sites. `locked_ <= total` does NOT hold: an auto-relock
        // member counts its constant weight `slope * (R - SIX_DAYS/2)` in
        // `total` but its decaying `slope * (transferableAfter - now)` in
        // `locked_`, which is larger by up to `slope * SIX_DAYS/2` when the
        // position was armed (or its amount or term last changed) in the first
        // half of a bucket, until the middle of that bucket. So `transferable`,
        // the one subtraction, saturates at 0. The amount it absorbs is at most
        // SUM(slope_i) * SIX_DAYS/2 over those members, which is at most a third
        // of the global constant aggregate `_gp.amount` because R >= 2 * SIX_DAYS.
        transferable = total > locked_ ? total - locked_ : 0;
    }
}

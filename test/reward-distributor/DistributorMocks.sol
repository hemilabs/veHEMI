// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

interface IWeightSource {
    function balanceOfNFT(uint256 tokenId_) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId_, uint256 timestamp_) external view returns (uint256);
}

/// @notice Counts updateRewards() calls, globally and per token, and records the
///         weight VeHemi's own view reported AT THE INSTANT OF EACH CALL.
contract CountingDistributor is IRewardDistributor {
    IWeightSource public immutable ve;
    uint256[] public seenWeights;
    uint256[] public seenTimes;

    /// @dev PER-TOKEN weight log. The global `seenWeights` array cannot
    ///      support an ORDERING assertion when more than one position is live
    ///      in the universe, and the ordering of the bracket -- notify-BEFORE
    ///      must observe w-, notify-AFTER must observe w+ -- is exactly what
    ///      the before/after notification call sites are FOR. Without this the count
    ///      assertion alone cannot distinguish `_updateReward` placed after
    ///      `_checkpoint` from `_updateReward` placed before it, and a hook
    ///      moved to the wrong side of the weight write is a silent no-op.
    mapping(uint256 => uint256[]) internal _weightsFor;
    mapping(uint256 => uint256[]) internal _timesFor;

    constructor(address ve_) {
        ve = IWeightSource(ve_);
    }

    function updateRewards(uint256 tokenId_) external override {
        uint256 w = ve.balanceOfNFT(tokenId_);
        seenWeights.push(w);
        seenTimes.push(block.timestamp);
        _weightsFor[tokenId_].push(w);
        _timesFor[tokenId_].push(block.timestamp);
    }

    function notificationCount() external view returns (uint256) {
        return seenWeights.length;
    }

    function notificationCountFor(uint256 tokenId_) external view returns (uint256) {
        return _weightsFor[tokenId_].length;
    }

    function weightAtNotification(uint256 tokenId_, uint256 index_) external view returns (uint256) {
        return _weightsFor[tokenId_][index_];
    }

    function timeOfNotification(uint256 tokenId_, uint256 index_) external view returns (uint256) {
        return _timesFor[tokenId_][index_];
    }
}

/// @notice THE TRAPEZOID INTEGRATOR. A checkpoint-on-touch reward
///         distributor: it accrues `∫ weight dt` by assuming the weight
///         trajectory between two consecutive notifications is the straight
///         line through the two OBSERVED endpoints, and integrating that line
///         exactly.
///
///         That assumption is not arbitrary — it is precisely what the
///         `IRewardDistributor.updateRewards` hook buys a distributor. On a
///         contract where every operation that changes `amount` or `end`
///         notifies first, a position's weight IS linear between
///         notifications, so the trapezoid is EXACT. Every wei-second of error
///         this contract reports is therefore an unannounced kink.
///
///         Units: wei-seconds.
contract TrapezoidIntegratorDistributor is IRewardDistributor {
    IWeightSource public immutable ve;
    mapping(uint256 => uint256) public lastTimestamp;
    mapping(uint256 => uint256) public lastWeight;
    mapping(uint256 => bool) public hasLastObservation;
    mapping(uint256 => uint256) public accrued;
    uint256 public calls;

    constructor(address ve_) {
        ve = IWeightSource(ve_);
    }

    function updateRewards(uint256 tokenId_) public override {
        calls += 1;
        uint256 w = ve.balanceOfNFT(tokenId_);
        if (hasLastObservation[tokenId_]) {
            uint256 dt = block.timestamp - lastTimestamp[tokenId_];
            if (dt != 0) {
                accrued[tokenId_] += ((lastWeight[tokenId_] + w) * dt) / 2;
            }
        } else {
            hasLastObservation[tokenId_] = true;
        }
        lastTimestamp[tokenId_] = block.timestamp;
        lastWeight[tokenId_] = w;
    }
}

/// @notice A hostile distributor that re-enters VeHemi from inside
///         `updateRewards`. The notify-after calls run AFTER all state is
///         settled in `enableAutoRelock` / `disableAutoRelock`, so the
///         re-entrancy surface is tested, not assumed.
contract ReentrantDistributor is IRewardDistributor {
    address public immutable ve;
    bytes public payload;
    uint256 public attempts;
    bool public lastInnerOk;
    bool public reentryPending;

    constructor(address ve_) {
        ve = ve_;
    }

    function setReentry(bytes calldata payload_) external {
        payload = payload_;
        reentryPending = true;
    }

    function updateRewards(uint256) external override {
        if (!reentryPending) return;
        reentryPending = false; // one shot
        attempts += 1;
        (bool ok, ) = ve.call(payload);
        lastInnerOk = ok;
    }
}

/// @notice A per-bucket catch-up distributor, the shape veCRV-style fee
///         distributors actually have: on each touch it walks forward one
///         SIX_DAYS bucket at a time from where it left off. Its gas is linear
///         in the number of buckets since the last touch, so a position that
///         sends no transaction for years is not merely under-served — its
///         next touch gets more expensive without bound.
contract CatchUpDistributor is IRewardDistributor {
    uint256 public constant BUCKET_LENGTH = 525960;
    IWeightSource public immutable ve;
    mapping(uint256 => uint256) public cursor; // bucket index
    mapping(uint256 => uint256) public credited;
    uint256 public lastIterations;
    /// @dev Sum of `lastIterations` over every call: one transaction can
    ///      notify twice (before and after the weight write), and the second
    ///      call, with the cursor already current, resets `lastIterations`.
    uint256 public totalIterations;
    bool public priceAtHistoricalWeight;

    constructor(address ve_, bool priceAtHistoricalWeight_) {
        ve = IWeightSource(ve_);
        priceAtHistoricalWeight = priceAtHistoricalWeight_;
    }

    function updateRewards(uint256 tokenId_) external override {
        uint256 currentBucket = block.timestamp / BUCKET_LENGTH;
        uint256 bucket = cursor[tokenId_];
        if (bucket == 0) {
            cursor[tokenId_] = currentBucket;
            lastIterations = 0;
            return;
        }
        uint256 w = ve.balanceOfNFT(tokenId_);
        uint256 iterations;
        uint256 sum;
        while (bucket < currentBucket) {
            // `priceAtHistoricalWeight` is the historically-faithful shape:
            // price each bucket at the weight the position actually had in it.
            sum += priceAtHistoricalWeight ? ve.balanceOfNFTAt(tokenId_, bucket * BUCKET_LENGTH) : w;
            unchecked { ++bucket; ++iterations; }
        }
        credited[tokenId_] += sum;
        cursor[tokenId_] = currentBucket;
        lastIterations = iterations;
        totalIterations += iterations;
    }
}

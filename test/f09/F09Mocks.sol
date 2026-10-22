// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";

interface IWeightSource {
    function balanceOfNFT(uint256 tokenId_) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId_, uint256 timestamp_) external view returns (uint256);
}

/// @notice Counts updateRewards() calls, globally and per token, and records the
///         weight VeHemi's own view reported AT THE INSTANT OF EACH CALL.
contract F09Counter is IRewardDistributor {
    IWeightSource public immutable ve;
    uint256 public calls;
    mapping(uint256 => uint256) public callsFor;
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
        calls += 1;
        callsFor[tokenId_] += 1;
        uint256 w = ve.balanceOfNFT(tokenId_);
        seenWeights.push(w);
        seenTimes.push(block.timestamp);
        _weightsFor[tokenId_].push(w);
        _timesFor[tokenId_].push(block.timestamp);
    }

    function nSeen() external view returns (uint256) {
        return seenWeights.length;
    }

    function nSeenFor(uint256 tokenId_) external view returns (uint256) {
        return _weightsFor[tokenId_].length;
    }

    function weightAt(uint256 tokenId_, uint256 k) external view returns (uint256) {
        return _weightsFor[tokenId_][k];
    }

    function timeAt(uint256 tokenId_, uint256 k) external view returns (uint256) {
        return _timesFor[tokenId_][k];
    }
}

/// @notice THE PROBE. A checkpoint-on-touch reward distributor: it accrues
///         `∫ weight dt` by assuming the weight trajectory between two
///         consecutive notifications is the straight line through the two
///         OBSERVED endpoints, and integrating that line exactly.
///
///         That assumption is not arbitrary — it is precisely what the
///         `IRewardDistributor.updateRewards` hook buys a distributor. On a
///         contract where every operation that changes `amount` or `end`
///         notifies first, a position's weight IS linear between
///         notifications, so the trapezoid is EXACT. Every wei-second of error
///         this contract reports is therefore an unannounced kink.
///
///         Units: wei-seconds.
contract F09SegmentIntegrator is IRewardDistributor {
    IWeightSource public immutable ve;
    mapping(uint256 => uint256) public lastTs;
    mapping(uint256 => uint256) public lastW;
    mapping(uint256 => bool) public seeded;
    mapping(uint256 => uint256) public accrued;
    uint256 public calls;

    constructor(address ve_) {
        ve = IWeightSource(ve_);
    }

    function updateRewards(uint256 tokenId_) public override {
        calls += 1;
        uint256 w = ve.balanceOfNFT(tokenId_);
        if (seeded[tokenId_]) {
            uint256 dt = block.timestamp - lastTs[tokenId_];
            if (dt != 0) {
                accrued[tokenId_] += ((lastW[tokenId_] + w) * dt) / 2;
            }
        } else {
            seeded[tokenId_] = true;
        }
        lastTs[tokenId_] = block.timestamp;
        lastW[tokenId_] = w;
    }

    /// @dev Off-contract poke, used to build the REFERENCE trajectory: the
    ///      accrual a distributor would have computed had VeHemi notified it
    ///      at the instant in question. Identical body to updateRewards; it
    ///      exists only so a test can distinguish contract-issued notifications
    ///      from test-issued ones.
    function poke(uint256 tokenId_) external {
        updateRewards(tokenId_);
    }
}

/// @notice A hostile distributor that re-enters VeHemi from inside
///         `updateRewards`. The notify-after calls run AFTER all state is
///         settled in `enableAutoRelock` / `disableAutoRelock`, so the
///         re-entrancy surface is tested, not assumed.
contract F09Reentrant is IRewardDistributor {
    address public immutable ve;
    bytes public payload;
    uint256 public attempts;
    bool public lastInnerOk;
    bool public armed;

    constructor(address ve_) {
        ve = ve_;
    }

    function arm(bytes calldata payload_) external {
        payload = payload_;
        armed = true;
    }

    function updateRewards(uint256) external override {
        if (!armed) return;
        armed = false; // one shot
        attempts += 1;
        (bool ok, ) = ve.call(payload);
        lastInnerOk = ok;
    }
}

/// @notice A per-epoch catch-up distributor, the shape veCRV-style fee
///         distributors actually have: on each touch it walks forward one
///         SIX_DAYS epoch at a time from where it left off. Its gas is linear
///         in the number of epochs since the last touch, so a position that
///         sends no transaction for years is not merely under-served — its
///         next touch gets more expensive without bound.
contract F09CatchUp is IRewardDistributor {
    uint256 public constant EPOCH = 525960;
    IWeightSource public immutable ve;
    mapping(uint256 => uint256) public cursor; // epoch index
    mapping(uint256 => uint256) public credited;
    uint256 public lastIterations;
    /// @dev Sum of `lastIterations` over every call: one transaction can
    ///      notify twice (before and after the weight write), and the second
    ///      call, with the cursor already current, resets `lastIterations`.
    uint256 public totalIterations;
    bool public heavy;

    constructor(address ve_, bool heavy_) {
        ve = IWeightSource(ve_);
        heavy = heavy_;
    }

    function updateRewards(uint256 tokenId_) external override {
        uint256 nowE = block.timestamp / EPOCH;
        uint256 c = cursor[tokenId_];
        if (c == 0) {
            cursor[tokenId_] = nowE;
            lastIterations = 0;
            return;
        }
        uint256 w = ve.balanceOfNFT(tokenId_);
        uint256 it;
        uint256 sum;
        while (c < nowE) {
            // `heavy` is the historically-faithful shape: price each epoch at
            // the weight the position actually had in it.
            sum += heavy ? ve.balanceOfNFTAt(tokenId_, c * EPOCH) : w;
            unchecked { ++c; ++it; }
        }
        credited[tokenId_] += sum;
        cursor[tokenId_] = nowE;
        lastIterations = it;
        totalIterations += it;
    }
}

/// @notice Reverts on every notification, with a custom error. Used to prove
///         the notify-after call sites (which run after all state is settled)
///         survive a broken distributor, as `RevertingRewardDistributor` does
///         for `createLock` and `increaseAmount`.
///
///         It cannot count its own calls: the counter SSTORE would be rolled
///         back with the revert. The call count is recovered from the
///         `RewardUpdateFailed` log instead, which is the same thing an
///         off-chain observer would have to do.
contract F09Reverting is IRewardDistributor {
    error F09Always();

    function updateRewards(uint256) external pure override {
        revert F09Always();
    }
}

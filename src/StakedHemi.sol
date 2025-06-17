// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * StakedHemi ( aka stHEMI) is a vesting and yield system based off of Curve’s veCRV mechanism.
 * Users may lock up their HEMI for up to 4 years for four times the amount of stHEMI (e.g. 100 HEMI locked for 4 years returns 400 stHEMI).
 * stHEMI is not a transferable token nor does it trade on liquid markets.
 * It is more akin to an account based point system that signifies the vesting duration of the wallet's locked HEMI tokens within the protocol.
 * The stHEMI balance linearly decreases as tokens approach their lock expiry, approaching 1 stHEMI per 1 HEMI at zero lock time remaining.
 * This encourages long-term staking and an active community.
 * User can create only lock position. Protocol will not allow to create more than 5 lock positions.
 * If a lock already created then user can only increase the amount of HEMI locked and/or increase the lock duration.
 * The lock duration can be set between 30 days and 4 years.
 * Anyone can deposit for someone else, but cannot extend their locktime and deposit for a brand new user
 * @title StakedHemi
 * @author
 * @notice
 */
contract StakedHemi is OwnableUpgradeable {
    // --- Types ---
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
        uint256 hemiAmt;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    // --- Constants ---
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 4 * 365 days; // 4 years
    uint256 public constant MULTIPLIER = 1e18;
    uint256 public constant VOTE_WEIGHT_MULTIPLIER = 3; // 4x gives 300% boost at 4 years

    // --- State ---
    IERC20 public immutable HEMI;
    uint256 public supply;
    mapping(address => LockedBalance) public locked;
    uint256 public epoch;
    mapping(uint256 => Point) public pointHistory; // epoch -> Point
    mapping(address => mapping(uint256 => Point)) public userPointHistory; // user -> Point[userEpoch]
    mapping(address => uint256) public userPointEpoch;
    mapping(uint256 => int128) public slopeChanges; // time -> signed slope change

    // --- Events ---
    event Deposit(address indexed provider, uint256 value, uint256 locktime, int128 type_, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    // --- Errors ---
    error AmountIsZero();
    error AddressIsNull();
    error LockExpired();
    error LockNotExpired();
    error LockDurationTooShort();
    error LockDurationTooLong();
    error NoExistingLock();
    error NothingLocked();

    constructor(address hemi_) {
        if (hemi_ == address(0)) revert AddressIsNull();
        HEMI = IERC20(hemi_);
        _disableInitializers();
    }

    // --- Initializer ---
    function initialize(address owner_) external initializer {
        require(owner_ != address(0), "Owner is zero");
        __Ownable_init_unchained(owner_);
        pointHistory[0].blk = block.number;
        pointHistory[0].ts = block.timestamp;
        pointHistory[0].hemiAmt = 0;
    }

    // --- Internal helpers ---
    function _checkpoint(address addr, LockedBalance memory oldLocked, LockedBalance memory newLocked) internal {
        // Reference: sample.vy _checkpoint
        Point memory lastPoint = pointHistory[epoch];
        uint256 lastCheckpoint = lastPoint.ts;
        uint256 blockSlope = 0; // dblock/dt

        if (block.timestamp > lastPoint.ts) {
            blockSlope = ((block.number - lastPoint.blk) * 1e18) / (block.timestamp - lastPoint.ts);
        }

        // If user is not zero address, update their history
        if (addr != address(0)) {
            // Calculate old and new slopes and biases
            int128 oldSlope = 0;
            int128 newSlope = 0;
            int128 oldBias = 0;
            int128 newBias = 0;

            // Old lock
            if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
                oldSlope = oldLocked.amount / int128(int256(MAXTIME));
                oldBias = oldSlope * int128(int256(oldLocked.end - block.timestamp));
            }

            // New lock
            if (newLocked.end > block.timestamp && newLocked.amount > 0) {
                newSlope = newLocked.amount / int128(int256(MAXTIME));
                newBias = newSlope * int128(int256(newLocked.end - block.timestamp));
            }

            // Update user point
            uint256 userEpoch = userPointEpoch[addr] + 1;
            userPointEpoch[addr] = userEpoch;
            userPointHistory[addr][userEpoch] = Point({
                bias: newBias,
                slope: newSlope,
                ts: block.timestamp,
                blk: block.number,
                hemiAmt: uint256(uint128(newLocked.amount))
            });

            // Update global slope changes
            if (oldLocked.end > block.timestamp) {
                slopeChanges[oldLocked.end] -= oldSlope;
            }
            if (newLocked.end > block.timestamp) {
                slopeChanges[newLocked.end] += newSlope;
            }
        }

        // Update global point history
        epoch += 1;
        pointHistory[epoch] = Point({
            bias: lastPoint.bias,
            slope: lastPoint.slope,
            ts: block.timestamp,
            blk: block.number,
            hemiAmt: supply
        });
    }

    function _depositFor(
        address addr,
        uint256 value,
        uint256 unlockTime,
        LockedBalance memory lockedBalance,
        int128 depositType
    ) internal {
        // Implement deposit logic as in sample.vy
    }

    // --- External functions ---

    function createLock(uint256 value, uint256 unlockTime) external {
        // Reference: sample.vy create_lock
        if (value == 0) revert AmountIsZero();

        LockedBalance memory userLock = locked[msg.sender];
        if (userLock.amount != 0) revert LockNotExpired(); // Must withdraw old tokens first

        // Round unlockTime down to weeks
        uint256 unlockTimeRounded = (unlockTime / WEEK) * WEEK;
        if (unlockTimeRounded <= block.timestamp) revert LockDurationTooShort();
        if (unlockTimeRounded > block.timestamp + MAXTIME) revert LockDurationTooLong();

        // Transfer tokens from user
        HEMI.transferFrom(msg.sender, address(this), value);

        // Update user's lock
        userLock.amount = int128(int256(value));
        userLock.end = unlockTimeRounded;
        locked[msg.sender] = userLock;

        // Update supply
        uint256 supplyBefore = supply;
        supply = supplyBefore + value;

        // Checkpoint
        _checkpoint(msg.sender, LockedBalance(0, 0), userLock);

        emit Deposit(msg.sender, value, unlockTimeRounded, int128(1), block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    function depositFor(address addr, uint256 value) external {
        // Implement depositFor logic as in sample.vy
    }

    function increaseAmount(uint256 value) external {
        // Implement increaseAmount logic as in sample.vy
    }

    function increaseUnlockTime(uint256 unlockTime) external {
        // Implement increaseUnlockTime logic as in sample.vy
    }

    function withdraw() external {
        LockedBalance memory userLock = locked[msg.sender];

        // Only allow withdrawal if lock expired (or emergency unlock, if you add that feature)
        if (block.timestamp < userLock.end) revert LockNotExpired();
        uint256 value = uint256(uint128(userLock.amount));
        if (value == 0) revert NothingLocked();

        LockedBalance memory oldLocked = userLock;

        // Reset user's lock
        userLock.amount = 0;
        userLock.end = 0;
        locked[msg.sender] = userLock;

        // Update supply
        uint256 supplyBefore = supply;
        supply = supplyBefore - value;

        // Checkpoint
        _checkpoint(msg.sender, oldLocked, userLock);

        // Transfer tokens back to user
        bool success = HEMI.transfer(msg.sender, value);
        require(success, "Token transfer failed");

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    // --- View functions ---

    function balanceOf(address addr) external view returns (uint256) {
        uint256 userEpoch = userPointEpoch[addr];
        if (userEpoch == 0) {
            return 0;
        }
        Point memory pt = userPointHistory[addr][userEpoch];
        if (block.timestamp < pt.ts) {
            return 0;
        }
        int128 dt = int128(int256(block.timestamp - pt.ts));
        int128 bias = pt.bias - pt.slope * dt;
        if (bias < 0) {
            bias = 0;
        }
        uint256 unweightedSupply = uint256(uint128(bias));
        uint256 weightedSupply = pt.hemiAmt + (VOTE_WEIGHT_MULTIPLIER * unweightedSupply);
        return weightedSupply;
    }

    function balanceOfAt(address addr, uint256 blockNumber) external view returns (uint256) {
        // Find the most recent user point at or before the given block
        uint256 userEpoch = userPointEpoch[addr];
        if (userEpoch == 0) {
            return 0;
        }

        // Binary search for the user epoch at or before blockNumber
        uint256 min = 0;
        uint256 max = userEpoch;
        while (min < max) {
            uint256 mid = (min + max + 1) / 2;
            if (userPointHistory[addr][mid].blk <= blockNumber) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }

        Point memory pt = userPointHistory[addr][min];
        if (pt.blk > blockNumber) {
            return 0;
        }

        // Find the timestamp for the given blockNumber using global pointHistory
        // Binary search for global epoch at or before blockNumber
        uint256 globalMin = 0;
        uint256 globalMax = epoch;
        while (globalMin < globalMax) {
            uint256 mid = (globalMin + globalMax + 1) / 2;
            if (pointHistory[mid].blk <= blockNumber) {
                globalMin = mid;
            } else {
                globalMax = mid - 1;
            }
        }
        uint256 blockTime = pointHistory[globalMin].ts;

        if (blockTime < pt.ts) {
            return 0;
        }

        int128 dt = int128(int256(blockTime - pt.ts));
        int128 bias = pt.bias - pt.slope * dt;
        if (bias < 0) {
            bias = 0;
        }
        uint256 unweightedSupply = uint256(uint128(bias));
        uint256 weightedSupply = pt.hemiAmt + (VOTE_WEIGHT_MULTIPLIER * unweightedSupply);
        return weightedSupply;
    }

    /// @notice Calculate total voting power at the current timestamp (veFXS logic)
    function totalSupply() external view returns (uint256) {
        uint256 t = block.timestamp;
        uint256 _epoch = epoch;
        Point memory lastPoint = pointHistory[_epoch];

        // Decay bias linearly to current time
        if (t < lastPoint.ts) {
            return 0;
        }
        int128 dt = int128(int256(t - lastPoint.ts));
        int128 bias = lastPoint.bias - lastPoint.slope * dt;
        if (bias < 0) {
            bias = 0;
        }
        uint256 unweightedSupply = uint256(uint128(bias));
        uint256 weightedSupply = lastPoint.hemiAmt + (VOTE_WEIGHT_MULTIPLIER * unweightedSupply);
        return weightedSupply;
    }

    function totalSupplyAt(uint256 blockNumber) external view returns (uint256) {
        // Binary search for the global epoch at or before blockNumber
        uint256 min = 0;
        uint256 max = epoch;
        while (min < max) {
            uint256 mid = (min + max + 1) / 2;
            if (pointHistory[mid].blk <= blockNumber) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        Point memory pt = pointHistory[min];
        if (pt.blk > blockNumber) {
            return 0;
        }

        // If blockNumber is before the point's timestamp, return 0
        uint256 blockTime = pt.ts;
        if (blockNumber != pt.blk && min < epoch) {
            // If not exact match, use next point's timestamp if available
            uint256 nextBlk = pointHistory[min + 1].blk;
            uint256 nextTs = pointHistory[min + 1].ts;
            if (nextBlk > pt.blk && nextBlk <= blockNumber) {
                blockTime = nextTs;
            }
        }

        if (blockTime < pt.ts) {
            return 0;
        }

        int128 dt = int128(int256(blockTime - pt.ts));
        int128 bias = pt.bias - pt.slope * dt;
        if (bias < 0) {
            bias = 0;
        }
        uint256 unweightedSupply = uint256(uint128(bias));
        uint256 weightedSupply = pt.hemiAmt + (VOTE_WEIGHT_MULTIPLIER * unweightedSupply);
        return weightedSupply;
    }
}

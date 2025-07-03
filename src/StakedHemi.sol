// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {console} from "forge-std/console.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {console2} from "forge-std/console2.sol";
import {StakedHemiStorageV1} from "./storage/StakedHemiStorageV1.sol";

/**
 * @title StakedHemi (veHemi)
 * @notice Vesting and yield system based on Curve's veCRV and AERO voting escrow mechanism. Users lock HEMI for up to 4 years for boosted stHEMI. Each lock is a non-transferable NFT.
 */
contract StakedHemi is
    StakedHemiStorageV1,
    ERC721EnumerableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient
{
    using SafeCast for uint256;
    using SafeCast for int128;
    // --- Types ---

    // --- Constants ---
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_TIME = 4 * 365 days; // 4 years
    uint256 internal constant MULTIPLIER = 1 ether;
    string public constant version = "1.0.0";
    uint8 public constant decimals = 18;

    // --- Errors ---
    error AmountIsZero();
    error AddressIsNull();
    error LockExpired();
    error LockNotExpired();
    error NoExistingLock();
    error NotOwner();
    error BlockNotReached();
    error CooldownPeriodTooShort();
    error CooldownPeriodTooLong();
    error CooldownAlreadyStarted();
    error CooldownNotStarted();

    // --- Events ---

    constructor(address hemi_) {
        if (hemi_ == address(0)) revert AddressIsNull();
        HEMI = IERC20(hemi_);

        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the owner and reward distributor addresses
     * @param owner_ The address of the contract owner
     * @param rewardDistributor_ The address of the reward distributor contract
     */
    function initialize(address owner_, address rewardDistributor_) external initializer {
        require(owner_ != address(0), "Owner is zero");
        __ERC721_init("veHemi", "veHemi");
        __Ownable_init_unchained(owner_);
        pointHistory[0].blockNumber = block.number;
        pointHistory[0].timestamp = block.timestamp;
        pointHistory[0].amount = 0;
        nextTokenId = 1;
        rewardDistributor = IRewardDistributor(rewardDistributor_); // this may be 0x0
    }

    /**
     * @notice Returns the current staked balance for a given NFT
     * @param tokenId_ The token ID
     * @return The staked balance for the NFT
     */
    function balanceOfNFT(uint256 tokenId_) external view returns (uint256) {
        return _balanceOfNFTAt(tokenId_, block.timestamp);
    }

    /**
     * @notice Returns the current staked balance for a given NFT
     * @param tokenId_ The token ID
     * @param timestamp_ timestamp
     * @return The staked balance for the NFT
     */
    function balanceOfNFTAt(uint256 tokenId_, uint256 timestamp_) external view returns (uint256) {
        return _balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Checkpoints the contract state to update global and user point histories
     */
    function checkpoint() external nonReentrant {
        _checkpoint(0, LockedBalance(0, 0, 0, false), LockedBalance(0, 0, 0, false));
    }

    /**
     * @notice Creates a new lock for the sender
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @return _tokenId The ID of the created lock NFT
     */
    function createLock(
        uint256 amount_,
        uint256 lockDuration_
    ) external returns (uint256 _tokenId) {
        _tokenId = _createLock(amount_, lockDuration_, msg.sender);
    }

    /**
     * @notice Creates a new lock for a specified account
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @param account_ The address to assign the lock NFT to
     * @return _tokenId The ID of the created lock NFT
     */
    function createLockFor(
        uint256 amount_,
        uint256 lockDuration_,
        address account_
    ) external returns (uint256 _tokenId) {
        if (account_ == address(0)) revert AddressIsNull();
        _tokenId = _createLock(amount_, lockDuration_, account_);
    }

    /**
     * @notice Get the locked balance information for a specific token
     * @param tokenId_ The token ID to get locked balance for
     * @return The LockedBalance struct containing amount and end time
     */
    function getLockedBalance(uint256 tokenId_) external view returns (LockedBalance memory) {
        return locked[tokenId_];
    }

    /**
     * @notice Returns the user point for a given token and epoch
     * @param tokenId_ The token ID
     * @param epoch_ The epoch number
     * @return The Point struct for the user at the given epoch
     */
    function getUserPoint(uint256 tokenId_, uint256 epoch_) external view returns (Point memory) {
        return userPointHistory[tokenId_][epoch_];
    }

    /**
     * @notice Increases the amount of HEMI locked for a given token
     * @param tokenId_ The token ID
     * @param amount_ The additional amount to lock
     */
    function increaseAmount(uint256 tokenId_, uint256 amount_) external nonReentrant {
        _increaseAmountFor(tokenId_, amount_);
    }

    function increaseCooldownPeriod(
        uint256 tokenId_,
        uint256 newCooldownPeriod_
    ) external nonReentrant {
        address _sender = _msgSender();
        if (_ownerOf(tokenId_) != _sender) revert NotOwner();
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        if (newCooldownPeriod_ <= _oldLocked.cooldownPeriod) revert CooldownPeriodTooShort();
        LockedBalance memory _newLocked = LockedBalance({
            amount: _oldLocked.amount,
            end: _oldLocked.end,
            cooldownPeriod: newCooldownPeriod_,
            cooldownStarted: _oldLocked.cooldownStarted
        });

        // TODO: call updateReward()
        if (_oldLocked.cooldownStarted) {
            if (_oldLocked.end <= block.timestamp) revert LockExpired();
            uint256 _unlockTime = ((block.timestamp + newCooldownPeriod_) / WEEK) * WEEK;
            if (_unlockTime > block.timestamp + MAX_TIME) revert CooldownPeriodTooLong();
            _newLocked.end = _unlockTime;
        } else {
            uint256 _slope = _newLocked.amount.toUint256() / MAX_TIME;
            totalBias = totalBias + (_slope * (newCooldownPeriod_ - _oldLocked.cooldownPeriod));
        }
        locked[tokenId_] = _newLocked;
        _checkpoint(tokenId_, _oldLocked, _newLocked);
    }

    /**
     * @notice Get the total supply of locked HEMI at the current timestamp
     * @return The total amount of HEMI currently locked
     */
    function totalSupply() public view override returns (uint256) {
        // FIXME: This is bug. This wont give historical balance because user can add amount or increase cool down period
        return _supplyAt(block.timestamp);
    }

    function totalNftSupply() external view returns (uint256) {
        return super.totalSupply();
    }

    /**
     * @notice Get the total supply of locked HEMI at a specific timestamp
     * @param _timestamp The timestamp to check total supply at
     * @return The total amount of HEMI locked at the given timestamp
     */
    function totalSupplyAt(uint256 _timestamp) external view returns (uint256) {
        // FIXME: This is bug. This wont give historical balance because user can add amount or increase cool down period
        return _supplyAt(totalBias + _timestamp);
    }

    /**
     * @notice Get the total supply of locked HEMI at a specific block number
     * @dev This function is not yet implemented
     * @param blockNumber_ The block number to check total supply at
     * @return The total amount of HEMI locked at the given block
     */
    function totalSupplyAtBlock(uint256 blockNumber_) external view returns (uint256) {
        if (blockNumber_ >= block.number) revert BlockNotReached();
        uint256 _epoch = epoch;
        uint256 _targetEpoch = _findBlockEpoch(blockNumber_, _epoch);
        Point memory _point = pointHistory[_targetEpoch];
        uint256 dt;
        if (_targetEpoch < _epoch) {
            Point memory _nextPoint = pointHistory[_targetEpoch + 1];
            if (_point.blockNumber != _nextPoint.blockNumber) {
                dt =
                    ((blockNumber_ - _point.blockNumber) *
                        (_nextPoint.timestamp - _point.timestamp)) /
                    (_nextPoint.blockNumber - _point.blockNumber);
            }
        } else {
            if (_point.blockNumber != block.number) {
                dt =
                    ((blockNumber_ - _point.blockNumber) * (block.timestamp - _point.timestamp)) /
                    (block.number - _point.blockNumber);
            }
        } // # Now dt contains info on how far are we beyond point
        return _supplyAt(_point, _point.timestamp + dt);
    }

    /**
     * @notice Update the reward distributor contract address
     * @dev Only callable by the contract owner. Can be set to address(0) to disable rewards.
     * @param rewardDistributor_ The new reward distributor contract address
     */
    function updateRewardDistributor(address rewardDistributor_) external onlyOwner {
        // Allowed to set to 0x0
        rewardDistributor = IRewardDistributor(rewardDistributor_);
    }

    /**
     * @notice Withdraws HEMI after the lock has expired and burns the NFT
     * @param tokenId_ The token ID to withdraw from
     */
    function withdraw(uint256 tokenId_) external nonReentrant {
        address _sender = _msgSender();
        if (_ownerOf(tokenId_) != _sender) revert NotOwner();
        _updateReward(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (!_oldLocked.cooldownStarted) revert CooldownNotStarted();
        if (block.timestamp < _oldLocked.end) revert LockNotExpired();
        uint256 _amount = _oldLocked.amount.toUint256();

        // Burn the NFT
        _burn(tokenId_);
        locked[tokenId_] = LockedBalance(0, 0, 0, false);
        uint256 _supplyBefore = supply;
        supply = _supplyBefore - _amount;

        // oldLocked can have either expired <= timestamp or zero end
        // oldLocked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(tokenId_, _oldLocked, LockedBalance(0, 0, 0, false));

        HEMI.transfer(_sender, _amount);

        emit Withdraw(_sender, tokenId_, _amount, block.timestamp);
        emit Supply(_supplyBefore, _supplyBefore - _amount);
    }

    /**
     * @notice Returns the staked balance for a given NFT at a specific timestamp
     * @param tokenId_ The token ID
     * @param timestamp_ The timestamp to check the balance at
     * @return The staked balance at the given timestamp
     */
    function _balanceOfNFTAt(uint256 tokenId_, uint256 timestamp_) internal view returns (uint256) {
        uint256 _epoch = _getPastUserPointIndex(tokenId_, timestamp_);

        // epoch 0 is an empty point
        if (_epoch == 0) return 0;
        Point memory _lastPoint = userPointHistory[tokenId_][_epoch];

        _lastPoint.bias -= _lastPoint.slope * (timestamp_ - _lastPoint.timestamp).toInt128();
        if (_lastPoint.bias < 0) {
            _lastPoint.bias = 0;
        }

        return _lastPoint.bias.toUint256() + _lastPoint.permanentBias;
    }

    function _findBlockEpoch(
        uint256 blockNumber_,
        uint256 max_epoch_
    ) internal view returns (uint256) {
        // # Binary search
        uint256 _min = 0;
        uint256 _max = max_epoch_;
        for (uint256 i = 0; i < 128; i++) {
            // # Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (pointHistory[_mid].blockNumber <= blockNumber_) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    /**
     * @notice Binary search to get the global point index at or prior to a given timestamp
     * @dev This function efficiently finds the most recent global checkpoint that is at or before
     * the given timestamp using binary search for optimal performance.
     * @param epoch_ The current global epoch
     * @param timestamp_ The timestamp to search for
     * @return The global point index at or before the timestamp
     */
    function _getPastGlobalPointIndex(
        uint256 epoch_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        if (epoch_ == 0) return 0;
        // First check most recent balance
        if (pointHistory[epoch_].timestamp <= timestamp_) return (epoch_);
        // Next check implicit zero balance
        if (pointHistory[1].timestamp > timestamp_) return 0;

        uint256 _lower = 0;
        uint256 _upper = epoch_;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2; // ceil, avoiding overflow
            Point memory _globalPoint = pointHistory[_center];
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

    /**
     * @notice Binary search to get the user point index for a token id at or prior to a given timestamp
     * @dev If a user point does not exist prior to the timestamp, this will return 0.
     * This function efficiently finds the most recent user checkpoint using binary search.
     * @param tokenId_ The token ID to search for
     * @param timestamp_ The timestamp to search for
     * @return User point index at or before the timestamp
     */
    function _getPastUserPointIndex(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        uint256 _userEpoch = userPointEpoch[tokenId_];
        if (_userEpoch == 0) return 0;
        Point memory _lastPoint = userPointHistory[tokenId_][_userEpoch];
        // First check most recent balance
        if (_lastPoint.timestamp <= timestamp_) return (_userEpoch);
        // Next check implicit zero balance
        if (userPointHistory[tokenId_][1].timestamp > timestamp_) return 0;

        uint256 lower = 0;
        uint256 upper = _userEpoch;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Point memory _userPoint = userPointHistory[tokenId_][center];
            if (_userPoint.timestamp == timestamp_) {
                return center;
            } else if (_userPoint.timestamp < timestamp_) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    /**
     * @notice Internal function to checkpoint user and global point histories
     * @param tokenId_ The token ID
     * @param oldLocked_ The previous locked balance
     * @param newLocked_ The new locked balance
     */
    function _checkpoint(
        uint256 tokenId_,
        LockedBalance memory oldLocked_,
        LockedBalance memory newLocked_
    ) internal {
        Point memory _oldUserPoint;
        Point memory _newUserPoint;
        uint256 _epoch = epoch;
        int128 _oldDslope = 0;
        int128 _newDslope = 0;

        // Update user point history for this lock (tokenId)
        if (tokenId_ != 0) {
            // Old lock
            if (oldLocked_.amount > 0) {
                if (oldLocked_.cooldownStarted) {
                    _oldUserPoint.slope = oldLocked_.amount / MAX_TIME.toInt128();
                    if (oldLocked_.end > block.timestamp) {
                        _oldUserPoint.bias =
                            _oldUserPoint.slope *
                            (oldLocked_.end - block.timestamp).toInt128();
                    }
                } else {
                    uint256 _slope = oldLocked_.amount.toUint256() / MAX_TIME;
                    _oldUserPoint.permanentBias = _slope * oldLocked_.cooldownPeriod;
                }
            }

            // New lock
            if (newLocked_.amount > 0) {
                if (newLocked_.cooldownStarted) {
                    _newUserPoint.slope = newLocked_.amount / MAX_TIME.toInt128();
                    if (newLocked_.end > block.timestamp) {
                        _newUserPoint.bias =
                            _newUserPoint.slope *
                            (newLocked_.end - block.timestamp).toInt128();
                    }
                } else {
                    uint256 _slope = newLocked_.amount.toUint256() / MAX_TIME;
                    _newUserPoint.permanentBias = _slope * newLocked_.cooldownPeriod;
                }
            }

            // Read values of scheduled changes in the slope
            // _oldLocked.end can be in the past and in the future
            // _newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            if (oldLocked_.end != 0) {
                _oldDslope = slopeChanges[oldLocked_.end];
            }
            if (newLocked_.end != 0) {
                if (newLocked_.end == oldLocked_.end) {
                    _newDslope = _oldDslope;
                } else {
                    _newDslope = slopeChanges[newLocked_.end];
                }
            }
        }

        Point memory _lastPoint = Point({
            bias: 0,
            slope: 0,
            timestamp: block.timestamp,
            blockNumber: block.number,
            amount: 0,
            permanentBias: 0
        });
        if (_epoch > 0) {
            _lastPoint = pointHistory[_epoch];
        }
        uint256 _lastCheckpoint = _lastPoint.timestamp;
        Point memory _initialLastPoint = Point({
            bias: _lastPoint.bias,
            slope: _lastPoint.slope,
            timestamp: _lastPoint.timestamp,
            blockNumber: _lastPoint.blockNumber,
            amount: _lastPoint.amount,
            permanentBias: _lastPoint.permanentBias
        });
        uint256 _blockSlope;
        if (block.timestamp > _lastPoint.timestamp) {
            _blockSlope =
                (MULTIPLIER * (block.number - _lastPoint.blockNumber)) /
                (block.timestamp - _lastPoint.timestamp);
        }

        // Go over weeks to fill history and calculate what the current point is
        {
            uint256 t_i = (_lastCheckpoint / WEEK) * WEEK;
            for (uint256 i; i < 255; ++i) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += WEEK; // Initial value of t_i is always larger than the ts of the last point
                int128 d_slope;
                if (t_i > block.timestamp) {
                    t_i = block.timestamp;
                } else {
                    d_slope = slopeChanges[t_i];
                }
                _lastPoint.bias -= _lastPoint.slope * (t_i - _lastCheckpoint).toInt128();
                _lastPoint.slope += d_slope;
                if (_lastPoint.bias < 0) {
                    // This can happen
                    _lastPoint.bias = 0;
                }
                if (_lastPoint.slope < 0) {
                    // This cannot happen - just in case
                    _lastPoint.slope = 0;
                }
                _lastCheckpoint = t_i;
                _lastPoint.timestamp = t_i;
                _lastPoint.blockNumber =
                    _initialLastPoint.blockNumber +
                    (_blockSlope * (t_i - _initialLastPoint.timestamp)) /
                    MULTIPLIER;
                _epoch += 1;
                if (t_i == block.timestamp) {
                    _lastPoint.blockNumber = block.number;
                    // FIXME:
                    // _lastPoint.amount = HEMI.balanceOf(address(this));
                    break;
                } else {
                    pointHistory[_epoch] = _lastPoint;
                }
            }
        }

        if (tokenId_ != 0) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            _lastPoint.slope += (_newUserPoint.slope - _oldUserPoint.slope);
            _lastPoint.bias += (_newUserPoint.bias - _oldUserPoint.bias);
            if (_lastPoint.slope < 0) {
                _lastPoint.slope = 0;
            }
            if (_lastPoint.bias < 0) {
                _lastPoint.bias = 0;
            }
            _lastPoint.permanentBias = totalBias;
        }
        // If timestamp of last global point is the same, overwrite the last global point
        // Else record the new global point into history
        // Exclude epoch 0 (note: _epoch is always >= 1, see above)
        // Two possible outcomes:
        // Missing global checkpoints in prior weeks. In this case, _epoch = epoch + x, where x > 1
        // No missing global checkpoints, but timestamp != block.timestamp. Create new checkpoint.
        // No missing global checkpoints, but timestamp == block.timestamp. Overwrite last checkpoint.
        if (_epoch != 1 && pointHistory[_epoch - 1].timestamp == block.timestamp) {
            // _epoch = epoch + 1, so we do not increment epoch
            pointHistory[_epoch - 1] = _lastPoint;
        } else {
            // more than one global point may have been written, so we update epoch
            epoch = _epoch;
            pointHistory[_epoch] = _lastPoint;
        }

        if (tokenId_ != 0) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [_newLocked.end]
            // and add old_user_slope to [_oldLocked.end]
            if (oldLocked_.end > block.timestamp) {
                // oldDslope was <something> - uOld.slope, so we cancel that
                _oldDslope += _oldUserPoint.slope;
                if (newLocked_.end == oldLocked_.end) {
                    _oldDslope -= _newUserPoint.slope; // It was a new deposit, not extension
                }
                slopeChanges[oldLocked_.end] = _oldDslope;
            }

            if (newLocked_.end > block.timestamp) {
                // update slope if new lock is greater than old lock and is not permanent
                if ((newLocked_.end > oldLocked_.end)) {
                    _newDslope -= _newUserPoint.slope; // old slope disappeared at this point
                    slopeChanges[newLocked_.end] = _newDslope;
                }
                // else: we recorded it already in oldDslope
            }
            // If timestamp of last user point is the same, overwrite the last user point
            // Else record the new user point into history
            // Exclude epoch 0
            _newUserPoint.timestamp = block.timestamp;
            _newUserPoint.blockNumber = block.number;
            _newUserPoint.amount = locked[tokenId_].amount.toUint256();
            uint256 _userEpoch = userPointEpoch[tokenId_];
            if (
                _userEpoch != 0 &&
                userPointHistory[tokenId_][_userEpoch].timestamp == block.timestamp
            ) {
                userPointHistory[tokenId_][_userEpoch] = _newUserPoint;
            } else {
                userPointEpoch[tokenId_] = ++_userEpoch;
                userPointHistory[tokenId_][_userEpoch] = _newUserPoint;
            }
        }
        emit Checkpoint(_epoch, tokenId_, oldLocked_, newLocked_);
    }

    /**
     * @notice Internal function to create a new lock
     * @param amount_ The amount of HEMI to lock
     * @param cooldownPeriod_ .
     * @param account_ The address to assign the lock NFT to
     * @return _tokenId The ID of the created lock NFT .
     */
    function _createLock(
        uint256 amount_,
        uint256 cooldownPeriod_,
        address account_
    ) internal returns (uint256 _tokenId) {
        if (cooldownPeriod_ < WEEK) revert CooldownPeriodTooShort();
        if (cooldownPeriod_ > MAX_TIME) revert CooldownPeriodTooLong();
        // cooldownPeriod_ = (cooldownPeriod_ / WEEK) * WEEK;
        if (amount_ == 0) revert AmountIsZero();
        supply += amount_;
        _tokenId = nextTokenId++;
        _mint(account_, _tokenId);
        _updateReward(_tokenId);
        uint256 _slope = amount_ / MAX_TIME;
        totalBias += _slope * cooldownPeriod_;
        LockedBalance memory _newLocked = LockedBalance({
            amount: amount_.toInt128(),
            cooldownPeriod: cooldownPeriod_,
            end: 0,
            cooldownStarted: false
        });

        locked[_tokenId] = _newLocked;
        _checkpoint(_tokenId, LockedBalance(0, 0, 0, false), _newLocked);
        address from = _msgSender();
        if (amount_ != 0) {
            HEMI.transferFrom(from, address(this), amount_);
        }
    }

    function startCooldown(uint256 tokenId_) external {
        address _sender = _msgSender();
        if (_ownerOf(tokenId_) != _sender) revert NotOwner();
        _startCooldown(tokenId_);
    }

    function _startCooldown(uint256 tokenId_) internal {
        LockedBalance memory _locked = locked[tokenId_];
        if (_locked.cooldownStarted) {
            revert CooldownAlreadyStarted();
        }
        uint256 _slope = _locked.amount.toUint256() / MAX_TIME;
        totalBias -= _slope * _locked.cooldownPeriod;
        _locked.cooldownStarted = true;
        _locked.end = ((block.timestamp + _locked.cooldownPeriod) / WEEK) * WEEK;

        locked[tokenId_] = _locked;
        _checkpoint(tokenId_, LockedBalance(0, 0, 0, false), _locked);
    }

    /**
     * @notice Internal function to increase the amount locked for a token
     * @param tokenId_ The token ID
     * @param amount_ The additional amount to lock
     */
    function _increaseAmountFor(uint256 tokenId_, uint256 amount_) internal {
        _updateReward(tokenId_);
        if (amount_ == 0) revert AmountIsZero();
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (_oldLocked.amount <= 0) revert NoExistingLock();

        LockedBalance memory _newLocked = LockedBalance({
            amount: _oldLocked.amount + amount_.toInt128(),
            end: _oldLocked.end,
            cooldownPeriod: _oldLocked.cooldownPeriod,
            cooldownStarted: _oldLocked.cooldownStarted
        });

        if (_oldLocked.cooldownStarted) {
            if (_oldLocked.end <= block.timestamp) revert LockExpired();
        } else {
            uint256 _slope = amount_ / MAX_TIME;
            totalBias += _slope * _newLocked.cooldownPeriod;
        }
        locked[tokenId_] = _newLocked;
        _checkpoint(tokenId_, _oldLocked, _newLocked);
        HEMI.transferFrom(msg.sender, address(this), amount_);
    }

    /**
     * @notice Calculate the total supply of locked HEMI at a specific timestamp
     * @dev This function calculates the total voting power (supply) at a given timestamp
     * by finding the appropriate global checkpoint and calculating the decay from that point.
     * It handles slope changes and ensures the bias never goes negative.
     * @param timestamp_ The timestamp to calculate supply at
     * @return The total supply of locked HEMI at the given timestamp
     */
    function _supplyAt(uint256 timestamp_) internal view returns (uint256) {
        uint256 _epoch = _getPastGlobalPointIndex(epoch, timestamp_);
        // epoch 0 is an empty point
        if (_epoch == 0) return 0;
        Point memory _point = pointHistory[_epoch];
        return _supplyAt(_point, timestamp_);
    }

    function _supplyAt(Point memory point_, uint256 timestamp_) internal view returns (uint256) {
        int128 bias = point_.bias;
        int128 slope = point_.slope;
        uint256 ts = point_.timestamp;
        uint256 t_i = (ts / WEEK) * WEEK;
        for (uint256 i; i < 255; ++i) {
            t_i += WEEK;
            int128 dSlope = 0;
            if (t_i > timestamp_) {
                t_i = timestamp_;
            } else {
                dSlope = slopeChanges[t_i];
            }
            bias -= slope * (t_i - ts).toInt128();
            if (t_i == timestamp_) {
                break;
            }
            slope += dSlope;
            ts = t_i;
        }

        if (bias < 0) {
            bias = 0;
        }
        return bias.toUint256() + point_.permanentBias;
    }

    /**
     * @notice Internal function to update the owner of a token (only allows mint and burn)
     * @param to_ The new owner address
     * @param tokenId_ The token ID
     * @param auth_ The authorized address
     * @return from The previous owner address
     */
    function _update(
        address to_,
        uint256 tokenId_,
        address auth_
    ) internal virtual override(ERC721EnumerableUpgradeable) returns (address from) {
        // Only allow mint (from == address(0)) and burn (to == address(0))
        from = super._ownerOf(tokenId_);
        if (from != address(0) && to_ != address(0)) {
            revert("NFT is non-transferable");
        }
        return super._update(to_, tokenId_, auth_);
    }

    /**
     * @notice Internal function to update rewards for a token
     * @param tokenId_ The token ID
     */
    function _updateReward(uint256 tokenId_) internal {
        if (address(rewardDistributor) != address(0)) {
            rewardDistributor.updateRewards(tokenId_);
        }
    }

    /**
     * Disabled functions
     */
    /**
     * @notice Disabled: Approve is not allowed (NFT is non-transferable)
     */
    function approve(address, uint256) public pure override(ERC721Upgradeable, IERC721) {
        revert("NFT is non-transferable");
    }

    /**
     * @notice Disabled: setApprovalForAll is not allowed (NFT is non-transferable)
     */
    function setApprovalForAll(address, bool) public pure override(ERC721Upgradeable, IERC721) {
        revert("NFT is non-transferable");
    }

    /**
     * @notice Disabled: transferFrom is not allowed (NFT is non-transferable)
     */
    function transferFrom(
        address,
        address,
        uint256
    ) public pure override(ERC721Upgradeable, IERC721) {
        revert("NFT is non-transferable");
    }
}

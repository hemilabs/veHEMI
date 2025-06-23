// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {StakedHemiStorageV1} from "./storage/StakedHemiStorageV1.sol";
import {console} from "forge-std/console.sol";

/**
 * @title StakedHemi (stHEMI)
 * @notice Vesting and yield system based on Curve's veCRV mechanism. Users lock HEMI for up to 4 years for boosted stHEMI. Each lock is a non-transferable NFT.
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
    uint256 public constant VOTE_WEIGHT_MULTIPLIER = 3; // 4x gives 300% boost at 4 years
    uint256 internal constant MULTIPLIER = 1 ether;

    // --- Errors ---
    error AmountIsZero();
    error AddressIsNull();
    error LockExpired();
    error LockNotExpired();
    error LockDurationTooShort();
    error LockDurationTooLong();
    error NoExistingLock();
    error NotOwner();
    error NewLockDurationNotGreater();
    error NonExistentToken();

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
        __ERC721_init("StakedHemi Lock", "stHEMI-LOCK");
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
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));
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

    function delegate(uint256 delegator_, uint256 delegatee_) external {
        _delegate(delegator_, delegatee_);
    }

    function getVotes(address account_, uint256 tokenId_) external view returns (uint256) {
        return _getPastVotes(account_, tokenId_, block.timestamp);
    }

    function getPastVotes(
        address account_,
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256) {
        return _getPastVotes(account_, tokenId_, timestamp_);
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

    /**
     * @notice Increases the unlock time for a given lock NFT
     * @param tokenId_ The token ID
     * @param lockDuration_ The new lock duration (from now)
     */
    function increaseUnlockTime(uint256 tokenId_, uint256 lockDuration_) external nonReentrant {
        address _sender = _msgSender();
        if (_ownerOf(tokenId_) != _sender) revert NotOwner();
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (_oldLocked.end <= block.timestamp) revert LockExpired();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        uint256 _unlockTime = ((block.timestamp + lockDuration_) / WEEK) * WEEK; // Locktime is rounded down to weeks
        if (_unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();
        if (_unlockTime <= _oldLocked.end) revert NewLockDurationNotGreater();
        _updateReward(tokenId_);
        _depositFor(tokenId_, 0, _unlockTime, _oldLocked);

        // TODO: emit event
    }

    function totalSupply() public view override returns (uint256) {
        return _supplyAt(block.timestamp);
    }

    function totalSupplyAt(uint256 _timestamp) external view returns (uint256) {
        return _supplyAt(_timestamp);
    }

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
        // TODO: should check approvedOrOwner?
        if (_ownerOf(tokenId_) != _sender) revert NotOwner();
        _updateReward(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (block.timestamp < _oldLocked.end) revert LockNotExpired();
        uint256 _amount = _oldLocked.amount.toUint256();

        // Burn the NFT
        _burnNFT(tokenId_);
        locked[tokenId_] = LockedBalance(0, 0);
        uint256 _supplyBefore = supply;
        supply = _supplyBefore - _amount;

        // oldLocked can have either expired <= timestamp or zero end
        // oldLocked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(tokenId_, _oldLocked, LockedBalance(0, 0));

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
        return _lastPoint.bias.toUint256();
    }

    function _burnNFT(uint256 tokenId_) internal {
        super._burn(tokenId_);
        // This is same as calling delegate(tokenId_, 0, address(0))
        // for gas saving calling _checkpointDelegator directly
        _checkpointDelegator(tokenId_, 0, address(0));
    }

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

    /// @notice Binary search to get the user point index for a token id at or prior to a given timestamp
    /// @dev If a user point does not exist prior to the timestamp, this will return 0.
    /// @param tokenId_ .
    /// @param timestamp_ .
    /// @return User point index
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

    function _getPastVotes(
        address account_,
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        uint48 _checkIndex = _getPastVotesIndex(tokenId_, timestamp_);
        DelegationCheckpoint memory _lastDelegationCheckpoint = delegationCheckpoints[tokenId_][
            _checkIndex
        ];
        // If no point exists prior to the given timestamp, return 0
        if (_lastDelegationCheckpoint.fromTimestamp > timestamp_) return 0;
        // Check ownership
        if (account_ != _lastDelegationCheckpoint.owner) return 0;
        // FIXME: This should decrease over time
        uint256 votes = _lastDelegationCheckpoint.delegatedBalance;
        return
            _lastDelegationCheckpoint.delegatee == 0
                ? votes + _balanceOfNFTAt(tokenId_, timestamp_)
                : votes;
    }

    function _getPastVotesIndex(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint48) {
        uint48 nCheckpoints_ = numDelegationCheckpoints[tokenId_];
        if (nCheckpoints_ == 0) return 0;
        // First check most recent balance
        if (delegationCheckpoints[tokenId_][nCheckpoints_ - 1].fromTimestamp <= timestamp_)
            return (nCheckpoints_ - 1);
        // Next check implicit zero balance
        if (delegationCheckpoints[tokenId_][0].fromTimestamp > timestamp_) return 0;

        uint48 lower_ = 0;
        uint48 upper_ = nCheckpoints_ - 1;
        while (upper_ > lower_) {
            uint48 center = upper_ - (upper_ - lower_) / 2; // ceil, avoiding overflow
            DelegationCheckpoint storage cp = delegationCheckpoints[tokenId_][center];
            if (cp.fromTimestamp == timestamp_) {
                return center;
            } else if (cp.fromTimestamp < timestamp_) {
                lower_ = center;
            } else {
                upper_ = center - 1;
            }
        }
        return lower_;
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
            if (oldLocked_.end > block.timestamp && oldLocked_.amount > 0) {
                _oldUserPoint.slope = oldLocked_.amount / MAX_TIME.toInt128();
                _oldUserPoint.bias =
                    _oldUserPoint.slope *
                    (oldLocked_.end - block.timestamp).toInt128();
            }

            // New lock
            if (newLocked_.end > block.timestamp && newLocked_.amount > 0) {
                _newUserPoint.slope = newLocked_.amount / MAX_TIME.toInt128();
                _newUserPoint.bias =
                    _newUserPoint.slope *
                    (newLocked_.end - block.timestamp).toInt128();
            }

            // Read values of scheduled changes in the slope
            // _oldLocked.end can be in the past and in the future
            // _newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            _oldDslope = slopeChanges[oldLocked_.end];
            // FIXME: can newLocked_.end be 0?
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
            amount: 0 // FIXME: double check use of this.
        });
        if (_epoch > 0) {
            _lastPoint = pointHistory[_epoch];
        } else {
            // FIXME: check if this is needed. By this time transferFrom user has not done.
            _lastPoint.amount = HEMI.balanceOf(address(this));
        }
        uint256 _lastCheckpoint = _lastPoint.timestamp;
        Point memory _initialLastPoint = Point({
            bias: _lastPoint.bias,
            slope: _lastPoint.slope,
            timestamp: _lastPoint.timestamp,
            blockNumber: _lastPoint.blockNumber,
            amount: _lastPoint.amount
        });
        uint256 _blockSlope = 0; // dblock/dt
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
                int128 d_slope = 0;
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
                    _lastPoint.amount = HEMI.balanceOf(address(this));
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
        }
        // If timestamp of last global point is the same, overwrite the last global point
        // Else record the new global point into history
        // Exclude epoch 0 (note: _epoch is always >= 1, see above)
        // Two possible outcomes:
        // Missing global checkpoints in prior weeks. In this case, _epoch = epoch + x, where x > 1
        // No missing global checkpoints, but timestamp != block.timestamp. Create new checkpoint.
        // No missing global checkpoints, but timestamp == block.timestamp. Overwrite last checkpoint.
        // FIXME: probably its bug.   epoch = _epoch may be outside if-else
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
            // TODO: check if this is needed
            _newUserPoint.amount = locked[tokenId_].amount.toUint256();
            uint256 userEpoch = userPointEpoch[tokenId_];
            if (
                userEpoch != 0 && userPointHistory[tokenId_][userEpoch].timestamp == block.timestamp
            ) {
                userPointHistory[tokenId_][userEpoch] = _newUserPoint;
            } else {
                userPointEpoch[tokenId_] = ++userEpoch;
                userPointHistory[tokenId_][userEpoch] = _newUserPoint;
            }
        }
    }

    function _checkpointDelegator(uint256 delegator_, uint256 delegatee_, address owner_) internal {
        uint256 _delegatedBalance = locked[delegator_].amount.toUint256();
        uint48 _numCheckpoint = numDelegationCheckpoints[delegator_];
        DelegationCheckpoint storage _cpOld = _numCheckpoint > 0
            ? delegationCheckpoints[delegator_][_numCheckpoint - 1]
            : delegationCheckpoints[delegator_][0];
        _checkpointDelegatee(_cpOld.delegatee, _delegatedBalance, false);
        DelegationCheckpoint memory _cp = delegationCheckpoints[delegator_][_numCheckpoint];
        _cp.delegatedBalance = _cpOld.delegatedBalance;
        _cp.fromTimestamp = block.timestamp;
        _cp.delegatee = delegatee_;
        _cp.owner = owner_;

        if (
            _numCheckpoint > 0 &&
            delegationCheckpoints[delegator_][_numCheckpoint - 1].fromTimestamp == block.timestamp
        ) {
            // same block as old checkpoint
            delegationCheckpoints[delegator_][_numCheckpoint - 1] = _cp;
            delete delegationCheckpoints[delegator_][_numCheckpoint];
        } else {
            // new block
            numDelegationCheckpoints[delegator_]++;
            delegationCheckpoints[delegator_][_numCheckpoint] = _cp;
        }

        delegates[delegator_] = delegatee_;
    }

    function _checkpointDelegatee(uint256 delegatee_, uint256 balance_, bool increase_) internal {
        if (delegatee_ == 0) return;
        uint48 _numCheckpoint = numDelegationCheckpoints[delegatee_];
        DelegationCheckpoint storage _cpOld = _numCheckpoint > 0
            ? delegationCheckpoints[delegatee_][_numCheckpoint - 1]
            : delegationCheckpoints[delegatee_][0];
        DelegationCheckpoint memory _cp = delegationCheckpoints[delegatee_][_numCheckpoint];
        _cp.fromTimestamp = block.timestamp;
        _cp.owner = _cpOld.owner;
        // do not expect balance_ > cpOld.delegatedBalance when decrementing but just in case
        _cp.delegatedBalance = increase_
            ? _cpOld.delegatedBalance + balance_
            : (balance_ < _cpOld.delegatedBalance ? _cpOld.delegatedBalance - balance_ : 0);
        _cp.delegatee = _cpOld.delegatee;

        if (
            _numCheckpoint > 0 &&
            delegationCheckpoints[delegatee_][_numCheckpoint - 1].fromTimestamp == block.timestamp
        ) {
            // same block as old checkpoint
            delegationCheckpoints[delegatee_][_numCheckpoint - 1] = _cp;
            delete delegationCheckpoints[delegatee_][_numCheckpoint];
        } else {
            // new block
            numDelegationCheckpoints[delegatee_]++;
            delegationCheckpoints[delegatee_][_numCheckpoint] = _cp;
        }
    }

    /**
     * @notice Internal function to create a new lock
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @param account_ The address to assign the lock NFT to
     * @return _tokenId The ID of the created lock NFT
     */
    function _createLock(
        uint256 amount_,
        uint256 lockDuration_,
        address account_
    ) internal returns (uint256 _tokenId) {
        uint256 unlockTime = ((block.timestamp + lockDuration_) / WEEK) * WEEK; // Lock time is rounded down to weeks

        if (amount_ == 0) revert AmountIsZero();
        if (unlockTime <= block.timestamp) revert LockDurationTooShort();
        if (unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();

        _tokenId = nextTokenId++;
        _mintNFT(account_, _tokenId);
        _updateReward(_tokenId);

        _depositFor(_tokenId, amount_, unlockTime, locked[_tokenId]);

        return _tokenId;
    }

    function _delegate(uint256 delegator_, uint256 delegatee_) internal {
        LockedBalance memory _delegateLocked = locked[delegator_];
        if (delegatee_ != 0 && _ownerOf(delegatee_) == address(0)) revert NonExistentToken();
        if (delegatee_ == delegator_) delegatee_ = 0;
        uint256 _currentDelegate = delegates[delegator_];
        if (_currentDelegate == delegatee_) return;

        uint256 _delegatedBalance = _delegateLocked.amount.toUint256();
        _checkpointDelegator(delegator_, delegatee_, _ownerOf(delegator_));
        _checkpointDelegatee(delegatee_, _delegatedBalance, true);

        emit DelegateChanged(_msgSender(), _currentDelegate, delegatee_);
    }

    /**
     * @notice Internal function to deposit for a lock (increase amount or extend duration)
     * @param tokenId_ The token ID
     * @param amount_ The amount to deposit
     * @param unlockTime_ The new unlock time
     * @param oldLocked_ The previous locked balance
     */
    function _depositFor(
        uint256 tokenId_,
        uint256 amount_,
        uint256 unlockTime_,
        LockedBalance memory oldLocked_
    ) internal {
        uint256 _supplyBefore = supply;
        supply = _supplyBefore + amount_;

        // Set newLocked to _oldLocked without mangling memory
        LockedBalance memory _newLocked;
        (_newLocked.amount, _newLocked.end) = (oldLocked_.amount, oldLocked_.end);

        // Adding to existing lock, or if a lock is expired - creating a new one
        _newLocked.amount += amount_.toInt128();
        if (unlockTime_ != 0) {
            _newLocked.end = unlockTime_;
        }
        locked[tokenId_] = _newLocked;

        // Possibilities:
        // Both _oldLocked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // newLocked.end > block.timestamp (always)
        _checkpoint(tokenId_, oldLocked_, _newLocked);

        address from = _msgSender();
        if (amount_ != 0) {
            HEMI.transferFrom(from, address(this), amount_);
        }

        emit Deposit(from, tokenId_, amount_, _newLocked.end, block.timestamp);
        // emit Supply(supplyBefore, supplyBefore + amount_);
    }

    /**
     * @notice Internal function to increase the amount locked for a token
     * @param tokenId_ The token ID
     * @param amount_ The additional amount to lock
     */
    function _increaseAmountFor(uint256 tokenId_, uint256 amount_) internal {
        _updateReward(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];

        if (amount_ == 0) revert AmountIsZero();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        if (_oldLocked.end <= block.timestamp) revert LockExpired();

        _checkpointDelegatee(delegates[tokenId_], amount_, true);
        _depositFor(tokenId_, amount_, 0, _oldLocked);

        // TODO: emit event
    }

    function _mintNFT(address to_, uint256 tokenId_) internal {
        super._mint(to_, tokenId_);
        _checkpointDelegator(tokenId_, 0, to_);
    }

    function _supplyAt(uint256 timestamp_) internal view returns (uint256) {
        uint256 _epoch = _getPastGlobalPointIndex(epoch, timestamp_);
        // epoch 0 is an empty point
        if (_epoch == 0) return 0;
        Point memory _point = pointHistory[_epoch];
        int128 bias = _point.bias;
        int128 slope = _point.slope;
        uint256 ts = _point.timestamp;

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
        return bias.toUint256();
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

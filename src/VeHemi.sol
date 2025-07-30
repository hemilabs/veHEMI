// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IVeHemiVoteDelegation} from "./interfaces/IVeHemiVoteDelegation.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IVeHemi} from "./interfaces/IVeHemi.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IVeHemiVoteDelegation} from "./interfaces/IVeHemiVoteDelegation.sol";

/**
 * @title VeHemi
 * @notice Vesting and yield system based on Curve's veCRV and AERO voting escrow mechanism. Users lock HEMI for up to 4 years.
 */
contract VeHemi is
    IVeHemi,
    ERC721EnumerableUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    IERC20 public immutable HEMI;

    // --- Constants ---
    uint256 private constant YEAR = 365.25 days;
    uint256 private constant SIX_DAYS = YEAR / (12 * 5); // 1 year = 12 month, 1 month = 30 day
    uint256 private constant MAX_TIME = 4 * YEAR; // 4 years
    uint256 private constant MULTIPLIER = 1 ether;
    string public constant version = "1.0.0";
    uint8 public constant decimals = 18;

    // --- State ---
    struct VeHemiStorage {
        uint256 _totalLocked;
        uint256 _epoch;
        uint256 _nextTokenId;
        IVeHemiVoteDelegation _voteDelegation;
        IRewardDistributor _rewardDistributor; // 0x0 is valid
        address _forfeitAdmin;
        mapping(uint256 epoch => Point) _globalPointHistory;
        mapping(uint256 tokenId => UserPoint[1000000000] userPointAtEpoch) _userPointHistory;
        mapping(uint256 tokenId => LockedBalance) _locked;
        mapping(uint256 tokenId => uint256 epoch) _userPointEpoch;
        mapping(uint256 timestamp => int128 slopeChange) _slopeChanges;
        mapping(uint256 tokenId => address) _provider;
        mapping(uint256 tokenId => uint256 timestamp) _transferableAfter;
        mapping(uint256 tokenId => bool) _isForfeitable;
    }

    // keccak256(abi.encode(uint256(keccak256("xyz.hemi.storage.VeHemi")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VeHemiStorageLocation =
        0xce9089376a1cc53ad6f3f228275562963bb36351d7ba82f45e7888c80a144d00;

    function _getVeHemiStorage() private pure returns (VeHemiStorage storage $) {
        assembly {
            $.slot := VeHemiStorageLocation
        }
    }

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
    error BlockNotReached();
    error NotForfeitable();
    error NotForfeitAdmin();
    error OwnerIsZero();
    error NotTransferable();

    constructor(address hemi_) {
        if (hemi_ == address(0)) revert AddressIsNull();
        HEMI = IERC20(hemi_);

        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the owner address
     * @param owner_ The address of the contract owner
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert OwnerIsZero();
        __ERC721_init("veHemi", "veHemi");
        __Ownable_init_unchained(owner_);
        VeHemiStorage storage $ = _getVeHemiStorage();
        $._globalPointHistory[0].blockNumber = block.number.toUint64();
        $._globalPointHistory[0].timestamp = block.timestamp.toUint64();
        $._nextTokenId = 1;
    }

    /**
     * @notice Returns the current staked balance for a given NFT
     * @param tokenId_ The token ID
     * @return _balance The staked balance for the NFT
     */
    function balanceOfNFT(uint256 tokenId_) external view returns (uint256 _balance) {
        (_balance, ) = _balanceOfNFTAt(tokenId_, block.timestamp);
    }

    /**
     * @notice Returns the current staked balance for a given NFT
     * @param tokenId_ The token ID
     * @param timestamp_ timestamp
     * @return _balance The staked balance for the NFT
     */
    function balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256 _balance) {
        (_balance, ) = _balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Returns the current staked balance for a given NFT
     * @param tokenId_ The token ID
     * @param timestamp_ timestamp
     * @return _balance The staked balance for the NFT
     * @return _owner The owner of the NFT
     */
    function balanceAndOwnerOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256 _balance, address _owner) {
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
    ) external nonReentrant returns (uint256 _tokenId) {
        _tokenId = _createLock(amount_, lockDuration_, _msgSender(), true, false);
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
        address account_,
        bool transferable_,
        bool forfeitable_
    ) external nonReentrant returns (uint256 _tokenId) {
        if (account_ == address(0)) revert AddressIsNull();
        _tokenId = _createLock(amount_, lockDuration_, account_, transferable_, forfeitable_);
    }

    /**
     * @notice Forfeit a lock by admin and withdraw HEMI
     * @param tokenId_ The token ID to forfeit
     */
    function forfeit(uint256 tokenId_) external nonReentrant {
        VeHemiStorage storage $ = _getVeHemiStorage();

        if (_msgSender() != $._forfeitAdmin) revert NotForfeitAdmin();
        if (!isForfeitable(tokenId_)) revert NotForfeitable();
        if ($._locked[tokenId_].end < block.timestamp) revert LockExpired();

        $._voteDelegation.delegate(tokenId_, address(0));

        _withdraw(tokenId_);

        $._isForfeitable[tokenId_] = false;
    }

    /**
     * @notice Increases the amount of HEMI locked for a given token
     * @param tokenId_ The token ID
     * @param amount_ The additional amount to lock
     */
    function increaseAmount(uint256 tokenId_, uint256 amount_) external nonReentrant {
        VeHemiStorage storage $ = _getVeHemiStorage();
        LockedBalance memory _oldLocked = $._locked[tokenId_];

        if (amount_ == 0) revert AmountIsZero();
        if (_oldLocked.end <= block.timestamp) revert LockExpired();
        if (_oldLocked.amount <= 0) revert NoExistingLock();

        _depositFor(tokenId_, amount_, 0, _oldLocked);
    }

    /**
     * @notice Increases the unlock time for a given lock NFT
     * @param tokenId_ The token ID
     * @param lockDuration_ The new lock duration (from now)
     */
    function increaseUnlockTime(uint256 tokenId_, uint256 lockDuration_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        VeHemiStorage storage $ = _getVeHemiStorage();
        LockedBalance memory _oldLocked = $._locked[tokenId_];
        if (_oldLocked.end <= block.timestamp) revert LockExpired();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        uint256 _unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) * SIX_DAYS; // unlock time is rounded down to SIX_DAYS
        if (_unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();
        if (_unlockTime <= _oldLocked.end) revert NewLockDurationNotGreater();

        _depositFor(tokenId_, 0, _unlockTime.toUint64(), _oldLocked);
    }

    /**
     * @notice Check if a token is transferable based on its extraData
     * @param tokenId_ The token ID
     * @return True if the token is transferable (default), false if transfer is not allowed
     */
    function isTransferable(uint256 tokenId_) public view returns (bool) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._transferableAfter[tokenId_] < block.timestamp;
    }

    /**
     * @notice Get the total supply of  veHEMI at the current timestamp
     * @return The total amount of veHEMI currently locked
     */
    function totalVeHemiSupply() public view returns (uint256) {
        return _supplyAt(block.timestamp);
    }

    /**
     * @notice Get the total supply of  veHEMI at a specific timestamp
     * @param timestamp_ The timestamp to check total supply at
     * @return The total amount of veHEMI  at the given timestamp
     */
    function totalVeHemiSupplyAt(uint256 timestamp_) external view returns (uint256) {
        return _supplyAt(timestamp_);
    }

    /**
     * @notice Get the total veHEMI at a specific block number
     * @param blockNumber_ The block number to check total supply at
     * @return The total amount of veHemi at the given block
     */
    function totalVeHemiSupplyAtBlock(uint256 blockNumber_) external view returns (uint256) {
        if (blockNumber_ >= block.number) revert BlockNotReached();
        VeHemiStorage storage $ = _getVeHemiStorage();
        uint256 _epoch = $._epoch;
        uint256 _targetEpoch = _findBlockEpoch(blockNumber_, _epoch);
        Point memory _point = $._globalPointHistory[_targetEpoch];
        uint256 dt;
        if (_targetEpoch < _epoch) {
            Point memory _nextPoint = $._globalPointHistory[_targetEpoch + 1];
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
     * @param newRewardDistributor_ The new reward distributor contract address
     */
    function updateRewardDistributor(IRewardDistributor newRewardDistributor_) external onlyOwner {
        // Allowed to set to 0x0
        VeHemiStorage storage $ = _getVeHemiStorage();
        IRewardDistributor _oldRewardDistributor = $._rewardDistributor;
        $._rewardDistributor = newRewardDistributor_;
        emit RewardDistributorUpdated(_oldRewardDistributor, newRewardDistributor_);
    }

    /**
     * @notice Update the forfeit admin address
     * @dev Only callable by the contract owner. Can be set to address(0) to disable forfeits.
     * @param newForfeitAdmin_ The new forfeit admin address
     */
    function updateForfeitAdmin(address newForfeitAdmin_) external onlyOwner {
        VeHemiStorage storage $ = _getVeHemiStorage();
        address _oldForfeitAdmin = $._forfeitAdmin;
        $._forfeitAdmin = newForfeitAdmin_;
        emit ForfeitAdminUpdated(_oldForfeitAdmin, newForfeitAdmin_);
    }

    /**
     * @notice Update the vote delegation contract address
     * @param newVoteDelegation_ The new vote delegation contract address
     */
    function updateVoteDelegation(IVeHemiVoteDelegation newVoteDelegation_) external onlyOwner {
        if (address(newVoteDelegation_) == address(0)) revert AddressIsNull();
        VeHemiStorage storage $ = _getVeHemiStorage();
        IVeHemiVoteDelegation _oldVoteDelegation = $._voteDelegation;
        $._voteDelegation = newVoteDelegation_;
        emit VoteDelegationUpdated(_oldVoteDelegation, newVoteDelegation_);
    }

    /**
     * @notice Withdraws HEMI after the lock has expired and burns the NFT
     * @param tokenId_ The token ID to withdraw from
     */
    function withdraw(uint256 tokenId_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        VeHemiStorage storage $ = _getVeHemiStorage();
        if (block.timestamp < $._locked[tokenId_].end) revert LockNotExpired();
        _withdraw(tokenId_);
    }

    function _balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256, address) {
        uint256 _epoch = _getPastUserPointIndex(tokenId_, timestamp_);
        // epoch 0 is an empty point
        if (_epoch == 0) return (0, address(0));
        VeHemiStorage storage $ = _getVeHemiStorage();

        UserPoint memory _lastUserPoint = $._userPointHistory[tokenId_][_epoch];
        _lastUserPoint.point.bias -=
            _lastUserPoint.point.slope *
            (timestamp_ - _lastUserPoint.point.timestamp).toInt256().toInt128();
        if (_lastUserPoint.point.bias < 0) {
            _lastUserPoint.point.bias = 0;
        }
        return (_lastUserPoint.point.bias.toUint256(), _lastUserPoint.owner);
    }

    function _findBlockEpoch(
        uint256 blockNumber_,
        uint256 maxEpoch_
    ) internal view returns (uint256) {
        // Binary search
        uint256 _min;
        uint256 _max = maxEpoch_;

        VeHemiStorage storage $ = _getVeHemiStorage();

        for (uint256 i; i < 128; i++) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if ($._globalPointHistory[_mid].blockNumber <= blockNumber_) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    function _getPastGlobalPointIndex(
        uint256 epoch_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        if (epoch_ == 0) return 0;

        VeHemiStorage storage $ = _getVeHemiStorage();

        // First check most recent balance
        if ($._globalPointHistory[epoch_].timestamp <= timestamp_) return (epoch_);
        // Next check implicit zero balance
        if ($._globalPointHistory[1].timestamp > timestamp_) return 0;

        uint256 _lower;
        uint256 _upper = epoch_;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2; // ceil, avoiding overflow
            Point memory _globalPoint = $._globalPointHistory[_center];
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
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        uint256 _userEpoch = userPointEpoch(tokenId_);
        if (_userEpoch == 0) return 0;

        VeHemiStorage storage $ = _getVeHemiStorage();

        Point memory _lastPoint = $._userPointHistory[tokenId_][_userEpoch].point;
        // First check most recent balance
        if (_lastPoint.timestamp <= timestamp_) return (_userEpoch);
        // Next check implicit zero balance
        if ($._userPointHistory[tokenId_][1].point.timestamp > timestamp_) return 0;

        uint256 _lower;
        uint256 _upper = _userEpoch;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2; // ceil, avoiding overflow
            Point memory _userPoint = $._userPointHistory[tokenId_][_center].point;
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
        VeHemiStorage storage $ = _getVeHemiStorage();
        uint256 _epoch = $._epoch;
        int128 _oldDslope;
        int128 _newDslope;

        // Update user point history for this lock (tokenId)
        if (tokenId_ != 0) {
            // Old lock
            if (oldLocked_.end > block.timestamp && oldLocked_.amount > 0) {
                _oldUserPoint.slope = oldLocked_.amount / MAX_TIME.toInt256().toInt128();
                _oldUserPoint.bias =
                    _oldUserPoint.slope *
                    (oldLocked_.end - block.timestamp).toInt256().toInt128();
            }

            // New lock
            if (newLocked_.end > block.timestamp && newLocked_.amount > 0) {
                _newUserPoint.slope = newLocked_.amount / MAX_TIME.toInt256().toInt128();
                _newUserPoint.bias =
                    _newUserPoint.slope *
                    (newLocked_.end - block.timestamp).toInt256().toInt128();
            }

            // Read values of scheduled changes in the slope
            // _oldLocked.end can be in the past and in the future
            // _newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            _oldDslope = $._slopeChanges[oldLocked_.end];
            if (newLocked_.end != 0) {
                if (newLocked_.end == oldLocked_.end) {
                    _newDslope = _oldDslope;
                } else {
                    _newDslope = $._slopeChanges[newLocked_.end];
                }
            }
        }

        Point memory _lastPoint = Point({
            bias: 0,
            slope: 0,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64(),
            amount: 0,
            fixedBias: 0
        });

        if (_epoch > 0) {
            _lastPoint = $._globalPointHistory[_epoch];
        }
        uint256 _lastCheckpoint = _lastPoint.timestamp;
        Point memory _initialLastPoint = Point({
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
                (MULTIPLIER * (block.number - _lastPoint.blockNumber)) /
                (block.timestamp - _lastPoint.timestamp);
        }

        // Go over SIX_DAYS to fill history and calculate what the current point is
        {
            uint256 t_i = (_lastCheckpoint / SIX_DAYS) * SIX_DAYS;
            for (uint256 i; i < 300; ++i) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += SIX_DAYS; // Initial value of t_i is always larger than the ts of the last point
                int128 d_slope;
                if (t_i > block.timestamp) {
                    t_i = block.timestamp;
                } else {
                    d_slope = $._slopeChanges[t_i];
                }
                _lastPoint.bias -= _lastPoint.slope * (t_i - _lastCheckpoint).toInt256().toInt128();
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
                _lastPoint.timestamp = t_i.toUint64();
                _lastPoint.blockNumber = (_initialLastPoint.blockNumber +
                    (_blockSlope * (t_i - _initialLastPoint.timestamp)) /
                    MULTIPLIER).toUint64();
                _epoch += 1;
                if (t_i == block.timestamp) {
                    _lastPoint.blockNumber = block.number.toUint64();
                    break;
                } else {
                    $._globalPointHistory[_epoch] = _lastPoint;
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
        // Missing global checkpoints in prior SIX_DAYS. In this case, _epoch = epoch + x, where x > 1
        // No missing global checkpoints, but timestamp != block.timestamp. Create new checkpoint.
        // No missing global checkpoints, but timestamp == block.timestamp. Overwrite last checkpoint.
        if (_epoch != 1 && $._globalPointHistory[_epoch - 1].timestamp == block.timestamp) {
            // _epoch = epoch + 1, so we do not increment epoch
            $._globalPointHistory[_epoch - 1] = _lastPoint;
        } else {
            // more than one global point may have been written, so we update epoch
            $._epoch = _epoch;
            $._globalPointHistory[_epoch] = _lastPoint;
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
                $._slopeChanges[oldLocked_.end] = _oldDslope;
            }

            if (newLocked_.end > block.timestamp) {
                // update slope if new lock is greater than old lock
                if ((newLocked_.end > oldLocked_.end)) {
                    _newDslope -= _newUserPoint.slope; // old slope disappeared at this point
                    $._slopeChanges[newLocked_.end] = _newDslope;
                }
                // else: we recorded it already in oldDslope
            }
            // If timestamp of last user point is the same, overwrite the last user point
            // Else record the new user point into history
            // Exclude epoch 0
            _newUserPoint.timestamp = block.timestamp.toUint64();
            _newUserPoint.blockNumber = block.number.toUint64();
            _newUserPoint.amount = $._locked[tokenId_].amount.toUint256().toUint128();
            uint256 _userEpoch = userPointEpoch(tokenId_);
            if (
                _userEpoch == 0 ||
                $._userPointHistory[tokenId_][_userEpoch].point.timestamp != block.timestamp
            ) {
                // Create new point at next epoch
                $._userPointEpoch[tokenId_] = ++_userEpoch;
            }

            $._userPointHistory[tokenId_][_userEpoch].point = _newUserPoint;
            $._userPointHistory[tokenId_][_userEpoch].owner = _ownerOf(tokenId_);
        }
        emit Checkpoint(_epoch, tokenId_, oldLocked_, newLocked_);
    }

    function _createLock(
        uint256 amount_,
        uint256 lockDuration_,
        address account_,
        bool transferable_,
        bool forfeitable_
    ) internal returns (uint256 _tokenId) {
        uint256 unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) * SIX_DAYS; // Lock time is rounded down to SIX_DAYS

        if (amount_ == 0) revert AmountIsZero();
        if (unlockTime <= block.timestamp) revert LockDurationTooShort();
        if (unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();

        VeHemiStorage storage $ = _getVeHemiStorage();

        _tokenId = $._nextTokenId++;
        _mint(account_, _tokenId);

        _depositFor(_tokenId, amount_, unlockTime.toUint64(), $._locked[_tokenId]);
        $._voteDelegation.delegate(_tokenId, account_);

        address _sender = _msgSender();

        $._provider[_tokenId] = _sender;

        if (!transferable_) {
            $._transferableAfter[_tokenId] = unlockTime;
        }

        if (forfeitable_) {
            $._isForfeitable[_tokenId] = true;
        }

        emit Lock(
            _sender,
            account_,
            _tokenId,
            amount_,
            block.timestamp,
            lockDuration_,
            0,
            transferable_,
            forfeitable_
        );

        return _tokenId;
    }

    function _depositFor(
        uint256 tokenId_,
        uint256 amount_,
        uint64 unlockTime_,
        LockedBalance memory oldLocked_
    ) internal {
        _updateReward(tokenId_);

        VeHemiStorage storage $ = _getVeHemiStorage();

        $._totalLocked += amount_;

        // Set newLocked to _oldLocked without mangling memory
        LockedBalance memory _newLocked;
        (_newLocked.amount, _newLocked.end) = (oldLocked_.amount, oldLocked_.end);

        // Adding to existing lock, or if a lock is expired - creating a new one
        _newLocked.amount += amount_.toInt256().toInt128();
        if (unlockTime_ != 0) {
            _newLocked.end = unlockTime_;
        }
        $._locked[tokenId_] = _newLocked;

        // Possibilities:
        // Both _oldLocked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // newLocked.end > block.timestamp (always)
        _checkpoint(tokenId_, oldLocked_, _newLocked);

        address from = _msgSender();
        if (amount_ != 0) {
            HEMI.transferFrom(from, address(this), amount_);
        }
        _reDelegate(tokenId_);
        emit Deposit(from, tokenId_, amount_, _newLocked.end, block.timestamp);
    }

    function _reDelegate(uint256 delegator_) internal {
        VeHemiStorage storage $ = _getVeHemiStorage();
        address _delegatee = $._voteDelegation.delegation(delegator_).delegatee;
        if (_delegatee != address(0)) {
            $._voteDelegation.delegate(delegator_, _delegatee);
        }
    }

    function _supplyAt(uint256 timestamp_) internal view returns (uint256) {
        VeHemiStorage storage $ = _getVeHemiStorage();

        uint256 _epoch = _getPastGlobalPointIndex($._epoch, timestamp_);
        // epoch 0 is an empty point
        if (_epoch == 0) return 0;
        Point memory _point = $._globalPointHistory[_epoch];
        return _supplyAt(_point, timestamp_);
    }

    function _supplyAt(Point memory point_, uint256 timestamp_) internal view returns (uint256) {
        int128 bias = point_.bias;
        int128 slope = point_.slope;
        uint256 ts = point_.timestamp;

        VeHemiStorage storage $ = _getVeHemiStorage();

        uint256 t_i = (ts / SIX_DAYS) * SIX_DAYS;
        for (uint256 i; i < 255; ++i) {
            t_i += SIX_DAYS;
            int128 dSlope = 0;
            if (t_i > timestamp_) {
                t_i = timestamp_;
            } else {
                dSlope = $._slopeChanges[t_i];
            }
            bias -= slope * (t_i - ts).toInt256().toInt128();
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

    function _updateReward(uint256 tokenId_) internal {
        VeHemiStorage storage $ = _getVeHemiStorage();
        if (address($._rewardDistributor) != address(0)) {
            // fail silently
            try $._rewardDistributor.updateRewards(tokenId_) {} catch {}
        }
    }

    function _withdraw(uint256 tokenId_) internal {
        _updateReward(tokenId_);
        VeHemiStorage storage $ = _getVeHemiStorage();
        LockedBalance memory _oldLocked = $._locked[tokenId_];
        uint256 _amount = _oldLocked.amount.toUint256();
        _burn(tokenId_);
        $._locked[tokenId_] = LockedBalance(0, 0);
        $._totalLocked -= _amount;
        // oldLocked can have either expired <= timestamp or zero end
        // oldLocked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(tokenId_, _oldLocked, LockedBalance(0, 0));

        address _sender = _msgSender();
        HEMI.transfer(_sender, _amount);

        emit Withdraw(_sender, tokenId_, _amount, block.timestamp);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 tokenId_
    ) public override(ERC721Upgradeable, IERC721) {
        VeHemiStorage storage $ = _getVeHemiStorage();

        if (from_ != address(0)) {
            if (!isTransferable(tokenId_)) revert NotTransferable();
            _updateReward(tokenId_);
            $._voteDelegation.delegate(tokenId_, to_);
        }

        super.transferFrom(from_, to_, tokenId_);

        if (from_ != address(0)) {
            LockedBalance memory _locked = $._locked[tokenId_];
            _checkpoint(tokenId_, _locked, _locked);
        }
    }

    /**
     * @notice Get the locked balance information for a specific token
     * @param tokenId_ The token ID to get locked balance for
     * @return The LockedBalance struct containing amount and end time
     */
    function getLockedBalance(uint256 tokenId_) external view returns (LockedBalance memory) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._locked[tokenId_];
    }

    /**
     * @notice Returns the user point for a given token and epoch
     * @param tokenId_ The token ID
     * @param epoch_ The epoch number
     * @return The Point struct for the user at the given epoch
     */
    function getUserPoint(
        uint256 tokenId_,
        uint256 epoch_
    ) external view returns (UserPoint memory) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._userPointHistory[tokenId_][epoch_];
    }

    /**
     * @notice Returns the global point for a given epoch
     * @param epoch_ The epoch number
     * @return The Point struct for the global point at the given epoch
     */
    function getGlobalPoint(uint256 epoch_) external view returns (Point memory) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._globalPointHistory[epoch_];
    }

    function totalLocked() public view returns (uint256) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._totalLocked;
    }

    function epoch() public view returns (uint256) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._epoch;
    }

    function nextTokenId() public view returns (uint256) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._nextTokenId;
    }

    function voteDelegation() public view returns (IVeHemiVoteDelegation) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._voteDelegation;
    }

    function rewardDistributor() public view returns (IRewardDistributor) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._rewardDistributor;
    }

    function forfeitAdmin() public view returns (address) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._forfeitAdmin;
    }

    function userPointEpoch(uint256 tokenId_) public view returns (uint256 _epoch) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._userPointEpoch[tokenId_];
    }

    function slopeChanges(uint256 timestamp_) public view returns (int128 _slopeChange) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._slopeChanges[timestamp_];
    }

    function provider(uint256 tokenId_) public view returns (address _provider) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._provider[tokenId_];
    }

    function isForfeitable(uint256 tokenId_) public view returns (bool) {
        VeHemiStorage storage $ = _getVeHemiStorage();
        return $._isForfeitable[tokenId_];
    }
}

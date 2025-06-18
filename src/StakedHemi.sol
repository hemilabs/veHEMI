// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    ERC721EnumerableUpgradeable,
    ERC721Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
/**
 * StakedHemi (aka stHEMI) is a vesting and yield system based off of Curve’s veCRV mechanism.
 * Users may lock up their HEMI for up to 4 years for four times the amount of stHEMI (e.g. 100 HEMI locked for 4 years returns 400 stHEMI).
 * Each lock position is represented by a non-transferable NFT.
 */

contract StakedHemi is ERC721EnumerableUpgradeable, OwnableUpgradeable, ReentrancyGuardTransient {
    using SafeCast for uint256;
    using SafeCast for int128;
    // --- Types ---

    struct Point {
        int128 bias;
        int128 slope;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 amount;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    IERC20 public immutable HEMI;

    // --- Constants ---
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_TIME = 4 * 365 days; // 4 years
    uint256 public constant VOTE_WEIGHT_MULTIPLIER = 3; // 4x gives 300% boost at 4 years
    uint256 internal constant MULTIPLIER = 1 ether;

    // --- State ---
    uint256 public supply;
    uint256 public epoch;
    uint256 public nextTokenId;
    mapping(uint256 => Point) public pointHistory; // epoch -> Point
    mapping(uint256 => mapping(uint256 => Point)) public userPointHistory; // tokenId -> Point[userEpoch]
    mapping(uint256 => uint256) public userPointEpoch; // tokenId -> epoch
    mapping(uint256 => int128) public slopeChanges; // time -> signed slope change
    mapping(uint256 => LockedBalance) public locked; // tokenId -> LockedBalance

    // --- Events ---
    event Deposit(
        address indexed provider, uint256 indexed tokenId, uint256 amount, uint256 lockTime, uint256 timestamp
    );
    event Withdraw(address indexed provider, uint256 indexed tokenId, uint256 amount, uint256 timestamp);
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
    error NotOwner();

    constructor(address hemi_) {
        if (hemi_ == address(0)) revert AddressIsNull();
        HEMI = IERC20(hemi_);
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        require(owner_ != address(0), "Owner is zero");
        __ERC721_init("StakedHemi Lock", "stHEMI-LOCK");
        __Ownable_init_unchained(owner_);
        pointHistory[0].blockNumber = block.number;
        pointHistory[0].timestamp = block.timestamp;
        pointHistory[0].amount = 0;
        nextTokenId = 1;
    }

    /// @inheritdoc IVotingEscrow
    function checkpoint() external nonReentrant {
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));
    }

    function createLock(uint256 amount_, uint256 lockDuration_) external returns (uint256 tokenId) {
        tokenId = _createLock(amount_, lockDuration_, msg.sender);
    }

    // TODO: allow this to specific role?
    function createLockFor(uint256 amount_, uint256 lockDuration_, address account_)
        external
        returns (uint256 tokenId)
    {
        if (account_ == address(0)) revert AddressIsNull();
        tokenId = _createLock(amount_, lockDuration_, account_);
    }

    function withdraw(uint256 tokenId_) external nonReentrant {
        address _sender = _msgSender();
        // TODO: should check approvedOrOwner?
        if (_ownerOf(tokenId_) != _sender) revert NotOwner();
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (block.timestamp < _oldLocked.end) revert LockNotExpired();
        uint256 _amount = _oldLocked.amount.toUint256();

        // Burn the NFT
        _burn(tokenId_);
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

    function approve(address, uint256) public pure override(ERC721Upgradeable, IERC721) {
        revert("NFT is non-transferable");
    }

    function setApprovalForAll(address, bool) public pure override(ERC721Upgradeable, IERC721) {
        revert("NFT is non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override(ERC721Upgradeable, IERC721) {
        revert("NFT is non-transferable");
    }

    function _createLock(uint256 amount_, uint256 lockDuration_, address account_) private returns (uint256 tokenId) {
        uint256 unlockTime = ((block.timestamp + lockDuration_) / WEEK) * WEEK; // Lock time is rounded down to weeks

        if (amount_ == 0) revert AmountIsZero();
        if (unlockTime <= block.timestamp) revert LockDurationTooShort();
        if (unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();

        tokenId = nextTokenId++;
        _mint(account_, tokenId);

        _depositFor(tokenId, amount_, unlockTime, locked[tokenId]);
        return tokenId;
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override(ERC721EnumerableUpgradeable)
        returns (address from)
    {
        // Only allow mint (from == address(0)) and burn (to == address(0))
        from = super._ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert("NFT is non-transferable");
        }
        return super._update(to, tokenId, auth);
    }

    // --- Internal helpers ---
    function _checkpoint(uint256 tokenId_, LockedBalance memory oldLocked_, LockedBalance memory newLocked_) internal {
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
                _oldUserPoint.bias = _oldUserPoint.slope * (oldLocked_.end - block.timestamp).toInt128();
            }

            // New lock
            if (newLocked_.end > block.timestamp && newLocked_.amount > 0) {
                _newUserPoint.slope = newLocked_.amount / MAX_TIME.toInt128();
                _newUserPoint.bias = _newUserPoint.slope * (newLocked_.end - block.timestamp).toInt128();
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
            // TODO: check if this is needed
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
                (MULTIPLIER * (block.number - _lastPoint.blockNumber)) / (block.timestamp - _lastPoint.timestamp);
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
                    _initialLastPoint.blockNumber + (_blockSlope * (t_i - _initialLastPoint.timestamp)) / MULTIPLIER;
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
            if (userEpoch != 0 && userPointHistory[tokenId_][userEpoch].timestamp == block.timestamp) {
                userPointHistory[tokenId_][userEpoch] = _newUserPoint;
            } else {
                userPointEpoch[tokenId_] = ++userEpoch;
                userPointHistory[tokenId_][userEpoch] = _newUserPoint;
            }
        }
    }

    function _depositFor(uint256 tokenId_, uint256 amount_, uint256 unlockTime_, LockedBalance memory oldLocked_)
        internal
    {
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
}

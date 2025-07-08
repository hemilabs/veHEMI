// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStakedHemi} from "./interfaces/IStakedHemi.sol";
import {DelegationStorageV1} from "./storage/DelegationStorageV1.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title HemiVoteDelegation
 * @notice Vote delegation system for veHemi tokens. Allows token holders to delegate their voting power
 * to other token holders without transferring ownership. Delegations take effect at the next epoch
 * (next day boundary) and expire when the delegator's lock expires.
 * @dev Based on Curve's veCRV delegation mechanism with adaptations for veHemi
 */
contract HemiVoteDelegation is ReentrancyGuardTransient, DelegationStorageV1 {
    using SafeCast for uint256;
    using SafeCast for int128;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(uint256 delegator,uint256 delegatee,uint256 nonce,uint256 expiry)");

    string public constant name = "veHEMIDelegation";
    string public constant version = "1.0.0";

    /// @notice The veHemi contract that manages locked balances
    IStakedHemi public immutable stakedHemi;

    /// @notice Maximum lock duration (4 years)
    uint256 public constant MAX_LOCK_DURATION = 365 days * 4;
    /// @notice Week duration in seconds
    uint256 public constant WEEK = 7 days;

    // --- Errors ---
    error InvalidStakedHemi();
    error NonExistentToken();
    error CanNotDelegateExpiredLocks();
    error NotOwner();
    error TimestampInFuture();
    error NoExpirations();
    error InvalidSignature();
    error InvalidNonce();
    error SignatureExpired();

    /**
     * @notice Constructor to initialize the vote delegation contract
     * @param stakedHemi_ Address of the veHemi contract
     */
    constructor(address stakedHemi_) {
        if (stakedHemi_ == address(0)) revert InvalidStakedHemi();
        stakedHemi = IStakedHemi(stakedHemi_);
    }

    /**
     * @notice Delegate voting power from one token to another
     * @dev Delegations take effect at the next epoch (next day boundary). The delegator loses
     * their voting power and the delegatee gains it. Delegations expire when the delegator's
     * lock expires. Delegating to self (same tokenId) is equivalent to no delegation.
     * @param delegator_ The token ID to delegate from (must be owned by msg.sender)
     * @param delegatee_ The token ID to delegate to (0 for no delegation, same as delegator_ for self-delegation)
     */
    function delegate(uint256 delegator_, uint256 delegatee_) external {
        if (stakedHemi.ownerOf(delegator_) != msg.sender) revert NotOwner();
        _delegate(delegator_, delegatee_);
    }

    /**
     * @dev Delegates votes from signatory to `delegatee`
     * @param delegator_ The token ID to delegate from (must be owned by msg.sender)
     * @param delegatee_ The token ID to delegate to (0 for no delegation, same as delegator_ for self-delegation)
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        uint256 delegator_,
        uint256 delegatee_,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegator_, delegatee_, nonce, expiry)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        address _signer = ecrecover(digest, v, r, s);
        console2.log(" _signer:", _signer);
        if (_signer == address(0)) revert InvalidSignature();
        if (stakedHemi.ownerOf(delegator_) != _signer) revert NotOwner();
        if (nonce != nonces[_signer]++) revert InvalidNonce();
        if (block.timestamp > expiry) revert SignatureExpired();
        return _delegate(delegator_, delegatee_);
    }

    function getDelegationCheckpoints(
        uint256 tokenId_
    ) external view returns (DelegateCheckpoint[] memory) {
        return delegateCheckpoints[tokenId_];
    }

    /**
     * @notice Get the current voting power for a token
     * @param tokenId_ The token ID to check
     * @return The current voting power (includes both self votes and delegated votes)
     */
    function getVotes(uint256 tokenId_) external view returns (uint256) {
        return _getPastVotes(tokenId_, block.timestamp);
    }

    /**
     * @notice Get the voting power for a token at a specific timestamp
     * @param tokenId_ The token ID to check
     * @param timestamp_ The timestamp to check voting power at (must not be in the future)
     * @return The voting power at the given timestamp
     */
    function getPastVotes(uint256 tokenId_, uint256 timestamp_) external view returns (uint256) {
        if (timestamp_ > block.timestamp) revert TimestampInFuture();
        return _getPastVotes(tokenId_, timestamp_);
    }

    /// @notice The ```calculateExpirations``` function calculates all expired delegations for an account since the last checkpoint.
    /// @dev Can be used in tandem with writeNewCheckpointForExpirations() to write a new checkpoint
    /// @dev Long time periods between checkpoints can increase gas costs for delegate() and castVote()
    /// @dev See _calculateExpirations
    /// @param tokenId_ tokenId of delegate
    /// @return _calculatedCheckpoint A new DelegateCheckpoint to write based on expirations since previous checkpoint
    function calculateExpiredDelegations(
        uint256 tokenId_
    ) public view returns (DelegateCheckpoint memory _calculatedCheckpoint) {
        DelegateCheckpoint[] storage delegationCheckpoints = delegateCheckpoints[tokenId_];

        uint256 _checkpointsLength = delegationCheckpoints.length;

        // Nothing to expire if no one delegated to you
        if (_checkpointsLength == 0) return _calculatedCheckpoint;

        DelegateCheckpoint memory _lastCheckpoint = delegationCheckpoints[_checkpointsLength - 1];

        // This ensures that checkpoints take effect at the next epoch
        uint256 _checkpointTimestamp = ((block.timestamp / 1 days) * 1 days) + 1 days;

        // Nothing expired because the most recent checkpoint is already written
        if (_lastCheckpoint.timestamp == _checkpointTimestamp) {
            return _calculatedCheckpoint;
        }

        (
            uint256 totalExpiredBias_,
            uint256 totalExpiredSlope_,
            uint256 totalExpiredAmount_
        ) = _calculateExpirations({
                tokenId_: tokenId_,
                start_: _lastCheckpoint.timestamp,
                end_: _checkpointTimestamp,
                checkpoint_: _lastCheckpoint
            });

        // All will be 0 if no expirations, only need to check one of them
        if (totalExpiredAmount_ == 0) return _calculatedCheckpoint;

        /// NOTE: Checkpoint values will always be larger than or equal to expired values
        unchecked {
            _calculatedCheckpoint = DelegateCheckpoint({
                timestamp: uint64(_checkpointTimestamp),
                normalizedBias: uint128(_lastCheckpoint.normalizedBias - totalExpiredBias_),
                normalizedSlope: uint64(_lastCheckpoint.normalizedSlope - totalExpiredSlope_),
                totalAmount: uint128(_lastCheckpoint.totalAmount - totalExpiredAmount_),
                fixedBias: 0
            });
        }
    }

    /// @notice The ```writeNewCheckpointForExpirations``` function writes a new checkpoint if any weight has expired since the previous checkpoint
    /// @dev Long time periods between checkpoints can increase gas costs for delegate() and castVote()
    /// @dev See _calculateExpirations
    /// @param tokenId_ tokenId of delegatee
    function writeNewCheckpointForExpiredDelegations(uint256 tokenId_) external {
        DelegateCheckpoint memory _newCheckpoint = calculateExpiredDelegations(tokenId_);

        if (_newCheckpoint.timestamp == 0) revert NoExpirations();

        delegateCheckpoints[tokenId_].push(_newCheckpoint);
    }

    /**
     * @notice Calculate a new checkpoint based on previous checkpoint and changes
     * @dev This function handles the complex logic of updating checkpoints with new delegations
     * and expirations. It ensures that voting power is correctly tracked over time.
     * @param previousCheckpoint_ The previous checkpoint to build upon
     * @param tokenId_ The token ID this checkpoint is for
     * @param isDeltaPositive_ Whether this is adding (true) or removing (false) voting power
     * @param deltaBias_ The change in bias (voting power at current time)
     * @param deltaSlope_ The change in slope (rate of voting power decay)
     * @param deltaAmount_ The change in locked amount
     * @param checkpointTimestamp_ The timestamp for this checkpoint
     * @param previousDelegationEnd_ The end time of the previous delegation (for expiration handling)
     * @return _newCheckpoint The calculated new checkpoint
     */
    function _calculateCheckpoint(
        DelegateCheckpoint memory previousCheckpoint_,
        uint256 tokenId_,
        bool isDeltaPositive_,
        uint256 deltaBias_,
        uint256 deltaSlope_,
        uint256 deltaAmount_,
        uint256 checkpointTimestamp_,
        uint256 previousDelegationEnd_
    ) private view returns (DelegateCheckpoint memory _newCheckpoint) {
        // If this is the first checkpoint, create a new one and early return
        if (previousCheckpoint_.timestamp == 0) {
            return
                DelegateCheckpoint({
                    // can be unsafely cast because values will never exceed uint128 max
                    timestamp: uint64(checkpointTimestamp_),
                    normalizedBias: uint128(deltaBias_),
                    normalizedSlope: uint64(deltaSlope_),
                    totalAmount: uint128(deltaAmount_),
                    fixedBias: 0
                });
        }

        _newCheckpoint.timestamp = previousCheckpoint_.timestamp;
        _newCheckpoint.normalizedBias = previousCheckpoint_.normalizedBias;
        _newCheckpoint.normalizedSlope = previousCheckpoint_.normalizedSlope;
        _newCheckpoint.totalAmount = previousCheckpoint_.totalAmount;

        // All checkpoint fields will never exceed their size so addition and subtraction doesnt need to be checked
        unchecked {
            // Add or subtract the delta to the previous checkpoint
            if (isDeltaPositive_) {
                _newCheckpoint.normalizedBias += uint128(deltaBias_);
                _newCheckpoint.normalizedSlope += uint64(deltaSlope_);
                _newCheckpoint.totalAmount += uint128(deltaAmount_);
            } else {
                // only subtract the weight from this tokenID if it has not already expired in a previous checkpoint
                if (previousDelegationEnd_ > previousCheckpoint_.timestamp) {
                    _newCheckpoint.normalizedBias -= uint128(deltaBias_);
                    _newCheckpoint.normalizedSlope -= uint64(deltaSlope_);
                    _newCheckpoint.totalAmount -= uint128(deltaAmount_);
                }
            }

            // If there have been expirations, incorporate the adjustments by subtracting them from the checkpoint
            if (_newCheckpoint.timestamp != checkpointTimestamp_) {
                (
                    uint256 totalExpiredBias,
                    uint256 totalExpiredSlope,
                    uint256 totalExpiredAmount
                ) = _calculateExpirations(
                        tokenId_,
                        _newCheckpoint.timestamp,
                        checkpointTimestamp_,
                        previousCheckpoint_
                    );

                _newCheckpoint.timestamp = uint64(checkpointTimestamp_);
                _newCheckpoint.normalizedBias -= uint128(totalExpiredBias);
                _newCheckpoint.normalizedSlope -= uint64(totalExpiredSlope);
                _newCheckpoint.totalAmount -= uint128(totalExpiredAmount);
            }
        }
    }

    /**
     * @notice Calculate expired voting power between two timestamps
     * @dev This function handles the complex calculation of how much voting power has expired
     * due to lock expirations between the start and end timestamps.
     * @param tokenId_ The token ID to calculate expirations for
     * @param start_ The start timestamp
     * @param end_ The end timestamp
     * @param checkpoint_ The checkpoint to calculate expirations from
     * @return totalExpiredBias The total expired bias
     * @return totalExpiredSlope The total expired slope
     * @return totalExpiredAmount The total expired amount
     */
    function _calculateExpirations(
        uint256 tokenId_,
        uint256 start_,
        uint256 end_,
        DelegateCheckpoint memory checkpoint_
    )
        private
        view
        returns (uint256 totalExpiredBias, uint256 totalExpiredSlope, uint256 totalExpiredAmount)
    {
        unchecked {
            if (end_ > start_ + MAX_LOCK_DURATION) {
                totalExpiredBias = checkpoint_.normalizedBias;
                totalExpiredSlope = checkpoint_.normalizedSlope;
                totalExpiredAmount = checkpoint_.totalAmount;
            } else {
                // Total values will always be less than or equal to a checkpoint's values
                uint256 currentWeek = WEEK + (start_ / WEEK) * WEEK;
                mapping(uint256 => Expiration) storage delegateExpirations = expiredDelegations[
                    tokenId_
                ];
                // Sum values from currentWeek until end
                while (currentWeek <= end_) {
                    Expiration memory expiration = delegateExpirations[currentWeek];
                    totalExpiredBias += expiration.bias;
                    totalExpiredSlope += expiration.slope;
                    totalExpiredAmount += expiration.amount;
                    currentWeek += WEEK;
                }
            }
        }
    }

    /**
     * @notice Perform binary search to find the closest checkpoint for a given timestamp
     * @dev This function efficiently finds the most recent checkpoint that is at or before
     * the given timestamp using binary search for optimal performance.
     * @param checkpoints_ The array of checkpoints to search through
     * @param timestamp_ The timestamp to search for
     * @return closestCheckpoint_ The closest checkpoint at or before the timestamp
     */
    function _checkpointBinarySearch(
        DelegateCheckpoint[] storage checkpoints_,
        uint256 timestamp_
    ) private view returns (DelegateCheckpoint memory closestCheckpoint_) {
        uint256 checkpointsLength_ = checkpoints_.length;

        // What the newest checkpoint could be for timestamp (rounded to whole days). It will be earlier when checkpoints are sparse.
        uint256 roundedDownTimestamp_ = (timestamp_ / 1 days) * 1 days;
        // Newest checkpoint's timestamp (already rounded to whole days)
        uint256 lastCheckpointTimestamp_ = checkpointsLength_ > 0
            ? checkpoints_[checkpointsLength_ - 1].timestamp
            : 0;
        // The furthest back a checkpoint will ever be is the number of days delta between timestamp and the last
        // checkpoints timestamp. This happens when there was a checkpoint written every single day over that period.
        // If roundedDownTimestamp > lastCheckpointTimestamp that means that we can just use the last index as
        // the checkpoint.
        uint256 delta = lastCheckpointTimestamp_ > roundedDownTimestamp_
            ? (lastCheckpointTimestamp_ - roundedDownTimestamp_) / 1 days
            : 0;
        // low index is equal to the last checkpoints index minus the index delta
        uint256 low = (checkpointsLength_ > 0 && checkpointsLength_ - 1 > delta)
            ? checkpointsLength_ - 1 - delta
            : 0;

        uint256 high = checkpointsLength_;
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (checkpoints_[mid].timestamp > timestamp_) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        closestCheckpoint_ = high == 0 ? closestCheckpoint_ : checkpoints_[high - 1];
    }

    function _delegate(uint256 delegator_, uint256 delegatee_) internal {
        if (delegatee_ != 0 && stakedHemi.ownerOf(delegatee_) == address(0))
            revert NonExistentToken();
        if (delegatee_ == delegator_) delegatee_ = 0;
        if (delegations[delegator_].delegatee == delegatee_) return;

        Delegation memory _previousDelegation = delegations[delegator_];

        uint256 _checkpointTimestamp = ((block.timestamp / 1 days) * 1 days) + 1 days;

        NormalizedVeHemiLockInfo memory _normalizedVeLockInfo = _getNormalizedLockedInfo(
            delegator_,
            _checkpointTimestamp
        );

        _moveVotingPowerFromPreviousDelegate({
            previousDelegation_: _previousDelegation,
            checkpointTimestamp_: _checkpointTimestamp
        });

        _moveVotingPowerToNewDelegate({
            newDelegatee_: delegatee_,
            delegatorVeLockInfo_: _normalizedVeLockInfo,
            checkpointTimestamp_: _checkpointTimestamp
        });

        delegations[delegator_] = Delegation({
            delegatee: delegatee_,
            firstDelegationTimestamp: _previousDelegation.firstDelegationTimestamp == 0
                ? uint48(_checkpointTimestamp)
                : _previousDelegation.firstDelegationTimestamp,
            end: uint48(_normalizedVeLockInfo.end),
            bias: uint96(_normalizedVeLockInfo.bias),
            amount: uint96(_normalizedVeLockInfo.amount),
            slope: uint64(_normalizedVeLockInfo.slope)
        });
    }

    /**
     * @notice Get the total voting power for a token at a specific timestamp
     * @dev This function combines the token's own voting power with any delegated voting power
     * it has received from other tokens.
     * @param tokenId_ The token ID to check
     * @param timestamp_ The timestamp to check voting power at
     * @return The total voting power (self votes + delegated votes)
     */
    function _getPastVotes(uint256 tokenId_, uint256 timestamp_) internal view returns (uint256) {
        uint256 _selfVotes = _getSelfVotesAt(tokenId_, timestamp_);
        uint256 _delegateVotes = _getDelegateVotesAt(tokenId_, timestamp_);
        return _selfVotes + _delegateVotes;
    }

    /**
     * @notice Get the token's own voting power at a specific timestamp
     * @dev A token has its own voting power only if it has never been delegated or if the
     * timestamp is before the first delegation. Once delegated, the token loses its own voting power.
     * @param tokenId_ The token ID to check
     * @param timestamp_ The timestamp to check voting power at
     * @return The token's own voting power (0 if delegated or expired)
     */
    function _getSelfVotesAt(uint256 tokenId_, uint256 timestamp_) internal view returns (uint256) {
        if (stakedHemi.getLockedBalance(tokenId_).end <= timestamp_) return 0;

        uint256 _firstDelegation = delegations[tokenId_].firstDelegationTimestamp;
        if (_firstDelegation == 0 || timestamp_ < _firstDelegation) {
            return stakedHemi.balanceOfNFTAt(tokenId_, timestamp_);
        }
        return 0;
    }

    /**
     * @notice Get normalized lock information for a delegator at a specific timestamp
     * @dev This function calculates the normalized voting power parameters (bias, slope, amount, end)
     * for a delegator at the given checkpoint timestamp. These values are used to track
     * delegated voting power over time.
     * @param delegator_ The token ID of the delegator
     * @param checkPointTimestamp_ The timestamp to calculate the lock info at
     * @return _normalizedVeHemiLockInfo The normalized lock information
     */
    function _getNormalizedLockedInfo(
        uint256 delegator_,
        uint256 checkPointTimestamp_
    ) internal view returns (NormalizedVeHemiLockInfo memory _normalizedVeHemiLockInfo) {
        IStakedHemi.LockedBalance memory _lockedBalance = stakedHemi.getLockedBalance(delegator_);
        uint256 _end = _lockedBalance.end;
        if (_end <= checkPointTimestamp_) revert CanNotDelegateExpiredLocks();

        uint256 _epoch = stakedHemi.userPointEpoch(delegator_);

        IStakedHemi.Point memory _userPoint = stakedHemi.getUserPoint(delegator_, _epoch);

        _normalizedVeHemiLockInfo.slope = _userPoint.slope.toUint256();
        _normalizedVeHemiLockInfo.bias =
            SafeCast.toUint256(_userPoint.bias) +
            (_normalizedVeHemiLockInfo.slope * _userPoint.timestamp);
        _normalizedVeHemiLockInfo.amount = _userPoint.amount;
        _normalizedVeHemiLockInfo.end = _end;
    }

    /**
     * @notice Get delegated voting power for a token at a specific timestamp
     * @dev This function calculates the total voting power that has been delegated to this token
     * by other tokens, taking into account any expirations that have occurred.
     * @param tokenId_ The token ID to check delegated votes for
     * @param timestamp_ The timestamp to check delegated votes at
     * @return _delegatedWeight The total delegated voting power
     */
    function _getDelegateVotesAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256 _delegatedWeight) {
        // Check if delegate token  has any delegations
        DelegateCheckpoint memory _checkpoint = _checkpointBinarySearch({
            checkpoints_: delegateCheckpoints[tokenId_],
            timestamp_: timestamp_
        });

        // If checkpoint is empty, short circuit and return 0 delegated weight
        if (_checkpoint.timestamp == 0) {
            return 0;
        }

        // It's possible that some delegated  veHemi has expired.
        // Add up all expirations during this time period, week by week.
        (uint256 totalExpiredBias, uint256 totalExpiredSlope, ) = _calculateExpirations({
            tokenId_: tokenId_,
            start_: _checkpoint.timestamp,
            end_: timestamp_,
            checkpoint_: _checkpoint
        });

        uint256 expirationAdjustedBias = _checkpoint.normalizedBias - totalExpiredBias;
        uint256 expirationAdjustedSlope = _checkpoint.normalizedSlope - totalExpiredSlope;

        uint256 voteDecay = expirationAdjustedSlope * timestamp_;
        _delegatedWeight = (expirationAdjustedBias > voteDecay)
            ? expirationAdjustedBias - voteDecay
            : 0;
    }

    /**
     * @notice Move voting power away from the previous delegate
     * @dev This function handles removing voting power from the previous delegate when
     * a delegation is changed or removed. It updates checkpoints and expiration records.
     * @param previousDelegation_ The previous delegation information
     * @param checkpointTimestamp_ The timestamp for the checkpoint
     */
    function _moveVotingPowerFromPreviousDelegate(
        Delegation memory previousDelegation_,
        uint256 checkpointTimestamp_
    ) private {
        if (previousDelegation_.delegatee == 0) return;
        // Remove voting power from previous delegate, if they exist

        // Get the last Checkpoint for previous delegate
        DelegateCheckpoint[] storage previousDelegationCheckpoints = delegateCheckpoints[
            previousDelegation_.delegatee
        ];
        uint256 accountCheckpointsLength = previousDelegationCheckpoints.length;
        // NOTE: we know that _accountsCheckpointLength > 0 because we have already checked that the previous delegation exists
        DelegateCheckpoint memory _lastCheckpoint = previousDelegationCheckpoints[
            accountCheckpointsLength - 1
        ];

        if (previousDelegation_.end > checkpointTimestamp_) {
            // Calculations
            Expiration memory expiration = expiredDelegations[previousDelegation_.delegatee][
                previousDelegation_.end
            ];
            // All expiration fields will never exceed their size so subtraction doesnt need to be checked
            // and they can be unsafely cast
            unchecked {
                expiration.bias -= uint96(previousDelegation_.bias);
                expiration.slope -= uint64(previousDelegation_.slope);
                expiration.amount -= uint96(previousDelegation_.amount);
            }

            // Effects
            expiredDelegations[previousDelegation_.delegatee][previousDelegation_.end] = expiration;
        }

        {
            // Calculate new checkpoint
            DelegateCheckpoint memory newCheckpoint = _calculateCheckpoint({
                previousCheckpoint_: _lastCheckpoint,
                tokenId_: previousDelegation_.delegatee,
                isDeltaPositive_: false,
                deltaBias_: previousDelegation_.bias,
                deltaSlope_: previousDelegation_.slope,
                deltaAmount_: previousDelegation_.amount,
                checkpointTimestamp_: checkpointTimestamp_,
                previousDelegationEnd_: previousDelegation_.end
            });

            // Write new checkpoint
            _writeCheckpoint({
                userDelegationCheckpoints_: previousDelegationCheckpoints,
                accountCheckpointsLength_: accountCheckpointsLength,
                newCheckpoint_: newCheckpoint,
                lastCheckpoint_: _lastCheckpoint
            });
        }
    }

    /**
     * @notice Move voting power to the new delegate
     * @dev This function handles adding voting power to the new delegate when
     * a delegation is created or changed. It updates checkpoints and expiration records.
     * @param newDelegatee_ The token ID of the new delegatee (0 for no delegation)
     * @param delegatorVeLockInfo_ The normalized lock information of the delegator
     * @param checkpointTimestamp_ The timestamp for the checkpoint
     */
    function _moveVotingPowerToNewDelegate(
        uint256 newDelegatee_,
        NormalizedVeHemiLockInfo memory delegatorVeLockInfo_,
        uint256 checkpointTimestamp_
    ) private {
        // Get the last checkpoint for the new delegate
        DelegateCheckpoint[] storage newDelegateCheckpoints = delegateCheckpoints[newDelegatee_];
        uint256 _accountCheckpointsLength = newDelegateCheckpoints.length;
        DelegateCheckpoint memory _lastCheckpoint = _accountCheckpointsLength == 0
            ? DelegateCheckpoint({
                timestamp: 0,
                normalizedBias: 0,
                normalizedSlope: 0,
                totalAmount: 0,
                fixedBias: 0
            })
            : newDelegateCheckpoints[_accountCheckpointsLength - 1];

        // Handle expiration
        // Calculations
        Expiration memory _expiration = expiredDelegations[newDelegatee_][delegatorVeLockInfo_.end];

        // NOTE: All expiration fields will never exceed their size so addition doesnt need to be checked
        // and can be unsafely cast
        unchecked {
            _expiration.bias += uint96(delegatorVeLockInfo_.bias);
            _expiration.slope += uint64(delegatorVeLockInfo_.slope);
            _expiration.amount += uint96(delegatorVeLockInfo_.amount);
        }
        // Effects
        expiredDelegations[newDelegatee_][delegatorVeLockInfo_.end] = _expiration;

        // Calculate new checkpoint
        DelegateCheckpoint memory _newCheckpoint = _calculateCheckpoint({
            previousCheckpoint_: _lastCheckpoint,
            tokenId_: newDelegatee_,
            isDeltaPositive_: true,
            deltaBias_: delegatorVeLockInfo_.bias,
            deltaSlope_: delegatorVeLockInfo_.slope,
            deltaAmount_: delegatorVeLockInfo_.amount,
            checkpointTimestamp_: checkpointTimestamp_,
            previousDelegationEnd_: 0
        });

        // Write new checkpoint
        _writeCheckpoint({
            userDelegationCheckpoints_: newDelegateCheckpoints,
            accountCheckpointsLength_: _accountCheckpointsLength,
            newCheckpoint_: _newCheckpoint,
            lastCheckpoint_: _lastCheckpoint
        });
    }

    /**
     * @notice Write a new checkpoint to the user's checkpoint array
     * @dev This function either overwrites the last checkpoint if it has the same timestamp,
     * or pushes a new checkpoint to the array. This ensures efficient storage usage.
     * @param userDelegationCheckpoints_ The array of checkpoints for the user
     * @param accountCheckpointsLength_ The current length of the checkpoints array
     * @param newCheckpoint_ The new checkpoint to write
     * @param lastCheckpoint_ The last checkpoint in the array
     */
    function _writeCheckpoint(
        DelegateCheckpoint[] storage userDelegationCheckpoints_,
        uint256 accountCheckpointsLength_,
        DelegateCheckpoint memory newCheckpoint_,
        DelegateCheckpoint memory lastCheckpoint_
    ) internal {
        // If the newCheckpoint has the same timestamp as the last checkpoint, overwrite it
        if (
            accountCheckpointsLength_ > 0 && lastCheckpoint_.timestamp == newCheckpoint_.timestamp
        ) {
            userDelegationCheckpoints_[accountCheckpointsLength_ - 1] = newCheckpoint_;
        } else {
            // Otherwise, push a new checkpoint
            userDelegationCheckpoints_.push(newCheckpoint_);
        }
    }
}

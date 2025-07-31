// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IVeHemi} from "./interfaces/IVeHemi.sol";
import {VeHemiDelegationStorageV1} from "./storage/VeHemiDelegationStorageV1.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title VeHemiVoteDelegation
 * @notice Vote delegation system for veHemi tokens. Allows token holders to delegate their voting power
 * to other token holders without transferring ownership. Delegations take effect at the next epoch
 * (next day boundary) and expire when the delegator's lock expires.
 * @dev Based on veFXS and veCRV delegation mechanism with adaptations for veHemi
 */
contract VeHemiVoteDelegation is ReentrancyGuardTransientUpgradeable, VeHemiDelegationStorageV1 {
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for int256;

    // --- Constants ---
    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;
    uint256 private constant MAX_LOCK_DURATION = 4 * YEAR;
    uint256 private constant ONE_DAY = 1 days;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice The veHemi contract that manages locked balances
    IVeHemi public immutable veHemi;

    // --- Errors ---
    error InvalidVeHemi();
    error NonExistentToken();
    error CanNotDelegateExpiredLocks();
    error NotOwner();
    error TimestampInFuture();
    error NoExpirations();
    error InvalidSignature();
    error InvalidNonce();
    error SignatureExpired();
    error InvalidDelegatee();
    error CallerIsNotAuthorized();

    modifier onlyAuthorized(uint256 tokenId_) {
        address _msgSender = msg.sender;
        if (_msgSender != veHemi.ownerOf(tokenId_) && _msgSender != address(veHemi))
            revert CallerIsNotAuthorized();
        _;
    }

    /**
     * @notice Constructor to initialize the vote delegation contract
     * @param veHemi_ Address of the veHemi contract
     */
    constructor(address veHemi_) {
        if (veHemi_ == address(0)) revert InvalidVeHemi();
        veHemi = IVeHemi(veHemi_);
        _disableInitializers();
    }

    function initialize() external initializer {}

    /**
     * @notice Delegate voting power from one token to another
     * @dev Delegations take effect at the next epoch (next day boundary). The delegator loses
     * their voting power and the delegatee gains it. Delegations expire when the delegator's
     * lock expires. Delegating to self (same tokenId) is equivalent to no delegation.
     * @param delegator_ The token ID to delegate from (must be owned by msg.sender)
     * @param delegatee_ The wallet address to delegate to (0 for no delegation, same as delegator_ for self-delegation)
     */
    function delegate(
        uint256 delegator_,
        address delegatee_
    ) external onlyAuthorized(delegator_) nonReentrant {
        _delegate(delegator_, delegatee_);
    }

    /**
     * @dev Delegates votes from signatory to `delegatee`
     * @param delegator_ The token ID to delegate from (must be owned by msg.sender)
     * @param delegatee_ delegatee address
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        uint256 delegator_,
        address delegatee_,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("veHEMIDelegation")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegator_, delegatee_, nonce, expiry)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        address _signer = ECDSA.recover(digest, v, r, s);
        if (_signer == address(0)) revert InvalidSignature();
        if (veHemi.ownerOf(delegator_) != _signer) revert NotOwner();
        if (nonce != nonces[_signer]++) revert InvalidNonce();
        if (block.timestamp > expiry) revert SignatureExpired();
        _delegate(delegator_, delegatee_);
    }

    /**
     * @notice Get the delegation checkpoints for a token
     * @param delegatee_ The delegatee_ to get checkpoints for
     * @return The array of delegation checkpoints
     */
    function getDelegationCheckpoints(
        address delegatee_
    ) external view returns (DelegateCheckpoint[] memory) {
        return delegateCheckpoints[delegatee_];
    }

    /**
     * @notice Get the delegation information for a token
     * @param tokenId_ The token ID to check
     * @return The delegation information
     */
    function delegation(uint256 tokenId_) external view returns (Delegation memory) {
        return delegations[tokenId_];
    }

    /**
     * @notice Get the current voting power for a token
     * @param account_ The account to check voting power for
     * @return The current voting power (includes both self votes and delegated votes)
     */
    function getVotes(address account_) external view returns (uint256) {
        return _getPastVotes(account_, block.timestamp);
    }

    /**
     * @notice Get the voting power for a token at a specific timestamp
     * @param account_ The account to check voting power for
     * @param timestamp_ The timestamp to check voting power at (must not be in the future)
     * @return _totalVotes The voting power at the given timestamp
     */
    function getPastVotes(
        address account_,
        uint256 timestamp_
    ) external view returns (uint256 _totalVotes) {
        _totalVotes = _getPastVotes(account_, timestamp_);
    }

    /**
     * @notice Calculate all expired delegations for an account since the last checkpoint
     * @dev Can be used in tandem with writeNewCheckpointForExpirations() to write a new checkpoint
     * @dev Long time periods between checkpoints can increase gas costs for delegate() and castVote()
     * @param delegatee_ delegatee_
     * @return _calculatedCheckpoint A new DelegateCheckpoint to write based on expirations since previous checkpoint
     */
    function calculateExpiredDelegations(
        address delegatee_
    ) public view returns (DelegateCheckpoint memory _calculatedCheckpoint) {
        DelegateCheckpoint[] storage delegationCheckpoints = delegateCheckpoints[delegatee_];

        uint256 _checkpointsLength = delegationCheckpoints.length;

        // Nothing to expire if no one delegated to you
        if (_checkpointsLength == 0) return _calculatedCheckpoint;

        DelegateCheckpoint memory _lastCheckpoint = delegationCheckpoints[_checkpointsLength - 1];

        // This ensures that checkpoints take effect at the next epoch
        uint256 _checkpointTimestamp = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;

        // Nothing expired because the most recent checkpoint is already written
        if (_lastCheckpoint.timestamp == _checkpointTimestamp) {
            return _calculatedCheckpoint;
        }

        (
            uint256 totalExpiredBias_,
            uint256 totalExpiredSlope_,
            uint256 totalExpiredAmount_
        ) = _calculateExpirations({
                delegatee_: delegatee_,
                start_: _lastCheckpoint.timestamp,
                end_: _checkpointTimestamp,
                checkpoint_: _lastCheckpoint
            });

        // All will be 0 if no expirations, only need to check one of them
        if (totalExpiredAmount_ == 0) return _calculatedCheckpoint;

        /// NOTE: Checkpoint values will always be larger than or equal to expired values
        unchecked {
            _calculatedCheckpoint = DelegateCheckpoint({
                timestamp: _checkpointTimestamp.toUint64(),
                normalizedBias: (_lastCheckpoint.normalizedBias - totalExpiredBias_).toUint128(),
                normalizedSlope: (_lastCheckpoint.normalizedSlope - totalExpiredSlope_).toUint64(),
                totalAmount: (_lastCheckpoint.totalAmount - totalExpiredAmount_).toUint128(),
                fixedBias: 0
            });
        }
    }

    /**
     * @notice Write a new checkpoint if any weight has expired since the previous checkpoint
     * @dev Long time periods between checkpoints can increase gas costs for delegate() and castVote()
     * @param delegatee_ delegatee
     */
    function writeNewCheckpointForExpiredDelegations(address delegatee_) external nonReentrant {
        DelegateCheckpoint memory _newCheckpoint = calculateExpiredDelegations(delegatee_);

        if (_newCheckpoint.timestamp == 0) revert NoExpirations();

        delegateCheckpoints[delegatee_].push(_newCheckpoint);
    }

    function _calculateCheckpoint(
        DelegateCheckpoint memory previousCheckpoint_,
        address delegatee_,
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
                    timestamp: checkpointTimestamp_.toUint64(),
                    normalizedBias: deltaBias_.toUint128(),
                    normalizedSlope: deltaSlope_.toUint64(),
                    totalAmount: deltaAmount_.toUint128(),
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
                _newCheckpoint.normalizedBias += deltaBias_.toUint128();
                _newCheckpoint.normalizedSlope += deltaSlope_.toUint64();
                _newCheckpoint.totalAmount += deltaAmount_.toUint128();
            } else {
                // only subtract the weight from this tokenID if it has not already expired
                if (previousDelegationEnd_ > checkpointTimestamp_) {
                    _newCheckpoint.normalizedBias -= deltaBias_.toUint128();
                    _newCheckpoint.normalizedSlope -= deltaSlope_.toUint64();
                    _newCheckpoint.totalAmount -= deltaAmount_.toUint128();
                }
            }

            // If there have been expirations, incorporate the adjustments by subtracting them from the checkpoint
            if (_newCheckpoint.timestamp != checkpointTimestamp_) {
                (
                    uint128 totalExpiredBias,
                    uint64 totalExpiredSlope,
                    uint128 totalExpiredAmount
                ) = _calculateExpirations(
                        delegatee_,
                        _newCheckpoint.timestamp,
                        checkpointTimestamp_,
                        previousCheckpoint_
                    );

                _newCheckpoint.timestamp = checkpointTimestamp_.toUint64();
                _newCheckpoint.normalizedBias -= totalExpiredBias;
                _newCheckpoint.normalizedSlope -= totalExpiredSlope;
                _newCheckpoint.totalAmount -= totalExpiredAmount;
            }
        }
    }

    function _calculateExpirations(
        address delegatee_,
        uint256 start_,
        uint256 end_,
        DelegateCheckpoint memory checkpoint_
    )
        private
        view
        returns (uint128 totalExpiredBias, uint64 totalExpiredSlope, uint128 totalExpiredAmount)
    {
        unchecked {
            if (end_ > start_ + MAX_LOCK_DURATION) {
                totalExpiredBias = checkpoint_.normalizedBias;
                totalExpiredSlope = checkpoint_.normalizedSlope;
                totalExpiredAmount = checkpoint_.totalAmount;
            } else {
                // Total values will always be less than or equal to a checkpoint's values
                uint256 currentSixDayWindow = SIX_DAYS + (start_ / SIX_DAYS) * SIX_DAYS;
                mapping(uint256 => Expiration) storage delegateExpirations = expiredDelegations[
                    delegatee_
                ];
                // Sum values from currentSixDayWindow until end
                while (currentSixDayWindow <= end_) {
                    Expiration memory expiration = delegateExpirations[currentSixDayWindow];
                    totalExpiredBias += expiration.bias;
                    totalExpiredSlope += expiration.slope;
                    totalExpiredAmount += expiration.amount;
                    currentSixDayWindow += SIX_DAYS;
                }
            }
        }
    }

    function _checkpointBinarySearch(
        DelegateCheckpoint[] storage checkpoints_,
        uint256 timestamp_
    ) private view returns (DelegateCheckpoint memory closestCheckpoint_) {
        uint256 checkpointsLength_ = checkpoints_.length;

        // What the newest checkpoint could be for timestamp (rounded to whole days). It will be earlier when checkpoints are sparse.
        uint256 roundedDownTimestamp_ = (timestamp_ / ONE_DAY) * ONE_DAY;
        // Newest checkpoint's timestamp (already rounded to whole days)
        uint256 lastCheckpointTimestamp_ = checkpointsLength_ > 0
            ? checkpoints_[checkpointsLength_ - 1].timestamp
            : 0;
        // The furthest back a checkpoint will ever be is the number of days delta between timestamp and the last
        // checkpoints timestamp. This happens when there was a checkpoint written every single day over that period.
        // If roundedDownTimestamp > lastCheckpointTimestamp that means that we can just use the last index as
        // the checkpoint.
        uint256 delta = lastCheckpointTimestamp_ > roundedDownTimestamp_
            ? (lastCheckpointTimestamp_ - roundedDownTimestamp_) / ONE_DAY
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

    function _delegate(uint256 delegator_, address delegatee_) internal {
        if (msg.sender != address(veHemi) && delegatee_ == address(0)) revert InvalidDelegatee();

        Delegation memory _previousDelegation = delegations[delegator_];

        uint256 _checkpointTimestamp = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;

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
            end: _normalizedVeLockInfo.end.toUint48(),
            bias: _normalizedVeLockInfo.bias.toUint96(),
            amount: _normalizedVeLockInfo.amount.toUint96(),
            slope: _normalizedVeLockInfo.slope.toUint64()
        });
    }

    function _getPastVotes(
        address account_,
        uint256 timestamp_
    ) internal view returns (uint256 _totalVotes) {
        if (timestamp_ > block.timestamp) revert TimestampInFuture();

        return _getDelegateVotesAt(account_, timestamp_);
    }

    function _getNormalizedLockedInfo(
        uint256 delegator_,
        uint256 checkPointTimestamp_
    ) internal view returns (NormalizedVeHemiLockInfo memory _normalizedVeHemiLockInfo) {
        uint256 _end = veHemi.getLockedBalance(delegator_).end;
        if (_end <= checkPointTimestamp_) revert CanNotDelegateExpiredLocks();

        uint256 _epoch = veHemi.userPointEpoch(delegator_);

        IVeHemi.UserPoint memory _userPoint = veHemi.getUserPoint(delegator_, _epoch);

        _normalizedVeHemiLockInfo.slope = _userPoint.point.slope.toUint256();
        _normalizedVeHemiLockInfo.bias =
            _userPoint.point.bias.toUint256() +
            (_normalizedVeHemiLockInfo.slope * _userPoint.point.timestamp);
        _normalizedVeHemiLockInfo.amount = _userPoint.point.amount;
        _normalizedVeHemiLockInfo.end = _end;
    }

    function _getDelegateVotesAt(
        address delegatee_,
        uint256 timestamp_
    ) internal view returns (uint256 _delegatedWeight) {
        // Check if delegate token has any delegations
        DelegateCheckpoint memory _checkpoint = _checkpointBinarySearch({
            checkpoints_: delegateCheckpoints[delegatee_],
            timestamp_: timestamp_
        });

        // If checkpoint is empty, short circuit and return 0 delegated weight
        if (_checkpoint.timestamp == 0) {
            return 0;
        }

        // It's possible that some delegated veHemi has expired.
        // Add up all expirations during this time period, SIX_DAYS by SIX_DAYS.
        (uint256 totalExpiredBias, uint256 totalExpiredSlope, ) = _calculateExpirations({
            delegatee_: delegatee_,
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

    function _moveVotingPowerFromPreviousDelegate(
        Delegation memory previousDelegation_,
        uint256 checkpointTimestamp_
    ) private {
        if (previousDelegation_.delegatee == address(0)) return;
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
                expiration.bias -= previousDelegation_.bias;
                expiration.slope -= previousDelegation_.slope;
                expiration.amount -= previousDelegation_.amount;
            }

            // Effects
            expiredDelegations[previousDelegation_.delegatee][previousDelegation_.end] = expiration;
        }

        {
            // Calculate new checkpoint
            DelegateCheckpoint memory newCheckpoint = _calculateCheckpoint({
                previousCheckpoint_: _lastCheckpoint,
                delegatee_: previousDelegation_.delegatee,
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
        address newDelegatee_,
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
            _expiration.bias += delegatorVeLockInfo_.bias.toUint96();
            _expiration.slope += delegatorVeLockInfo_.slope.toUint64();
            _expiration.amount += delegatorVeLockInfo_.amount.toUint96();
        }
        // Effects
        expiredDelegations[newDelegatee_][delegatorVeLockInfo_.end] = _expiration;

        // Calculate new checkpoint
        DelegateCheckpoint memory _newCheckpoint = _calculateCheckpoint({
            previousCheckpoint_: _lastCheckpoint,
            delegatee_: newDelegatee_,
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

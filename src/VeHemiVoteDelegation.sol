// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IVeHemi} from "./interfaces/IVeHemi.sol";
import {VeHemiDelegationStorageV1} from "./storage/VeHemiDelegationStorageV1.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Minimal interface for reading VeHemi's Ownable2Step owner.
interface IOwnable {
    function owner() external view returns (address);
}

/// @dev Callback interface for relaying DelegateVotesChanged events to the adapter.
interface IAdapterNotify {
    function notifyVotesChanged(address delegatee, uint256 previousVotes, uint256 newVotes) external;
    function notifyDelegateChanged(address delegator, address fromDelegate, address toDelegate) external;
}

/**
 * @title VeHemiVoteDelegation
 * @notice Vote delegation system for veHemi tokens. Allows token holders to delegate their voting power
 * to other token holders without transferring ownership. Delegations take effect at the next epoch
 * boundary and expire when the delegator's lock expires.
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
    uint256 private constant CHECKPOINT_INTERVAL = 1 hours;
    uint256 private constant EPOCH_OFFSET = 0;

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
    error NotTrustedAdapter();
    error NotVeHemiOwner();

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
     * @dev Clock used for flagging checkpoints.
     */
    function clock() public view returns (uint48) {
        return block.timestamp.toUint48();
    }

    /**
     * @dev Machine-readable description of the clock as specified in ERC-6372.
     */
    function CLOCK_MODE() public view virtual returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @notice Delegate voting power from one token to another
     * @dev Delegations take effect at the next epoch boundary. The delegator loses
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
     * @notice Set the trusted adapter contract that can call delegateAllFor
     * @param adapter_ The adapter address (or address(0) to disable)
     */
    function setTrustedAdapter(address adapter_) external {
        if (msg.sender != IOwnable(address(veHemi)).owner()) revert NotVeHemiOwner();
        address oldAdapter = trustedAdapter;
        trustedAdapter = adapter_;
        emit TrustedAdapterUpdated(oldAdapter, adapter_);
    }

    /**
     * @notice Delegate all of an owner's veHEMI positions to a single delegatee.
     * @dev Can only be called by the trusted adapter, which passes through the
     *      real msg.sender as the owner parameter. Expired locks are silently
     *      skipped (they have zero voting power). Sets autoDelegate[owner_] so
     *      future locks created for this owner auto-delegate to delegatee_.
     * @param owner_ The NFT owner whose positions should be delegated
     * @param delegatee_ The address to delegate all voting power to
     */
    function delegateAllFor(
        address owner_,
        address delegatee_
    ) external nonReentrant {
        if (msg.sender != trustedAdapter) revert NotTrustedAdapter();

        // Set auto-delegate so future positions created for this owner
        // are automatically delegated to the same address.
        autoDelegate[owner_] = delegatee_;

        uint256 checkpointTs = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
        uint256 count = veHemi.balanceOf(owner_);
        for (uint256 i; i < count;) {
            uint256 tokenId = veHemi.tokenOfOwnerByIndex(owner_, i);
            // Skip expired locks — they have zero voting power and _delegate
            // would revert with CanNotDelegateExpiredLocks.
            if (veHemi.getLockedBalance(tokenId).end > checkpointTs) {
                _delegate(tokenId, delegatee_);
            }
            unchecked { ++i; }
        }
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
        if (timestamp_ > block.timestamp) revert TimestampInFuture();

        _totalVotes = _getPastVotes(account_, timestamp_);
    }

    /**
     * @dev Returns the total supply of votes available at a specific moment in the past. If the `clock()` is
     * configured to use block numbers, this will return the value at the end of the corresponding block.
     *
     * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
     * Votes that have not been delegated are still part of total supply, even though they would not participate in a
     * vote.
     */
    function getPastTotalSupply(
        uint256 timestamp_
    ) external view returns (uint256 pastTotalSupply) {
        if (timestamp_ > block.timestamp) revert TimestampInFuture();

        pastTotalSupply = veHemi.totalVeHemiSupplyAt(timestamp_);
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
        uint256 _checkpointTimestamp = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;

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

        _calculatedCheckpoint = DelegateCheckpoint({
            timestamp: _checkpointTimestamp.toUint64(),
            normalizedBias: (_lastCheckpoint.normalizedBias - totalExpiredBias_).toUint128(),
            normalizedSlope: (_lastCheckpoint.normalizedSlope - totalExpiredSlope_).toUint64(),
            totalAmount: (_lastCheckpoint.totalAmount - totalExpiredAmount_).toUint128(),
            fixedBias: 0
        });
    }

    /**
     * @notice Write a new checkpoint if any weight has expired since the previous checkpoint
     * @dev Long time periods between checkpoints can increase gas costs for delegate() and castVote()
     * @param delegatee_ delegatee
     */
    function writeNewCheckpointForExpiredDelegations(address delegatee_) external nonReentrant {
        uint256 _checkpointTimestamp = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;

        uint256 _previousVotes = _getPastVotes(delegatee_, _checkpointTimestamp);

        DelegateCheckpoint memory _newCheckpoint = calculateExpiredDelegations(delegatee_);

        if (_newCheckpoint.timestamp == 0) revert NoExpirations();

        delegateCheckpoints[delegatee_].push(_newCheckpoint);

        uint256 _newVotes = _getPastVotes(delegatee_, _checkpointTimestamp);

        emit DelegateVotesChanged({
            delegatee: delegatee_,
            previousVotes: _previousVotes,
            newVotes: _newVotes
        });

        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged(
                delegatee_, _previousVotes, _newVotes
            ) {} catch {}
        }
    }

    /**
     * @notice Emit a DelegateVotesChanged event with the current (decayed) voting power
     * for a given delegatee, and relay it to the adapter.
     * @dev This function writes no state. It exists so that off-chain indexers
     * (e.g. Aragon's subgraph) can be informed of voting-power decay between
     * checkpoints. Anyone can call it (permissionless).
     *
     * Both previousVotes and newVotes in the emitted event are set to the
     * current decayed power. This signals "the authoritative power is now X"
     * without implying any delegation change occurred.
     *
     * This does NOT duplicate writeNewCheckpointForExpiredDelegations, which
     * writes a new checkpoint to reflect expired delegations in storage. This
     * function is purely for event emission.
     * @param delegatee_ The delegatee whose voting power to refresh
     */
    function refreshVotingPower(address delegatee_) public {
        // Use the same next-epoch-boundary timestamp that _delegate and
        // writeNewCheckpointForExpiredDelegations use so that the emitted
        // value is consistent with delegation events. Using block.timestamp
        // would produce a different value (the checkpoint written by _delegate
        // has a future timestamp invisible to block.timestamp queries), which
        // causes the Aragon subgraph to overwrite correct delegation event
        // values with stale pre-delegation ones.
        uint256 checkpointTimestamp = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
        uint256 currentVotes = _getPastVotes(delegatee_, checkpointTimestamp);

        emit DelegateVotesChanged({
            delegatee: delegatee_,
            previousVotes: currentVotes,
            newVotes: currentVotes
        });

        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged(
                delegatee_, currentVotes, currentVotes
            ) {} catch {}
        }
    }

    /**
     * @notice Batch version of refreshVotingPower for multiple delegatees.
     * @dev Iterates over the array and calls refreshVotingPower for each.
     * The caller is responsible for keeping the array length within gas limits.
     * @param delegatees_ Array of delegatee addresses to refresh
     */
    function refreshVotingPowerBatch(address[] calldata delegatees_) external {
        uint256 length = delegatees_.length;
        for (uint256 i; i < length;) {
            refreshVotingPower(delegatees_[i]);
            unchecked { ++i; }
        }
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

    function _checkpointBinarySearch(
        DelegateCheckpoint[] storage checkpoints_,
        uint256 timestamp_
    ) private view returns (DelegateCheckpoint memory closestCheckpoint_) {
        uint256 checkpointsLength_ = checkpoints_.length;

        // What the newest checkpoint could be for timestamp (rounded to epoch boundary). It will be earlier when checkpoints are sparse.
        uint256 roundedDownTimestamp_ = timestamp_ < EPOCH_OFFSET
            ? 0
            : ((timestamp_ - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL + EPOCH_OFFSET;
        // Newest checkpoint's timestamp (already rounded to epoch boundary)
        uint256 lastCheckpointTimestamp_ = checkpointsLength_ > 0
            ? checkpoints_[checkpointsLength_ - 1].timestamp
            : 0;
        // The furthest back a checkpoint will ever be is the number of epochs delta between timestamp and the last
        // checkpoints timestamp. This happens when there was a checkpoint written every single epoch over that period.
        // If roundedDownTimestamp > lastCheckpointTimestamp that means that we can just use the last index as
        // the checkpoint.
        uint256 delta = lastCheckpointTimestamp_ > roundedDownTimestamp_
            ? (lastCheckpointTimestamp_ - roundedDownTimestamp_) / CHECKPOINT_INTERVAL
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

        uint256 _checkpointTimestamp = (((block.timestamp - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL + EPOCH_OFFSET;

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

        emit DelegateChanged({
            delegator: delegator_,
            fromDelegatee: _previousDelegation.delegatee,
            toDelegatee: delegatee_
        });

        // Relay DelegateChanged to adapter with address-based IVotes signature.
        // Resolve tokenId → owner outside try/catch so a revert in ownerOf
        // is not silently swallowed.  All call sites pass valid token IDs,
        // but keeping the resolution explicit avoids a subtle pitfall where
        // argument evaluation happens before Solidity enters try scope.
        if (trustedAdapter != address(0)) {
            address _owner = veHemi.ownerOf(delegator_);
            try IAdapterNotify(trustedAdapter).notifyDelegateChanged(
                _owner,
                _previousDelegation.delegatee,
                delegatee_
            ) {} catch {}
        }
    }

    function _getPastVotes(
        address account_,
        uint256 timestamp_
    ) internal view returns (uint256 _totalVotes) {
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

        uint256 _previousVotes = _getPastVotes(previousDelegation_.delegatee, checkpointTimestamp_);

        if (previousDelegation_.end > checkpointTimestamp_) {
            // Calculations
            Expiration memory expiration = expiredDelegations[previousDelegation_.delegatee][
                previousDelegation_.end
            ];

            expiration.bias -= previousDelegation_.bias;
            expiration.slope -= previousDelegation_.slope;
            expiration.amount -= previousDelegation_.amount;

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

        uint256 _newVotesForPrevDelegatee = _getPastVotes({
            account_: previousDelegation_.delegatee,
            timestamp_: checkpointTimestamp_
        });

        emit DelegateVotesChanged({
            delegatee: previousDelegation_.delegatee,
            previousVotes: _previousVotes,
            newVotes: _newVotesForPrevDelegatee
        });

        // Relay to adapter so the event appears from the voting token address
        // that Aragon's subgraph indexes.
        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged(
                previousDelegation_.delegatee, _previousVotes, _newVotesForPrevDelegatee
            ) {} catch {}
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

        uint256 _previousVotes = _getPastVotes(newDelegatee_, checkpointTimestamp_);

        // Handle expiration
        // Calculations
        Expiration memory _expiration = expiredDelegations[newDelegatee_][delegatorVeLockInfo_.end];
        _expiration.bias += delegatorVeLockInfo_.bias.toUint96();
        _expiration.slope += delegatorVeLockInfo_.slope.toUint64();
        _expiration.amount += delegatorVeLockInfo_.amount.toUint96();

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

        uint256 _newVotesForNewDelegatee = _getPastVotes({
            account_: newDelegatee_,
            timestamp_: checkpointTimestamp_
        });

        emit DelegateVotesChanged({
            delegatee: newDelegatee_,
            previousVotes: _previousVotes,
            newVotes: _newVotesForNewDelegatee
        });

        // Relay to adapter so the event appears from the voting token address
        // that Aragon's subgraph indexes.
        if (trustedAdapter != address(0)) {
            try IAdapterNotify(trustedAdapter).notifyVotesChanged(
                newDelegatee_, _previousVotes, _newVotesForNewDelegatee
            ) {} catch {}
        }
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

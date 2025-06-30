# veHemi

A decentralized voting escrow and delegation system for HEMI tokens. This project implements a time-locked staking system where users can lock their HEMI tokens for up to 4 years to receive voting power and delegate it to other users.

## Overview

veHemi consists of two main contracts:

1. **StakedHemi (veHemi)** - The main voting escrow contract that handles token locking and voting power calculation
2. **HemiVoteDelegation** - The delegation system that allows users to delegate their voting power to other users

## Description

### Voting Power Mechanics

veHemi implements a linear decay voting power system where:

- **Initial voting power**: 1 HEMI locked for 4 years = 1 veHEMI voting power
- **Linear decay**: Voting power decreases linearly over time
- **Example**: After 2 years, 1 HEMI locked for 4 years will have 0.5 veHEMI voting power
- **Maximum lock duration**: 4 years (1,460 days)
- **Formula**: `voting_power = locked_amount * (lock_end_time - current_time) / max_lock_duration`

### Lock Management

#### Creating Locks
- Users can lock HEMI tokens for any duration up to 4 years
- Each lock is represented as a unique, non-transferable NFT
- Lock duration is rounded down to the nearest week
- Minimum lock duration is 1 week

#### Extending Lock Duration
- **Owner-only**: Only the NFT owner can extend the lock duration
- **Must be longer**: New lock duration must be greater than the current lock end time
- **Cannot exceed maximum**: Lock duration cannot exceed 4 years from the current time
- **Function**: `increaseUnlockTime(tokenId, lockDuration)`

#### Increasing Lock Amount
- **Anyone can increase**: Any user can increase the HEMI amount in an existing lock
- **No duration change**: Increasing amount doesn't affect the lock duration
- **Immediate effect**: Additional voting power is available immediately
- **Function**: `increaseAmount(tokenId, amount)`

#### Lock Expiration
- When a lock expires, the user can withdraw their HEMI tokens
- The NFT is burned upon withdrawal
- No voting power remains after lock expiration

### Delegation System

The delegation system allows users to delegate their voting power to other token holders:

- **Epoch-based**: Delegations take effect at the next day boundary
- **Automatic expiration**: Delegations expire when the delegator's lock expires
- **Flexible delegation**: Users can delegate to any valid token ID or to themselves (no delegation)
- **Revocable**: Users can change or revoke delegations at any time

## Architecture

### Core Contracts

```
src/
├── StakedHemi.sol                 # Main voting escrow contract
├── HemiVoteDelegation.sol         # Vote delegation system
├── interfaces/
│   ├── IHemiVoteDelegation.sol    # Delegation interface
│   ├── IRewardDistributor.sol     # Reward distributor interface
│   └── IStakedHemi.sol           # StakedHemi interface
├── libraries/
│   └── SafeCast.sol              # Safe casting utilities
└── storage/
    ├── StakedHemiStorageV1.sol   # StakedHemi storage layout
    └── DelegationStorageV1.sol   # Delegation storage layout
```

### Key Concepts

#### Voting Power Calculation
Voting power is calculated using a bias-slope model:
- **Bias**: Current voting power at a given timestamp
- **Slope**: Rate of voting power decay over time
- **Formula**: `voting_power = bias - (slope * time_since_checkpoint)`

#### Delegation System
- Delegations are stored as checkpoints with timestamps
- Binary search is used to efficiently find voting power at any point in time
- Expired delegations are automatically tracked and can be cleaned up


## Installation & Setup

### Prerequisites
- Node.js (v16 or higher)
- Foundry (latest version)

### Installation
```bash
# Clone the repository
git clone git@github.com:hemilabs/veHEMI.git
cd veHemi

# Install dependencies
forge install

# Build contracts
forge build
```

### Testing
```bash
# Run all tests
forge test

# Run specific test file
forge test --match-contract TestHemiVoteDelegation

# Run with verbose output
forge test -vvv
```

## Usage

### Creating a Lock

```solidity
// Approve HEMI tokens
hemiToken.approve(address(stakedHemi), amount);

// Create lock for 4 years
uint256 tokenId = stakedHemi.createLock(amount, 4 * 365 days);
```

### Delegating Voting Power

```solidity
// Direct delegation
hemiVoteDelegation.delegate(delegatorTokenId, delegateeTokenId);

// Gasless delegation via signature
bytes32 digest = getTypedDataHash(delegator, delegatee, nonce, expiry);
(uint8 v, bytes32 r, bytes32 s) = sign(digest, privateKey);
hemiVoteDelegation.delegateBySig(delegator, delegatee, nonce, expiry, v, r, s);
```

### Checking Voting Power

```solidity
// Current voting power
uint256 votes = hemiVoteDelegation.getVotes(tokenId);

// Voting power at specific timestamp
uint256 pastVotes = hemiVoteDelegation.getPastVotes(tokenId, timestamp);
```


## Deployment

### Prerequisites
- HEMI token contract address
- Owner address
- Reward distributor address (optional)

### Deployment Steps



## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.



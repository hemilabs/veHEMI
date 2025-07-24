# veHemi

A decentralized voting escrow system for HEMI tokens implementing time-locked staking with voting power and incentive distribution.

## Overview

veHemi consists of two main contracts:
1. **veHemi** - Main voting escrow contract handling token locking, voting power calculation, and NFT transfers
2. **HemiVoteDelegation** - Delegation system for voting power

## Core Mechanics

### Voting Power & Incentives

veHemi uses a linear decay system where both voting power and incentives are calculated using the same formula:
- **Formula**: `locked_amount * (lock_end_time - current_time) / max_lock_duration`
- **Voting power**: Determines governance voting weight
- **Incentive distribution**: Determines reward allocation proportion
- **Longer locks = more weight**: Users locking for longer durations get proportionally more voting power and incentives

#### Example: Lock Duration Impact

Consider two users in veHemi:
- **User A**: Locks 100 HEMI for 4 years (single lock)
- **User B**: Locks 100 HEMI for 2 years, then relocks for 2 more years

**User A gets more weight** because:
- Single 4-year lock has higher average voting power over the entire period
- Linear decay curve favors longer initial lock durations
- More consistent incentive distribution throughout the lock period

### Lock Management

- **Duration**: Up to 4 years maximum
- **NFT representation**: Each lock is a unique NFT
- **Transferability**: Default transferable, can be non-transferable
- **Extensions**: Only NFT owner can extend lock duration
- **Amount increases**: Anyone can increase locked amount

### NFT Transferability

- **Default**: Transferable by default
- **Non-transferable**: Created with `transferable = false` (e.g., protocol distributions)
- **Auto-transferable**: Non-transferable NFTs become transferable after first lock duration ends
- **Delegation reset**: Transfers automatically move delegation to self

### Delegation System

- **Epoch-based**: Delegations take effect at next day boundary
- **Flexible**: Delegate to any token ID or self
- **Revocable**: Change or revoke at any time

## Installation & Testing

```bash
# Install and build
forge install
forge build

# Run tests
forge test
```

## Usage Examples

### Creating Locks
```solidity
// Transferable lock
uint256 tokenId = veHemi.createLock(amount, 4 * 365 days);

// Non-transferable lock
uint256 tokenId = veHemi.createLockFor(amount, 4 * 365 days, recipient, false);
```

### Delegation
```solidity
// Direct delegation
hemiVoteDelegation.delegate(delegatorTokenId, delegateeTokenId);

// Check voting power
uint256 votes = hemiVoteDelegation.getVotes(tokenId);
```

### Transfers
```solidity
// Check transferability
bool isTransferable = veHemi.isTransferable(tokenId);

// Transfer NFT
veHemi.transferFrom(from, to, tokenId);
```

## Installation

This repo uses both `foundry` and `hardhat` frameworks, it uses npm to manages all dependencies (foundry libs included), meaning the foundry test will only work after running:

```sh
npm i
```

## Tests

```sh
forge t
```

## Deployment

### Preparation

Before any deployment/upgrade it's recommended to run scripts against local fork chain:

Make sure that the `.env` file has correct params and then run:

```sh
./scripts/start-forked-node.sh
./scripts/test-next-deployment-on-fork.sh
```

### Deployment

Make sure that the `.env` file has correct params and then run:

```sh
npx hardhat deploy --network hemi
```

### Verification

```sh
npx hardhat etherscan-verify --network hemi
```

## License

MIT License



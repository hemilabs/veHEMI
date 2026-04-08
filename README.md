# veHemi

A decentralized voting escrow system for HEMI tokens implementing time-locked staking with voting power and incentive distribution.

## Overview

veHemi consists of three main contracts:
1. **VeHemi** - Main voting escrow contract handling token locking, voting power calculation, and NFT transfers
2. **VeHemiVoteDelegation** - Delegation system for voting power with hourly epoch checkpoints
3. **VeHemiAragonAdapter** - Stateless adapter that presents veHEMI through the IVotes + ERC20-like metadata interface (`balanceOf`, `totalSupply`, `decimals`, `name`, `symbol`) expected by Aragon's TokenVoting plugin

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
- **Minimum for `createLockFor`**: When creating a lock on behalf of another account via `createLockFor`, the amount must be at least 10 HEMI (`MIN_LOCK_FOR_AMOUNT`). `createLock` (self-locks) has no minimum

### NFT Transferability

- **Default**: Transferable by default
- **Non-transferable**: Created with `transferable = false` (e.g., protocol distributions)
- **Auto-transferable**: Non-transferable NFTs become transferable after first lock duration ends
- **Delegation on transfer**: Transfers re-delegate the lock to the recipient — or to the recipient's auto-delegate target if they set one via the Aragon adapter

### Delegation System

- **Epoch-based**: Delegations take effect at the next hourly epoch boundary
- **Per-token**: Each veHEMI NFT can be delegated independently
- **Flexible**: Delegate to any address or self
- **Revocable**: Change or revoke at any time
- **Auto-delegate**: When set via the Aragon adapter, future locks and transfers automatically delegate to the chosen address

### Aragon Governance Integration

The `VeHemiAragonAdapter` enables veHEMI to be used as the voting token for Aragon's TokenVoting plugin. The adapter is a stateless, immutable contract that translates veHEMI's per-NFT delegation model into the standard IVotes interface that Aragon expects.

**How it works:**
- **IVotes compliance**: Implements `getVotes`, `getPastVotes`, `getPastTotalSupply`, `delegates`, `delegate`, and `delegateBySig`. `delegateBySig` reverts with a message pointing to `VeHemiVoteDelegation.delegateBySig`, because the IVotes address-based signature is incompatible with veHEMI's per-tokenId delegation scheme and cannot be transparently forwarded
- **ERC-6372**: Reports `clock()` as `block.timestamp` with `CLOCK_MODE = "mode=timestamp"`
- **Bulk delegation**: `adapter.delegate(delegatee)` delegates ALL of the caller's veHEMI positions to a single address via `delegateAllFor`, matching Aragon's one-click delegation UX
- **Event relay**: Delegation events (`DelegateVotesChanged`, `DelegateChanged`) are relayed from the delegation contract to the adapter address so Aragon's subgraph indexes them correctly
- **Subgraph sync**: `refreshVotingPower` / `refreshVotingPowerBatch` re-emit events with current decayed voting power for keeper-driven subgraph updates
- **Balance display**: `balanceOf` returns total locked HEMI across all positions (not NFT count), providing meaningful data for the Aragon member detail page
- **`delegates(account)` semantics**: Returns the delegatee only when ALL of an account's veHEMI positions are delegated to the same address. Returns `address(0)` if the account has no positions or if positions are split across different delegatees (a consequence of veHEMI's per-NFT delegation model, where there isn't always a single account-wide delegatee)

**Hourly checkpoints**: Delegations activate at the next hourly epoch boundary (up to 1 hour delay). This provides anti-flash-delegation protection while keeping the governance experience responsive. The keeper should call `refreshVotingPowerBatch` periodically to keep the Aragon subgraph in sync with naturally decaying voting power.

## Usage Examples

### Creating Locks
```solidity
// Transferable self-lock at maximum duration (4 years)
uint256 tokenId = veHemi.createLock(amount, 4 * 365.25 days);

// Non-transferable, non-forfeitable lock for another account
// Args: amount, lockDuration, recipient, transferable, forfeitable
//   transferable=false → recipient cannot transfer until first unlock time
//   forfeitable=false  → forfeitAdmin cannot claw back this lock
uint256 tokenId = veHemi.createLockFor(amount, 4 * 365.25 days, recipient, false, false);
```

### Delegation
```solidity
// Per-token delegation (via delegation contract directly)
veHemiVoteDelegation.delegate(tokenId, delegateeAddress);

// Bulk delegation via Aragon adapter (delegates ALL positions)
veHemiAragonAdapter.delegate(delegateeAddress);

// Check voting power
uint256 votes = veHemiVoteDelegation.getVotes(accountAddress);
```

### Transfers
```solidity
// Check transferability
bool isTransferable = veHemi.isTransferable(tokenId);

// Transfer NFT
veHemi.transferFrom(from, to, tokenId);
```

## Installation & Testing

This repo uses both `foundry` and `hardhat` frameworks, but npm manages all dependencies (foundry libs included). Foundry commands will only work after installing dependencies with npm:

```sh
npm i        # install dependencies (including foundry libs)
forge build  # build contracts
forge test   # run tests
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



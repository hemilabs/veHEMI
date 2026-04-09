# veHemi

A decentralized voting escrow system for HEMI tokens implementing time-locked staking with voting power and incentive distribution.

## Overview

veHemi consists of the following contracts:
1. **VeHemi** - Main voting escrow contract (V2) handling token locking, stake weight calculation, NFT transfers, and parallel locked/forfeitable subcurve tracking
2. **VeHemiVoteDelegation** - Delegation system for voting power with hourly epoch checkpoints and auto-delegation support
3. **VeHemiAragonAdapter** - Stateless adapter that presents veHEMI through the IVotes + ERC20-like metadata interface (`balanceOf`, `totalSupply`, `decimals`, `name`, `symbol`) expected by Aragon's TokenVoting plugin
4. **VeHemiStorageV2** - Storage extension appending locked/forfeitable subcurve state after the V1 storage layout

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
- **Minimum amount**: All lock creation (`createLock` and `createLockFor`) requires at least 10 HEMI (`MIN_LOCK_AMOUNT`) to prevent dust lock griefing

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

### Locked & Forfeitable Subcurve Tracking (V2)

VeHemi V2 maintains parallel subcurves alongside the global supply curve to track non-transferable and forfeitable stake weight independently.

**Three supply curves:**
- **Global** (`totalVeHemiSupply`): All positions, decaying linearly to zero at `lock.end`
- **Locked** (`nonTransferableTotalVeHemiSupply`): Non-transferable positions only, bounded by `transferableAfter`
- **Forfeitable** (`forfeitableTotalVeHemiSupply`): Forfeitable subset of locked positions, also bounded by `transferableAfter`

**Invariant:** `forfeitable <= locked <= total` always holds.

**Subcurve transition:** When `block.timestamp >= transferableAfter`, a position exits both the locked and forfeitable subcurves while retaining its full global voting power until `lock.end`. This means:
- A non-transferable position extended past its original `transferableAfter` becomes transferable at the originally promised time
- `increaseUnlockTime` does NOT extend `transferableAfter` — the user's transferability promise is preserved
- The forfeit window is bounded by `transferableAfter` — once a position becomes transferable, it can no longer be forfeited

**Seeding:** The subcurves are initialized via a one-shot `seedAndFinalizeLockedPositions(tokenIds)` call that atomically computes and stores the aggregate bias/slope for all existing non-transferable positions. This function can only be called once (`lockedSeedingFinalized` gate).

**Combined supply view:** `supplyBreakdown()` returns `(total, locked, forfeitable, transferable)` in a single call with defensive caps enforcing the ordering invariant.

### Forfeit Mechanism

- **Forfeitable positions**: Created with `forfeitable = true` via `createLockFor`
- **Forfeit admin**: A privileged address (set by the contract owner) that can claw back forfeitable positions
- **Forfeit window**: Only valid when `block.timestamp < transferableAfter` — once the position becomes transferable, it can no longer be forfeited
- **Token destination**: Forfeited HEMI is transferred to the forfeit admin (`msg.sender`), not the position owner
- **Cleanup**: Forfeit burns the NFT and cleans up all associated storage (locked balance, transferableAfter, forfeitable flag, provider)

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

// Bulk delegation via Aragon adapter (delegates ALL positions + sets auto-delegate)
veHemiAragonAdapter.delegate(delegateeAddress);

// Clear auto-delegate (future positions will self-delegate by default)
veHemiVoteDelegation.clearAutoDelegate();

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

### Supply Queries (V2)

Individual supply functions:
```solidity
// Global aggregate stake weight
uint256 totalSupply = veHemi.totalVeHemiSupply();

// Non-transferable stake weight (locked subcurve)
uint256 lockedSupply = veHemi.nonTransferableTotalVeHemiSupply();

// Forfeitable stake weight (subset of locked)
uint256 forfeitableSupply = veHemi.forfeitableTotalVeHemiSupply();
```

All four values at once with defensive caps enforcing `forfeitable <= locked <= total`:
```solidity
(uint256 total, uint256 locked, uint256 forfeitable, uint256 transferable) = veHemi.supplyBreakdown();
```

Per-position queries:
```solidity
// Stake weight: linearly-decaying bias (NOT the deposited HEMI amount)
uint256 weight = veHemi.balanceOfNFT(tokenId);

// Deposited HEMI amount (constant until withdraw)
int128 amount = veHemi.getLockedBalance(tokenId).amount;
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

### V1 → V2 Upgrade

The V2 upgrade introduces parallel locked/forfeitable subcurves and the Aragon adapter. Two deploy scripts handle this:

1. **`deploy/04_upgrade_vehemi_v2.ts`** — upgrades the VeHemi proxy to the V2 implementation and seeds the locked subcurve. This script batches two transactions for the Gnosis Safe:
   - `upgradeAndCall(proxy, newImpl, "")` — upgrades the proxy. The V2 locked-curve logic is gated by `lockedSeedingFinalized`, so the contract behaves identically to V1 until seeding completes.
   - `seedAndFinalizeLockedPositions(tokenIds)` — initializes the locked + forfeitable subcurves with the aggregate bias/slope of all existing non-transferable positions.

2. **`deploy/05_aragon_adapter.ts`** — deploys the immutable `VeHemiAragonAdapter` and calls `setTrustedAdapter(adapter)` on `VeHemiVoteDelegation` (owner-only, batched for the Gnosis Safe).

⚠️ **`seedAndFinalizeLockedPositions` is one-shot and irreversible.** The function can only be called once (gated by `lockedSeedingFinalized`). The `tokenIds` array MUST include ALL active non-transferable positions, sorted strictly ascending. If any position is missed, the locked subcurve will permanently understate its supply with no recovery path other than a full V3 upgrade. Until seeding completes, `nonTransferableTotalVeHemiSupply()` and `forfeitableTotalVeHemiSupply()` return zero.

**Pre-execution checklist:**
- Re-derive the `LOCKED_TOKEN_IDS` array against current on-chain state (positions where `transferableAfter != 0`, `lock.end > block.timestamp`, `amount > 0`).
- Verify the array is strictly sorted ascending and contains no duplicates.
- Run `forge test --match-path test/ForkUpgradeLockedCurve.t.sol --fork-url $HEMI_RPC_URL` to validate the upgrade against mainnet state.
- Verify Gnosis Safe calldata against the script-generated batch before signing.

After both scripts complete, configure the Aragon TokenVoting plugin to use the deployed adapter address as its voting token.

### Verification

```sh
npx hardhat etherscan-verify --network hemi
```

## License

MIT License



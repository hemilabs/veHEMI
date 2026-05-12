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

**Seeding:** The subcurves are initialized via a 3-phase on-chain enumeration: `markSeedingStarted()` opens the window and snapshots `nextTokenId` into `seedingTargetId`; `seedBatch(maxIterations)` (callable many times) iterates token IDs and accumulates per-position slope/bias deltas; `finalizeSeeding()` materializes the aggregate `LockedPoint`s for both subcurves and flips `lockedSeedingFinalized`. All three phases must execute in a single block (`block.timestamp == seedingStartedAt`), so the deploy script bundles them into one Gnosis Safe MultiSend. The on-chain scan replaces an earlier caller-supplied `tokenIds` array, eliminating both the operator-drift footgun and the adversarial front-run vector where someone could mint a non-transferable position into the gap between off-chain list derivation and Safe execution.

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

### Coverage

`forge coverage` at default settings takes ~15 minutes on this codebase because
it disables the Solidity optimizer (for accurate source-line mapping) and then
runs all 131,072 invariant mutations × 6 invariants × unoptimized bytecode,
plus 1,000-run fuzz tests. Fork tests are NOT a cause — they self-skip
in microseconds when RPC URLs are unset.

**Fast coverage (~5 seconds, smoke-test quality)** — override the
fuzz/invariant run counts via env vars:

```sh
FOUNDRY_FUZZ_RUNS=1 FOUNDRY_INVARIANT_RUNS=1 FOUNDRY_INVARIANT_DEPTH=1 \
  forge coverage --report summary --report lcov
```

Produces per-contract coverage of:
- `src/VeHemi.sol`: **97.89%** lines, 81.38% branches, 95.56% functions
- `src/VeHemiVoteDelegation.sol`: **98.10%** lines, 88.64% branches, **100%** functions
- `src/adapter/VeHemiAragonAdapter.sol`: **100%** lines, branches, functions
- `src/utils/PositionFactory.sol`: **100%** lines, branches, functions

The reduced run counts affect input-space exploration depth but not which
branches of production code get hit (the deterministic test suite already
reaches them all). Full fuzz/invariant exploration remains available by
running `forge test` separately at default settings.

**Full coverage (~15 minutes, default config)**:
```sh
forge coverage --report summary --report lcov
```

**`--ir-minimum` does NOT work** on this codebase — fails with a Yul
stack-too-deep error on VeHemi.sol's curve math. `--via-ir` is silently
ignored by `forge coverage` (Foundry issue #6592).

Additional test-quality signals beyond line coverage:

- **Shadow-accounting stress tests** (`test/VeHemiStressTest.t.sol`) prove
  algebraic equivalence between contract aggregates and an independent
  calculator at every mutation.
- **Invariant suite** (`test/Invariant.t.sol`) with 6 invariants:
  `invariant_tokenConservation`, `invariant_veHemiSupply`, `invariant_votingPower`,
  `invariant_subcurveOrdering`, `invariant_supplyBreakdownConsistency`, and
  `invariant_epochMonotonicity`. Runs 131,072 mutations per invariant per run.
- **Fork tests** — 92 in `test/ForkUpgradeLockedCurve.t.sol` (against Hemi
  mainnet state via `HEMI_RPC_URL`) and 14 in `test/adapter/VeHemiAragonAdapterFork.t.sol`
  (against Ethereum mainnet Aragon OSx via `ETH_RPC_URL`).
- **100% declared-error coverage** — every custom error is exercised by at
  least one `expectRevert` test.
- **Fuzz tests** (32 `testFuzz_*` across the suite) with 1,000 runs per test.

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

The V2 upgrade introduces parallel locked/forfeitable subcurves, hourly delegation epochs, and the Aragon adapter. Two deploy scripts handle this:

1. **`deploy/04_upgrade_vehemi_v2.ts`** — bundles `4 + N` transactions into a single Gnosis Safe MultiSend (executed atomically; all share `block.timestamp`):
   - `upgrade(VeHemiVoteDelegation proxy, new delegation impl)` — upgrades the delegation contract to add hourly checkpoints, `autoDelegate`/`delegateAllFor`/`clearAutoDelegate`, and the trusted-adapter hook consumed by the Aragon adapter.
   - `upgrade(VeHemi proxy, new VeHemi V2 impl)` — upgrades VeHemi to the V2 implementation. The V2 locked-curve logic is gated by `lockedSeedingFinalized`, so the contract behaves identically to V1 until seeding completes.
   - `markSeedingStarted()` — opens the seeding window, snapshots `nextTokenId` into `seedingTargetId`, and freezes `seedingStartedAt = block.timestamp`. While the window is open, `_createLock` rejects new non-transferable mints and `forfeit`/`increaseAmount`/`increaseUnlockTime` reject mutations of existing non-transferable positions, so the seeded set cannot drift mid-flow.
   - `seedBatch(SEED_BATCH_SIZE)` × `N` — `N = ceil(nextTokenId / SEED_BATCH_SIZE) + 1`. Each call iterates a chunk of token IDs in `[lastProcessedId+1, seedingTargetId)`, skipping burned/transferable/expired entries and accumulating slope-change writes for the locked + forfeitable subcurves. The on-chain scan replaces the prior caller-supplied list. The `+1` slack absorbs any mints that race the off-chain `nextTokenId` snapshot — extra calls past the cursor are structural no-ops.
   - `finalizeSeeding()` — requires the cursor to have reached `seedingTargetId - 1`, then advances the global epoch, writes the aggregate `LockedPoint`s for both subcurves, flips `lockedSeedingFinalized`, and clears the accumulator.

   The two `upgrade()` calls use the bare form (not `upgradeAndCall`) — no initializer is called because the `initializer` modifier would revert on already-initialized proxies.

2. **`deploy/05_aragon_adapter.ts`** — deploys the immutable `VeHemiAragonAdapter` and calls `setTrustedAdapter(adapter)` on `VeHemiVoteDelegation` (owner-only, batched for the Gnosis Safe). Includes pre-flight checks (`voteDelegation() != address(0)`, `totalVeHemiSupply() > 0`) and post-deploy ERC-165 verification (`IVotes`, `ERC165`, `ERC6372`).

⚠️ **The seeding flow is one-shot and irreversible.** `markSeedingStarted` sets a latch that is never cleared and `finalizeSeeding` sets `lockedSeedingFinalized = true`; both latches are monotonic. The on-chain scan removes the operator-drift and front-run risks of the prior caller-supplied list, but the **atomicity guard** is load-bearing: `seedBatch` and `finalizeSeeding` revert with `SeedingInProgress` if `block.timestamp != seedingStartedAt`. Cross-block execution would leave slope-change entries at past `subEnd` values as dead storage (the forward-only `_checkpoint` catchup never visits past timestamps).

⚠️ **NEVER submit `markSeedingStarted` outside the same transaction as `seedBatch`/`finalizeSeeding`.** The Safe MultiSend guarantees same-tx execution by construction — DO NOT manually decompose the bundle into separate proposals. If `markSeedingStarted` lands in a different block from the follow-ups, the contract enters a permanent stuck state: the `seedingStarted` latch can't be re-armed, the cross-block atomicity guard rejects every subsequent `seedBatch`/`finalizeSeeding`, and new non-transferable position mints stay blocked until an implementation upgrade migrates the latch state. Existing positions and transferable operations remain unaffected, but the V2 subcurve features and new locked-mint flow are bricked. Recovery requires a fresh proxy upgrade with a custom storage migration — high-friction emergency. Both the contract NatSpec on `markSeedingStarted` and the deploy script structure document this; verify Safe calldata before signing.

**Pre-execution checklist:**
- **Delete any leftover Safe batch staging file** before re-running the deploy script: `rm -f multisig.batch.tmp.json`. The helper that persists the batch (`helpers/safe.ts::saveForSafeBatchExecution`) APPENDS to this file with exact-calldata dedup only — a stale file from a previous run can silently inject extra transactions into the Safe batch. This is the highest-impact pre-flight step.
- Run `./scripts/check-storage-layouts.sh` to confirm the new implementation's storage layout matches the committed golden fixtures.
- Run `forge test --match-path test/ForkUpgradeLockedCurve.t.sol --fork-url $HEMI_RPC_URL` to validate the upgrade against mainnet state.
- Fork-simulate the full MultiSend (e.g., via `./scripts/test-next-deployment-on-fork.sh`) and verify each `seedBatch` sub-call's gas estimate stays under ~25M. If any batch approaches 30M, lower `SEED_BATCH_SIZE` in `deploy/04_upgrade_vehemi_v2.ts` — the `+1` slack means smaller batches just produce a few more no-op calls.
- Verify Gnosis Safe calldata against the script-generated batch before signing. Expected transaction count is `4 + N` where `N = ceil(nextTokenId / SEED_BATCH_SIZE) + 1` — a different count indicates either stale-file contamination, a script bug, or an unexpected mid-script `nextTokenId` drift.

After both scripts complete, configure the Aragon TokenVoting plugin to use the deployed adapter address as its voting token.

### Verification

```sh
npx hardhat etherscan-verify --network hemi
```

## License

MIT License



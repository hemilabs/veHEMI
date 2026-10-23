# veHemi

A decentralized voting escrow system for HEMI tokens implementing time-locked staking with voting power and incentive distribution.

## Overview

veHemi consists of the following contracts:
1. **VeHemi** - Main voting escrow contract (v3.0.0: V2 subcurves plus auto-relock) handling token locking, stake weight calculation, NFT transfers, and parallel locked/forfeitable subcurve tracking
2. **VeHemiVoteDelegation** - Delegation of voting power with auto-delegation support. Delegation changes take effect at `block.timestamp + 1` (from the auto-relock upgrade block until the next hour boundary, dated at that boundary)
3. **VeHemiAragonAdapter** - Stateless adapter that presents veHEMI through the IVotes + ERC20-like metadata interface (`balanceOf`, `totalSupply`, `decimals`, `name`, `symbol`) expected by Aragon's TokenVoting plugin
4. **VeHemiStorageV2/V3, VeHemiDelegationStorageV4** - Append-only storage extensions after the V1 layouts (V2: locked/forfeitable subcurves; V3: auto-relock; V4: booking times and the upgrade-hour window)
5. **VeHemiCurveLib / VeHemiSupplyLib** - Separately deployed libraries that VeHemi DELEGATECALLs for its curve and supply math

## Core Mechanics

### Voting Power & Incentives

veHemi uses a linear decay system where both voting power and incentives are calculated using the same formula:
- **Formula**: `locked_amount * (lock_end_time - current_time) / max_lock_duration`
- **Voting power**: Determines governance voting weight
- **Incentive distribution**: Determines reward allocation proportion
- **Longer locks = more weight**: Users locking for longer durations get proportionally more voting power and incentives
- **Auto-relock**: positions armed with `enableAutoRelock` or `createLockWithAutoRelock` have the constant weight `slope * (R - SIX_DAYS/2)` instead (see [Auto-relock](#auto-relock))

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
- **Amount increases**: Only the NFT owner can increase the locked amount (`increaseAmount` reverts `NotOwner` otherwise; this reverses the earlier permissionless behaviour)
- **Minimum amount**: All lock creation (`createLock`, `createLockFor` and `createLockWithAutoRelock`) requires at least 10 HEMI (`MIN_LOCK_AMOUNT`) to prevent dust lock griefing

### NFT Transferability

- **Default**: Transferable by default
- **Non-transferable**: Created with `transferable = false` (e.g., protocol distributions)
- **Auto-transferable**: Non-transferable NFTs become transferable after first lock duration ends
- **Delegation on transfer**: Transfers re-delegate the lock to the recipient — or to the recipient's auto-delegate target if they set one via the Aragon adapter
- **Auto-relock on transfer**: a transfer of an auto-relock position to another account disables auto-relock first. An approved operator cannot transfer a token to its own owner

### Delegation System

- **Next-block**: a delegation change takes effect at `block.timestamp + 1`; as before, an UNARMED position whose lock ends at or before the next hour boundary cannot be delegated (unless its record is a stranded flat term, which `delegate` retires, booking nothing; an auto-relock position can always be delegated)
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

**Ordering:** `forfeitable <= locked` always holds; `locked <= total` does NOT (an auto-relock non-transferable position counts its constant weight in `total` and its decaying weight in `locked`).

**Subcurve transition:** When `block.timestamp >= transferableAfter`, a position exits both the locked and forfeitable subcurves while retaining its full global voting power until `lock.end`. This means:
- A non-transferable position extended past its original `transferableAfter` becomes transferable at the originally promised time
- `increaseUnlockTime` does NOT extend `transferableAfter` — the user's transferability promise is preserved
- The forfeit window is bounded by `transferableAfter` — once a position becomes transferable, it can no longer be forfeited

**Seeding:** The subcurves are initialized via a 3-phase on-chain enumeration: `markSeedingStarted()` opens the window and snapshots `nextTokenId` into `seedingTargetId`; `seedBatch(maxIterations)` (callable many times) iterates token IDs and accumulates per-position slope/bias deltas; `finalizeSeeding()` materializes the aggregate `LockedPoint`s for both subcurves and flips `lockedSeedingFinalized`. `seedBatch` / `finalizeSeeding` do not check the block; the seeding window must not cross a SIX_DAYS boundary (see `finalizeSeeding`'s NatSpec), so the deploy script bundles them into one Gnosis Safe MultiSend. The on-chain scan replaces an earlier caller-supplied `tokenIds` array, eliminating both the operator-drift footgun and the adversarial front-run vector where someone could mint a non-transferable position into the gap between off-chain list derivation and Safe execution.

**Combined supply view:** `supplyBreakdown()` returns `(total, locked, forfeitable, transferable)` in a single call: raw values; `transferable` saturates at 0.

### Forfeit Mechanism

- **Forfeitable positions**: Created with `forfeitable = true` via `createLockFor`
- **Forfeit admin**: A privileged address (set by the contract owner) that can claw back forfeitable positions
- **Forfeit window**: Only valid when `block.timestamp < transferableAfter` — once the position becomes transferable, it can no longer be forfeited
- **Token destination**: Forfeited HEMI is transferred to the forfeit admin (`msg.sender`), not the position owner
- **Cleanup**: Forfeit burns the NFT and cleans up all associated storage (locked balance, transferableAfter, forfeitable flag, provider) AND the per-token delegation cache in `VeHemiVoteDelegation.delegations[id]`

### V2.1 Patch Notes (Delegation Cleanup)

The V2.1 implementation upgrade fixes a stale-cache bug in the forfeit path:

- **Bug**: when `forfeit(id)` ran within the last hour of a lock's lifetime (`block.timestamp + 1h > lock.end`), the outer near-expiry guard short-circuited the `voteDelegation.delegate(id, address(0))` cleanup call, leaving `delegations[id]` populated forever after the NFT was burned. Vote tallies were unaffected (slope-change roll-off still handled by the checkpoint walk), but `delegation(burnedId)` returned stale data for indexers and frontends.
- **Fix**: two-part — `VeHemi._delegate` now lets `delegatee_ == address(0)` cleanup calls pass through the guard unconditionally, and `VeHemiVoteDelegation._delegate` invokes `_getNormalizedLockedInfo` only in the new-delegatee branch so cleanup tolerates at-or-near-expiry locks.
- **Indexer impact**: post-upgrade, near-expiry forfeits emit `DelegateChanged(id, prev, address(0))` and `DelegateVotesChanged` events from the Aragon adapter that pre-upgrade were silently dropped. Event signatures are unchanged; consumers that already handle the regular forfeit path will absorb the new cases automatically. No back-fill events are emitted for pre-upgrade stale records (they remain frozen and benign — the NFT is burned, so `ownerOf` reverts and downstream reads can gate on that).
- **Tests**: regression coverage lives in `test/DelegationBehavior.t.sol` (3 boundary tests including a sub-hour sweep at `{1, 60, 3599, 3600, 3601}` seconds before lock end), `test/VeHemiForfeitableCurve.t.sol::test_Forfeit_JointAccountingDecrement` (per-accumulator exact-delta pin), and `test/adapter/VeHemiAragonAdapter.t.sol::test_relay_onForfeit_nearExpiry` (adapter relay liveness on the previously-buggy path). Fuzzed by `invariant_pastVotesImmutability` and `invariant_adapterRelayParity` in `test/Invariant.t.sol` (20 invariants × 1024 runs × 128 depth).

### V2.1 Patch Notes (updateVoteDelegation Safety)

The V2.1 implementation also addresses a hazard of `VeHemi.updateVoteDelegation`, a single-SSTORE pointer swap that performs zero state migration. Calling it on a freshly-deployed `VeHemiVoteDelegation` proxy silently zeros every voter's stake, breaks in-flight Aragon proposals, and severs the event-relay path until each user manually re-delegates. The mitigation has three parts:

- **Strong NatSpec warning** on `VeHemi.updateVoteDelegation` documenting the silent-orphaning failure mode, the in-flight-proposal brick risk, and the mandatory operator runbook. Operators reading the source saw the exact pre-flight checklist (deploy new VVD → snapshot → import → seal → swap); the checklist now lives in [`docs/VOTE_DELEGATION_RECOVERY.md`](docs/VOTE_DELEGATION_RECOVERY.md), which the NatSpec points to.
- **State-migration tooling on `VeHemiVoteDelegation`** (new `VeHemiDelegationStorageV3` chain at slot 50):
  - `importDelegationsFromLegacy(legacy, tokenIds)` — owner-only (VeHemi owner). Reads `delegation(id)` from the legacy VVD and replays it via `_delegate` so checkpoint history begins building forward in the new contract. Idempotent. Emits `LegacyDelegationImported`.
  - `importAutoDelegatesFromLegacy(legacy, owners)` — same pattern for `autoDelegate` mappings. Emits `AutoDelegateSet` + `LegacyAutoDelegateImported`.
  - `finalizeMigration()` — one-way latch sealing the import path. After this call, the import functions revert permanently with `MigrationFinalizedError`, preventing any post-migration state injection that would corrupt future `getPastVotes` history.
- **Operator runbook** (encoded in NatSpec on `updateVoteDelegation` at the time; now [`docs/VOTE_DELEGATION_RECOVERY.md`](docs/VOTE_DELEGATION_RECOVERY.md)): the original V2.1 runbook required the new VVD's `importDelegationsFromLegacy` + `importAutoDelegatesFromLegacy` + `setTrustedAdapter` + `finalizeMigration` to execute in the same Safe MultiSend as the final `veHemi.updateVoteDelegation(newVVD)` call; at mainnet scale the imports span several Safe transactions, so `finalizeMigration` and the swap go last, in one MultiSend (optionally after late imports of entries still missing), forfeits are disabled for the whole window, and a reconcile follows the swap (`scripts/plan-legacy-migration.ts` prints the transactions).
- **Tests**: end-to-end runbook coverage in `test/HIGH2_LegacyImport.t.sol` (28 tests), including:
  - `test_endToEndMigrationRunbook_preservesVotes` — full operator flow → delegate votes preserved post-swap
  - `test_withoutImport_swapZerosVotes_documentedBug` — proves that a swap with no import leaves the new module with no delegation record and zero votes, so operators who skip the import path lose state
  - Idempotency, access control (only VeHemi owner), legacy-address validation, finalize semantics, post-finalize reverts
- **Bytecode impact**: zero on VeHemi (NatSpec only). VeHemiVoteDelegation grew from 14,185B to 16,364B (+2,179B), leaving an 8,212B EIP-170 margin (down from 10,391B before the migration tooling), at the time.
- **Limitation (out-of-scope for V2)**: historical `getPastVotes` queries for blocks BEFORE the migration return zero on the new contract — the import replays delegations via `_delegate` which builds NEW checkpoints starting at the next epoch boundary. Operators MUST schedule the migration during a governance freeze (no in-flight proposals) to avoid bricking proposals whose snapshot block precedes the swap. A full historical checkpoint copy was deferred to V3 alongside the planned library extraction. (At the time; since the auto-relock upgrade a freshly deployed, initialized module dates imports at `block.timestamp + 1`, and 3.0.0 has no historical copy either.)

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
- **Account-wide `DelegateChanged`**: `DelegateChanged` is only emitted when the post-change state is account-wide consistent (all NFTs delegated to the same address, including `address(0)`). Mixed-state per-tokenId calls from multi-token owners are silently skipped, and `adapter.delegate(addr)` emits exactly one consolidated event after the batch (using an EIP-1153 transient flag to suppress the per-token relay). This preserves `delegateAllFor`'s O(N) gas profile

**Delegation timing**: delegations take effect at `block.timestamp + 1`, so a delegation is never counted in the block that makes it. Aragon's quorum denominator (`getPastTotalSupply(t)`) reads supply at `t - 1`. Voting power keeps decaying with no event; a keeper should call `refreshVotingPowerBatch` periodically to keep the Aragon subgraph in sync.

**The deployed adapter predates the auto-relock upgrade.** Its verified NatSpec describes the hourly dating: `refreshVotingPower` now reports power at `block.timestamp + 1` (at the hour boundary only during the upgrade hour), and `delegate(addr)` also re-delegates auto-relock positions whose `getLockedBalance(id).end` is in the past.

### Auto-relock

An owner can freeze a position's remaining lock time so that its weight stops decaying: `enableAutoRelock(tokenId)` on an existing position, or `createLockWithAutoRelock(amount, duration, transferable, forfeitable)` for a new one.

- **Weight**: constant at `slope * (R - SIX_DAYS/2)`, where R (`autoRelockRemaining`, in seconds) is the whole SIX_DAYS buckets from the start of the current bucket to `end`, at least two buckets.
- **Unlocking**: `withdraw` reverts while auto-relock is enabled; `disableAutoRelock(tokenId)` resumes linear decay over R. Read `effectiveLockEnd(tokenId)` for the unlock time: while armed, `getLockedBalance(tokenId).end` is not one.
- **Heartbeat**: the owner must call `refreshAutoRelock(tokenId)` at least every `STALE_FLAT_BUCKETS * SIX_DAYS` (365.25 days); from `autoRelockStaleAt(tokenId)` on, anyone may call `retireStaleAutoRelock(tokenId)`.
- **Transfers**: a transfer to another account disables auto-relock inside the transfer.
- **Gas limit**: when the position is delegated, calls that book or retire an auto-relock term (`enableAutoRelock`, `disableAutoRelock`, `retireStaleAutoRelock`, `increaseAmount`/`increaseUnlockTime` on an armed position, and the fallback removal of an armed transfer whose move was refused) need a gas LIMIT of about 8.8 million (with no reward distributor installed and the global point current; each distributor notification before the floor, and each six-day bucket of global catch-up, adds its cost, and the fallback removal needs more when the refused move's delegatees were not checkpointed for months) — far above the gas they use: 8,176,984 gas must remain at the re-delegation, on top of what the call spends before it. `createLockWithAutoRelock` needs about 9.2 million with no distributor, more when the owner already holds many positions (up to about 17 million) or when its first booking goes to a delegatee not checkpointed for months; if the reward distributor spends more than about 6.8 million gas per `updateRewards` call (less for an owner with many positions) it cannot fit in a block (use `createLock`, then `enableAutoRelock`). A shorter limit reverts `DelegationCallStarved`, so an `eth_estimateGas` of a transaction that calls VeHemi directly already accounts for it; a caller that catches the revert (a try/catch loop, Multicall3 with `allowFailure`, a Safe transaction with `safeTxGas != 0`, an action allowed to fail) must forward that much gas explicitly and check the result.

The integrator-facing details — events, errors, armed semantics of existing views, monitoring — are in [`docs/AUTO_RELOCK_INTEGRATOR_NOTICE.md`](docs/AUTO_RELOCK_INTEGRATOR_NOTICE.md).

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

All four values at once (raw values; `transferable` saturates at 0):
```solidity
(uint256 total, uint256 locked, uint256 forfeitable, uint256 transferable) = veHemi.supplyBreakdown();
```

Per-position queries:
```solidity
// Stake weight: linearly-decaying bias, or the constant weight of an auto-relock position (NOT the deposited HEMI amount)
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

`forge coverage` at default settings takes well over an hour on this codebase
(the invariant campaigns alone take about 45 minutes on 16 cores in a plain
`forge test`, with the optimizer on) because it disables the Solidity optimizer
(for accurate source-line mapping) and then runs every invariant campaign at
1024 runs × 128 depth on unoptimized bytecode, plus 1,000-run fuzz tests. Fork
tests are NOT a cause — they self-skip in microseconds when RPC URLs are unset.

**Fast coverage (smoke-test quality)** — override the
fuzz/invariant run counts via env vars:

```sh
FOUNDRY_FUZZ_RUNS=1 FOUNDRY_INVARIANT_RUNS=1 FOUNDRY_INVARIANT_DEPTH=1 \
  forge coverage --report summary --report lcov
```

Run the command for current per-contract figures.

The reduced run counts affect input-space exploration depth but not which
branches of production code get hit (the deterministic test suite already
reaches them all). Full fuzz/invariant exploration remains available by
running `forge test` separately at default settings.

**Full coverage (well over an hour, default config)**:
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
- **Invariant suites**: `test/Invariant.t.sol` (20 invariants over the escrow,
  the subcurves, delegation and the adapter relay), `test/AutoRelockInvariant.t.sol`
  (7 auto-relock invariants: flat weight, restored end, past votes never above
  the past total supply) and `test/arl/ARLInvariant.t.sol` (one campaign that
  checks the auto-relock laws against an independently authored ledger). The
  default profile runs 1024 runs x 128 depth; CI's pull-request job runs them at
  128 x 128 (two campaigns carry inline overrides: 32 x 128 and 128 x 64) and
  the scheduled job at the full budget.
- **Auto-relock gas floor** (`test/j11/J11Gate.t.sol`): for every call that books
  or retires an auto-relock term, finds the smallest committing gas limit and
  checks below it (refused with `DelegationCallStarved`), above it (exact), and at
  an emulated `eth_estimateGas` limit, with the delegation module called directly
  and behind an ERC1967 proxy (the armed transfer's floor is covered in
  `test/td24/`).
- **Auto-relock upgrade on a Hemi fork** (`test/r31/`, pinned by `R31_FORK_BLOCK`,
  default 5,524,738): the upgrade-hour window at seven execution offsets, rollback
  and re-forward, state identity with the live writer, and reader continuity
  across the batch. The deploy script itself is rehearsed end to end by
  `npm run test:hardhat:fork:autorelock`.
- **Fork tests** — 100 in `test/ForkUpgradeLockedCurve.t.sol` (against Hemi
  mainnet state via `HEMI_RPC_URL`) and 14 in `test/adapter/VeHemiAragonAdapterFork.t.sol`
  (against Ethereum mainnet Aragon OSx via `ETH_RPC_URL`).
- **Declared-error coverage** — every reachable custom error is exercised by at
  least one test that checks its selector, except the zero-address refusal of
  the `VeHemiVoteDelegation` constructor (`InvalidVeHemi`; the same selector is
  checked on `PositionFactory`). `NoExistingLock`, `EndBelowTransferableAfter`,
  `AdditiveBranchExpectsZeroEnd` and `InvalidSignature` are defensive and
  unreachable by construction (`ECDSA.recover` reverts rather than return the
  zero address that `InvalidSignature` checks for).
- **Fuzz tests**: 37 `testFuzz_*` across the suite, most at 1,000 runs.

## Deployment

### Preparation

Before any deployment/upgrade it's recommended to run scripts against local fork chain:

Make sure that the `.env` file has correct params and then run:

```sh
./scripts/start-forked-node.sh
./scripts/test-next-deployment-on-fork.sh
```

### Initial deployment

The untagged run is V1/V2 history and does not complete on any chain today: it never gets past `deploy/03`, which deploys a contract this repository does not contain (`RestakeManager`). Never run it against Hemi: before it stops it redeploys implementations, queues their upgrade legs into the Safe batch file and overwrites the deployment records (see [`docs/AUTO_RELOCK_UPGRADE.md`](docs/AUTO_RELOCK_UPGRADE.md), section 5).

```sh
npx hardhat deploy --network hemi
```

### Auto-relock upgrade

Run `npx hardhat --network hemi deploy --tags AutoRelockUpgrade` (NOT an untagged run). It deploys the two libraries and both implementations and proposes ONE MultiSend `[upgrade(VeHemi), upgradeAndCall(VVD, impl, armLegacyDatingWindow())]`; never split or hand-build it. After execution run `D1_POST_CHECK_ONLY=1 npx hardhat --network hemi deploy --tags AutoRelockUpgrade` (archive RPC). Rehearse with `HEMI_RPC_URL=<archive RPC> HEMI_FORK_BLOCK=<signing pin> npm run test:hardhat:fork:autorelock` and `HEMI_RPC_URL=<archive RPC> R31_FORK_BLOCK=<same pin> forge test --match-path 'test/r31/*' --threads 1 -vv` (the pin in digits only; the logged `fork block` must equal it; both must report no failure, the deploy rehearsal no pending body, and the `test/r31` summary 0 skipped, except at a signing block after an in-window rollback, where exactly the two `R31Transition` plain-upgrade fallback bodies skip by design and the deploy rehearsal's `rollback limits, control` body fails (pre-flight 5b counts the rolled-back forward's VeHemi `Upgraded` log as a VeHemi-leg rollback); run the deploy rehearsal from a tree whose `deployments/hemi/` names the live implementations, e.g. a scratch clone of the reviewed commit; see the runbook, section 4; 5,524,738 is the default `R31_FORK_BLOCK`). The full runbook — signer checklist, upgrade-hour window, rollback limits, post-execution check and monitoring — is [`docs/AUTO_RELOCK_UPGRADE.md`](docs/AUTO_RELOCK_UPGRADE.md). The Aragon adapter is not part of this upgrade.

### V1 → V2 Upgrade (history)

The V2 upgrade introduces parallel locked/forfeitable subcurves, hourly delegation epochs, and the Aragon adapter. Two deploy scripts handle this:

1. **`deploy/04_upgrade_vehemi_v2.ts`** — bundles `4 + N` transactions into a single Gnosis Safe MultiSend (executed atomically; all share `block.timestamp`):
   - `upgrade(VeHemiVoteDelegation proxy, new delegation impl)` — upgrades the delegation contract to add hourly checkpoints, `autoDelegate`/`delegateAllFor`/`clearAutoDelegate`, and the trusted-adapter hook consumed by the Aragon adapter.
   - `upgrade(VeHemi proxy, new VeHemi V2 impl)` — upgrades VeHemi to the V2 implementation. The V2 locked-curve logic is gated by `lockedSeedingFinalized`, so the contract behaves identically to V1 until seeding completes.
   - `markSeedingStarted()` — opens the seeding window, snapshots `nextTokenId` into `seedingTargetId`, and freezes `seedingStartedAt = block.timestamp`. While the window is open, `_createLock` rejects new non-transferable mints and `forfeit`/`increaseAmount`/`increaseUnlockTime` reject mutations of existing non-transferable positions, so the seeded set cannot drift mid-flow.
   - `seedBatch(SEED_BATCH_SIZE)` × `N` — `N = ceil(nextTokenId / SEED_BATCH_SIZE) + 1`. Each call iterates a chunk of token IDs in `[lastProcessedId+1, seedingTargetId)`, skipping burned/transferable/expired entries and accumulating slope-change writes for the locked + forfeitable subcurves. The on-chain scan replaces the prior caller-supplied list. The `+1` slack absorbs any mints that race the off-chain `nextTokenId` snapshot — extra calls past the cursor are structural no-ops.
   - `finalizeSeeding()` — requires the cursor to have reached `seedingTargetId - 1`, then advances the global epoch, writes the aggregate `LockedPoint`s for both subcurves, flips `lockedSeedingFinalized`, and clears the accumulator.

   The two `upgrade()` calls use the bare form (not `upgradeAndCall`) — no initializer is called because the `initializer` modifier would revert on already-initialized proxies.

2. **`deploy/05_aragon_adapter.ts`** — deploys the immutable `VeHemiAragonAdapter` and calls `setTrustedAdapter(adapter)` on `VeHemiVoteDelegation` (owner-only, batched for the Gnosis Safe). Includes pre-flight checks (`voteDelegation() != address(0)`, `totalVeHemiSupply() > 0`) and post-deploy ERC-165 verification (`IVotes`, `ERC165`, `ERC6372`).

⚠️ **The seeding flow is one-shot and irreversible.** `markSeedingStarted` sets a latch that is never cleared and `finalizeSeeding` sets `lockedSeedingFinalized = true`; both latches are monotonic. The on-chain scan removes the operator-drift and front-run risks of the prior caller-supplied list, but `seedBatch` / `finalizeSeeding` do not check the block: the operator constraint is that the seeding window must not cross a SIX_DAYS boundary (see `finalizeSeeding`'s NatSpec). The Hemi mainnet seeding ran in a 252 s window inside one bucket.

⚠️ **(History, V2 rollout.) NEVER split scripts 04 and 05 across separate Safe proposals.** Run `npx hardhat --network hemi deploy` without a `--tags` filter so the full 00→07→99 sequence executes in one invocation; both scripts append to the same `multisig.batch.tmp.json` and script 99 (`runAtTheEnd: true`) proposes the accumulated batch as a single Safe MultiSend. Splitting them (e.g., `--tags VeHemiV2Upgrade` followed days later by `--tags VeHemiAragonAdapter`) creates an adapter-bootstrap window during which `trustedAdapter == address(0)` on the upgraded VVD: every `_delegate` notify hook is silently skipped (Aragon's subgraph sees zero `DelegateChanged`/`DelegateVotesChanged` events), and `delegateAllFor` reverts with `NotTrustedAdapter`, bricking `adapter.delegate(X)` entirely. Script 05's pre-flight aborts if VVD is still V1 on-chain and the Safe batch file is empty. `helpers/safe.ts` refuses to run if a non-empty batch file from an earlier run is present: it moves it to `multisig.batch.tmp.json.stale-<time>` and prints how to restore and propose it (`PROPOSE_EXISTING_BATCH=1 … --tags safe`). Never `rm` it: it may be the only record of a queued upgrade.

⚠️ **(History, V2 rollout; mainnet seeding is finalized.) NEVER submit `markSeedingStarted` outside the same transaction as `seedBatch`/`finalizeSeeding`.** The Safe MultiSend guarantees same-tx execution by construction — DO NOT manually decompose the bundle into separate proposals. `seedBatch` and `finalizeSeeding` have no same-block guard: anyone may run them, in later blocks. A single transaction executes at a single timestamp, so one MultiSend cannot cross the SIX_DAYS boundary above. Between `markSeedingStarted` and `finalizeSeeding`, non-transferable mints, `forfeit`, and `increaseAmount` / `increaseUnlockTime` on non-transferable positions revert `SeedingInProgress`; transferable positions are unaffected.

**Pre-execution checklist:**
- **A leftover Safe batch staging file is refused at process start** by `helpers/safe.ts` (module load, before any deploy script body runs): a non-empty `multisig.batch.tmp.json` is moved to `multisig.batch.tmp.json.stale-<time>` and the run stops with instructions to restore and propose it. Never `rm` it.
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



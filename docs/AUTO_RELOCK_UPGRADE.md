# Auto-relock upgrade: operator and signer runbook

This upgrade moves the live veHEMI proxies on Hemi mainnet (chain 43111) to the
auto-relock implementations. It is run with `deploy/08_upgrade_autorelock.ts`
and proposed to the Safe as **one** MultiSend. The Aragon adapter is not part of
it.

| Contract | Address |
| --- | --- |
| VeHemi proxy | `0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89` |
| VeHemiVoteDelegation (VVD) proxy | `0xBF5b2f370370494B8A4575962512dd3ea7c29e2d` |
| DefaultProxyAdmin | `0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F` |
| Safe (owner of VeHemi and of the ProxyAdmin) | `0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6` |
| MultiSendCallOnly 1.4.1 | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| HEMI token | `0x99e3dE3817F6081B2568208337ef83295b7f591D` |
| Live VeHemi implementation (before the upgrade) | `0xf1e3AA617E5011793F759092b59d22247E57b84A` |
| Live VVD implementation (before the upgrade) | `0xAcAA0d96121C035fC21345551317d66921394128` |
| Deployed Aragon adapter (unchanged) | `0x3f41c138082b29fb1a6c91066e73480163f984e4` |

## 1. What the run does

From the deployer EOA (no Safe, no quorum; harmless until the proxies point at
them):

1. deploy `VeHemiCurveLib`
2. deploy `VeHemiSupplyLib`
3. deploy the VeHemi implementation, linked against 1 and 2 (five link sites)
4. deploy the VVD implementation

Queued into one Safe MultiSend (`deploy/99_safe-txs.ts` proposes it), in this
order:

5. `DefaultProxyAdmin.upgrade(VeHemi proxy, new VeHemi implementation)`
6. `DefaultProxyAdmin.upgradeAndCall(VVD proxy, new VVD implementation, 0x62c0fe7a)`
   — `0x62c0fe7a` is `armLegacyDatingWindow()`; value 0

**Never split the two legs, and never hand-build the forward batch** (the only
hand-built transactions are the rollback of section 8 and the recovery legs of
section 9).

- VVD first leaves the new VVD under the live VeHemi. The new VVD calls
  `veHemi.autoRelockRemaining`, which the live VeHemi does not have. Every
  direct delegation write reverts, and every update the live VeHemi triggers
  (mint, increase, transfer) is dropped with `DelegationUpdateFailed`.
- VeHemi first leaves the new VeHemi over the live VVD. The arming guard's
  window probe fails open there, because the live VVD has no
  `legacyDatingActive`, so holders can arm. The live VVD books such a record as
  decaying weight with an expiry bucket while its shape is flat. Once the VVD leg
  lands, every move of that record either reverts or takes its weight out of the
  delegatee's other flat terms. The last of those terms can then never be
  removed: permanent votes with no locked HEMI behind them.

`deploy/08` asserts the order, the targets, the payload, the value and the
from-implementations of the queued batch. `deploy/99` re-checks it against the
chain when it proposes.

## 2. Behaviour that changes at execution, for every caller

Auto-relock itself is opt-in. These changes do not wait for anyone to opt in:

1. `getPastTotalSupply(t)` (the Aragon quorum denominator) is evaluated at
   `t - 1` instead of `t`. Every in-flight proposal's denominator is
   re-evaluated at the upgrade block. The change is tiny and deliberate: the
   denominator then sees exactly the lock changes that `getPastVotes(., t)` sees.
2. From the hour boundary that ends the execution hour, every delegation write
   is dated `block.timestamp + 1` instead of the next hour boundary. Vote events
   and refreshes are read there too. Until that boundary the new implementation
   keeps the live dating (section 3).
3. `increaseAmount` is owner-only (it was permissionless).
4. `transferFrom(a, a, id)` (and both `safeTransferFrom` overloads) reverts
   `NotOwner` for any caller other than `a`, an approved operator included,
   before any other check.
5. `safeTransferFrom` holds the reentrancy guard across `onERC721Received`.
6. Every call from VeHemi into the delegation module is gas-capped at 8,000,000.
   The window probe is capped at 50,000.
7. New events: `DelegationUpdateFailedReason` and `DelegationUpdateSkipped`. The
   VVD emits `DelegateChanged` before the `DelegateVotesChanged` pair.
8. A delegation write no longer reverts on a VVD `totalAmount` underflow: a
   retirement larger than the aggregate leaves `totalAmount` as it is, and
   expirations saturate it at 0 (`calculateExpiredDelegations` /
   `writeNewCheckpointForExpiredDelegations` still use checked arithmetic).
   `totalAmount` feeds no vote or supply value.
9. Every booking writes `delegationBookedAt`. New views: `legacyDatingActive`,
   `legacyDatingUntil`, `delegationBookedAt`, `getDelegationCheckpointsLength`
   and `getDelegationCheckpointsPage`.
10. `supplyBreakdown` drops its two caps and returns raw values (`transferable`
    saturates at 0).
11. The reward distributor's `updateRewards(id)` is called before and after a
    weight change: twice per deposit-type write (lock creation,
    `increaseAmount`, `increaseUnlockTime`), and on `enableAutoRelock`,
    `disableAutoRelock`, `retireStaleAutoRelock` and an armed position's
    transfer to another account; `withdraw`, `forfeit` and every other transfer
    still notify once, before.
    Each call is capped at 8,000,000 gas, a distributor address with no code is
    skipped without an event, and `refreshAutoRelock` does not notify. If a
    distributor spends more than about 6.8 million gas per `updateRewards` call
    (less for an owner with many positions), `createLockWithAutoRelock` cannot
    fit in a block: it calls the distributor three times, each capped at
    8,000,000 gas, before the 8,176,984-gas floor.
    Holders then use `createLock`, then `enableAutoRelock`, and a future
    distributor must keep its per-call cost well below that. None of this has
    any effect while `rewardDistributor()` is 0x0, as it is today.

The integrator notice (`docs/AUTO_RELOCK_INTEGRATOR_NOTICE.md`) carries the
integrator-facing list, including the auto-relock semantics.

## 3. The upgrade-hour window

The live VVD dates both legs of every delegation write at the next hour boundary
B. The new VVD writes at `block.timestamp + 1`. If the first new-implementation
write in the execution hour followed the new rule, it would mis-serve records the
live implementation booked earlier in that hour: an under-count, a `Panic(0x11)`
on a retirement, or a double count frozen into `getPastVotes`.

The VVD leg therefore arms a window. `armLegacyDatingWindow()` sets
`legacyDatingUntil = B`, the next hour boundary after the execution block. Until
B, every new-implementation write keeps the live dating. From B on, the new
semantics apply. The calldata carries no time, so the batch may execute in any
block of any hour, by any executor. No proposal veto, refresh or forfeit freeze
is needed; the post-execution check (section 7) is still required. (A forfeit
inside the window lowers the quorum denominator at once while its weight still
counts in votes until B, so the forfeit admin should avoid one.)

Until B (at most 3,599 seconds), users see live behaviour:

- delegation changes take effect at B;
- vote events carry B values;
- `enableAutoRelock` and `createLockWithAutoRelock` revert
  `VoteDelegationTransitionInProgress()` until B − 1 (B − 1 already admits
  arming; the dating there equals `block.timestamp + 1`).

Executing late in the hour shortens the window, and with it the time available
for an in-window rollback. A batch that executes at B − 1 (timestamp ≡ 3599 mod
3600) leaves no in-window rollback at all.

## 4. Before running: operator pre-flight

- [ ] **Census.** Run the census at the block you will sign at and refuse to
      sign unless it prints `CENSUS: CLEAN` and exits 0:
      `python3 scripts/d1-census.py <signing block> census.json`. It checks
      four premises of the live VVD state:
      - P1: no checkpoint carries `fixedBias`;
      - P2: no flat-shaped record exists;
      - P3: checkpoints sit on hour boundaries, at most one per hour;
      - P4: each delegatee's last checkpoint is at most four years old, and its
        `totalAmount` and `normalizedSlope` equal the sums of `amount` and
        `slope` over that delegatee's records that end after that checkpoint (a
        delegatee with no checkpoint fails if any of its records ends after the
        census block).

      It also refuses (`INCOMPLETE`, exit 3) an endpoint that is not Hemi
      mainnet (chain id 43111) and a block at which the VVD proxy is not on the
      live implementation `0xAcAA0d96121C035fC21345551317d66921394128`.
- [ ] **Live configuration.** Read `VeHemi.rewardDistributor()`,
      `VeHemi.forfeitAdmin()` and `VVD.trustedAdapter()` and confirm they are
      what you expect: `trustedAdapter() ==
      0x3f41c138082b29fb1a6c91066e73480163f984e4`, and `rewardDistributor()` is
      0x0 today (a non-zero distributor must meet the bound in section 2,
      item 11).
- [ ] **Safe premises.** Confirm the Safe has no modules or guard you do not
      expect and no pending transaction on the nonce this proposal will use.
      Confirm the Safe SDK versions in `package.json` are the ones you reviewed.
- [ ] **Archive RPC.** Pre-flight 5b (rollback and recovery states, and the
      first forward) and the post-execution check (section 7) read historical
      state: set `PROVIDER_URL` (the RPC `--network hemi` uses) to an
      archive-capable Hemi endpoint. `HEMI_RPC_URL` serves only the census and
      the rehearsals.
- [ ] **Tooling and keys.** `npm ci`; forge 1.5.1, `cast`, `jq`, `python3` and
      `git` on PATH; `DEPLOYER_PRIVATE_KEY` of a funded EOA that is a Safe owner
      or registered delegate; `SAFE_API_KEY` (checked only after the four
      contracts are deployed).
- [ ] **Integrator notice.** Publish `docs/AUTO_RELOCK_INTEGRATOR_NOTICE.md`
      with the proposal, before execution.
- [ ] **Rollback file.** Build and review the in-window rollback (section 8) as
      a Transaction Builder file. **Do not propose it and do not sign it.**
- [ ] **Rehearse** on a fork at the signing block:
      ```
      HEMI_RPC_URL=<archive RPC> HEMI_FORK_BLOCK=<signing block> npm run test:hardhat:fork:autorelock
      HEMI_RPC_URL=<archive RPC> R31_FORK_BLOCK=<signing block> forge test --match-path 'test/r31/*' --threads 1 -vv
      ```
      Write the block as digits only; every forked `test/r31` body (all but the
      ten `R31Window` bodies, which run without a fork) logs `fork block`,
      which must equal the signing block. Both must pass with no failure, and
      the forge summary of `test/r31` must read 0 skipped: a skip is a fork
      premise that did not hold at that block (another chain, or a block after
      the upgrade). The one expected exception is a signing block after an
      in-window rollback, where exactly the two `R31Transition` plain-upgrade
      fallback bodies skip by design and the deploy rehearsal's
      `rollback limits, control` body fails (pre-flight 5b counts the
      rolled-back forward's VeHemi `Upgraded` log as a VeHemi-leg rollback). The
      deploy rehearsal loads the `deployments/hemi/` records of the tree it runs
      from, so all of this holds only from a tree whose records are the reviewed
      commit's, which name the live implementations: once the proposing run's
      records are committed, run it from a scratch clone of the reviewed commit.
      With the proposing run's records nearly every body fails (`HALF A BATCH`),
      and with the implementation records deleted every body fails. 5,524,738 is
      the default pin of `test/r31` (repository variable `R31_FORK_BLOCK`) and
      of the nightly deploy rehearsal (repository variable
      `AUTORELOCK_FORK_BLOCK`, which CI passes as the `HEMI_FORK_BLOCK`
      environment variable of the command above; the repository variable
      `HEMI_FORK_BLOCK` pins only the V2-history step, at or below 4,458,622).
      The deploy rehearsal must also report no pending body: without an RPC
      every body is pending and mocha still exits 0.

## 5. Running it

```
npx hardhat --network hemi deploy --tags AutoRelockUpgrade
```

Use exactly this tag. An untagged run runs the scripts in `deploy/` in order
(00 to 08, then 99) and never gets past `deploy/03`, which deploys a contract
this repository does not contain (`RestakeManager`). Before that it redeploys
implementations, queues their upgrade legs into the Safe batch file, and
overwrites the deployment records. The `AutoRelockUpgrade` tag selects
`deploy/08` and `deploy/99` only.

- The run must start from a **clean checkout of the reviewed commit**. On
  `--network hemi`, pre-flight 5d refuses uncommitted changes in any file that
  decides the proposed bytes. It then prints
  `PROPOSING FROM COMMIT <sha>; attestation digest <digest>, srcTree <hash>`.
  Paste that line where the signers will see it.
- Pre-flight 7 rebuilds and verifies the build against the committed
  `test/fixtures/eip170-attestation.json` (`check-eip170.sh --verify`). It
  writes nothing, and any drift aborts the run.
- Record the two live implementation addresses (table above) before running.
  Steps 3–4 overwrite `deployments/hemi/*_Implementation.json`, which held them.
- **Commit `deployments/hemi/` right after the proposing run**, before any
  re-run. The post-execution check needs both `*_Implementation.json` records
  that run wrote. A plain re-run between proposal and execution rewrites
  `VeHemi.json` and `VeHemiVoteDelegation.json` to name implementations the
  chain is not on yet: hardhat-deploy does this in its non-executing upgrade
  branch. Never commit changes to those two files made by a refused run.
- If the run prints `Nothing queued`, that claim has been checked against both
  proxies' implementation slots.
- `deploy --tags safe` on its own is not a recovery command. `helpers/safe.ts`
  refuses to start while a non-empty batch file from an earlier run is on disk.
  It moves the file to `multisig.batch.tmp.json.stale-<time>` and prints how to
  restore and propose it:
  `PROPOSE_EXISTING_BATCH=1 npx hardhat --network hemi deploy --tags safe`, in a
  run that queues nothing else. A file moved to `.refused-*` was refused by a
  gate, or left unchecked by an error after queuing started: never propose it.
  Never `rm` a batch file. It may be the only record of a queued upgrade.

## 6. Signer checklist (required)

Before signing, every signer checks:

1. **Source verification.** All four EOA-deployed contracts are source-verified
   on explorer.hemi.xyz from the PR commit (`npm run verify:hemi` after the
   proposing run): `VeHemiCurveLib`, `VeHemiSupplyLib`, and both
   implementations.
2. **Transaction shape.** The Safe transaction goes to MultiSendCallOnly 1.4.1
   `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` with operation DELEGATECALL and
   value 0. It has exactly two inner calls, each with value 0, to the
   DefaultProxyAdmin `0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F`:
   - first `upgrade(0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89, <verified VeHemi implementation>)`;
   - then `upgradeAndCall(0xBF5b2f370370494B8A4575962512dd3ea7c29e2d, <verified VVD implementation>, 0x62c0fe7a)`.
3. **Immutables.** On the VeHemi implementation `HEMI()` equals
   `0x99e3dE3817F6081B2568208337ef83295b7f591D`; on the VVD implementation
   `veHemi()` equals the VeHemi proxy.
4. **Commit binding.** The commit and the attestation digest the proposer printed
   equal the reviewed PR commit (or a later commit that differs from it only
   under `deployments/`; check with the compare view) and its committed
   `test/fixtures/eip170-attestation.json`.
5. **No downgrade after the window.** Never sign a ProxyAdmin upgrade to
   `0xAcAA0d96121C035fC21345551317d66921394128` or
   `0xf1e3AA617E5011793F759092b59d22247E57b84A` once `legacyDatingActive()` is
   false. Never pre-sign the rollback.
6. **Safe fields.** `nonce` equals the Safe's on-chain `nonce()`; `safeTxGas`,
   `baseGas` and `gasPrice` are 0; `gasToken` and `refundReceiver` are
   `0x0000000000000000000000000000000000000000`. The safeTxHash your wallet
   shows equals the one `deploy/99` printed (`MultiSig tx '<hash>' was
   proposed`) and the Safe's `getTransactionHash(…)` on the explorer.
7. **Links and settings.** The VeHemi implementation's explorer page lists
   exactly the two library addresses verified in item 1. All four are full
   matches with solc 0.8.29, optimizer on, 1 run, EVM cancun. VeHemi's
   `version()` returns `"3.0.0"`.
8. **From-state.** Both proxies' EIP-1967 implementation slots still read
   `0xf1e3AA617E5011793F759092b59d22247E57b84A` (VeHemi) and
   `0xAcAA0d96121C035fC21345551317d66921394128` (VVD).
9. **Census.** The operator has posted `CENSUS: CLEAN` with its `block`,
   `block_hash` and `script_sha256` for a block after the proposal. Each signer
   checks `script_sha256` against `sha256sum scripts/d1-census.py` at the PR
   commit and `block_hash` against explorer.hemi.xyz for that block. (The
   census refuses a chain other than Hemi and a VVD that is not on the live
   implementation; section 4.)

Signing does not execute. Execution is a separate action and needs no timing.

## 7. After execution: the post-execution check

```
D1_POST_CHECK_ONLY=1 npx hardhat --network hemi deploy --tags AutoRelockUpgrade
```

Run it from the same tree and the same `deployments/` directory that produced
the batch. It deploys, queues and proposes nothing. It checks:

- both implementation slots;
- `legacyDatingUntil() == floor(U / 3600) * 3600 + 3600`, where U is the
  execution block's timestamp;
- `LegacyDatingWindowArmed(B, true)` in the VVD upgrade transaction;
- that the VeHemi upgrade is in that same transaction.

It refuses in these cases:

- any `AutoRelockEnabled` from the VeHemi proxy before the arm (searched from
  block 5,524,738, where the proxy was still on the live implementation);
- a later, separate VeHemi upgrade with `DelegationUpdateFailed` in between;
- any upgrade of the VeHemi proxy *away* from this build after the arm.

A separate earlier VeHemi upgrade with no arm, or a later one with no dropped
update, is a warning. The run then ends `POST-EXECUTION CHECK: PASS WITH
WARNINGS`: treat that as not the expected one-MultiSend shape. After a pass
(with or without warnings) the check refreshes `deployments/hemi/VeHemi.json`
and `VeHemiVoteDelegation.json` (local files only). Commit the refreshed files.

- The check needs an **archive RPC**. It reads the VeHemi implementation slot at
  the audit start block, and `D1_LOGS_FROM` cannot avoid that read.
- If the RPC caps `eth_getLogs`, set `D1_LOGS_STEP` (a positive integer). The
  default is 10,000 blocks, halved on errors while above 500.
- You can also set `D1_LOGS_FROM`. It must be a block at or before the first
  upgrade of the VeHemi proxy to any auto-relock build, at which the proxy was
  still on the live implementation. It replaces the implementation record's
  receipt block as the start of the `Upgraded`-log searches. It can only move
  the `AutoRelockEnabled` audit earlier than block 5,524,738, never later.
- Do not use a plain re-run as the check. After the forward it refuses before
  anything is deployed.

**Follow-up PR.** Re-extract
`test/fixtures/storage-layouts/onchain/{VeHemi,VeHemiVoteDelegation}.deployed.json`
from the new `*_Implementation.json` records, normalized as the working-tree
fixtures are (a raw copy keeps AST ids in its type names and fails the anchor's
type check):

```
source scripts/_normalize-storage-layout.sh
for c in VeHemi VeHemiVoteDelegation; do
  jq .storageLayout deployments/hemi/${c}_Implementation.json | normalize \
    > test/fixtures/storage-layouts/onchain/${c}.deployed.json
done
```

Then set `ANCHORED_VEHEMI_IMPL` / `ANCHORED_VVD_IMPL` in
`test/StorageLayoutOnchainAnchor.t.sol` to the new implementations, and
re-baseline its append assertions
(`test_AutoRelockAppendsExactlyThreeVeHemiEntriesAndNothingElse` counts 26
deployed / 29 current VeHemi entries and 9 / 12 VVD entries; the re-extracted
deployed fixtures hold 29 and 12). Land it promptly: until it lands no frozen
fixture covers VeHemi V3 or VVD V4, and only the hard-coded pins
(`StorageLayoutGolden.t.sol`, the anchor's append test, and the slot-65 runtime
test in `G08Zero.t.sol`) guard against deleting or reordering one of their
declarations, which would move live state (VeHemi slots 64 and 65, VVD slots 100
and 101). Until it lands, CI's Hemi-fork step fails at
`test_AnchorStillDescribesTheLiveImplementation`, by design. In the same pull
request retire the nightly deploy rehearsal, or point it at a scratch clone of
the reviewed commit: once the proposing run's records (section 5) reach the
default branch it fails every night (section 4); if they reach it before this
pull request, retire or repoint it then.

## 8. Rollback limits

**In-window rollback.** This is allowed only while `legacyDatingActive()` is
true, only if no `AutoRelockEnabled` was emitted since the forward, and only
after a forward whose two legs landed in one transaction (after a split, follow
section 9: rolling back a VVD-first split leaves its dropped updates unlisted by
every tool). It is one Safe MultiSend with both plain legs, value 0:

```
upgrade(0xBF5b2f370370494B8A4575962512dd3ea7c29e2d, 0xAcAA0d96121C035fC21345551317d66921394128)
upgrade(0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89, 0xf1e3AA617E5011793F759092b59d22247E57b84A)
```

- It must be **mined before B − 1** (B = `legacyDatingUntil()`). The Safe cannot
  enforce that, so a rollback not landed by then must be abandoned: after B it is
  the forbidden rollback described below.
- Build and review it before executing the forward, as a Transaction Builder
  file (the file carries no nonce). If the rollback is decided, set its nonce to
  N + 1 in the Safe UI's confirmation dialog, where N is the forward's nonce,
  and check that field before signing. `deploy/99` takes N from the Safe's
  on-chain nonce.
- Do **not** propose it to the Safe Transaction Service, and collect **no**
  signature on it, until the rollback is decided. A proposed Safe transaction
  stays executable until its nonce is consumed, and every signature on it keeps
  counting toward the threshold. Keep a threshold of signers (`getThreshold()`;
  3 today) on call for the execution hour.
- If it was proposed anyway, consume nonce N + 1 on chain as soon as B has passed
  or the no-rollback decision is made. Use the Safe UI "Reject", or the next
  planned Safe transaction. Then delete it from the queue.
- Never split it into two transactions (section 1).

**After B, a rollback is forbidden once any `AutoRelockEnabled` has been
emitted**, and unsupported for history otherwise. Over an armed position the live
code:

- returns principal at the frozen `end`;
- never debits the flat aggregate in the global `Point.amount`;
- drops `fixedBias` on its checkpoint writes;
- lets anyone rewrite the armed point as decaying (live `increaseAmount` is
  permissionless).

After any re-forward, one owner `delegate()` then books a permanent phantom
`fixedBias` of about `slope * end`. After B the emergency response is a
**forward fix only**.

**Re-forward.** Any re-forward over the live implementation must again be
`upgradeAndCall(…, 0x62c0fe7a)`. A plain re-forward over a past non-zero window
word reproduces the double count for that hour. Produce it with this script:
delete both `*_Implementation.json` records and re-run. This is allowed **only
if no `AutoRelockEnabled` was ever emitted**. Pre-flight 5b refuses otherwise,
and it also refuses a VeHemi-only rollback: a VeHemi proxy that was on this
build and is back on the live implementation while the VVD stays on this build,
or that armed positions while the VVD never left the live implementation. None
of these states is repaired by re-running this script; each needs a dedicated
repair. After an in-window rollback, re-forward only with the one MultiSend this
script proposes: its pre-flight cannot yet tell a split that follows a rollback
from the states it refuses (section 9 gives the manual legs).

After an in-window rollback and a re-forward, `delegationBookedAt(id)` can still
hold a stamp written before the rollback for an id the live implementation
rebooked or burned in between (that implementation never writes the slot). It
feeds no vote, and it is exact again from the id's next booking.

## 9. Recovery from a split batch

`deploy/08` names each recovery state it detects and prints what to do. In short:

- **Both proxies still live, batch lost.** First check the Safe queue: if the
  forward batch `deploy/99` proposed is pending there, get it executed and run
  the post-execution check; redeploy nothing (a pending rollback follows section
  8, never this advice). Otherwise restore a preserved `.stale-*` batch that
  this script printed `ORDER ASSERTED` for, or delete both implementation
  records and re-run in one process.
- **VVD already on this build, VeHemi never upgraded.** Direct delegation writes
  revert and VeHemi-driven updates are dropped. Propose `upgrade(VeHemi, impl)`
  alone, immediately, and do not re-arm. The leg is
  `upgrade(0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89, <the VeHemi implementation in deployments/hemi/VeHemi_Implementation.json>)`
  on the DefaultProxyAdmin (operation CALL, value 0). Signers check it with
  items 1, 3 and 7 (for that implementation), 4, 5, 6 (the safeTxHash is the one
  `deploy/99` printed, or the Safe UI's if the leg was built there) and 8 (the
  VeHemi slot still reads `0xf1e3AA617E5011793F759092b59d22247E57b84A`, and the
  VVD slot reads the VVD implementation in
  `deployments/hemi/VeHemiVoteDelegation_Implementation.json`, not
  `0xAcAA0d96121C035fC21345551317d66921394128`), instead of item 2; the census
  does not apply (the VVD is no longer the live writer). Then run the
  post-execution check, which lists the dropped updates. If any update was
  dropped the check refuses for good, by design: record the listed ids as an
  incident and refresh `deployments/hemi/VeHemi.json` and
  `VeHemiVoteDelegation.json` by hand (implementation, merged ABI, and for the
  VVD the execute method `armLegacyDatingWindow`, as the check's
  `refreshProxyRecord` does after a pass). Each affected owner must re-delegate
  with `VVD.delegate(id, <delegatee>)`; for a token transferred in the gap, that
  is the new owner. Do not use the in-window rollback file in this state. If it
  was used, every `DelegationUpdateFailed` from the VeHemi proxy between the VVD
  proxy's `Upgraded(<the VVD implementation>)` and its
  `Upgraded(0xAcAA0d96121C035fC21345551317d66921394128)` is a dropped update
  that no later check lists: record each as an incident; its owner (for a token
  transferred in the gap, the new owner) re-delegates with
  `VVD.delegate(id, <delegatee>)`. After an earlier in-window rollback,
  `deploy/08` refuses this state as a VeHemi-leg rollback, because it counts the
  rolled-back forward's VeHemi `Upgraded` log. Build this leg in the Safe UI
  only if both of these hold. First, every
  `Upgraded(0xf1e3AA617E5011793F759092b59d22247E57b84A)` from the VeHemi proxy
  since block 5,524,738 (each return of the proxy to the live implementation,
  including the one after the log `deploy/08` names) is in a transaction that
  also carries the VVD proxy's
  `Upgraded(0xAcAA0d96121C035fC21345551317d66921394128)` (the two-leg rollback
  of section 8). Second, the VeHemi proxy emitted no `AutoRelockEnabled` since
  block 5,524,738. Otherwise the state is a VeHemi-leg rollback (or a breached
  rollback precondition), which this leg does not repair.
- **VeHemi already on this build, VVD not (a split forward).** If VVD storage
  slot 101 is not 0 (read it as storage: the live implementation has no
  `legacyDatingUntil()` getter) and the VeHemi proxy emitted any
  `AutoRelockEnabled` since block 5,524,738, delete no record and follow the
  window-word case at the end of this item. Otherwise re-run with only the VVD
  implementation record deleted. That gets the split-forward audit, and the
  completion is one hand-built armed VVD leg. That re-run deploys a NEW VVD
  implementation and records it; the hand-built leg must name that address,
  which must be explorer-verified. The leg is one Safe transaction to the
  DefaultProxyAdmin `0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F` (operation
  CALL, value 0) with data
  `upgradeAndCall(0xBF5b2f370370494B8A4575962512dd3ea7c29e2d, <that implementation>, 0x62c0fe7a)`,
  built in the Safe UI. Signers check it with items 1, 3 and 7 (for that
  implementation), 4, 5, 6 (the safeTxHash is the Safe UI's; `deploy/99` prints
  none for this leg) and 8 (the VVD slot still reads
  `0xAcAA0d96121C035fC21345551317d66921394128`, and the VeHemi slot reads the
  VeHemi implementation in `deployments/hemi/VeHemi_Implementation.json`),
  instead of item 2. Commit the VVD implementation record that re-run wrote
  before proposing the leg, and do not re-run with it deleted again (a second
  run deploys another implementation). After the leg lands, run the
  post-execution check. If any id was armed in the gap it refuses for good, by
  design, even for ids disarmed in time: refresh `deployments/hemi/VeHemi.json`
  and `VeHemiVoteDelegation.json` by hand, as for the VVD-first case. Arming
  stays open until that leg lands, so do not delay it waiting on holders. After
  the leg lands, run the census with BLOCK = the leg's execution block − 1 (from
  the leg's own block on, the VVD runs another implementation and the census
  stops with INCOMPLETE). It is NOT CLEAN with only P2 non-zero if any record is
  flat-shaped at that block, and CLEAN otherwise; CLEAN does not prove that
  nothing was armed. P2 lists the delegated ids armed at the end of that block
  whose re-booking the live VVD accepted (it keeps such a record flat-shaped,
  slope 0, in its decaying accounting; a disarm re-books it with its slope),
  plus any disarmed id whose re-booking it refused
  (`AutoRelockRetirementUnverified`); an armed id whose re-booking it refused
  (`DelegationUpdateFailed`) keeps its decaying record and does not show. The
  incident list is every id the post-execution check lists that was still armed
  when the leg's transaction executed: read each id's last `AutoRelockEnabled`
  or `AutoRelockDisabled` before that transaction, including those in the leg's
  own block. P2 shows which of them hold a flat record. The census does not hold
  the leg back. If VVD slot 101 already holds a window word from an earlier,
  rolled-back forward, pre-flight 5b refuses this state before deploying
  anything once the VeHemi proxy emitted any `AutoRelockEnabled` since block
  5,524,738 ('a re-forward over a rollback with armed positions'). Do not delete
  any record (if the VVD record was already deleted, restore
  `deployments/hemi/VeHemiVoteDelegation_Implementation.json` from the commit
  made right after the proposing run): build the armed VVD leg by hand, naming
  the implementation in
  `deployments/hemi/VeHemiVoteDelegation_Implementation.json` (deployed by the
  proposing run of the forward that split), list the gap's ids by hand
  (`AutoRelockEnabled` from the VeHemi proxy since its latest
  `Upgraded(<the VeHemi implementation in deployments/hemi/VeHemi_Implementation.json>)`,
  plus any id with an `AutoRelockEnabled` from the VeHemi proxy since block
  5,524,738 that precedes that log, armed in the rolled-back forward, a breach
  of section 8: record it as an incident too), and land the leg without delay.
  - A listed id that its owner disarmed **before** the VVD leg lands is clean:
    under the live VVD the removal matches its booking.
  - Treat any listed id still armed after the leg lands as an open
    vote-integrity incident. Watch its delegatee's `fixedBias` and that
    delegatee's other flat delegators.

## 10. Monitoring after the upgrade

- **`AutoRelockRetirementUnverified(id)`.** If `delegation(id)` is flat
  (slope 0, bias > 0) and `isAutoRelockEnabled(id)` is false:
  1. Call `VVD.retireStrandedFlatTerm(id)`. It is permissionless.
  2. If that reverts `DelegationSlopeOverflow`, the delegatee cannot absorb the
     restored slope. The owner of a live position cures it at once with
     `VVD.delegate(id, <a delegatee with room>)`; otherwise record an open
     phantom and retry later (each retry nets the delegatee's expirations
     itself) and, at the latest, after the restored end, when the re-booking
     books nothing.
- **`DelegationUpdateFailed` for an id that is armed after the transaction**,
  or `AutoRelockEnabled` and `DelegationUpdateFailed` for the same id in one
  transaction. The module refused the re-booking, so the position's votes are
  not counted as VeHemi counts them. Tell the holder to call
  `VVD.delegate(id, <delegatee>)`.
- **`DelegationUpdateFailed` in a `forfeit` of an armed id** (a `Withdraw` whose
  provider is the forfeit admin, for an id that was armed before it; no
  `AutoRelockRetirementUnverified` is emitted on this path). If `delegation(id)`
  is still flat, fix the cause named by `DelegationUpdateFailedReason`, then
  call `VVD.retireStrandedFlatTerm(id)` (permissionless; it works on the burned
  id). `VVD.delegate` cannot be used: the id is burned.
- **`AutoRelockDisabled` and `DelegationUpdateFailed` for the same id in one
  transfer**, with no `AutoRelockRetirementUnverified`. The module refused the
  move, so the position arrived undelegated. The new owner calls
  `VVD.delegate(id, <a delegatee other than the refused one>)`.
- **Gas limits.** When the position is delegated, calls that book or retire an
  auto-relock term (`enableAutoRelock`, `disableAutoRelock`,
  `retireStaleAutoRelock`, `increaseAmount` / `increaseUnlockTime` on an armed
  position, and the fallback removal of an armed transfer whose move was
  refused) need a gas **limit** of about 8.8 million while no reward distributor
  is installed (add the distributor's per-call cost for each notification before
  the floor: one for most of these calls, two for the armed transfer's fallback
  removal, which also needs more when the refused move's delegatees were not
  checkpointed for months), far above the gas they use: 8,176,984 gas must
  remain at the re-delegation, on top of what the call spends before it. These
  figures assume the global point is current: each six-day bucket it lags adds
  up to about 150,000 gas of catch-up before the floor (see Global catch-up
  below). `createLockWithAutoRelock` needs about 9.2 million with no distributor
  (more when the owner already holds many positions, up to about 17 million, or
  when its first booking goes to a delegatee not checkpointed for months; it
  notifies the distributor three times before the floor, see section 2, item 11
  for the reward-distributor bound). A shorter limit reverts
  `DelegationCallStarved` (`0xce31767f`), so an `eth_estimateGas` of a
  transaction that calls VeHemi directly accounts for it; a caller that catches
  the revert (a try/catch loop, Multicall3 with `allowFailure`, a Safe
  transaction with `safeTxGas != 0`, an action allowed to fail) must forward
  that much gas explicitly and check the result. Keepers: call
  `retireStaleAutoRelock` directly, or call `VeHemi.checkpoint()` first and then
  forward at least 9 million gas per id, plus the distributor's per-call cost if
  one is installed, and treat the `DelegationCallStarved` selector as fatal.
- **Global catch-up.** Every VeHemi write first catches the global point up, one
  SIX_DAYS bucket at a time, at most 300 buckets per call. After a very long
  period with no VeHemi write at all (years), that catch-up no longer fits in a
  transaction, and every write reverts until an upgrade. Calls that book or
  retire an auto-relock term need the 8.2 million gas floor on top of the
  catch-up, so they reach the block gas limit sooner: after roughly 135 to 240
  idle buckets for a typical call, fewer the more curves still carry slope (plan
  for about 135, roughly 2.2 years, on the Hemi deployment, where each idle
  bucket costs about 150,000 gas; a `createLockWithAutoRelock` that needs 17
  million fits only about 85). Calling `VeHemi.checkpoint()` first restores them
  while `checkpoint()` itself still fits (roughly 200 to 300 idle buckets), and
  calling it now and then while the protocol is quiet keeps the global point
  fresh. Anyone may call it.

## 11. Not part of this upgrade

- **The Aragon adapter.** It is not redeployed, and it keeps working against the
  new contracts. Its verified NatSpec predates the upgrade:
  - `refreshVotingPower` reports power at `block.timestamp + 1`, or at the hour
    boundary during the upgrade hour;
  - `delegate(address)` also re-delegates auto-relock positions whose
    `getLockedBalance(id).end` is in the past.
- **`updateVoteDelegation`.** VeHemi's `updateVoteDelegation` is the fresh-proxy
  recovery primitive for an irreparably broken VVD proxy. It is not this path,
  and it does not fit in one MultiSend: its procedure is
  `docs/VOTE_DELEGATION_RECOVERY.md`, and `scripts/plan-legacy-migration.ts`
  prints its Safe transactions.
- **No seeding or migration.** Nothing in this upgrade needs a seeding loop, a
  migration batch or a proxy swap. Both storage layouts are append-only over the
  live ones.

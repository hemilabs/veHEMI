# veHEMI auto-relock upgrade: notice to integrators

This notice is for teams that read or act on veHEMI positions: the Aragon
TokenVoting deployment, the Hemi front end, indexers and subgraphs, the rewards
distributor, NFT marketplaces and lenders that hold veHEMI, and keepers. It lists
the behaviour changes you can observe on chain and what to do about them.

Contracts on Hemi mainnet (chain 43111):

- VeHemi proxy `0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89`
- VeHemiVoteDelegation (VVD) proxy `0xBF5b2f370370494B8A4575962512dd3ea7c29e2d`
- Aragon adapter `0x3f41c138082b29fb1a6c91066e73480163f984e4` (not changed by
  this upgrade)

Both proxies keep their addresses and storage. VeHemi's `version()` becomes
`"3.0.0"`.

## 1. Changes for every position, from the upgrade block

These apply whether or not anyone uses auto-relock.

**Delegation timing.**
- A delegation change made in a block with timestamp `ts` takes effect at
  `ts + 1`. Before the upgrade it took effect at the next hour boundary.
- So a delegation is never counted in the block that makes it, and
  `getPastVotes(account, t)` reflects every change made before `t`.
- During the hour in which the upgrade executes, until the next hour boundary
  B, the old timing still applies: changes take effect at B, and vote events
  carry B values. `VVD.legacyDatingActive()` is true until B − 1 (at B − 1 the
  dating already equals `block.timestamp + 1`), and `VVD.legacyDatingUntil()`
  returns B.

**Quorum denominator.**
- `VVD.getPastTotalSupply(t)` now returns the total veHEMI supply at `t - 1`
  (0 for `t == 0`). The denominator then sees exactly the lock changes that
  `getPastVotes(., t)` sees.
- Every open proposal's denominator is re-evaluated at the upgrade block. The
  change is negligible in size.
- Inside the upgrade hour, the denominator also sees lock changes that votes
  only see from B. Lock creations and increases raise it; a forfeit lowers it
  while the forfeited weight still counts in `getPastVotes` until B. Avoid
  forfeits during the upgrade hour.

**Other changes.**
- `increaseAmount` is owner-only. It used to be callable by anyone; it now
  reverts `NotOwner` for anyone else. The owner check comes first, so for a
  nonexistent or burned id every caller now gets `NotOwner` (it was
  `NoExistingLock`, or `AmountIsZero` with amount 0), and so does a non-owner
  calling with amount 0 (it was `AmountIsZero`).
- `transferFrom(a, a, id)` and both `safeTransferFrom` overloads revert
  `NotOwner` for any caller other than `a` (approved or not), before any other
  check, so such calls no longer return `NotTransferable` or the ERC-721
  errors.
- `safeTransferFrom` holds VeHemi's reentrancy guard while it calls
  `onERC721Received`. A receiver hook cannot re-enter VeHemi's guarded
  functions.
- VeHemi caps each call into the delegation module at 8,000,000 gas (the
  `legacyDatingActive` probe at 50,000). A refused `delegate` is announced with
  `DelegationUpdateFailed(id)` and the new
  `DelegationUpdateFailedReason(id, selector)`; a failed `delegation(id)` read
  before a re-delegation emits `DelegationUpdateFailed` alone;
  `disableAutoRelock` re-raises `DelegationSlopeOverflow`. A starved call of
  those listed in section 2 (Gas limit) reverts `DelegationCallStarved`, while
  any other starved re-delegation (of an UNARMED position, or an owner's
  self-transfer of an armed one) can commit behind the deployed proxy,
  announced as a refusal (`DelegationUpdateFailed`, with
  `DelegationUpdateFailedReason(id, 0x00000000)` when the write itself ran out
  of gas), leaving that position's record as it was until it is re-delegated.
- `DelegationUpdateSkipped(id)` (new) is emitted when VeHemi does not forward an
  update for an ordinary position in the last `((end - 1) mod 3600) + 1` seconds
  of its lock (360 to 3,600 s), and at any time after `end` (for example a
  transfer of an expired, not yet withdrawn position). See section 4 for the
  consequence.
- The VVD emits `DelegateChanged` before the `DelegateVotesChanged` pair of the
  same write.
- A delegation write no longer reverts on a VVD `totalAmount` underflow: a
  retirement larger than the aggregate leaves `totalAmount` as it is, and
  expirations saturate it at 0 (`calculateExpiredDelegations` /
  `writeNewCheckpointForExpiredDelegations` still use checked arithmetic).
  `totalAmount` feeds no vote or supply value.
- `supplyBreakdown()` returns raw values: `transferable` saturates at 0, and
  `locked <= total` no longer holds. An auto-relock non-transferable position
  counts its constant weight in `total` and its decaying weight in `locked`.
- New VVD views:
  - `delegationBookedAt(id)`: the time from which a record is in force. 0 means
    already in force: never delegated, cleared by a withdraw, a forfeit or an
    armed transfer whose move was refused (the removal itself counts from the
    next second, or from the window's end during the upgrade hour), or booked
    before the upgrade, except a record booked earlier in the upgrade hour,
    before the upgrade executed, which takes effect only at that hour's
    boundary. If the upgrade is rolled back within the upgrade hour and later
    re-applied, a stamp written before the rollback can outlive a rebooking or
    burn of that id by the pre-upgrade implementation in between, which never
    writes it; it is exact again from the id's next booking;
  - `legacyDatingActive()` and `legacyDatingUntil()`;
  - `getDelegationCheckpointsLength(delegatee)`;
  - `getDelegationCheckpointsPage(delegatee, offset, limit)`.

  They are declared in `IVeHemiVoteDelegationAutoRelock`.
- The checkpoint array of a delegatee can now grow by up to two elements per
  block that touches it, instead of at most one per hour.
  `getDelegationCheckpoints(delegatee)` is unchanged, but it can outgrow an
  `eth_call` gas budget for a very deep array. Page with the length and page
  views instead.
- Two error declarations that were never emitted are gone:
  `VeHemi.TokenDoesNotExist` and `VVD.NonExistentToken`.

**Reward distributor.** None of this has any effect while
`rewardDistributor()` is 0x0, as it is today.
- `updateRewards(id)` is called before and after a weight change: twice per
  deposit-type write (lock creation, `increaseAmount`, `increaseUnlockTime`),
  and on `enableAutoRelock`, `disableAutoRelock`, `retireStaleAutoRelock` and
  an armed position's transfer to another account. `withdraw`, `forfeit` and
  every other transfer still notify once, before. `refreshAutoRelock` does not
  notify.
- Every notification is best-effort: a call that reverts or runs out of gas is
  swallowed (`RewardUpdateFailed`) and does not revert the VeHemi call (which
  can still revert for its own reasons, such as `DelegationCallStarved`), so a
  distributor must derive weights from `balanceOfNFTAt` history rather than rely
  on receiving each notification.
- At the notification before an armed `increaseUnlockTime`,
  `autoRelockRemaining` and `effectiveLockEnd` already report the new value,
  while `balanceOfNFT` is still the weight before the extension.
- Each call is capped at 8,000,000 gas. A distributor address with no code is
  skipped without an event.
- If a distributor spends more than about 6.8 million gas per `updateRewards`
  call (less for an owner with many positions), `createLockWithAutoRelock`
  cannot fit in a block: it calls the distributor three times, each capped at
  8,000,000 gas, before the 8,176,984-gas floor (section 2, Gas limit). Use
  `createLock`, then `enableAutoRelock`. A future distributor must keep its
  per-call cost well below that.

## 2. Auto-relock

A holder can freeze a position's remaining lock time so that its weight stops
decaying. The entry points are `enableAutoRelock(id)` on an existing position and
`createLockWithAutoRelock(amount, duration, transferable, forfeitable)` for a new
one.

**Weight.**
- While armed, the position's weight is constant at `slope * (R - SIX_DAYS/2)`.
- `slope = amount / MAX_TIME`. R is the frozen remaining term: the whole SIX_DAYS
  buckets (6.0875 days each) from the start of the current bucket to `end`, at
  least 2 buckets.
- `autoRelockRemaining(id)` returns R in **seconds**.
- `slope * R` overstates the weight by `slope * SIX_DAYS / 2`.

**Reading a position.**
- Use `isAutoRelockEnabled(id)` to tell whether a position is armed.
- Use `effectiveLockEnd(id)` for its unlock time. While armed,
  `getLockedBalance(id).end` and `Deposit.lockTime` are **not** unlock times and
  may lie in the past.
- `withdraw` reverts `LockNotExpired` while armed, whatever `end` says.
- To unlock, the owner calls `disableAutoRelock(id)`. Linear decay then resumes
  for R, floor-snapped onto the SIX_DAYS grid; `AutoRelockDisabled` carries the
  restored end.
- `disableAutoRelock` can revert `DelegationSlopeOverflow()` when the current
  delegatee cannot absorb the restored slope. Delegate the position elsewhere
  first.

**Heartbeat.**
- The owner must call `refreshAutoRelock(id)` at least every
  `STALE_FLAT_BUCKETS * SIX_DAYS` (60 buckets, 365.25 days).
- `autoRelockRefreshedAt(id)` returns the last heartbeat: the time of the
  arming or of the latest `refreshAutoRelock`, 0 while unarmed.
- From `autoRelockStaleAt(id)` on, anyone may call `retireStaleAutoRelock(id)`.
  It ends the term as a disable would, but never reverts on a refusal by the
  vote module: a disable re-raises only `DelegationSlopeOverflow`, and a retire
  swallows that too. A swallowed refusal is announced with
  `DelegationUpdateFailed` / `DelegationUpdateFailedReason`, and with
  `AutoRelockRetirementUnverified` when the record still reads flat afterwards
  (or cannot be read).
- `autoRelockStaleAt` reverts `AutoRelockNotEnabled` for an unarmed, burned or
  nonexistent id. Batch readers should gate on `isAutoRelockEnabled` or allow
  failure.

**Transfers.**
- A transfer of an armed position to another account disarms it inside the
  transfer. The end and the weight are rewritten in that call.
- A buyer therefore does not receive the armed weight it read before the
  transfer. Marketplaces and lenders should value an armed position only after
  holding it, or require the seller to disarm first.
- If the module refuses the move to the recipient's delegatee, the position
  arrives undelegated (`DelegateChanged(id, old, 0)`) and the transfer needs
  the gas limit below; the new owner must delegate it.

**Gas limit.**
- When the position is delegated, these calls need a gas **limit** of about 8.8
  million while no reward distributor is installed (each distributor
  notification before the floor adds its cost: one for most of these calls, two
  for the armed transfer's fallback removal, which also needs more when the
  refused move's delegatees were not checkpointed for months; each six-day
  bucket the global point lags adds up to about 150,000 gas of catch-up, see
  section 5, Global catch-up), far above the gas they actually use:
  - `enableAutoRelock`;
  - `disableAutoRelock` and `retireStaleAutoRelock`;
  - `increaseAmount` and `increaseUnlockTime` on an armed position;
  - a transfer of an armed position whose move to the recipient's delegatee is
    refused (the fallback removal).
- `createLockWithAutoRelock` needs about 9.2 million with no distributor, more
  when the owner already holds many positions (the deployed adapter walks them
  in the unarmed first booking, before the floor; up to about 17 million) or
  when that first booking goes to a delegatee not checkpointed for months, plus
  three distributor notifications if one is installed. If the reward distributor
  spends more than about 6.8 million gas per `updateRewards` call (less for an
  owner with many positions), it cannot fit in a block (section 1, Reward
  distributor): use `createLock`, then `enableAutoRelock`.
- 8,176,984 gas must remain when these calls reach the delegation module, on
  top of what the call spends before it. A shorter limit reverts
  `DelegationCallStarved()` (`0xce31767f`); resend with more gas.
- An `eth_estimateGas` of a transaction that calls VeHemi directly already
  includes the requirement, because a lower limit reverts. A caller that
  catches the revert (a try/catch loop, Multicall3 with `allowFailure`, a Safe
  transaction with `safeTxGas != 0`, an action allowed to fail) must forward
  that much gas explicitly and check the result: an estimate through such a
  frame can settle on a limit at which VeHemi reverts and the outer
  transaction still succeeds. Do not cap these calls' gas limits below it.

**Upgrade hour.** `enableAutoRelock` and `createLockWithAutoRelock` revert
`VoteDelegationTransitionInProgress()` while `legacyDatingActive()` is true.

**Delegation records.**
- An armed position's `delegation(id)` record is flat: `slope == 0`, and `bias`
  is its constant weight.
- `end` in that record is the stored lock end, not an expiry.
- An armed position can always be delegated, whatever its stored `end`.

**Indexers.**
- `DelegateCheckpoint.fixedBias` now carries the constant auto-relock weight. A
  delegatee's votes at `t` are
  `max(normalizedBias − expiredBias − (normalizedSlope − expiredSlope) · t, 0) + fixedBias`.
- `totalAmount` includes the principal of armed positions.
- `getGlobalPoint(e).amount` is the aggregate constant weight: supply is the
  walked bias plus `amount`.
- An armed position's user points have `slope == 0` and a constant `bias`.

**Events.** An indexer that reconstructs positions must handle all five, all on
the VeHemi proxy:

| Event | Meaning |
| --- | --- |
| `AutoRelockEnabled(tokenId, remaining)` | armed; `remaining` is R in seconds |
| `AutoRelockDisabled(tokenId, restoredEnd)` | disarmed by a disable, a stale retire or a transfer; `restoredEnd` is the new `end` |
| `AutoRelockRefreshed(tokenId, refreshedAt)` | heartbeat |
| `AutoRelockRetired(tokenId, caller)` | the disarm was a stale retire; `AutoRelockDisabled` follows in the same transaction |
| `AutoRelockRetirementUnverified(tokenId)` | the disarm could not confirm that the vote module retired the flat term (see section 5) |

- `AutoRelockEnabled` and `AutoRelockDisabled` are emitted before the
  `Checkpoint` they describe.
- `increaseUnlockTime` on an armed position can grow R with no auto-relock
  event. Re-read `autoRelockRemaining`.
- A forfeit of an armed position clears R without `AutoRelockDisabled`. The
  `Checkpoint` with a zeroed new lock and the burn are its signals.

**New VeHemi errors:** `AutoRelockAlreadyEnabled`, `AutoRelockNotEnabled`,
`AutoRelockDurationTooShort`, `AutoRelockNotStale`,
`VoteDelegationTransitionInProgress`, `EndBelowTransferableAfter`,
`DelegationCallStarved`, `DelegationSlopeOverflow`, `SeedingNotFinalized` and
`VoteDelegationHasNoCode`. The errors are declared in `VeHemi.sol` (their
selectors are in VeHemi's ABI); the new functions and events are in `IVeHemi`.

**New VVD errors and event:** `CheckpointLayoutViolated`,
`FlatTermNotRetryable`, `NotUpgradeCall` and
`LegacyDatingWindowArmed(until, viaUpgradeCall)`.

## 3. Aragon and the adapter

The Aragon adapter `0x3f41c138082b29fb1a6c91066e73480163f984e4` is unchanged by
this upgrade: same address, same bytecode, and it stays the TokenVoting voting
token. Nothing on the Aragon side needs reconfiguring.

- Through the adapter, delegation changes take effect at
  `block.timestamp + 1`, and `getPastTotalSupply(t)` returns VeHemi supply at
  `t - 1`. `DelegateVotesChanged.newVotes` is the value from the next second
  on.
- Aragon reads `getPastVotes(account, block.timestamp - 1)` and
  `getPastTotalSupply(block.timestamp - 1)` at proposal creation. The two are
  consistent outside the upgrade hour (section 1).
- The adapter's verified NatSpec predates the upgrade:
  - `refreshVotingPower` now reports power at `block.timestamp + 1` (at the
    hour boundary only during the upgrade hour);
  - `delegate(address)` also re-delegates auto-relock positions whose
    `getLockedBalance(id).end` is in the past.
- Auto-relock positions carry constant weight that neither decays nor expires,
  and no event marks the time passing. Re-read `getVotes` / `getPastVotes`.
- The adapter relays `DelegateChanged` only when all of an owner's positions are
  delegated to the same address. To check that, it walks every position of the
  owner, about 5.5k gas each, with no bound. Above roughly 1,450 positions that
  walk no longer fits in VeHemi's 8,000,000-gas ceiling on delegation calls, and
  the relay is silently dropped. The delegation itself is still recorded.
- Skipping mixed-state `DelegateChanged` events means the event stream does not
  track `delegates(account)`. Do not rebuild delegation state from that stream;
  re-read `delegates(account)` or the per-token `delegation(id)`.

## 4. A late transfer keeps the previous delegatee

This behaviour is unchanged from today.

- When an **unarmed** position is transferred in the last 360 to 3,600 seconds
  of its lock, VeHemi skips the delegation update (`DelegationUpdateSkipped`).
- The record still names the seller's delegatee. The new owner cannot move the
  weight with `delegate()` until the lock is extended
  (`CanNotDelegateExpiredLocks`; the exception is a stranded flat record, which
  that call retires, booking nothing).
- Extending the lock with `increaseUnlockTime` first re-books the weight to the
  **previous** delegatee. The same happens on a later `increaseAmount`,
  `enableAutoRelock` or `retireStaleAutoRelock`. After auto-relock that weight is
  constant.
- The new owner must then call `delegate()` to take the weight back. A position
  transferred after its end has no weight to recover.

## 5. Keepers and monitoring

- **Voting power.** Voting power keeps decaying without events. Call
  `refreshVotingPowerBatch` periodically if you display event-sourced power.
- **Stale positions.** From `autoRelockStaleAt(id)` on, anyone may retire a
  position with `retireStaleAutoRelock(id)`, using the gas limit in section 2. A
  keeper should call it directly, or call `VeHemi.checkpoint()` first and then
  forward at least 9 million gas per id, plus the distributor's per-call cost if
  one is installed, and treat the `DelegationCallStarved` selector
  (`0xce31767f`) as fatal: an estimate-sized call through a frame that catches
  reverts retires nothing.
- **Unverified retirements.** On `AutoRelockRetirementUnverified(id)`, if
  `delegation(id)` is still flat and `isAutoRelockEnabled(id)` is false:
  1. call `VVD.retireStrandedFlatTerm(id)` (permissionless);
  2. if it reverts `DelegationSlopeOverflow`, the delegatee cannot absorb the
     restored slope: the owner of a live position cures it at once with
     `VVD.delegate(id, <a delegatee with room>)`; otherwise retry later (each
     retry nets the delegatee's expirations itself) and, at the latest, after
     the restored end, when the re-booking books nothing.
- **Refused updates on armed ids.** On `DelegationUpdateFailed` for an id that
  is armed after the transaction, the position's vote record is out of step.
  The holder fixes it with `VVD.delegate(id, <delegatee>)`.
- **Refused removals in a forfeit of an armed id.** `DelegationUpdateFailed` in
  a `forfeit` of an armed id (a `Withdraw` whose provider is the forfeit admin,
  for an id that was armed before it; no `AutoRelockRetirementUnverified` is
  emitted on this path). If `delegation(id)` is still flat, fix the cause named
  by `DelegationUpdateFailedReason`, then call `VVD.retireStrandedFlatTerm(id)`
  (permissionless; it works on the burned id). `VVD.delegate` cannot be used:
  the id is burned.
- **Armed transfers that arrive undelegated.** `AutoRelockDisabled` and
  `DelegationUpdateFailed` for the same id in one transfer, with no
  `AutoRelockRetirementUnverified`: the module refused the move and the
  position arrived undelegated. The new owner calls
  `VVD.delegate(id, <a delegatee other than the refused one>)`.
- **Global catch-up.** Every VeHemi write first catches the global point up, one
  SIX_DAYS bucket at a time. After years with no VeHemi write at all, that
  catch-up would no longer fit in a transaction. Calls that book or retire an
  auto-relock term need the gas floor on top of it, so they hit the block gas
  limit sooner: after roughly 135 to 240 idle buckets for a typical call, fewer
  the more curves still carry slope (plan for about 135, roughly 2.2 years, on
  the Hemi deployment, where each idle bucket costs about 150,000 gas; a
  `createLockWithAutoRelock` that needs 17 million fits only about 85). Calling
  `VeHemi.checkpoint()` first restores them while `checkpoint()` itself still
  fits (roughly 200 to 300 idle buckets). Anyone can call it, and calling it
  periodically keeps the global point fresh.

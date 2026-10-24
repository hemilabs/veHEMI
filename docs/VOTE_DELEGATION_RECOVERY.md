# Vote-delegation module replacement: operator procedure

`VeHemi.updateVoteDelegation(newProxy)` points VeHemi at a brand-new
VeHemiVoteDelegation (VVD) proxy. It is a recovery primitive for a VVD proxy
that is irreparably broken; a routine implementation change is a proxy upgrade,
which keeps all storage (for example `docs/AUTO_RELOCK_UPGRADE.md`). This
document is the procedure for the replacement.
`scripts/plan-legacy-migration.ts` counts the live chain (read-only) and prints
its Safe transactions: the plan.

| Contract | Address |
| --- | --- |
| VeHemi proxy | `0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89` |
| VVD proxy in use today (the OLD module below) | `0xBF5b2f370370494B8A4575962512dd3ea7c29e2d` |
| Safe (owner of VeHemi) | `0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6` |

## 1. What the swap does

The swap is one storage write. It migrates nothing: every delegation record,
every `autoDelegate`, the checkpoint history, the slope buckets, the EIP-712
nonces and `trustedAdapter` stay in the OLD module, and the new one starts
empty. The new module is therefore populated from the OLD one before the swap
(section 3), and the swap is followed by a reconcile (section 5).

- **History.** The imports build forward-only checkpoints, dated
  `block.timestamp + 1` of each import on a freshly deployed, initialized
  module. `getPastVotes` on the new module for a time before an import returns
  only what was imported by then, so a proposal snapshotted before or during the
  import window (from the first import to the swap) reads too little there.
- **Aragon relay.** The adapter's event relay stops until `setTrustedAdapter` is
  called on the new module. The adapter reads `veHemi.voteDelegation()` on every
  call, so after the swap its `delegate(address)` acts on the new module.
- **Module shape.** VeHemi refuses a module with no code. The new module must
  also return decodable data from `delegation(uint256)` and
  `autoDelegate(address)`: VeHemi cannot catch a decode failure, and for an
  armed position that blocks `disableAutoRelock` and `retireStaleAutoRelock`, so
  its principal stays locked until the module is replaced again.

## 2. Before the first import

- **Governance freeze.** No Aragon proposal may be snapshotted from the first
  import until the reconcile (section 5) is complete, and none may be in flight
  when the import window opens.
- **Holder freeze.** Announce that holders should not arm, disarm, top up,
  extend, transfer or re-delegate positions, or change their `autoDelegate`,
  from the first import until the swap. Nothing enforces this: the window probe
  (VeHemi's 50,000-gas `legacyDatingActive()` call before arming a position)
  reads the module VeHemi points at, which is still the OLD one. Every such
  change is reconciled after the swap, and the fewer there are, the shorter the
  reconcile.
- **Forfeit disabled.** The first Safe transaction is
  `VeHemi.updateForfeitAdmin(address(0))`; record the admin it replaces, which
  is restored after the swap. A position forfeited in the import window keeps
  its decaying imported record on the new module, and no call can remove it (the
  id is burned: `delegate` reverts, and `retireStrandedFlatTerm` refuses a
  decaying record).
- **The new module.** Deploy the new VVD proxy and implementation, constructed
  with the VeHemi proxy address and initialized in the deploy (`initialize()`,
  as `deploy/01_vote_delegation.ts` does). Uninitialized, its first booking
  opens an upgrade-hour window, and every booking until the next hour boundary
  is dated at that boundary. Verify both on the explorer.

## 3. Imports (Safe transactions, in order)

1. `VeHemi.updateForfeitAdmin(address(0))` (section 2).
2. `newProxy.importDelegationsFromLegacy(oldProxy, ids)`, in batches, over every
   live id (`ownerOf` succeeds) from 1 to `nextTokenId() - 1` that the OLD
   module holds a record for (the plan's list; a burned id would be skipped
   anyway and only costs calldata and two reads). Each call books the id at the
   OLD module's delegatee, with the lock and auto-relock flag it has at that
   moment, and skips an id the new module already holds a record for, one the
   OLD module holds none for, a burned id, and an unarmed lock that ends at or
   before the next hour boundary. Calls are idempotent and can be re-sent. The
   plan uses 150 ids per call: the import's original figure is about 165,000 gas
   per id, and 172 fit in one Safe transaction at that figure after the Safe
   proxy's DELEGATECALL, the Safe's CALL and the VVD proxy's DELEGATECALL keep
   1/64 each. That figure predates the auto-relock upgrade, which adds a cold
   `delegationBookedAt` stamp and `autoRelockRemaining` reads per id: size every
   import transaction with an `eth_estimateGas` of the Safe transaction.
3. `newProxy.importAutoDelegatesFromLegacy(oldProxy, owners)`, over every
   address that ever emitted `AutoDelegateSet` on the OLD module plus every live
   owner: `setAutoDelegate` is permissionless, so an address that never held a
   position can carry one. It skips an address the new module already holds a
   value for and one whose OLD value is 0. The plan skips this step when no
   scanned address has a value.
4. `newProxy.setTrustedAdapter(adapter)`.
5. Before the swap, both forfeit checks (section 4).
6. One MultiSend: optionally `importDelegationsFromLegacy` and
   `importAutoDelegatesFromLegacy` again, for the ids and addresses that still
   have no entry on the new module (an id minted after its batch, an address
   that set its `autoDelegate` after the import), then
   `newProxy.finalizeMigration()`, then `VeHemi.updateVoteDelegation(newProxy)`.
   This is the swap; call its block S. `finalizeMigration` seals both imports
   for good. A late import covers only a missing entry: it skips an id or
   address the new module already holds, so a changed entry still needs the
   reconcile. The MultiSend must fit in one Safe transaction: size it with
   `eth_estimateGas`.
7. `VeHemi.updateForfeitAdmin(<the admin recorded in section 2>)`.

## 4. The forfeit checks (before the swap)

- **Events.** `VeHemi.forfeitAdmin()` returns `address(0)`. If VeHemi emitted
  any `ForfeitAdminUpdated` after the one from Safe transaction 1 (section 3,
  step 1), each non-zero `newForfeitAdmin` in those logs is an admin appointed
  since Safe transaction 1. If `forfeitAdmin()` is not `address(0)`, first send
  `VeHemi.updateForfeitAdmin(address(0))` (an admin in place can forfeit after
  these checks, up to the swap). Then treat as a forfeit each `Withdraw` that
  VeHemi emitted after the deployment of the module being checked, while its
  `provider` was such an admin (from the log that appointed it to the next
  `ForfeitAdminUpdated`). VeHemi emits no forfeit event, and the log cannot tell
  a forfeit from that address's own withdrawal. An earlier forfeit cannot reach
  this module: its import skips burned ids. No Safe transaction may appoint a
  forfeit admin between these checks and the swap, so `forfeitAdmin()` is still
  `address(0)` when the swap executes.
- **Records.** No id that VeHemi has burned (`ownerOf` reverts) holds a decaying
  record on the new module (slope above 0) whose `end` is after the current
  time. A record's `end` is its lock's end when it was booked, and `withdraw`
  requires the lock to have ended, so a withdrawn id's record has always ended.
  An unended decaying record on a burned id is a forfeit in the import window.
  (A flat record on a burned id is removed by section 5, step 1.)

If either check finds a forfeit, do not swap: with `VeHemi.forfeitAdmin()` at
`address(0)`, deploy a fresh module and import into it again from section 3,
step 2 (the import skips burned ids; the fresh module's Events check starts at
its deployment, so a forfeit found here is not counted again).

## 5. Reconcile (after the swap)

The import is a snapshot, and the OLD module stays authoritative until the swap.
So the new module can hold, after the swap:

- a stale record for an id armed, disarmed, transferred, topped up, extended or
  re-delegated after its batch, and no record for an id minted after it and not
  imported in the swap's MultiSend;
- a stale or missing `autoDelegate` for an address that set or cleared it on the
  OLD module after its import (a missing one only if it was not imported in the
  swap's MultiSend);
- a record or `autoDelegate` written directly on the new module before the swap:
  `delegate` and `delegateBySig` need only the position's ownership, and
  `setAutoDelegate` only the caller. The imports skip what such a write left.

After the swap, VeHemi books every change on the new module. That does not
repair a stale delegatee by itself: arming, disarming, a top-up, an extension
and a retirement re-book an id at its stored delegatee, and a mint or a transfer
books it at its owner's `autoDelegate` on the new module, which may itself be
stale.

Read the OLD module at block S (an archive RPC). Apart from step 1, no Safe-side
call repairs a single record (a trusted adapter could re-book all of an owner's
positions with `delegateAllFor`, overriding the holder's own choices), so steps
2 and 3 are owner actions: publish the list and the calls to the affected
owners. An owner whose positions should all go to one delegatee can do steps 2
and 3 in one call with the adapter's `delegate(address)`, which sets
`autoDelegate` and re-books every live position of that owner (it skips an
unarmed lock that ends at or before the next hour boundary).

**Step 1. Stranded flat terms (permissionless).** For every id from 1 to
`nextTokenId() - 1`, live or burned, imported or not, whose record on the new
module is flat (slope 0, bias above 0) while `VeHemi.autoRelockRemaining(id)` is
0, anyone calls `newProxy.retireStrandedFlatTerm(id)`. It re-books the id as
decaying at the record's own delegatee (it books nothing for a burned id or a
lock that ends at or before the next hour boundary). An armed id keeps its flat
record.

**Step 2. `autoDelegate`.** For every address that emitted `AutoDelegateSet` on
the OLD module up to S or on the new module (the import emits it too), compare
its `autoDelegate` on the new module with the OLD module's at S. It needs
nothing if they are equal, or if the address set its own value on the new module
after the swap: an `AutoDelegateSet` for it from the new module after the swap
(`setAutoDelegate`, `clearAutoDelegate` or the adapter's `delegate(address)`),
or a call of the adapter's `delegate(address)` by it after the swap (which emits
`AutoDelegateSet` only when the value changes). Otherwise that address calls
`newProxy.setAutoDelegate(<the OLD module's value at S>)`, where `address(0)`
clears it. This re-books no position.

**Step 3. Positions.** For every live id, take the last booking after the swap
that chose its delegatee on the new module (its `DelegateChanged` logs from the
new module after the swap, matched to the transactions that emitted them) and
apply the first row that matches:

| The id's delegatee was last chosen after the swap by | It needs |
| --- | --- |
| Its owner: `delegate`, `delegateBySig` or the adapter's `delegate(address)` | Nothing. |
| Its mint, or a transfer whose move the new module booked, while its owner's `autoDelegate` on the new module equalled the OLD module's at S or had been set by that owner after the swap | Nothing. |
| Its mint, or a transfer whose move the new module booked, while its owner's `autoDelegate` on the new module was still stale | `delegate(id, D)`, where D is the owner's `autoDelegate` as step 2 leaves it (the value it set on the new module after the swap, else the OLD module's at S), or the owner if that is 0. |
| A transfer of an armed id whose move was refused, so the new module removed the record (`DelegateChanged(id, <old>, 0)`) | Nothing beyond what any such transfer needs: the new owner delegates. |
| None of these | The comparison below. |

For an id with no such choice, compare its record on the new module (after step
1) with the OLD module's record at S in every field: delegatee, end, bias,
amount and slope.

- **Equal:** nothing.
- **Different, or no record on the new module:** its owner calls
  `newProxy.delegate(id, D)`, where D is the OLD module's delegatee at S. That
  books the id's current lock and shape at D. An id listed only because its lock
  changed on the new module after the swap (a top-up, an extension, arming,
  disarming or a retirement, with its delegatee already D) is re-booked at D
  harmlessly.
- **Exceptions:**
  - an unarmed id whose lock ends at or before the next hour boundary needs
    nothing (`delegate` reverts `CanNotDelegateExpiredLocks`; at most its last
    hour of weight stays where it is);
  - where the OLD module holds no record at S (a refused armed-transfer move in
    the import window removed it, so the position was undelegated there), the
    owner chooses a delegatee; until then, a record imported before that
    transfer keeps counting the position for the previous owner's delegatee;
  - an id that changed owner after the swap without a booking (a transfer of an
    unarmed id whose move was refused): the new owner chooses.

Burned ids: after step 1, a burned id's record must have ended or be gone. An
unended decaying record on a burned id is a forfeit in the import window that
section 4 missed; its weight stays with that delegatee until its end, and no
call can remove it.

## 6. After the reconcile

- End the governance freeze.
- Keep the reconcile list and the archive reads at block S with the incident
  record.

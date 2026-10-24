// ─────────────────────────────────────────────────────────────────────────────
// Plan for VeHemi's `updateVoteDelegation` recovery path (read-only).
//
// The procedure is docs/VOTE_DELEGATION_RECOVERY.md; this script counts the live
// chain and prints its Safe transactions, and leaves the reconcile after the swap
// to that document. The import cannot fit in one MultiSend: its pre-auto-relock
// figure is ~165,000 gas per tokenId (150 ids is ~25M gas), and Hemi's block gas
// limit is 30,000,000; after the Safe proxy's DELEGATECALL, the Safe's CALL and
// the VVD proxy's DELEGATECALL keep 1/64 each, one Safe transaction carries at
// most ~172 ids at that figure, so the plan uses 150 (IDS_PER_BATCH overrides).
// At block 5,305,210 every one of the 15,592 live positions carried a
// delegation: ~104 Safe transactions of imports at 150 ids each, not one. This
// script counts them on chain and prints the sequence.
//
// It is not the auto-relock upgrade path, which is a storage-preserving proxy
// upgrade in one MultiSend with two inner calls (deploy/08_upgrade_autorelock.ts,
// docs/AUTO_RELOCK_UPGRADE.md). `updateVoteDelegation` is the fresh-proxy
// recovery primitive, for a VVD proxy that is irreparably broken.
//
// Usage:
//   HEMI_RPC_URL=https://... npx ts-node scripts/plan-legacy-migration.ts
//   HEMI_RPC_URL=... IDS_PER_BATCH=150 npx ts-node scripts/plan-legacy-migration.ts
// ─────────────────────────────────────────────────────────────────────────────

import { Contract, JsonRpcProvider, Interface, id } from "ethers";

const RPC_URL = process.env.HEMI_RPC_URL;
if (!RPC_URL) {
    console.error("HEMI_RPC_URL is required (read-only; this script signs nothing).");
    process.exit(1);
}

const VEHEMI_PROXY = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89";
const VVD_PROXY = "0xBF5b2f370370494B8A4575962512dd3ea7c29e2d";
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

// The import's gas figure plus Hemi's limits, named so the plan's arithmetic
// is visible.
const GAS_PER_ID = 165_000; // ~165k gas/iter worst case, measured before the auto-relock upgrade's booking stamp and autoRelockRemaining reads; size each Safe tx with eth_estimateGas
const BLOCK_GAS_LIMIT = 30_000_000; // Hemi
const PER_TX_CEILING = 29_930_000; // measured Hemi per-tx ceiling
const SAFE_BASE_GAS = 21_000 + 9_000; // 21k intrinsic + ~3k per ECDSA check, 3 signatures (today's threshold)
const CALLDATA_GAS_PER_ID = 32 * 16; // one uint256 of non-zero calldata, worst case
const VVD_DEPLOY_BLOCK = 2_527_716; // deployments/hemi/VeHemiVoteDelegation_Proxy.json receipt.blockNumber
const AUTO_DELEGATE_SET_TOPIC = id("AutoDelegateSet(address,address,address)");

const VEHEMI_ABI = [
    "function nextTokenId() view returns (uint256)",
    "function ownerOf(uint256) view returns (address)",
];
const VVD_ABI = [
    "function delegation(uint256) view returns (tuple(address delegatee,uint48 end,uint96 bias,uint96 amount,uint64 slope))",
    "function autoDelegate(address) view returns (address)",
];
const MULTICALL3_ABI = [
    "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[])",
];

async function main() {
    const provider = new JsonRpcProvider(RPC_URL, 43111, { staticNetwork: true });
    const multicall = new Contract(MULTICALL3, MULTICALL3_ABI, provider);
    const veHemiIface = new Interface(VEHEMI_ABI);
    const vvdIface = new Interface(VVD_ABI);
    const veHemi = new Contract(VEHEMI_PROXY, VEHEMI_ABI, provider);

    // Every read below is pinned to this block, the block printed in the COUNTS
    // heading.
    const block = await provider.getBlockNumber();
    const nextTokenId = Number(await veHemi.nextTokenId({ blockTag: block }));
    console.log(`Hemi block ${block} — nextTokenId ${nextTokenId}`);

    const aggregate = async (calls: any[]) => {
        for (let a = 0; a < 8; a++) {
            try {
                return await multicall.aggregate3.staticCall(calls, { blockTag: block });
            } catch (e) {
                if (a === 7) throw e;
                await new Promise((r) => setTimeout(r, 500 * 2 ** a));
            }
        }
        return [];
    };

    const liveDelegated: number[] = [];
    const burnedDelegated: number[] = [];
    const owners = new Set<string>();
    let live = 0;

    const IDS_PER_SCAN_CALL = 300;
    for (let i = 1; i < nextTokenId; i += IDS_PER_SCAN_CALL) {
        const end = Math.min(i + IDS_PER_SCAN_CALL, nextTokenId);
        const calls: any[] = [];
        for (let id = i; id < end; id++) {
            calls.push({ target: VEHEMI_PROXY, allowFailure: true, callData: veHemiIface.encodeFunctionData("ownerOf", [id]) });
            calls.push({ target: VVD_PROXY, allowFailure: true, callData: vvdIface.encodeFunctionData("delegation", [id]) });
        }
        const res: any[] = await aggregate(calls);
        for (let k = 0; k < end - i; k++) {
            const id = i + k;
            const ownerResult = res[2 * k];
            const delegationResult = res[2 * k + 1];
            const isLive = ownerResult.success && ownerResult.returnData !== "0x";
            if (isLive) {
                live++;
                owners.add((veHemiIface.decodeFunctionResult("ownerOf", ownerResult.returnData)[0] as string).toLowerCase());
            }
            if (delegationResult.success && delegationResult.returnData !== "0x") {
                const record: any = vvdIface.decodeFunctionResult("delegation", delegationResult.returnData)[0];
                if (record[0] !== "0x0000000000000000000000000000000000000000") {
                    (isLive ? liveDelegated : burnedDelegated).push(id);
                }
            }
        }
    }

    // autoDelegate counts (the auto-delegate import). `setAutoDelegate` is permissionless, so
    // scan every address that ever emitted AutoDelegateSet, not only live owners.
    const liveOwners = owners.size;
    const scanned = new Set<string>(owners);
    let autoDelegateLogs = 0;
    for (let b = VVD_DEPLOY_BLOCK, step = 50_000; b <= block; ) {
        const e = Math.min(b + step - 1, block);
        let logs;
        try {
            logs = await provider.getLogs({ address: VVD_PROXY, topics: [AUTO_DELEGATE_SET_TOPIC], fromBlock: b, toBlock: e });
        } catch (err) {
            if (step > 1_000) {
                step = Math.max(1_000, Math.floor(step / 4));
                continue;
            }
            throw err; // a lost range would under-count the auto-delegate import: stop rather than print a short plan
        }
        autoDelegateLogs += logs.length;
        for (const l of logs) scanned.add(("0x" + l.topics[1].slice(26)).toLowerCase());
        b = e + 1;
    }
    let addressesWithAutoDelegate = 0;
    const scannedAddresses = [...scanned];
    for (let i = 0; i < scannedAddresses.length; i += 500) {
        const slice = scannedAddresses.slice(i, i + 500);
        const res: any[] = await aggregate(
            slice.map((o) => ({
                target: VVD_PROXY,
                allowFailure: true,
                callData: vvdIface.encodeFunctionData("autoDelegate", [o]),
            }))
        );
        for (const r of res) {
            if (r.success && r.returnData !== "0x") {
                const autoDelegateValue = vvdIface.decodeFunctionResult("autoDelegate", r.returnData)[0] as string;
                if (autoDelegateValue !== "0x0000000000000000000000000000000000000000") addressesWithAutoDelegate++;
            }
        }
    }

    // ── The plan ──────────────────────────────────────────────────────────
    // The Safe proxy DELEGATECALLs its singleton, which CALLs the new VVD proxy, which
    // DELEGATECALLs its implementation: three EIP-150 63/64 retentions before the import
    // loop runs.
    const perTxBudget = Math.floor(((PER_TX_CEILING - SAFE_BASE_GAS) * 63 * 63 * 63) / (64 * 64 * 64));
    const fitIds = Math.floor(perTxBudget / (GAS_PER_ID + CALLDATA_GAS_PER_ID));
    const idsPerBatch = process.env.IDS_PER_BATCH === undefined ? Math.min(150, fitIds) : Number(process.env.IDS_PER_BATCH);
    if (!Number.isInteger(idsPerBatch) || idsPerBatch < 1) throw new Error("IDS_PER_BATCH must be a positive integer");
    if (idsPerBatch > fitIds) console.warn(`WARNING: IDS_PER_BATCH=${idsPerBatch} is above the ${fitIds} ids that fit in one Safe transaction`);
    const delegationImportTxs = Math.ceil(liveDelegated.length / idsPerBatch);
    const autoDelegateImportTxs = addressesWithAutoDelegate === 0 ? 0 : Math.ceil(addressesWithAutoDelegate / idsPerBatch);
    const forfeitTxs = 2; // updateForfeitAdmin(address(0)) first; the previous admin restored last
    const tailTxs = 2; // setTrustedAdapter; then MultiSend[(late imports), finalizeMigration, updateVoteDelegation]
    const totalTxs = forfeitTxs + delegationImportTxs + autoDelegateImportTxs + tailTxs;
    const importGas = BigInt(liveDelegated.length) * BigInt(GAS_PER_ID);

    console.log(`
=== COUNTS (read-only, block ${block}) ===
  ids ever minted                  ${nextTokenId - 1}
  live positions                   ${live}
  live positions WITH a delegation  ${liveDelegated.length}  (${((100 * liveDelegated.length) / live).toFixed(1)}% of live)
  delegation records on burned ids  ${burnedDelegated.length}  <-- the import skips them
  distinct owners of live positions ${liveOwners}
  AutoDelegateSet logs since deploy ${autoDelegateLogs}  (blocks ${VVD_DEPLOY_BLOCK} .. ${block})
  addresses scanned for autoDelegate ${scannedAddresses.length}  (live owners and every AutoDelegateSet emitter)
  addresses with autoDelegate set   ${addressesWithAutoDelegate}${addressesWithAutoDelegate === 0 ? "  <-- the auto-delegate import is a NO-OP today" : ""}

=== WHY THE IMPORTS CANNOT BE ONE MULTISEND ===
  assumed import cost               ${GAS_PER_ID.toLocaleString()} gas per imported id
  Hemi block gas limit              ${BLOCK_GAS_LIMIT.toLocaleString()}
  measured per-tx ceiling           ${PER_TX_CEILING.toLocaleString()}
  Safe overhead (3 signatures)      ${SAFE_BASE_GAS.toLocaleString()}
  ids that fit in ONE Safe tx       ${fitIds}  (after three 63/64 retentions; the plan uses ${idsPerBatch})
  ids that MUST be imported         ${liveDelegated.length}
  => minimum Safe transactions      ${delegationImportTxs} for the delegation imports alone
  total import gas                  ${importGas.toLocaleString()} (~${Math.ceil(Number(importGas) / BLOCK_GAS_LIMIT)} full Hemi blocks)

=== THE SEQUENCE (${totalTxs} Safe transactions, ${idsPerBatch} ids per import tx) ===
  Safe tx   1         veHemi.updateForfeitAdmin(address(0))   <-- FIRST: no forfeit in the import window
  Safe tx   2 .. ${String(1 + delegationImportTxs).padStart(3)}   importDelegationsFromLegacy(oldProxy, ids[..]) — idempotent, resumable
${
        autoDelegateImportTxs === 0
            ? "  (importAutoDelegatesFromLegacy: SKIPPED — no scanned address has autoDelegate set)"
            : `  Safe tx ${String(2 + delegationImportTxs).padStart(3)} .. ${String(1 + delegationImportTxs + autoDelegateImportTxs).padStart(3)}   importAutoDelegatesFromLegacy(oldProxy, owners[..])`
    }
  Safe tx ${String(totalTxs - 2).padStart(3)}         setTrustedAdapter(adapter)
  Safe tx ${String(totalTxs - 1).padStart(3)}         MultiSend[ (late imports, optional), finalizeMigration(), veHemi.updateVoteDelegation(newProxy) ]  <-- the swap
  Safe tx ${String(totalTxs).padStart(3)}         veHemi.updateForfeitAdmin(<the previous forfeit admin>)   <-- LAST

  Before the swap MultiSend, run both forfeit checks (forfeitAdmin() is
  address(0), and no Withdraw since the new proxy was deployed by a forfeit
  admin appointed after Safe tx 1, while it was the admin; no burned id with an
  unended decaying record on the new proxy). AFTER the swap, RECONCILE on the
  new proxy: retire stranded flat terms, then owners re-set a stale
  autoDelegate and re-delegate stale positions. This script does not compute
  the reconcile: follow docs/VOTE_DELEGATION_RECOVERY.md, sections 4 and 5.
  Announce the governance and holder freezes of its section 2 first.

  Per import tx: ~${(idsPerBatch * GAS_PER_ID + SAFE_BASE_GAS).toLocaleString()} gas (${idsPerBatch} x ${GAS_PER_ID.toLocaleString()} + ${SAFE_BASE_GAS.toLocaleString()} Safe overhead)

=== OPERATIONAL CONSEQUENCES ===
  * NOT ATOMIC. ${totalTxs} separate Safe quorums. Between the first import and
    the swap the NEW proxy is partially populated and the OLD one is still
    authoritative. Only the swap is a state change voters see.
  * Import ONLY the ${liveDelegated.length} LIVE ids. The ${burnedDelegated.length} delegation records on burned
    ids are skipped by importDelegationsFromLegacy (lock.amount == 0), but you
    still pay calldata and two STATICCALLs for each.
  * A GOVERNANCE FREEZE MUST SPAN ALL ${totalTxs} TRANSACTIONS AND THE RECONCILE.
    Any Aragon proposal snapshotted from the first import until the reconcile is
    complete reads, on the new contract, only what the new contract had booked by
    its snapshot (the imports so far; after the swap, stale records until the
    reconcile), and that is unrecoverable (forward-only checkpoints).
  * Every import tx is idempotent (delegations[id].delegatee != 0 -> continue),
    so a failed batch can simply be re-sent.
`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});

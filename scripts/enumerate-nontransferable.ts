// One-shot enumerator for live non-transferable veHEMI positions on Hemi
// mainnet. Outputs:
//   - count of live non-transferable positions
//   - subEnd distribution (histogram by month)
//   - the N positions with the earliest subEnd (most relevant to the
//     phantom-carry trigger surface, since these would be the first to
//     lapse if a seeding window stretched too long)
//
// Usage:
//   HEMI_RPC_URL=https://... npx ts-node scripts/enumerate-nontransferable.ts
//
// Multicall3 is at the canonical 0xcA11... address on Hemi (confirmed).

import { Contract, JsonRpcProvider, Interface } from "ethers";

const RPC_URL = process.env.HEMI_RPC_URL;
if (!RPC_URL) {
    console.error("HEMI_RPC_URL is required (private mainnet RPC).");
    process.exit(1);
}
const VE_HEMI = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89";
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

const VE_HEMI_ABI = [
    "function nextTokenId() view returns (uint256)",
    "function ownerOf(uint256) view returns (address)",
    "function transferableAfter(uint256) view returns (uint256)",
    "function getLockedBalance(uint256) view returns (tuple(int128 amount, uint64 end))",
    "function forfeitable(uint256) view returns (bool)",
];

const MULTICALL3_ABI = [
    "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[])",
];

interface LivePosition {
    tokenId: number;
    owner: string;
    amountWei: bigint;
    lockEnd: number;
    transferableAfter: number;
    forfeitable: boolean;
    subEnd: number;
}

const SIX_DAYS = Math.floor((365.25 * 24 * 60 * 60) / 60); // 525,960 s

async function main() {
    const provider = new JsonRpcProvider(RPC_URL);
    const veHemi = new Contract(VE_HEMI, VE_HEMI_ABI, provider);
    const multicall = new Contract(MULTICALL3, MULTICALL3_ABI, provider);
    const veHemiIface = new Interface(VE_HEMI_ABI);

    const block = await provider.getBlockNumber();
    const blk = await provider.getBlock(block);
    const now = blk!.timestamp;

    const nextTokenId = Number(await veHemi.nextTokenId());
    console.log(`Block:           ${block}`);
    console.log(`Now (timestamp): ${now}  (${new Date(now * 1000).toISOString()})`);
    console.log(`nextTokenId:     ${nextTokenId}`);
    console.log(`Scan range:      [1, ${nextTokenId})  =  ${nextTokenId - 1} ids`);
    console.log(``);

    // Stage 1: batch transferableAfter for every id. Skip transferable (== 0)
    // and already-open (<= now) — those are the cheap predicates that prune
    // most of the set before we spend RPC on the more expensive reads.
    const tasOf: Map<number, number> = new Map();
    const TA_BATCH = 800;
    process.stdout.write("Stage 1 (transferableAfter): ");
    for (let i = 1; i < nextTokenId; i += TA_BATCH) {
        const end = Math.min(i + TA_BATCH, nextTokenId);
        const calls = [];
        for (let id = i; id < end; id++) {
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: veHemiIface.encodeFunctionData("transferableAfter", [id]),
            });
        }
        const results: any[] = await multicall.aggregate3.staticCall(calls);
        for (let j = 0; j < results.length; j++) {
            const r = results[j];
            if (!r.success) continue;
            const ta = Number(BigInt(r.returnData));
            if (ta !== 0 && ta > now) {
                tasOf.set(i + j, ta);
            }
        }
        process.stdout.write(`${end}/${nextTokenId - 1} `);
    }
    console.log(``);
    console.log(`Candidates (TA > now): ${tasOf.size}`);
    console.log(``);

    // Stage 2: for the candidates, fetch ownerOf + getLockedBalance + forfeitable.
    const candidates = Array.from(tasOf.keys()).sort((a, b) => a - b);
    const live: LivePosition[] = [];
    const C_BATCH = 200;
    process.stdout.write("Stage 2 (owner/lock/forfeit):  ");
    for (let i = 0; i < candidates.length; i += C_BATCH) {
        const slice = candidates.slice(i, i + C_BATCH);
        const calls = [];
        for (const id of slice) {
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: veHemiIface.encodeFunctionData("ownerOf", [id]),
            });
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: veHemiIface.encodeFunctionData("getLockedBalance", [id]),
            });
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: veHemiIface.encodeFunctionData("forfeitable", [id]),
            });
        }
        const results: any[] = await multicall.aggregate3.staticCall(calls);
        for (let k = 0; k < slice.length; k++) {
            const tokenId = slice[k];
            const ownerRes = results[k * 3 + 0];
            const lockRes = results[k * 3 + 1];
            const forfRes = results[k * 3 + 2];
            if (!ownerRes.success) continue; // burned
            if (!lockRes.success) continue;
            const owner = veHemiIface.decodeFunctionResult("ownerOf", ownerRes.returnData)[0];
            if (owner === "0x0000000000000000000000000000000000000000") continue;
            const lock = veHemiIface.decodeFunctionResult("getLockedBalance", lockRes.returnData)[0];
            const amountWei: bigint = BigInt(lock.amount);
            const lockEnd: number = Number(lock.end);
            if (amountWei <= 0n) continue;
            if (lockEnd <= now) continue;
            const forfeitable = forfRes.success
                ? Boolean(veHemiIface.decodeFunctionResult("forfeitable", forfRes.returnData)[0])
                : false;
            const ta = tasOf.get(tokenId)!;
            const subEnd = Math.min(lockEnd, ta);
            live.push({ tokenId, owner, amountWei, lockEnd, transferableAfter: ta, forfeitable, subEnd });
        }
        process.stdout.write(`${i + slice.length}/${candidates.length} `);
    }
    console.log(``);
    console.log(``);

    // Output
    console.log(`=== SUMMARY ===`);
    console.log(`Live non-transferable positions:    ${live.length}`);
    console.log(`  forfeitable:                      ${live.filter((p) => p.forfeitable).length}`);
    console.log(`  non-forfeitable:                  ${live.filter((p) => !p.forfeitable).length}`);
    const totalWei = live.reduce((acc, p) => acc + p.amountWei, 0n);
    console.log(`Total locked HEMI (non-transferable): ${formatHemi(totalWei)} HEMI`);
    const totalForfWei = live.filter((p) => p.forfeitable).reduce((acc, p) => acc + p.amountWei, 0n);
    console.log(`Total forfeitable HEMI:               ${formatHemi(totalForfWei)} HEMI`);
    console.log(``);

    // Earliest subEnd → highest phantom-carry risk
    const sorted = [...live].sort((a, b) => a.subEnd - b.subEnd);
    console.log(`=== ALL ${sorted.length} POSITIONS (sorted by subEnd ascending) ===`);
    console.log(`  tokenId   subEnd       UTC                   Δ days    lock.amount HEMI   lock.end             transferableAfter    owner`);
    for (const p of sorted) {
        const dayDelta = (p.subEnd - now) / 86400;
        const subEndStr = new Date(p.subEnd * 1000).toISOString();
        const lockEndStr = new Date(p.lockEnd * 1000).toISOString();
        const taStr = new Date(p.transferableAfter * 1000).toISOString();
        const subEndFlag = p.lockEnd <= p.transferableAfter ? "lock" : "TA";
        console.log(
            `  ${pad(p.tokenId, 7)}   ${p.subEnd}   ${subEndStr}   ${dayDelta.toFixed(2).padStart(7)}   ${formatHemi(p.amountWei).padStart(14)}   ${lockEndStr}   ${taStr}   ${p.owner}   [${subEndFlag}]`
        );
    }
    console.log(``);

    // CSV dump for downstream tooling.
    const fs = await import("fs");
    const csvLines = [
        "tokenId,owner,amountHemi,amountWei,lockEnd,lockEndIso,transferableAfter,transferableAfterIso,subEnd,subEndIso,subEndIs,forfeitable,daysFromNow",
    ];
    for (const p of sorted) {
        const lockEndIso = new Date(p.lockEnd * 1000).toISOString();
        const taIso = new Date(p.transferableAfter * 1000).toISOString();
        const subIso = new Date(p.subEnd * 1000).toISOString();
        const dayDelta = ((p.subEnd - now) / 86400).toFixed(2);
        const subFlag = p.lockEnd <= p.transferableAfter ? "lock" : "TA";
        csvLines.push(
            `${p.tokenId},${p.owner},${formatHemi(p.amountWei)},${p.amountWei.toString()},${p.lockEnd},${lockEndIso},${p.transferableAfter},${taIso},${p.subEnd},${subIso},${subFlag},${p.forfeitable},${dayDelta}`
        );
    }
    fs.writeFileSync("/tmp/nontransferable-positions.csv", csvLines.join("\n") + "\n");
    console.log(`Wrote CSV to /tmp/nontransferable-positions.csv (${sorted.length} rows)`);
    console.log(``);

    // Histogram by month
    console.log(`=== subEnd DISTRIBUTION (by month) ===`);
    const buckets: Map<string, number> = new Map();
    for (const p of live) {
        const dt = new Date(p.subEnd * 1000);
        const key = `${dt.getUTCFullYear()}-${String(dt.getUTCMonth() + 1).padStart(2, "0")}`;
        buckets.set(key, (buckets.get(key) || 0) + 1);
    }
    const monthKeys = Array.from(buckets.keys()).sort();
    for (const key of monthKeys) {
        const count = buckets.get(key)!;
        console.log(`  ${key}   ${"#".repeat(Math.min(count, 60))}  ${count}`);
    }
    console.log(``);

    // SIX_DAYS bucket grid — which buckets actually have non-zero
    // slope-change deltas? These are the buckets that `finalizeSeeding`
    // would skip if minSubEnd is in the past.
    console.log(`=== SIX_DAYS BUCKETS WITH NON-ZERO slope-change (= ${SIX_DAYS}s = ${(SIX_DAYS / 86400).toFixed(4)} days) ===`);
    const bucketCounts: Map<number, number> = new Map();
    for (const p of live) {
        const b = Math.floor(p.subEnd / SIX_DAYS) * SIX_DAYS;
        bucketCounts.set(b, (bucketCounts.get(b) || 0) + 1);
    }
    console.log(`Distinct SIX_DAYS buckets:           ${bucketCounts.size}`);
    const earliestBucket = Math.min(...bucketCounts.keys());
    const latestBucket = Math.max(...bucketCounts.keys());
    console.log(`Earliest bucket:                     ${earliestBucket}  (${new Date(earliestBucket * 1000).toISOString()})`);
    console.log(`Latest bucket:                       ${latestBucket}  (${new Date(latestBucket * 1000).toISOString()})`);
    console.log(`Days from now to earliest bucket:    ${((earliestBucket - now) / 86400).toFixed(2)}`);
    console.log(``);

    // Worst-case seeding-window margin: how long can finalize lag
    // markSeedingStarted before the FIRST seeded position's subEnd lapses?
    console.log(`=== SEEDING-WINDOW MARGIN ===`);
    if (sorted.length > 0) {
        const earliest = sorted[0];
        const marginSecs = earliest.subEnd - now;
        console.log(`Earliest subEnd minus now: ${marginSecs}s (${(marginSecs / 86400).toFixed(2)} days, ${(marginSecs / 3600).toFixed(1)} hours)`);
        console.log(`Token id with earliest subEnd: ${earliest.tokenId}`);
        console.log(`Owner: ${earliest.owner}`);
        console.log(`Amount: ${formatHemi(earliest.amountWei)} HEMI`);
        console.log(`forfeitable: ${earliest.forfeitable}`);
    }
}

function formatHemi(wei: bigint): string {
    const whole = wei / 10n ** 18n;
    const frac = wei % 10n ** 18n;
    const fracStr = frac.toString().padStart(18, "0").slice(0, 4);
    return `${whole.toString()}.${fracStr}`;
}

function pad(n: number, w: number): string {
    return n.toString().padStart(w, " ");
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});

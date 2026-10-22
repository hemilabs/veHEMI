// Post-Safe seeding runner.
//
// The V2 upgrade Safe MultiSend produced by deploy/04_upgrade_vehemi_v2.ts
// queues three transactions: upgrade VVD, upgrade VeHemi, and
// markSeedingStarted. Once the Safe quorum approves and executes the
// MultiSend, this script drives the multi-block permissionless flow:
//   - seedBatch(N) repeatedly until the cursor reaches seedingTargetId - 1
//   - finalizeSeeding to flip lockedSeedingFinalized and write the
//     aggregate LockedPoints.
//
// Both calls are permissionless on-chain (no onlyOwner). This script runs
// them from a single EOA so the gas cost is concentrated on one keeper,
// but any caller may run an equivalent loop in parallel — the cursor
// advances monotonically.
//
// Usage:
//   PRIVATE_KEY=0x... npx hardhat --network hemi run scripts/run-seeding-loop.ts
//
// Configuration via env vars:
//   * VE_HEMI_ADDRESS    — VeHemi proxy address (defaults to the Hemi
//                          mainnet deployment file under deployments/hemi/).
//   * SEED_BATCH_SIZE    — token IDs per seedBatch call (default: 1000).
//                          Sized so the per-call gas estimate stays under
//                          ~20M on Hemi's 30M block limit even at a heavy
//                          process-density. Lower if a fork simulation
//                          shows headroom shrinking.
//   * MAX_LOOPS          — safety cap on the number of seedBatch calls
//                          (default: 200). The runner aborts if seeding
//                          has not completed after this many iterations.
//   * POLL_TIMEOUT_MS    — milliseconds to wait between tx confirmations
//                          (default: 60_000).
//
// Operator mandate: complete the loop + finalize within hours of Safe
// execution. The seeded totals are time-independent (slope, subEnd), but
// the materialized LockedPoint at finalize uses block.timestamp; if
// finalize lags past any seeded position's subEnd, the subcurve carries
// that position past its true expiry. MIN_LOCK_DURATION (~12 days) gives
// the operator margin but do not wait days.

import { promises as fs } from "fs";
import path from "path";
import { Contract, JsonRpcProvider, Wallet } from "ethers";
import dotenv from "dotenv";

dotenv.config();

const DEFAULT_RPC_URL = "https://rpc.hemi.network/rpc";
const DEFAULT_DEPLOYMENT_FILE = "deployments/hemi/VeHemi.json";

const VE_HEMI_MIN_ABI = [
    "function seedingStarted() view returns (bool)",
    "function seedingTargetId() view returns (uint256)",
    "function seedingCursor() view returns (uint256)",
    "function lockedSeedingFinalized() view returns (bool)",
    "function seedBatch(uint256 maxIterations)",
    "function finalizeSeeding()"
];

async function loadVeHemiAddress(): Promise<string> {
    if (process.env.VE_HEMI_ADDRESS) return process.env.VE_HEMI_ADDRESS;
    const filePath = path.resolve(process.cwd(), DEFAULT_DEPLOYMENT_FILE);
    const raw = await fs.readFile(filePath, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed.address) throw new Error(`No address in ${filePath}`);
    return parsed.address;
}

async function main() {
    const rpcUrl = process.env.RPC_URL ?? DEFAULT_RPC_URL;
    const privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) throw new Error("PRIVATE_KEY env var required");

    // `??` fires only on null/undefined, so an empty value (`SEED_BATCH_SIZE=` in
    // a .env file) passes it, and `BigInt("")` is `0n`: `seedBatch(0)` advances no
    // cursor, so the loop would broadcast MAX_LOOPS gas-burning no-ops. Treat
    // empty/whitespace as unset, and reject a non-positive batch size.
    const rawBatchSize = process.env.SEED_BATCH_SIZE?.trim() || "1000";
    let batchSize: bigint;
    try {
        batchSize = BigInt(rawBatchSize);
    } catch {
        throw new Error(`SEED_BATCH_SIZE must be a positive integer; got "${rawBatchSize}".`);
    }
    if (batchSize <= 0n) {
        throw new Error(
            `SEED_BATCH_SIZE must be > 0; got "${rawBatchSize}". ` +
            "seedBatch(0) advances no cursor and would burn the whole loop budget on no-ops."
        );
    }

    // Same for MAX_LOOPS: `Number("")` is 0, which skips the loop and then
    // reports "Loop budget exhausted" after zero attempts.
    const rawMaxLoops = process.env.MAX_LOOPS?.trim() || "200";
    const maxLoops = Number(rawMaxLoops);
    if (!Number.isInteger(maxLoops) || maxLoops <= 0) {
        throw new Error(`MAX_LOOPS must be a positive integer; got "${rawMaxLoops}".`);
    }

    const provider = new JsonRpcProvider(rpcUrl);
    const signer = new Wallet(privateKey, provider);
    const veHemiAddress = await loadVeHemiAddress();
    const veHemi = new Contract(veHemiAddress, VE_HEMI_MIN_ABI, signer);

    console.log(`VeHemi proxy:    ${veHemiAddress}`);
    console.log(`Signer:          ${await signer.getAddress()}`);
    console.log(`SEED_BATCH_SIZE: ${batchSize}`);
    console.log(`MAX_LOOPS:       ${maxLoops}`);
    console.log("");

    // Pre-flight: window must be open and not yet finalized.
    const started = (await veHemi.seedingStarted()) as boolean;
    const finalized = (await veHemi.lockedSeedingFinalized()) as boolean;
    if (!started) throw new Error("Seeding has not started. Safe MultiSend must execute markSeedingStarted first.");
    if (finalized) throw new Error("Seeding already finalized.");

    const target = BigInt((await veHemi.seedingTargetId()) as bigint);
    const expectedEnd = target === 0n ? 0n : target - 1n;
    console.log(`seedingTargetId: ${target}`);
    console.log(`expected cursor at completion: ${expectedEnd}\n`);

    // Drive seedBatch until cursor reaches expectedEnd. Use the
    // `seedingCursor()` view (added in this branch) for clean type-safe
    // progress probes — no storage-slot magic.
    for (let i = 0; i < maxLoops; ++i) {
        const cursor = BigInt(await veHemi.seedingCursor());
        if (cursor >= expectedEnd) {
            console.log(`Cursor ${cursor} >= ${expectedEnd}; ready to finalize.`);
            break;
        }
        console.log(`[loop ${i + 1}/${maxLoops}] cursor=${cursor}, calling seedBatch(${batchSize})...`);
        const tx = await veHemi.seedBatch(batchSize);
        const receipt = await tx.wait();
        console.log(`  tx ${tx.hash} mined in block ${receipt?.blockNumber} (gas used: ${receipt?.gasUsed?.toString()})`);
    }

    // Final pre-flight before finalize.
    const cursorFinal = BigInt(await veHemi.seedingCursor());
    if (cursorFinal < expectedEnd) {
        throw new Error(
            `Loop budget exhausted: cursor=${cursorFinal} < expectedEnd=${expectedEnd}. ` +
            "Re-run with a higher MAX_LOOPS or smaller SEED_BATCH_SIZE."
        );
    }

    console.log("\nCalling finalizeSeeding()...");
    const tx = await veHemi.finalizeSeeding();
    const receipt = await tx.wait();
    console.log(`  tx ${tx.hash} mined in block ${receipt?.blockNumber} (gas used: ${receipt?.gasUsed?.toString()})`);

    const ok = (await veHemi.lockedSeedingFinalized()) as boolean;
    if (!ok) throw new Error("finalizeSeeding did not flip the latch — investigate.");
    console.log("\nDone. lockedSeedingFinalized = true. V2 subcurve logic is now live.");
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

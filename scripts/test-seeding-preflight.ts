// Standalone smoke-test for the seeding margin pre-flight that lives in
// deploy/04_upgrade_vehemi_v2.ts. Runs the same Multicall3 scan against
// live Hemi mainnet state to verify the check fires correctly under real
// conditions. Drop after CI for the deploy script lands.
//
// Usage:
//   HEMI_RPC_URL=https://... npx ts-node scripts/test-seeding-preflight.ts
//   HEMI_SUBEND_SAFETY_HOURS=240 npx ts-node …  # force a fail
//
// Mirrors the helper function shape; if you change one, change the other.

import { Contract, JsonRpcProvider, Interface } from "ethers";

const RPC_URL = process.env.HEMI_RPC_URL;
if (!RPC_URL) {
    console.error("HEMI_RPC_URL is required (private mainnet RPC).");
    process.exit(1);
}
const VE_HEMI = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89";
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

const ABI = [
    "function nextTokenId() view returns (uint256)",
    "function ownerOf(uint256) view returns (address)",
    "function transferableAfter(uint256) view returns (uint256)",
    "function getLockedBalance(uint256) view returns (tuple(int128 amount, uint64 end))",
];
const MULTICALL3_ABI = [
    "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[])",
];

async function main() {
    const provider = new JsonRpcProvider(RPC_URL);
    const iface = new Interface(ABI);
    const veHemi = new Contract(VE_HEMI, ABI, provider);
    const multicall = new Contract(MULTICALL3, MULTICALL3_ABI, provider);

    const safetyHours = Number(process.env.HEMI_SUBEND_SAFETY_HOURS ?? 24);
    const block = await provider.getBlock("latest");
    const now: number = Number(block!.timestamp);
    const threshold = now + Math.floor(safetyHours * 3600);
    const nextTokenId = Number(await veHemi.nextTokenId());
    console.log(`Scanning [1, ${nextTokenId}) — safetyHours=${safetyHours}`);

    const tasOf: Map<number, number> = new Map();
    for (let i = 1; i < nextTokenId; i += 800) {
        const end = Math.min(i + 800, nextTokenId);
        const calls = [];
        for (let id = i; id < end; id++) {
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: iface.encodeFunctionData("transferableAfter", [id]),
            });
        }
        const results: any[] = await multicall.aggregate3.staticCall(calls);
        for (let j = 0; j < results.length; j++) {
            const r = results[j];
            if (!r.success) continue;
            const ta = Number(BigInt(r.returnData));
            if (ta !== 0 && ta > now) tasOf.set(i + j, ta);
        }
    }

    let minSubEnd: number = Number.MAX_SAFE_INTEGER;
    let minSubEndTokenId = 0;
    let liveCount = 0;
    const candidates = Array.from(tasOf.keys()).sort((a, b) => a - b);
    for (let i = 0; i < candidates.length; i += 200) {
        const slice = candidates.slice(i, i + 200);
        const calls = [];
        for (const id of slice) {
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: iface.encodeFunctionData("ownerOf", [id]),
            });
            calls.push({
                target: VE_HEMI,
                allowFailure: true,
                callData: iface.encodeFunctionData("getLockedBalance", [id]),
            });
        }
        const results: any[] = await multicall.aggregate3.staticCall(calls);
        for (let k = 0; k < slice.length; k++) {
            const tokenId = slice[k];
            const ownerRes = results[k * 2];
            const lockRes = results[k * 2 + 1];
            if (!ownerRes.success || !lockRes.success) continue;
            const owner = iface.decodeFunctionResult("ownerOf", ownerRes.returnData)[0];
            if (owner === "0x0000000000000000000000000000000000000000") continue;
            const lock = iface.decodeFunctionResult("getLockedBalance", lockRes.returnData)[0];
            const amountWei: bigint = BigInt(lock.amount);
            const lockEnd = Number(lock.end);
            if (amountWei <= 0n) continue;
            if (lockEnd <= now) continue;
            liveCount++;
            const ta = tasOf.get(tokenId)!;
            const subEnd = Math.min(lockEnd, ta);
            if (subEnd < minSubEnd) {
                minSubEnd = subEnd;
                minSubEndTokenId = tokenId;
            }
        }
    }

    if (liveCount === 0) {
        console.log("OK: no live non-transferable positions");
        return;
    }
    const marginHours = (minSubEnd - now) / 3600;
    console.log(`liveCount=${liveCount}, minSubEnd=${new Date(minSubEnd * 1000).toISOString()}, token=${minSubEndTokenId}, marginHours=${marginHours.toFixed(2)}`);

    if (minSubEnd <= threshold) {
        console.log(`PREFLIGHT FAIL (as expected if safety > ${marginHours.toFixed(2)}h)`);
        process.exit(2);
    }
    console.log(`PREFLIGHT PASS (${marginHours.toFixed(2)}h >= ${safetyHours}h required)`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});

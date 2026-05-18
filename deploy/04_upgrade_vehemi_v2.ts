import { DeployFunction } from "hardhat-deploy/types";
import { execSync } from "child_process";
import { Contract, Interface } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";
const VOTE_DELEGATION = "VeHemiVoteDelegation";

// ── Deployment documentation ───────────────────────────────────────────────
// This script upgrades the veHEMI system to V2 (subcurves + Aragon support).
// It queues THREE transactions into the Safe MultiSend:
//
//   1. upgrade(VeHemiVoteDelegation proxy, new delegation impl) - upgrades the
//      delegation contract to add hourly checkpoints, autoDelegate /
//      delegateAllFor / clearAutoDelegate, and the trusted-adapter hook
//      consumed by the Aragon adapter (script 05). NO initializer call —
//      reusing initialize() would revert because of the `initializer` modifier.
//
//   2. upgrade(VeHemi proxy, new VeHemi V2 impl) - upgrades VeHemi to the V2
//      implementation. NO initializer call. The V2 locked-curve functionality
//      is gated behind `lockedSeedingFinalized` (defaults to false), so the
//      contract behaves identically to V1 until the seeding flow finishes.
//
//   3. markSeedingStarted() - opens the seeding window: snapshots the
//      current `nextTokenId` into `seedingTargetId` and sets `seedingStarted`.
//      While the window is open, `_createLock` rejects new non-transferable
//      mints and `forfeit` / `increaseAmount` / `increaseUnlockTime` reject
//      mutations on non-transferable positions, so the seeded set cannot
//      drift. Reverts if already started.
//
// The remaining seeding steps run OUTSIDE the Safe MultiSend, via the
// permissionless `seedBatch` and `finalizeSeeding` entry points (see
// `scripts/run-seeding-loop.ts`):
//
//   4. seedBatch(N) [× as many times as needed] - iterates token IDs in
//      [lastProcessedId + 1, seedingTargetId), accumulating slope/bias deltas
//      and writing slope-change entries on the locked + forfeitable
//      subcurves. Permissionless: any caller may drive the cursor. The
//      cursor advances monotonically and the per-iteration math is a
//      deterministic read of immutable non-transferable position state, so
//      no attacker can corrupt the accumulator. At Hemi mainnet scale
//      (~30K non-transferable positions) this step spans many blocks; the
//      single-block atomicity guard was removed because the catchup loop
//      cannot fit in one block.
//
//   5. finalizeSeeding() - permissionless. Requires the cursor to have
//      reached `seedingTargetId - 1` (the "latch does not unlatch until max
//      position is reached" property). Then advances the global epoch,
//      writes the aggregate `LockedPoint`s for both subcurves, flips
//      `lockedSeedingFinalized`, and clears the accumulator.
//
// OPERATOR MANDATE:
//   * Steps 1-3 are queued by this script into the Safe MultiSend.
//   * Steps 4-5 are NOT in the MultiSend. After the Safe quorum approves
//     and executes the MultiSend, run `scripts/run-seeding-loop.ts` from a
//     funded EOA (deployer or any keeper) to drive seedBatch + finalize.
//   * Complete steps 4-5 within hours of the Safe execution. The seeded
//     totals are time-independent (slope, subEnd), but the materialized
//     LockedPoint at finalize uses `block.timestamp`. If finalize lags
//     past any seeded position's `subEnd`, the subcurve carries that
//     position past its true expiry. MIN_LOCK_DURATION (~12 days) gives
//     the operator a comfortable margin; do not wait days to finalize.
//
// ── Bundle with script 05 ─────────────────────────────────────────────────
// This script MUST be invoked in the same `hardhat deploy` run as script 05
// (`05_aragon_adapter.ts`) so the adapter deployment + `setTrustedAdapter`
// land in the SAME Safe MultiSend as the V2 upgrade. Splitting them creates
// a window where the upgraded VVD is live but `trustedAdapter == address(0)`,
// silently dropping every `_delegate` notify hook and bricking
// `adapter.delegate(X)` (which calls `delegateAllFor`, gated on
// `msg.sender == trustedAdapter`). Both scripts append to the same
// `multisig.batch.tmp.json`; script 99 (`runAtTheEnd`) proposes the
// accumulated batch as one MultiSend.
//
// OPERATOR MANDATE: run `npx hardhat --network hemi deploy` (no `--tags`
// filter). Script 05's pre-flight enforces this with a defense-in-depth
// check: if VVD is still V1 on-chain AND the Safe batch file is empty
// when 05 starts, deployment aborts.

// SEED_BATCH_SIZE was retired alongside the Safe-bundled seedBatch loop.
// The post-Safe `scripts/run-seeding-loop.ts` runner picks its own chunk
// size and drives `seedBatch` permissionlessly across as many blocks as
// needed.

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, execute, get, read } = deployments;
    const { deployer } = await getNamedAccounts();

    // Only run on Hemi mainnet or localhost
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // ── Pre-flight checks ──────────────────────────────────────────────────
    // Validate the on-chain state of both proxies before queueing any
    // upgrade transactions. Failing here is much cheaper than catching a
    // bad upgrade after the Safe has already executed it.
    console.log("=== Pre-flight checks ===");

    const { address: veHemiAddress } = await get(VE_HEMI);
    const { address: voteDelegationAddress } = await get(VOTE_DELEGATION);
    console.log("VeHemi proxy:           ", veHemiAddress);
    console.log("VoteDelegation proxy:   ", voteDelegationAddress);

    // 1. VeHemi must reference the expected VoteDelegation proxy.
    const currentVoteDelegation = (await read(VE_HEMI, "voteDelegation")) as string;
    if (currentVoteDelegation.toLowerCase() !== voteDelegationAddress.toLowerCase()) {
        throw new Error(
            `VeHemi.voteDelegation() mismatch: expected ${voteDelegationAddress}, got ${currentVoteDelegation}`
        );
    }
    console.log("VeHemi.voteDelegation:   OK (matches deployment)");

    // 2. VeHemi must already hold real positions — guards against running on
    //    a fresh proxy where seeding would silently produce a zero subcurve.
    const totalSupply = (await read(VE_HEMI, "totalVeHemiSupply")) as bigint;
    if (totalSupply === 0n) {
        throw new Error("VeHemi.totalVeHemiSupply() is zero — wrong network or fresh proxy?");
    }
    console.log("VeHemi.totalSupply:      ", totalSupply.toString());

    // 3. VeHemi.owner() must be the Gnosis Safe (required for step 3 +
    //    setTrustedAdapter in script 05).
    const veHemiOwner = (await read(VE_HEMI, "owner")) as string;
    if (veHemiOwner.toLowerCase() !== Addresses.Hemi.GNOSIS_SAFE.toLowerCase()) {
        throw new Error(
            `VeHemi.owner() mismatch: expected ${Addresses.Hemi.GNOSIS_SAFE}, got ${veHemiOwner}`
        );
    }
    console.log("VeHemi.owner:            OK (matches Safe)");

    // 3a. The TransparentProxy upgrades route through `DefaultProxyAdmin`
    //     (a shared hardhat-deploy ProxyAdmin contract that owns every
    //     OpenZeppelinTransparentProxy in this repo). The proxy's own `owner()`
    //     (checked in step 3 above) is the VeHemi owner role, NOT the upgrade
    //     authority — `ProxyAdmin.owner()` is. If those drift apart (e.g., a
    //     historical `transferOwnership` on ProxyAdmin that didn't accompany a
    //     `VeHemi.transferOwnership`), `catchUnknownSigner` will surface the
    //     mismatch at Safe execution time, but failing it here is much cheaper.
    const proxyAdminOwner = (await read("DefaultProxyAdmin", "owner")) as string;
    if (proxyAdminOwner.toLowerCase() !== Addresses.Hemi.GNOSIS_SAFE.toLowerCase()) {
        throw new Error(
            `DefaultProxyAdmin.owner() mismatch: expected ${Addresses.Hemi.GNOSIS_SAFE}, got ${proxyAdminOwner}`
        );
    }
    console.log("ProxyAdmin.owner:        OK (matches Safe)");

    // 4. VeHemiVoteDelegation must already point at the same VeHemi proxy.
    const delegationVeHemi = (await read(VOTE_DELEGATION, "veHemi")) as string;
    if (delegationVeHemi.toLowerCase() !== veHemiAddress.toLowerCase()) {
        throw new Error(
            `VeHemiVoteDelegation.veHemi() mismatch: expected ${veHemiAddress}, got ${delegationVeHemi}`
        );
    }
    console.log("Delegation.veHemi:       OK (matches VeHemi proxy)");

    // 4a. VeHemi.HEMI() immutable must match the value this script will pass to
    //     the new implementation's constructor. `immutable` lives in bytecode,
    //     not storage; if a future edit renamed the constructor arg or reordered
    //     the base list, a mismatched new impl would return the wrong HEMI
    //     address on every call. Caught here, not post-upgrade.
    //
    //     Sanity-check the constant itself first: a misconfigured Addresses file
    //     with HEMI_TOKEN == address(0) would make the equality check below
    //     silently pass if the live HEMI were also zero (it isn't, but belt-and-
    //     suspenders against a future config slip).
    if (Addresses.Hemi.HEMI_TOKEN === "0x0000000000000000000000000000000000000000") {
        throw new Error("Addresses.Hemi.HEMI_TOKEN is zero — refusing to upgrade");
    }
    const currentHemi = (await read(VE_HEMI, "HEMI")) as string;
    if (currentHemi.toLowerCase() !== Addresses.Hemi.HEMI_TOKEN.toLowerCase()) {
        throw new Error(
            `VeHemi.HEMI() mismatch: expected ${Addresses.Hemi.HEMI_TOKEN}, got ${currentHemi}`
        );
    }
    console.log("VeHemi.HEMI:             OK (matches new impl constructor arg)");

    // 5. Storage layout pre-flight. The new implementation's storage layout
    //    MUST match the committed golden fixture under test/fixtures/storage-layouts/.
    //    Any drift here would silently corrupt the live proxy on upgrade.
    //    The check script normalizes AST IDs (which change on any source edit)
    //    and diffs the resulting layout against the golden file.
    //
    //    Regenerating the golden (after an intentional layout change):
    //      ./scripts/update-storage-layouts.sh
    //    Then commit the fixture diff alongside the source change.
    console.log("Running storage layout pre-flight...");
    try {
        execSync("./scripts/check-storage-layouts.sh", { stdio: "inherit" });
        console.log("Storage layouts:         OK (match golden fixtures)");
    } catch {
        throw new Error(
            "Storage layout regression detected. Aborting upgrade. " +
                "Run ./scripts/check-storage-layouts.sh for details."
        );
    }

    // 6. Seeding safety margin: scan every live non-transferable position and
    //    refuse to queue the MultiSend if any position's `subEnd =
    //    min(lock.end, transferableAfter)` is closer than the safety margin.
    //
    //    Why this matters: `finalizeSeeding` materializes the locked
    //    LockedPoint as `bias = totalBias - totalSlope * tsFinal`. If
    //    `tsFinal >= subEnd` for any seeded position, the slope-change
    //    `seedBatch` wrote at that bucket lands in the past (never revisited
    //    by the post-finalize forward walk), and the position's slope is
    //    carried on the subcurve past its true expiry. The corruption is
    //    permanent — recovery requires a contract upgrade.
    //
    //    The window between `markSeedingStarted` (queued by this script) and
    //    `finalizeSeeding` (driven by `scripts/run-seeding-loop.ts` after the
    //    Safe quorum executes) is the trigger surface. The default 24-hour
    //    margin gives the operator several Safe-quorum cycles plus the
    //    keeper-loop runtime even on a degraded network. Override via env
    //    var `HEMI_SUBEND_SAFETY_HOURS` only if you have ground truth that
    //    a faster finalize is guaranteed.
    //
    //    Skipped on localhost (31337) where positions are synthetic.
    if (network.config.chainId === 43111) {
        await seedingMarginPreFlight(hre, veHemiAddress);
    } else {
        console.log("Seeding margin check:    SKIPPED (non-mainnet chain)");
    }

    console.log("");

    // ── Step 1: Upgrade VeHemiVoteDelegation ───────────────────────────────
    // Bare upgrade — no initializer call. hardhat-deploy detects the
    // bytecode change and queues `ProxyAdmin.upgrade(proxy, newImpl)`.
    // Adding `execute.init` here would make hardhat-deploy queue
    // `upgradeAndCall(proxy, newImpl, initialize())` which reverts because
    // initialize() carries the `initializer` modifier.
    const upgradeDelegationFunction = () =>
        deploy(VOTE_DELEGATION, {
            from: deployer,
            log: true,
            args: [veHemiAddress],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
            }
        });

    const multiSigDelegationUpgradeTx = await catchUnknownSigner(upgradeDelegationFunction, { log: true });

    if (multiSigDelegationUpgradeTx) {
        await saveForSafeBatchExecution(multiSigDelegationUpgradeTx);
    }

    // ── Step 2: Upgrade VeHemi to V2 ───────────────────────────────────────
    // Same pattern: bare upgrade with no initializer call. The V2
    // locked-curve logic is dormant until finalizeSeeding (step 5) runs.
    const upgradeVeHemiFunction = () =>
        deploy(VE_HEMI, {
            from: deployer,
            log: true,
            args: [Addresses.Hemi.HEMI_TOKEN],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
            }
        });

    const multiSigVeHemiUpgradeTx = await catchUnknownSigner(upgradeVeHemiFunction, { log: true });

    if (multiSigVeHemiUpgradeTx) {
        await saveForSafeBatchExecution(multiSigVeHemiUpgradeTx);
    }

    // ── Step 3: Open the seeding window ────────────────────────────────────
    // Snapshots `nextTokenId` into `seedingTargetId` so the seed range is
    // frozen at this point. New non-transferable mints are blocked until
    // `finalizeSeeding` runs.
    const markSeedingFunction = () =>
        execute(VE_HEMI, { from: deployer, log: true }, "markSeedingStarted");

    const multiSigMarkTx = await catchUnknownSigner(markSeedingFunction, { log: true });

    if (multiSigMarkTx) {
        await saveForSafeBatchExecution(multiSigMarkTx);
    }

    // ── Steps 4 & 5: deferred to post-Safe permissionless flow ─────────────
    // `seedBatch` and `finalizeSeeding` are now permissionless. They run
    // OUTSIDE the Safe MultiSend, via `scripts/run-seeding-loop.ts`, after
    // the Safe quorum approves the MultiSend produced by this script.
    // This split is required because the catchup loop at Hemi mainnet
    // scale (30K+ non-transferable positions) cannot fit in a single
    // Safe MultiSend transaction.
    const nextId = (await read(VE_HEMI, "nextTokenId")) as bigint;
    console.log(
        "\n=== Post-Safe seeding instructions ===\n" +
        `Estimated seeding range: [1, ${nextId.toString()}) at queue time.\n` +
        "After the Safe MultiSend executes, run:\n" +
        "    npx hardhat --network hemi run scripts/run-seeding-loop.ts\n" +
        "from a funded EOA to drive seedBatch + finalizeSeeding.\n" +
        "Complete within hours of Safe execution; MIN_LOCK_DURATION " +
        "(~12 days) gives margin but do not wait days.\n"
    );
};

func.tags = ["VeHemiV2Upgrade"];
func.dependencies = [VE_HEMI, VOTE_DELEGATION];
export default func;

// ── Helper: seeding safety-margin pre-flight ───────────────────────────────
// Multicall3-batched scan of every token id in [1, nextTokenId). Refuses to
// queue the MultiSend if any live non-transferable position has
// `subEnd = min(lock.end, transferableAfter) <= now + safetyHours`.
//
// Two passes:
//   1. `transferableAfter` — cheap predicate. Filters out transferable
//      positions (TA == 0) and already-open positions (TA <= now).
//   2. For TA candidates: `ownerOf`, `getLockedBalance`. Filters burned
//      tokens, expired locks, zero-balance locks. The survivors are the
//      live non-transferable positions that `seedBatch` will include.
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
const MULTICALL3_ABI = [
    "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[])",
];
const SAFETY_PRE_FLIGHT_ABI = [
    "function nextTokenId() view returns (uint256)",
    "function ownerOf(uint256) view returns (address)",
    "function transferableAfter(uint256) view returns (uint256)",
    "function getLockedBalance(uint256) view returns (tuple(int128 amount, uint64 end))",
];

async function seedingMarginPreFlight(hre: HardhatRuntimeEnvironment, veHemiAddress: string) {
    const provider = (hre as any).ethers.provider;
    const veHemiIface = new Interface(SAFETY_PRE_FLIGHT_ABI);
    const veHemi = new Contract(veHemiAddress, SAFETY_PRE_FLIGHT_ABI, provider);
    const multicall = new Contract(MULTICALL3, MULTICALL3_ABI, provider);

    const safetyHours = Number(process.env.HEMI_SUBEND_SAFETY_HOURS ?? 24);
    if (!Number.isFinite(safetyHours) || safetyHours <= 0) {
        throw new Error(`Invalid HEMI_SUBEND_SAFETY_HOURS: ${process.env.HEMI_SUBEND_SAFETY_HOURS}`);
    }

    const block = await provider.getBlock("latest");
    const now: number = Number(block.timestamp);
    const threshold: number = now + Math.floor(safetyHours * 3600);
    const nextTokenId = Number(await veHemi.nextTokenId());

    console.log(`Seeding margin check:    scanning [1, ${nextTokenId}) — safety margin = ${safetyHours}h`);

    // Pass 1: batch `transferableAfter`. Skip transferable (== 0) and
    // already-open (<= now); both are guaranteed to be excluded by
    // `seedBatch`'s skip predicates and can't trigger the phantom carry.
    const tasOf: Map<number, number> = new Map();
    const TA_BATCH = 800;
    for (let i = 1; i < nextTokenId; i += TA_BATCH) {
        const end = Math.min(i + TA_BATCH, nextTokenId);
        const calls = [];
        for (let id = i; id < end; id++) {
            calls.push({
                target: veHemiAddress,
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
    }

    // Pass 2: ownerOf + getLockedBalance for candidates. Skip burned/empty/expired
    // — `seedBatch` does the same. Whatever survives is what gets seeded.
    let minSubEnd: number = Number.MAX_SAFE_INTEGER;
    let minSubEndTokenId: number = 0;
    let liveCount = 0;
    const candidates = Array.from(tasOf.keys()).sort((a, b) => a - b);
    const C_BATCH = 200;
    for (let i = 0; i < candidates.length; i += C_BATCH) {
        const slice = candidates.slice(i, i + C_BATCH);
        const calls = [];
        for (const id of slice) {
            calls.push({
                target: veHemiAddress,
                allowFailure: true,
                callData: veHemiIface.encodeFunctionData("ownerOf", [id]),
            });
            calls.push({
                target: veHemiAddress,
                allowFailure: true,
                callData: veHemiIface.encodeFunctionData("getLockedBalance", [id]),
            });
        }
        const results: any[] = await multicall.aggregate3.staticCall(calls);
        for (let k = 0; k < slice.length; k++) {
            const tokenId = slice[k];
            const ownerRes = results[k * 2 + 0];
            const lockRes = results[k * 2 + 1];
            if (!ownerRes.success || !lockRes.success) continue; // burned / non-existent
            const owner = veHemiIface.decodeFunctionResult("ownerOf", ownerRes.returnData)[0];
            if (owner === "0x0000000000000000000000000000000000000000") continue;
            const lock = veHemiIface.decodeFunctionResult("getLockedBalance", lockRes.returnData)[0];
            const amountWei: bigint = BigInt(lock.amount);
            const lockEnd: number = Number(lock.end);
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
        console.log("Seeding margin check:    OK (no live non-transferable positions to seed)");
        return;
    }

    const marginSecs = minSubEnd - now;
    const marginHours = marginSecs / 3600;
    const minSubEndIso = new Date(minSubEnd * 1000).toISOString();
    console.log(
        `Seeding margin check:    ${liveCount} live non-transferable position(s); ` +
            `earliest subEnd = ${minSubEndIso} (token ${minSubEndTokenId}, ` +
            `${marginHours.toFixed(2)}h from now)`
    );

    if (minSubEnd <= threshold) {
        throw new Error(
            `\nSeeding margin violation. Aborting upgrade.\n\n` +
            `  Earliest subEnd:   ${minSubEndIso} (token ${minSubEndTokenId})\n` +
            `  Margin to subEnd:  ${marginHours.toFixed(2)} hours\n` +
            `  Required margin:   ${safetyHours} hours\n\n` +
            `  Phantom-carry risk: if finalizeSeeding lands after this subEnd, the\n` +
            `  position's slope-change is stranded in a past bucket and the\n` +
            `  subcurve carries it past true expiry. Corruption is permanent.\n\n` +
            `  Resolution paths:\n` +
            `    * Wait for the at-risk position to expire / be withdrawn, then\n` +
            `      re-run this script.\n` +
            `    * If the Safe MultiSend + keeper loop are guaranteed to complete\n` +
            `      before this subEnd (with comfortable headroom), override via\n` +
            `      HEMI_SUBEND_SAFETY_HOURS=<smaller value>. Use with caution.\n`
        );
    }

    console.log(`Seeding margin check:    OK (${marginHours.toFixed(2)}h >= ${safetyHours}h required)`);
}

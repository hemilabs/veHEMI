import { DeployFunction } from "hardhat-deploy/types";
import { execSync } from "child_process";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";
const VOTE_DELEGATION = "VeHemiVoteDelegation";

// ── Deployment documentation ───────────────────────────────────────────────
// This script upgrades the veHEMI system to V2 (subcurves + Aragon support).
// It bundles a sequence of transactions for the Gnosis Safe, executed
// atomically as a single MultiSend. Step 4 (seedBatch) expands to N calls
// depending on `nextTokenId / SEED_BATCH_SIZE`, so the total transaction
// count is `4 + N`. All steps share the same `block.timestamp`, which the
// atomicity guard in `_requireSeedingActive` requires.
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
//      contract behaves identically to V1 until step 5 runs.
//
//   3. markSeedingStarted() - opens the seeding window: snapshots the
//      current `nextTokenId` into `seedingTargetId` and sets `seedingStarted`.
//      While the window is open, `_createLock` rejects new non-transferable
//      mints so the seeded set cannot drift. Reverts if already started or
//      finalized.
//
//   4. seedBatch(N) [× as many times as needed] - iterates token IDs in
//      [lastProcessedId + 1, seedingTargetId), accumulating slope/bias deltas
//      and writing slope-change entries on the locked + forfeitable
//      subcurves. The scan is on-chain — no off-chain list is trusted.
//      Burned, transferable, expired, and already-mature positions are
//      silently skipped. Each call advances the cursor monotonically; the
//      caller picks the chunk size that fits the block gas limit.
//
//   5. finalizeSeeding() - requires the cursor to have reached
//      `seedingTargetId - 1`, then advances the global epoch, writes the
//      aggregate `LockedPoint`s for both subcurves, flips
//      `lockedSeedingFinalized`, and clears the accumulator. Reverts if the
//      scan is incomplete or already finalized.
//
// All `4 + N` transactions are saved to the Safe batch file so they execute
// in a single multisig proposal. The 3-phase seeding flow (steps 3-5)
// replaces the prior single-shot function that trusted a caller-supplied
// token-ID array: the on-chain scan removes both the operator-drift footgun
// and the adversarial front-run vector where someone could mint a
// non-transferable position into the gap between off-chain list derivation
// and Safe execution.

// Maximum token IDs scanned per `seedBatch` call. Sized against the Hemi
// 30M block gas limit with margin for low-density (mostly-burned or
// mostly-transferable) ranges:
//   - skip path  ≈ 2.2k–8.6k gas/ID (ownerOf + optional transferableAfter/locked SLOADs)
//   - process path ≈ 55–60k gas/ID for a qualifying forfeitable position
//     (4 SLOADs + 1–2 cold SSTOREs to lockedSlopeChanges / forfeitableSlopeChanges)
// Density caveat: at ≥10% qualifying density, 5000 × (0.9 × 4.4k + 0.1 × 60k)
// ≈ 50M — exceeds 30M. The current Hemi VeHemi has ~126 non-transferable
// positions in ~30k IDs (< 0.5% density), well within budget. If the live
// distribution shifts (e.g., a future V3 seeded onto a heavier deployment),
// REDUCE this constant accordingly.
//
// OPERATOR MANDATE: Before signing the Safe proposal on mainnet, run
// `./scripts/test-next-deployment-on-fork.sh` (or an equivalent fork
// simulation) and confirm each `seedBatch` sub-call's gas estimate stays
// under ~25M. If any batch approaches the cap, lower SEED_BATCH_SIZE here
// and re-run. The +1 slack batch (see below) means lower values just
// produce a few more no-op calls — never an `SeedingIncomplete` revert.
const SEED_BATCH_SIZE = 5_000;

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

    // ── Step 4: Batched on-chain seed scan ─────────────────────────────────
    // Resolve `nextTokenId` to compute how many `seedBatch` calls cover the
    // range. Each call iterates up to SEED_BATCH_SIZE token IDs and writes
    // slope-change entries for the non-transferable positions it accepts.
    // The cursor advances monotonically; calling more times than needed is
    // a structural no-op.
    const nextId = (await read(VE_HEMI, "nextTokenId")) as bigint;
    // +1 slack batch: this script reads `nextTokenId` off-chain but the actual
    // `seedingTargetId` is whatever `nextTokenId` is at MultiSend execution
    // time. If positions are minted between this read and Safe execution, the
    // off-chain count would be too small and `finalizeSeeding` would revert
    // with `SeedingIncomplete`. Extra calls past the cursor are structural
    // no-ops (`if (startId >= seedingTargetId) return;`), so the buffer is
    // free gas and absorbs up to `SEED_BATCH_SIZE` worth of late mints.
    const batches = Math.max(1, Math.ceil(Number(nextId) / SEED_BATCH_SIZE)) + 1;
    console.log(`Seeding range: [1, ${nextId.toString()}); will queue ${batches} seedBatch call(s) of ${SEED_BATCH_SIZE} IDs each (+1 slack)`);

    for (let i = 0; i < batches; i++) {
        const seedBatchFunction = () =>
            execute(VE_HEMI, { from: deployer, log: true }, "seedBatch", SEED_BATCH_SIZE);

        const multiSigBatchTx = await catchUnknownSigner(seedBatchFunction, { log: true });

        if (multiSigBatchTx) {
            await saveForSafeBatchExecution(multiSigBatchTx);
        }
    }

    // ── Step 5: Finalize ───────────────────────────────────────────────────
    // Materializes the accumulated totals into `lockedGlobalPointHistory` +
    // `forfeitableGlobalPointHistory`, flips `lockedSeedingFinalized`, and
    // clears the accumulator. Reverts if the cursor did not reach
    // `seedingTargetId - 1`.
    const finalizeFunction = () =>
        execute(VE_HEMI, { from: deployer, log: true }, "finalizeSeeding");

    const multiSigFinalizeTx = await catchUnknownSigner(finalizeFunction, { log: true });

    if (multiSigFinalizeTx) {
        await saveForSafeBatchExecution(multiSigFinalizeTx);
    }
};

func.tags = ["VeHemiV2Upgrade"];
func.dependencies = [VE_HEMI, VOTE_DELEGATION];
export default func;

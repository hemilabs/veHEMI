import { DeployFunction } from "hardhat-deploy/types";
import { execSync, spawnSync } from "child_process";
import fs from "fs";
import { Interface } from "ethers";
import { Addresses } from "../helpers/addresses";
import { MULTI_SIG_TXS_FILE, quarantineRefusedBatch, saveForSafeBatchExecution } from "../helpers/safe";
import { mergeABIs } from "hardhat-deploy/dist/src/utils";
import {
    assertDeployedCodeMatchesLinkedArtifact,
    assertLinkManifest,
    assertMatchesFoundryArtifact,
} from "../helpers/linking";
import { VEHEMI_LINK_MANIFEST, deployVeHemiLibraries } from "../helpers/vehemiLibraries";

const VE_HEMI = "VeHemi";
const VOTE_DELEGATION = "VeHemiVoteDelegation";
const PROXY_ADMIN = "DefaultProxyAdmin";

// A verdict of one of this file's gates, as opposed to an instrument failure (a
// provider error, a missing record). `deploy/99_safe-txs.ts` quarantines a batch
// only on one of these; anything else propagates as itself and leaves the file
// where it is (the exit guard and the `.stale-*` path then apply, and deploy/99
// re-checks a restored file).
export class GateRefusal extends Error {}

// Integer operator inputs: unset -> undefined; anything but plain decimal
// digits, or below `min`, throws.
function envInt(name: string, min: number): number | undefined {
    const raw = process.env[name];
    if (raw === undefined) return undefined;
    const n = Number(raw);
    if (!/^[0-9]+$/.test(raw) || !Number.isSafeInteger(n) || n < min) {
        throw new Error(`${name} must be an integer >= ${min} (got "${raw}").`);
    }
    return n;
}

// ── Auto-relock upgrade ────────────────────────────────────────────────────
// Upgrades the live VeHemi and VeHemiVoteDelegation proxies to the auto-relock
// implementations. The operator and signer runbook -- pre-flight, the signer
// checklist, the upgrade-hour window, rollback limits, the post-execution check,
// recovery and monitoring -- is docs/AUTO_RELOCK_UPGRADE.md. Read it first.
//
//     npx hardhat --network hemi deploy --tags AutoRelockUpgrade
//     D1_POST_CHECK_ONLY=1 npx hardhat --network hemi deploy --tags AutoRelockUpgrade   (after execution)
//
// From the deployer EOA: (1) VeHemiCurveLib, (2) VeHemiSupplyLib, (3) the VeHemi
// implementation linked against both (five link sites; helpers/vehemiLibraries.ts),
// (4) the VeHemiVoteDelegation implementation. Queued into ONE Safe MultiSend,
// proposed by deploy/99_safe-txs.ts, in this order:
//     [0] DefaultProxyAdmin.upgrade(VeHemi proxy, new VeHemi implementation)
//     [1] DefaultProxyAdmin.upgradeAndCall(VVD proxy, new VVD implementation,
//             armLegacyDatingWindow() = 0x62c0fe7a), value 0
//
// The two legs must land together. The new VVD calls
// `veHemi.autoRelockRemaining(uint256)` outside any try, from `_delegate`,
// `delegateAllFor`, `importDelegationsFromLegacy` and the permissionless
// `retireStrandedFlatTerm`; the live VeHemi does not have it, so a VVD-first gap
// reverts every direct delegation write and drops every VeHemi-driven update. The
// new VeHemi reaches the delegation module at five sites -- four try/catch calls
// with a gas ceiling (`_reDelegate`, `_requireFlatTermRetired`,
// `_resolveAutoDelegate`, the 4-argument `_delegate`) and the 50,000-gas window
// probe in `_enableAutoRelock`, a STATICCALL that fails open -- so a VeHemi-first
// gap degrades to the old delegation semantics instead of reverting, but the probe
// fails open against the live VVD and holders can arm records that the live VVD
// books as decaying weight. Inside one MultiSend the order is harmless (the arm
// makes no VeHemi call); it is asserted anyway, so a split never runs VVD-first.
//
// This script asserts the batch it queued (order, targets, payload, value, both
// from-implementations, leg count) and refuses rather than propose anything else.
// Only the two proxies' implementations change: both storage layouts are
// append-only over the live ones, and no seeding, migration or proxy swap is
// needed. `deploy/99_safe-txs.ts` carries the AutoRelockUpgrade tag so that the
// command above also proposes the batch: if either tag list changes, change both.

// Set once this run starts queuing (step 3). From then on a throw leaves a
// batch on disk that no gate has passed, so `func` moves it aside
// (`quarantineRefusedBatch`) instead of leaving it to look restorable.
let queuingStarted = false;

async function upgradeAutoRelock(hre: import("hardhat/types").HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, read } = deployments;
    const { deployer } = await getNamedAccounts();

    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // Operator inputs are validated before anything runs: a mistyped
    // D1_POST_CHECK_ONLY must not fall through to the full deploy-and-queue path.
    const postCheckEnv = process.env.D1_POST_CHECK_ONLY;
    if (postCheckEnv !== undefined && postCheckEnv !== "1") {
        throw new Error(`D1_POST_CHECK_ONLY must be exactly "1" (got "${postCheckEnv}"); refusing rather than running the full deploy.`);
    }
    envInt("D1_LOGS_STEP", 1);
    envInt("D1_LOGS_FROM", 0);

    console.log("=== Pre-flight checks ===");

    // 0. The link manifest, before anything is deployed: it fails if a library
    //    appears, disappears or gains a call site that this script does not deploy.
    await assertLinkManifest(hre, VEHEMI_LINK_MANIFEST as unknown as Record<string, Record<string, number>>);

    const { address: veHemiAddress } = await get(VE_HEMI);
    const { address: voteDelegationAddress } = await get(VOTE_DELEGATION);
    const { address: proxyAdminAddress } = await get(PROXY_ADMIN);
    console.log("VeHemi proxy:           ", veHemiAddress);
    console.log("VoteDelegation proxy:   ", voteDelegationAddress);
    console.log("ProxyAdmin:             ", proxyAdminAddress);

    // 1. Wiring: both proxies must already point at each other.
    const currentVoteDelegation = (await read(VE_HEMI, "voteDelegation")) as string;
    if (currentVoteDelegation.toLowerCase() !== voteDelegationAddress.toLowerCase()) {
        throw new Error(
            `VeHemi.voteDelegation() mismatch: expected ${voteDelegationAddress}, got ${currentVoteDelegation}`
        );
    }
    const delegationVeHemi = (await read(VOTE_DELEGATION, "veHemi")) as string;
    if (delegationVeHemi.toLowerCase() !== veHemiAddress.toLowerCase()) {
        throw new Error(
            `VeHemiVoteDelegation.veHemi() mismatch: expected ${veHemiAddress}, got ${delegationVeHemi}`
        );
    }
    console.log("Proxy wiring:            OK (VeHemi ⇄ VoteDelegation)");

    // 2. Live state, not a fresh proxy.
    const totalSupply = (await read(VE_HEMI, "totalVeHemiSupply")) as bigint;
    if (totalSupply === 0n) {
        throw new Error("VeHemi.totalVeHemiSupply() is zero — wrong network or fresh proxy?");
    }
    console.log("VeHemi.totalSupply:      ", totalSupply.toString());

    // 3. Both owner roles must be the Safe. NOTE: `VeHemiVoteDelegation` has
    //    NO `owner()` of its own — its four gates read `veHemi.owner()`, and
    //    `VVD.owner()` REVERTS on the live proxy. Do not add a check for it.
    const veHemiOwner = (await read(VE_HEMI, "owner")) as string;
    if (veHemiOwner.toLowerCase() !== Addresses.Hemi.GNOSIS_SAFE.toLowerCase()) {
        throw new Error(`VeHemi.owner() mismatch: expected ${Addresses.Hemi.GNOSIS_SAFE}, got ${veHemiOwner}`);
    }
    const proxyAdminOwner = (await read(PROXY_ADMIN, "owner")) as string;
    if (proxyAdminOwner.toLowerCase() !== Addresses.Hemi.GNOSIS_SAFE.toLowerCase()) {
        throw new Error(
            `DefaultProxyAdmin.owner() mismatch: expected ${Addresses.Hemi.GNOSIS_SAFE}, got ${proxyAdminOwner}`
        );
    }
    console.log("Owner roles:             OK (VeHemi.owner and ProxyAdmin.owner are the Safe)");

    // 4. The live proxy's HEMI immutable (the OLD implementation's) must be the
    //    HEMI token. This checks chain state before anything is deployed; it cannot
    //    see this run's constructor argument, because `read(VE_HEMI, ...)` goes
    //    through the proxy to the live implementation. Step 3b binds the argument,
    //    and can only run after the new implementation is deployed.
    if (Addresses.Hemi.HEMI_TOKEN === "0x0000000000000000000000000000000000000000") {
        throw new Error("Addresses.Hemi.HEMI_TOKEN is zero — refusing to upgrade");
    }
    const currentHemi = (await read(VE_HEMI, "HEMI")) as string;
    if (currentHemi.toLowerCase() !== Addresses.Hemi.HEMI_TOKEN.toLowerCase()) {
        throw new Error(`VeHemi.HEMI() mismatch: expected ${Addresses.Hemi.HEMI_TOKEN}, got ${currentHemi}`);
    }
    console.log("VeHemi.HEMI:             OK (the LIVE proxy holds the HEMI token; this run's constructor arg is checked at step 3b)");

    // 5. The V2 locked/forfeitable subcurves must already be LIVE. The
    //    auto-relock curve is built on top of them: a flat position is
    //    valued through the same subcurve machinery `finalizeSeeding`
    //    materializes. Upgrading on top of an unfinalized seeding would leave
    //    the subcurves that flat positions are valued through unseeded.
    const finalized = (await read(VE_HEMI, "lockedSeedingFinalized")) as boolean;
    if (!finalized) {
        throw new Error(
            "VeHemi.lockedSeedingFinalized() is false — run deploy/04 + scripts/run-seeding-loop.ts first"
        );
    }
    console.log("V2 seeding:              OK (lockedSeedingFinalized == true)");

    // 5b. Window premises (read-only). The VVD leg arms the upgrade-hour window
    //     (docs/AUTO_RELOCK_UPGRADE.md, section 3). The arm authenticates the
    //     EIP-1967 admin, so that must be the ProxyAdmin. The arm overwrites
    //     slot 101 (`legacyDatingUntil`) unconditionally, so for this script's
    //     armed leg any prior value is harmless: 5b admits 0, or an hour boundary
    //     at or before nb(now) (the next boundary after now) left by an earlier
    //     armed forward (a rollback), and refuses anything else as written by
    //     something unknown. Under a PLAIN leg only 0 (or nb(now)) would be safe:
    //     a past boundary makes the new implementation date immediately, which is
    //     why the matcher refuses a plain VVD leg. `_initialized == 1` keeps
    //     `initialize()` out of reach (it writes the sentinel 1, which would close
    //     a plain leg's open window for good); that too matters only for a plain
    //     leg.
    {
        const p = hre.ethers.provider;
        const vvdImplNow = "0x" + (await p.getStorage(voteDelegationAddress, EIP1967_IMPL_SLOT)).slice(-40);
        const vvdAdmin = "0x" + (await p.getStorage(voteDelegationAddress, EIP1967_ADMIN_SLOT)).slice(-40);
        if (vvdAdmin.toLowerCase() !== proxyAdminAddress.toLowerCase()) {
            throw new Error(`VVD proxy admin (EIP-1967) is ${vvdAdmin}, expected the ProxyAdmin ${proxyAdminAddress}`);
        }
        if (BOUNDARY_DATING_VVD_IMPLS.some((a) => a.toLowerCase() === vvdImplNow.toLowerCase())) {
            const w = BigInt(await p.getStorage(voteDelegationAddress, VVD_WINDOW_SLOT));
            const nowTs = BigInt((await p.getBlock("latest"))!.timestamp);
            const nbNow = (nowTs / 3600n) * 3600n + 3600n;
            if (w !== 0n && !(w % 3600n === 0n && w <= nbNow)) {
                throw new Error(
                    `VVD storage slot ${VVD_WINDOW_SLOT} is ${w}: neither 0 nor an hour boundary at or before ${nbNow} ` +
                        "left by an earlier armed forward. Something unknown wrote it. Refusing."
                );
            }
            // Nothing may have been armed before this forward (a rollback, or a
            // VeHemi-only forward rolled back). deploy/99 re-runs the same audit.
            await assertNothingArmedBeforeForward(
                hre,
                { veHemiProxy: veHemiAddress, vvdProxy: voteDelegationAddress, vvdImplNow },
                "Refusing before anything is deployed."
            );
            const ini = BigInt(await p.getStorage(voteDelegationAddress, OZ5_INITIALIZABLE_SLOT));
            if ((ini & U64) !== 1n || ((ini >> 64n) & 0xffn) !== 0n) {
                throw new Error(`VVD Initializable state is ${ini}, expected _initialized == 1 and _initializing == 0`);
            }
            console.log(`Window premises:         OK (VVD on ${vvdImplNow}, admin = ProxyAdmin, slot 101 ok, _initialized == 1)`);
        } else {
            // Only legitimate case: the proxy is ALREADY on this tree's recorded
            // implementation (the post-upgrade re-run). Anything else is refused
            // here, before the EOA deploys anything: the window is armed only
            // over a boundary-dating implementation.
            const postCheckOnly = process.env.D1_POST_CHECK_ONLY === "1";
            const rec = await deployments.getOrNull(`${VOTE_DELEGATION}_Implementation`);
            if (!rec || rec.address.toLowerCase() !== vvdImplNow.toLowerCase()) {
                if (postCheckOnly) {
                    // In post-check mode the chain is the reference, so a
                    // mismatch means the records are off, not the chain.
                    throw new Error(
                        `D1_POST_CHECK_ONLY: the VVD proxy is on ${vvdImplNow} but deployments/${network.name}/${VOTE_DELEGATION}_Implementation.json ` +
                            `names ${rec?.address ?? "nothing"}: this deployments/ directory did not produce the executed batch, or a later ` +
                            `run overwrote the record. Restore deployments/${network.name}/*_Implementation.json (both records) from the ` +
                            "commit that recorded the implementation the executed VVD leg names (the one made right after the proposing " +
                            "run, or after a split-forward recovery the one made right after the SPLIT FORWARD re-run; " +
                            "docs/AUTO_RELOCK_UPGRADE.md, section 9), then re-run the check."
                    );
                }
                throw new Error(
                    `VVD proxy is on ${vvdImplNow}: neither ${BOUNDARY_DATING_VVD_IMPLS.join(", ")} nor this tree's recorded ` +
                        `implementation (${rec?.address ?? "none"}). deploy/08 is the one-time live-to-V4 transition. ` +
                        "Refusing before anything is deployed. If the VVD proxy is on an implementation an earlier run of " +
                        `this tree deployed (a VVD-first split), restore deployments/${network.name}/${VOTE_DELEGATION}_Implementation.json ` +
                        "from the commit made right after that run and re-run."
                );
            }
            // Both proxies off their live implementations means the forward has
            // executed. A plain re-run would rebuild and, on any metadata drift,
            // deploy and propose a one-leg re-upgrade: refuse it here, before the
            // EOA deploys anything. (The VVD on this build over the LIVE VeHemi is
            // the VVD-first recovery state, and runs on.)
            const veImplNow = "0x" + (await p.getStorage(veHemiAddress, EIP1967_IMPL_SLOT)).slice(-40);
            if (!postCheckOnly && !LIVE_VEHEMI_IMPLS.some((a) => a.toLowerCase() === veImplNow.toLowerCase())) {
                throw new Error(
                    `BOTH proxies are off their live implementations (VeHemi ${veImplNow}, VVD ${vvdImplNow}): the forward has ` +
                        "executed. deploy/08 is the one-time live-to-V4 transition and deploys, queues and proposes nothing after it. " +
                        "For the post-execution check run it with D1_POST_CHECK_ONLY=1. Refusing before anything is deployed."
                );
            }
            // The VVD is on this build and VeHemi is live: the VVD-first recovery
            // state ONLY if VeHemi was never on this build (audited by the helper;
            // deploy/99 re-runs the same audit).
            if (!postCheckOnly) {
                await assertNothingArmedBeforeForward(
                    hre,
                    { veHemiProxy: veHemiAddress, vvdProxy: voteDelegationAddress, vvdImplNow, vvdBuildImpl: rec.address },
                    "Refusing before anything is deployed."
                );
            }
            console.log(`Window premises:         VVD already on this tree's implementation ${vvdImplNow} (post-upgrade run); the window word is checked below.`);
        }
        const fa = (await read(VE_HEMI, "forfeitAdmin")) as string;
        console.log(`VeHemi.forfeitAdmin:      ${fa} (informational: a forfeit inside the window takes effect at its boundary)`);
    }

    // 5c. The read-only post-execution check (docs/AUTO_RELOCK_UPGRADE.md,
    //     section 7). Everything above is read-only; everything below builds,
    //     attests, deploys and queues. With D1_POST_CHECK_ONLY=1 this run stops
    //     here and only reads the chain.
    if (process.env.D1_POST_CHECK_ONLY === "1") {
        if (fs.existsSync(MULTI_SIG_TXS_FILE)) {
            throw new Error(`D1_POST_CHECK_ONLY: a Safe batch file (${MULTI_SIG_TXS_FILE}) is on disk; refusing.`);
        }
        const vvdRec = (await get(`${VOTE_DELEGATION}_Implementation`)).address;
        const veRec = (await get(`${VE_HEMI}_Implementation`)).address;
        // Either record still naming a live implementation means steps 3-4 never
        // ran from this directory, and "current" would mean "never upgraded".
        if (
            BOUNDARY_DATING_VVD_IMPLS.some((a) => a.toLowerCase() === vvdRec.toLowerCase()) ||
            LIVE_VEHEMI_IMPLS.some((a) => a.toLowerCase() === veRec.toLowerCase())
        ) {
            throw new Error(
                `D1_POST_CHECK_ONLY: deployments/${network.name}/*_Implementation.json still name a live implementation ` +
                    `(VeHemi ${veRec}, VVD ${vvdRec}): steps 3-4 never deployed this build's implementations from this ` +
                    "deployments/ directory. Run the check from the tree and deployments/ directory that produced the batch."
            );
        }
        const warnings = await assertNothingToDoIsTrue(
            hre,
            { veHemiProxy: veHemiAddress, veHemiImpl: veRec, vvdProxy: voteDelegationAddress, vvdImpl: vvdRec },
            "D1_POST_CHECK_ONLY=1 (read-only post-execution check)"
        );
        // The only write of this mode, to local files, after a pass.
        const refreshed: string[] = [];
        if (await refreshProxyRecord(hre, VE_HEMI)) refreshed.push(VE_HEMI);
        if (await refreshProxyRecord(hre, VOTE_DELEGATION, "armLegacyDatingWindow")) refreshed.push(VOTE_DELEGATION);
        const records = refreshed.length
            ? `deployments/${network.name}/${refreshed.map((n) => `${n}.json`).join(" and ")} refreshed`
            : `deployments/${network.name} proxy records already current`;
        console.log(
            `POST-EXECUTION CHECK: ${warnings.length ? `PASS WITH WARNINGS (${warnings.length})` : "PASS"} ` +
                `(chain read-only; nothing deployed, queued or proposed; ${records})`
        );
        return;
    }

    // 5d. The proposed bytes come from a committed tree. On Hemi mainnet,
    //     refuse uncommitted changes in any file that decides them, and print the
    //     commit and the attestation the signers compare with the reviewed PR
    //     (signer checklist, docs/AUTO_RELOCK_UPGRADE.md). Keyed on the network
    //     name, not the chain id: the hardhat fork also reports 43111.
    if (network.name === "hemi") {
        const dirty = execSync(
            "git status --porcelain -- src test/fixtures deploy helpers scripts foundry.toml hardhat.config.ts " +
                "package.json package-lock.json remappings.txt",
            { encoding: "utf8" }
        ).trim();
        if (dirty) {
            throw new Error(
                `Uncommitted changes in files that decide the proposed bytes:\n${dirty}\n` +
                    "Propose only from a clean checkout of the reviewed commit."
            );
        }
        const head = execSync("git rev-parse HEAD", { encoding: "utf8" }).trim();
        const att = JSON.parse(fs.readFileSync("test/fixtures/eip170-attestation.json", "utf8"));
        console.log(
            `PROPOSING FROM COMMIT ${head}; attestation digest ${att.digest}, srcTree ${att.srcTreeSha256}. ` +
                "Signers: compare both with the reviewed PR."
        );
    }

    // 6. Storage-layout pre-flight. It compares the build with the golden fixture
    //    in the same tree, which the change set regenerated, so it passes by
    //    construction for a re-cut golden. The append-only check against the
    //    deployed layout is test/StorageLayoutOnchainAnchor.t.sol (a forge test;
    //    this script does not run it).
    console.log("Running storage layout pre-flight...");
    {
        const r = spawnSync("./scripts/check-storage-layouts.sh", [], { stdio: "inherit", shell: false });
        if (r.status === 0) {
            console.log("Storage layouts:         OK (match golden fixtures — SAME-TREE comparison)");
        } else if (r.status === 1) {
            throw new Error(
                "Storage layout regression detected. Aborting upgrade. " +
                    "Run ./scripts/check-storage-layouts.sh for details."
            );
        } else {
            throw new Error(
                `Storage layout gate COULD NOT RUN (exit ${r.status}). This is NOT a pass and NOT a regression ` +
                    "verdict. Aborting upgrade."
            );
        }
    }

    // 6b. Library storage-mirror pre-flight. Pre-flight 6 cannot see a drift in
    //     `src/lib/VeHemiLayout.sol`, which is not in the golden: a
    //     `__gapV2 [37] -> [38]` slip leaves the VeHemi runtime byte-identical,
    //     passes pre-flight 6, and makes every library read of slots 64+ land
    //     one slot off. This upgrade appends three entries (slots 64 and 65, and
    //     `__gapV3` from 66). The DELEGATECALL libraries only READ slot 64
    //     (`autoRelockRemaining`, in VeHemiCurveLib) through the mirror, so a
    //     one-slot drift makes them read the heartbeat (`autoRelockRefreshedAt`)
    //     or a word nothing writes as R.
    console.log("Running library storage-mirror pre-flight...");
    {
        const r = spawnSync("./scripts/check-library-layout-mirror.sh", [], { stdio: "inherit", shell: false });
        if (r.status === 0) {
            console.log("Library mirror:          OK (VeHemiLayout mirrors VeHemi storage)");
        } else if (r.status === 1) {
            throw new Error(
                "LIBRARY STORAGE-MIRROR DRIFT. src/lib/VeHemiLayout.sol no longer mirrors " +
                    "VeHemi's storage layout. Every delegatecall library read of the " +
                    "V3 slots would land on the wrong slot. Aborting upgrade. " +
                    "Run ./scripts/check-library-layout-mirror.sh for the diff."
            );
        } else {
            // The gate's own header: never treat 2 as success, and never report
            // it as a layout regression. It is a broken instrument, not a verdict.
            throw new Error(
                `Library storage-mirror gate COULD NOT RUN (exit ${r.status}). This is NOT a pass ` +
                    "and NOT a drift verdict -- the gate could not produce one. Aborting upgrade."
            );
        }
    }

    // 7. EIP-170 and the attestation. Builds, then VERIFIES the build against
    //    test/fixtures/eip170-attestation.json as it is on disk and writes
    //    nothing; any drift (source, settings, bytecode) aborts before anything is
    //    deployed. The binding to the reviewed commit is pre-flight 5d plus the
    //    signer checklist.
    console.log("Running EIP-170 pre-flight (verify-only)...");
    try {
        execSync("./scripts/check-eip170.sh --verify", { stdio: "inherit" });
    } catch {
        throw new Error("EIP-170 gate failed or the build does not match the committed attestation. Aborting upgrade.");
    }

    // 8. Bind the bytes hardhat will deploy to the bytes forge measured.
    console.log("Foundry ⇄ Hardhat build cross-check...");
    for (const [name, p] of [
        [VE_HEMI, "out/VeHemi.sol/VeHemi.json"],
        [VOTE_DELEGATION, "out/VeHemiVoteDelegation.sol/VeHemiVoteDelegation.json"],
        ["VeHemiCurveLib", "out/VeHemiCurveLib.sol/VeHemiCurveLib.json"],
        ["VeHemiSupplyLib", "out/VeHemiSupplyLib.sol/VeHemiSupplyLib.json"],
    ] as const) {
        await assertMatchesFoundryArtifact(hre, name, p);
    }

    console.log("");

    // ── Step 1+2: deploy the DELEGATECALL libraries (deployer EOA) ─────────
    console.log("--- Steps 1-2: deploy VeHemi DELEGATECALL libraries ---");
    const libraries = await deployVeHemiLibraries(hre, deployer);

    // ── Step 3: deploy the LINKED VeHemi implementation, queue its upgrade ─
    // hardhat-deploy forwards `libraries:` to the implementation deploy and drops
    // it from the proxy deploy, where it is meaningless. The ProxyAdmin.upgrade
    // call has no local signer, hence catchUnknownSigner.
    queuingStarted = true;
    console.log("\n--- Step 3: deploy VeHemi implementation (LINKED) + queue upgrade ---");
    const upgradeVeHemiFunction = () =>
        deploy(VE_HEMI, {
            from: deployer,
            log: true,
            args: [Addresses.Hemi.HEMI_TOKEN],
            libraries,
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
            },
        });

    const multiSigVeHemiUpgradeTx = await catchUnknownSigner(upgradeVeHemiFunction, { log: true });
    if (multiSigVeHemiUpgradeTx) {
        await saveForSafeBatchExecution(multiSigVeHemiUpgradeTx);
    }

    // Verify the link on chain. hardhat-deploy links the CREATION bytecode only,
    // so the saved record's `deployedBytecode` still holds `__$…$__`
    // placeholders; this helper links it locally before comparing.
    const veHemiImpl = await get(`${VE_HEMI}_Implementation`);
    await assertDeployedCodeMatchesLinkedArtifact(hre, VE_HEMI, veHemiImpl.address, libraries);

    // ── 3b. Bind the constructor argument, on the bytes about to go live ──
    //     Nothing else here sees the `args:` array of the step-3 deploy:
    //     pre-flight 4 reads HEMI() through the proxy (the OLD implementation),
    //     assertDeployedCodeMatchesLinkedArtifact zeroes every immutable before
    //     comparing (and the constructor argument lands in one), and
    //     assertMatchesFoundryArtifact compares artifact to artifact. So read
    //     HEMI() off the implementation just deployed, before the batch is
    //     proposed.
    const newImplHemi = (await read(`${VE_HEMI}_Implementation`, "HEMI")) as string;
    if (newImplHemi.toLowerCase() !== Addresses.Hemi.HEMI_TOKEN.toLowerCase()) {
        throw new Error(
            "\n" + "=".repeat(78) + "\n" +
            "NEW VeHemi IMPLEMENTATION CARRIES THE WRONG HEMI TOKEN. REFUSING TO QUEUE IT.\n" +
            "=".repeat(78) + "\n" +
            `  implementation just deployed : ${veHemiImpl.address}\n` +
            `      its HEMI() immutable     : ${newImplHemi}\n` +
            `      Addresses.Hemi.HEMI_TOKEN : ${Addresses.Hemi.HEMI_TOKEN}\n\n` +
            "  The HEMI immutable is set by the `args:` array of the step-3 VeHemi deploy\n" +
            "  above, and is then UNCHANGEABLE for the life of the implementation. Upgrading\n" +
            "  the proxy to it would point every deposit, withdraw, increaseAmount and\n" +
            "  reward transfer at the address above instead of the HEMI token.\n" +
            "  Pre-flight 4 cannot catch this: it reads HEMI() off the live proxy, i.e.\n" +
            "  off the OLD implementation. Fix the `args:` array, do not silence this.\n" +
            "=".repeat(78) + "\n"
        );
    }
    console.log(`New impl HEMI arg:       OK (${newImplHemi} -- read off the implementation just deployed)`);

    // ── Step 4: deploy the VVD implementation, queue its upgrade SECOND ────
    console.log("\n--- Step 4: deploy VeHemiVoteDelegation implementation + queue upgrade ---");
    const upgradeDelegationFunction = () =>
        deploy(VOTE_DELEGATION, {
            from: deployer,
            log: true,
            args: [veHemiAddress],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
                // The VVD leg arms the upgrade-hour window.
                // `onUpgrade.args: []` is required: without it hardhat-deploy
                // reuses the constructor's one argument for a 0-input method and
                // throws. `init` is never read by this script (hardhat-deploy
                // reads it only when no proxy record exists, and
                // `get(VOTE_DELEGATION)` above requires one); it mirrors deploy/01.
                execute: {
                    init: { methodName: "initialize", args: [] },
                    onUpgrade: { methodName: "armLegacyDatingWindow", args: [] },
                },
            },
        });

    const multiSigDelegationUpgradeTx = await catchUnknownSigner(upgradeDelegationFunction, { log: true });
    if (multiSigDelegationUpgradeTx) {
        await saveForSafeBatchExecution(multiSigDelegationUpgradeTx);
    }

    const vvdImpl = await get(`${VOTE_DELEGATION}_Implementation`);
    await assertDeployedCodeMatchesLinkedArtifact(hre, VOTE_DELEGATION, vvdImpl.address, {});

    // The twin of 3b: bind the VVD constructor argument on the implementation
    // just deployed. Pre-flight 1 reads `veHemi()` through the proxy (the OLD
    // implementation), and the code comparison above zeroes immutables, so
    // neither sees the `args:` array of the step-4 deploy.
    const newVvdVeHemi = (await read(`${VOTE_DELEGATION}_Implementation`, "veHemi")) as string;
    if (newVvdVeHemi.toLowerCase() !== veHemiAddress.toLowerCase()) {
        throw new Error(
            `NEW VVD IMPLEMENTATION CARRIES veHemi=${newVvdVeHemi}, expected the VeHemi proxy ${veHemiAddress}. REFUSING TO QUEUE IT.`
        );
    }
    console.log(`New VVD veHemi arg:      OK (${newVvdVeHemi} -- read off the implementation just deployed)`);

    // ── Step 5: ASSERT THE BATCH ORDER ────────────────────────────────────
    await assertBatchOrder(hre, {
        proxyAdmin: proxyAdminAddress,
        veHemiProxy: veHemiAddress,
        veHemiImpl: veHemiImpl.address,
        vvdProxy: voteDelegationAddress,
        vvdImpl: vvdImpl.address,
    });
}

const func: DeployFunction = async function (hre) {
    queuingStarted = false;
    try {
        await upgradeAutoRelock(hre);
    } catch (e) {
        // A batch refused by step 5 (or left unchecked by a throw between step
        // 3's save and step 5) must never be proposable through the `.stale-*`
        // restore path in helpers/safe.ts.
        if (queuingStarted) quarantineRefusedBatch();
        throw e;
    }
};

func.tags = ["AutoRelockUpgrade"];
// NO `func.dependencies`, DELIBERATELY. `deploy/00` and `deploy/01` re-deploy
// both proxies' implementations from scratch; pulled in as dependencies they
// would queue their own `ProxyAdmin.upgrade` calls before this script runs, and
// `deploy/01` runs AFTER `deploy/00` but still ahead of us — so the batch order
// would be decided by scripts that know nothing about the VeHemi-first
// constraint. This script reads the existing deployment records with `get()`
// instead. It upgrades existing proxies only; on a chain without deployed
// proxies it refuses before deploying anything (no record for `get()`, or no
// live state at pre-flights 2 and 5).
export default func;

// ── Helper: batch-order assertion + gas estimates ──────────────────────────
// The MultiSend executes its inner calls in array order, and
// `saveForSafeBatchExecution` appends in call order, so "queued first" is
// "executed first". The order decides whether delegation works in between, so
// it is asserted rather than assumed. The matcher must know `upgradeAndCall`:
// `parseTransaction` returns null (it does not throw) for a selector the ABI
// lacks, so the armed VVD leg would go unrecognised.
const PROXY_ADMIN_ABI = [
    "function upgrade(address proxy, address implementation)",
    "function upgradeAndCall(address proxy, address implementation, bytes data) payable",
];

// The leg payloads. This ProxyAdmin is OZ-v4 shaped: `upgradeAndCall` routes to
// `TransparentUpgradeableProxy.upgradeToAndCall` with `forceCall = true`, so even
// EMPTY data delegate-calls the new implementation, and neither implementation
// has a `fallback` or `receive`. `upgradeAndCall(proxy, impl, 0x)` therefore
// reverts ("Address: low-level delegate call failed") and takes the upgrade with
// it, forward or rollback: a Safe quorum spent for nothing. The VeHemi leg and
// every rollback leg use `upgrade(address,address)`; the forward VVD leg is
// `upgradeAndCall(VVD, impl, armLegacyDatingWindow())` with exactly those four
// bytes and value 0.
//
// The arm runs only over a boundary-dating (pre-V4) VVD implementation: this
// script is the one-time live-to-V4 transition, and arming over a V4
// implementation would open a window in which disable / disarm step-downs lag.
// Nothing that reads VeHemi may join this payload: step 4's `estimateGas` runs
// before the VeHemi leg has executed and would revert.
export const VVD_ARM_DATA = new Interface(["function armLegacyDatingWindow()"]).encodeFunctionData(
    "armLegacyDatingWindow",
    []
); // 0x62c0fe7a
// The live, boundary-dating VVD implementation (what
// deployments/hemi/VeHemiVoteDelegation_Implementation.json names before this
// script runs; step 4 overwrites that record).
export const BOUNDARY_DATING_VVD_IMPLS = ["0xAcAA0d96121C035fC21345551317d66921394128"];
// The live VeHemi implementation (what deployments/hemi/VeHemi_Implementation.json
// names before this script runs; step 3 overwrites that record). It has no
// `enableAutoRelock`, so it cannot emit `AutoRelockEnabled`, and no
// `autoRelockRemaining`. A VeHemi leg runs only over it.
export const LIVE_VEHEMI_IMPLS = ["0xf1e3AA617E5011793F759092b59d22247E57b84A"];
// Per chain, a block at which the VeHemi proxy was on a LIVE_VEHEMI_IMPLS
// implementation and before any auto-relock build was deployed, so no
// `AutoRelockEnabled` from the proxy can predate it. Hemi: 5,524,738, the fork
// pin of test/r31 and the deploy rehearsal. `autoRelockAuditFrom` re-reads the
// premise at the block the audit starts from.
const AUTO_RELOCK_AUDIT_FLOOR: Record<number, number> = { 43111: 5_524_738 };
// EIP-1967 admin slot and the OZ5 Initializable namespaced slot (pre-flight 5b).
const EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const OZ5_INITIALIZABLE_SLOT = "0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00";
const VVD_WINDOW_SLOT = 101; // VeHemiDelegationStorageV4.legacyDatingUntil, uint64 at offset 0
const U64 = (1n << 64n) - 1n;

// ── "Nothing to do" is a claim about the chain, so read the chain ──────────
// hardhat-deploy queues a ProxyAdmin upgrade only for a newly deployed
// implementation. Once a run has deployed the implementations, every later run
// queues nothing, whether or not the batch that run produced was ever proposed
// or executed. So "nothing queued" is checked against both proxies' EIP-1967
// implementation slots, never inferred from the absence of a batch.
//
// EIP-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
export const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function assertNothingToDoIsTrue(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    expected: { veHemiProxy: string; veHemiImpl: string; vvdProxy: string; vvdImpl: string },
    because: string
): Promise<string[]> {
    const slot = async (proxy: string) => {
        const raw = await hre.ethers.provider.getStorage(proxy, EIP1967_IMPL_SLOT);
        return "0x" + raw.slice(-40);
    };
    const live = { veHemi: await slot(expected.veHemiProxy), vvd: await slot(expected.vvdProxy) };
    const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
    const veOk = eq(live.veHemi, expected.veHemiImpl);
    const vvdOk = eq(live.vvd, expected.vvdImpl);
    if (veOk && vvdOk) {
        // A record naming a live implementation cannot be this forward's leg: with
        // the VeHemi record reverted to the live one, "VeHemi current" would mean
        // VeHemi was never upgraded (the new VVD over the live VeHemi).
        if (
            LIVE_VEHEMI_IMPLS.some((a) => eq(a, expected.veHemiImpl)) ||
            BOUNDARY_DATING_VVD_IMPLS.some((a) => eq(a, expected.vvdImpl))
        ) {
            throw new GateRefusal(
                `deployments/<net>/*_Implementation.json name a LIVE implementation (VeHemi ${expected.veHemiImpl}, VVD ` +
                    `${expected.vvdImpl}): those cannot be this forward's legs, so "current" here does not mean upgraded. ` +
                    "Restore the records that name the executed legs (the proposing run's, or after a split-forward " +
                    "recovery the SPLIT FORWARD re-run's), then re-run the check. Investigate."
            );
        }
        // The post-upgrade check also reads the window word and binds it to the
        // arming upgrade transaction.
        const w = BigInt(await hre.ethers.provider.getStorage(expected.vvdProxy, VVD_WINDOW_SLOT)) & U64;
        if (w === 0n) {
            throw new GateRefusal(
                "\n" + "=".repeat(78) + "\n" +
                "THE VVD PROXY IS ON THIS BUILD BUT ITS UPGRADE-HOUR WINDOW WAS NEVER ARMED.\n" +
                "=".repeat(78) + "\n" +
                "  legacyDatingUntil() == 0: the VVD leg landed as a PLAIN upgrade, not\n" +
                "  upgradeAndCall(VVD, impl, armLegacyDatingWindow()). The implementation reads 0\n" +
                "  as an OPEN window (live dating) until the first _delegate closes it at the next\n" +
                "  hour boundary -- fail-safe, but not the reviewed shape. Investigate before\n" +
                "  reporting the upgrade as done; auto-relock arming is refused until it closes.\n" +
                "=".repeat(78) + "\n"
            );
        }
        // deploy/01 initializes a fresh proxy to the sentinel 1 (no window).
        if (w === 1n) {
            if (hre.network.config.chainId === 43111) {
                throw new GateRefusal(
                    "VVD legacyDatingUntil() == 1 (fresh-deployment sentinel) on the Hemi proxy, which must carry the arm's boundary. Investigate."
                );
            }
            console.log("Window word:             legacyDatingUntil = 1 (fresh-deployment sentinel: this proxy never had an upgrade-hour window)");
            return [];
        }
        if (w % 3600n !== 0n) {
            throw new GateRefusal(`VVD legacyDatingUntil() == ${w} is not an hour boundary: not written by the reviewed arm. Investigate.`);
        }
        const armTx = await assertWindowArmedByUpgrade(hre, expected.vvdProxy, expected.vvdImpl, w);
        console.log(`Window word:             legacyDatingUntil = ${w}, bound to the arming upgrade tx (immediate dating from ${w} on)`);
        return await assertVeHemiUpgradedWithArm(hre, expected.veHemiProxy, expected.veHemiImpl, armTx);
    }

    throw new GateRefusal(
        "\n" + "=".repeat(78) + "\n" +
        `THIS RUN QUEUED NOTHING AND THE UPGRADE IS NOT COMPLETE (${veOk ? "VeHemi current" : "VeHemi NOT upgraded"}, ` +
        `${vvdOk ? "VVD current" : "VVD NOT upgraded"}). REFUSING TO EXIT 0.\n` +
        "=".repeat(78) + "\n" +
        `  reason this branch was reached : ${because}\n` +
        `  VeHemi proxy ${expected.veHemiProxy}\n` +
        `      implementation on chain    : ${live.veHemi}${veOk ? "  (current)" : "  <-- NOT THE NEW IMPLEMENTATION"}\n` +
        `      this build's implementation : ${expected.veHemiImpl}\n` +
        `  VoteDelegation proxy ${expected.vvdProxy}\n` +
        `      implementation on chain    : ${live.vvd}${vvdOk ? "  (current)" : "  <-- NOT THE NEW IMPLEMENTATION"}\n` +
        `      this build's implementation : ${expected.vvdImpl}\n\n` +
        "  hardhat-deploy emits the ProxyAdmin.upgrade call ONLY when the implementation\n" +
        "  is NEWLY deployed. A previous run has already deployed these implementations,\n" +
        "  so re-running cannot re-queue the upgrade. The batch that run produced was\n" +
        "  either PROPOSED AND NOT YET EXECUTED, never proposed, or destroyed.\n\n" +
        "  TO RECOVER\n" +
        "    * FIRST check the Safe queue. If the 2-leg upgrade batch is pending there,\n" +
        "      do nothing here: get it executed, then run this script with\n" +
        "      D1_POST_CHECK_ONLY=1 as the post-upgrade check. Do NOT redeploy -- a\n" +
        "      second proposal would share the pending one's nonce.\n" +
        "    * If BOTH proxies are still on their live implementations and a preserved\n" +
        "      two-leg batch exists that this script printed ORDER ASSERTED for\n" +
        "      (multisig.batch.tmp.json.stale-*; never a .refused-* file), restore it:\n" +
        "          mv multisig.batch.tmp.json.stale-<ts> multisig.batch.tmp.json\n" +
        "          PROPOSE_EXISTING_BATCH=1 npx hardhat --network <net> deploy --tags safe\n" +
        "      (in a run that queues nothing else; no execution timing is needed)\n" +
        "    * Otherwise, while BOTH proxies are still on their live implementations,\n" +
        "      delete the implementation records so this script deploys and queues\n" +
        "      fresh ones, then run the whole thing in ONE process:\n" +
        "          rm deployments/<net>/VeHemi_Implementation.json \\\n" +
        "             deployments/<net>/VeHemiVoteDelegation_Implementation.json\n" +
        "          npx hardhat --network <net> deploy --tags AutoRelockUpgrade\n" +
        "    * If the VVD proxy is ALREADY on this build and VeHemi NEVER was (no\n" +
        "      Upgraded(<this VeHemi impl>) from the VeHemi proxy; direct\n" +
        "      delegation writes revert; VeHemi-driven updates are dropped): propose\n" +
        "      upgrade(VeHemi, impl) ALONE, immediately; do NOT re-arm; then\n" +
        "      run D1_POST_CHECK_ONLY=1, which lists the dropped updates. Do NOT use the\n" +
        "      in-window rollback file in this state (docs/AUTO_RELOCK_UPGRADE.md, section 9).\n" +
        "    * If VeHemi is already on this build and the VVD is not (a split forward):\n" +
        "      if no SPLIT FORWARD audit has been run from this deployments/ directory,\n" +
        "      re-run with ONLY deployments/<net>/VeHemiVoteDelegation_Implementation.json\n" +
        "      deleted to get it, and follow it (one hand-built armed VVD leg, no VeHemi\n" +
        "      leg, proposed through the Safe UI, then D1_POST_CHECK_ONLY=1). If it has\n" +
        "      (a plain re-run after it ends here), do NOT delete the record again:\n" +
        "      commit it; the hand-built leg must name it, and another deletion deploys\n" +
        "      another implementation. Do NOT restore a two-leg batch and do NOT delete\n" +
        "      both records.\n" +
        "=".repeat(78) + "\n"
    );
}

// Post-upgrade binding: the VVD proxy's latest `Upgraded(<this build>)`
// log must sit in a transaction that also emitted
// `LegacyDatingWindowArmed(W, true)` from the proxy, with W == the next hour
// boundary after that block. A plain leg (event absent, or only the lazy
// close's `(B, false)` in a later tx) and a stale word both fail here.
const UPGRADED_TOPIC = "0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b"; // Upgraded(address)
const ARMED_TOPIC = new Interface(["event LegacyDatingWindowArmed(uint256 until, bool viaUpgradeCall)"]).getEvent(
    "LegacyDatingWindowArmed"
)!.topicHash;
async function assertWindowArmedByUpgrade(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    vvdProxy: string,
    vvdImpl: string,
    w: bigint
) {
    const p = hre.ethers.provider;
    const rec = await hre.deployments.getOrNull("VeHemiVoteDelegation_Implementation");
    const head = await p.getBlockNumber();
    const from = logsFromBlock(rec, head);
    const logs = await getLogsChunked(hre, { address: vvdProxy, topics: [UPGRADED_TOPIC, addressTopic(vvdImpl)] }, from, head);
    const found: LogRef | undefined = logs.length ? logs[logs.length - 1] : undefined;
    if (!found) {
        throw new GateRefusal(
            `No Upgraded(${vvdImpl}) log from the VVD proxy since block ${from}: cannot bind the window word to the ` +
                "arming transaction. Confirm LegacyDatingWindowArmed(B, true) in the execution receipt by hand. Refusing to exit 0."
        );
    }
    const receipt = await p.getTransactionReceipt(found.transactionHash);
    const blk = await p.getBlock(found.blockNumber);
    const nb = (BigInt(blk!.timestamp) / 3600n) * 3600n + 3600n;
    const armed = receipt!.logs.filter(
        (l) => l.address.toLowerCase() === vvdProxy.toLowerCase() && l.topics[0] === ARMED_TOPIC
    );
    const ok = armed.some((l) => {
        const [until, via] = new Interface(["event LegacyDatingWindowArmed(uint256 until, bool viaUpgradeCall)"])
            .decodeEventLog("LegacyDatingWindowArmed", l.data, l.topics) as unknown as [bigint, boolean];
        return via === true && until === nb && until === w;
    });
    if (!ok) {
        throw new GateRefusal(
            `The VVD upgrade tx ${found.transactionHash} (block ${found.blockNumber}) carries no LegacyDatingWindowArmed(${nb}, true) ` +
                `matching legacyDatingUntil() == ${w}: the VVD leg was not the reviewed upgradeAndCall(..., armLegacyDatingWindow()). Investigate.`
        );
    }
    return found;
}

// The window binding above names only the VVD leg. Bind the VeHemi side to it:
//   * ANY `AutoRelockEnabled` from the VeHemi proxy before the arm fails. The
//     live VeHemi cannot emit it, so either the position was armed while the
//     VVD was not on this armed build (a split forward; a split completed by a
//     two-leg batch whose VeHemi re-upgrade lands in the arming transaction),
//     where the replaced VVD booked its record as decaying weight while its
//     shape is flat, and once the VVD leg lands every move of it either reverts
//     or takes its weight out of the delegatee's other flat terms, the last of
//     which can then never be removed; or it was armed in an earlier forward
//     that was rolled back and re-forwarded (a breached rollback precondition;
//     docs/AUTO_RELOCK_UPGRADE.md, section 8). The search starts at
//     `autoRelockAuditFrom`, not at the latest Upgraded log, so a re-upgrade
//     cannot hide the gap.
//   * VeHemi upgraded in the arming transaction: the reviewed shape.
//   * VeHemi upgraded in an EARLIER transaction, nothing armed: a warning.
//   * VeHemi upgraded in a LATER transaction: the new VVD ran under the live
//     VeHemi, which commits its own mint / lock / transfer changes and drops the
//     VVD update (`DelegationUpdateFailed`). Any such event in the gap fails;
//     none is a warning.
// Returns the warnings.
const AUTO_RELOCK_ENABLED_TOPIC = new Interface(["event AutoRelockEnabled(uint256 indexed tokenId, uint64 remaining)"]).getEvent(
    "AutoRelockEnabled"
)!.topicHash;
const DELEGATION_UPDATE_FAILED_TOPIC = new Interface(["event DelegationUpdateFailed(uint256 indexed delegator)"]).getEvent(
    "DelegationUpdateFailed"
)!.topicHash;
async function assertVeHemiUpgradedWithArm(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    veHemiProxy: string,
    veHemiImpl: string,
    armTx: LogRef
): Promise<string[]> {
    const p = hre.ethers.provider;
    const auditFrom = await autoRelockAuditFrom(hre, veHemiProxy, armTx.blockNumber);
    const armedEarly = (
        await getLogsChunked(hre, { address: veHemiProxy, topics: [AUTO_RELOCK_ENABLED_TOPIC] }, auditFrom, armTx.blockNumber)
    ).filter((l) => before(l, armTx));
    if (armedEarly.length) {
        throw new GateRefusal(
            `AutoRelockEnabled from the VeHemi proxy BEFORE the VVD arm (tx ${armTx.transactionHash}, block ${armTx.blockNumber}; ` +
                `searched from block ${auditFrom}): token ids ${tokenIds(armedEarly)}. Those positions were armed either while the ` +
                "VVD was not on this armed build (a split forward), where the replaced VVD booked them as decaying weight while " +
                "their shape is flat and every move of such a record now either reverts or takes its weight out of the " +
                "delegatee's other flat terms, or in an earlier forward that was rolled back (a breached rollback precondition). " +
                "Under a split forward an id its owner disarmed before the VVD leg landed is clean; treat each id still armed " +
                "when it landed (or armed in a rolled-back forward) as an open vote-integrity incident (docs/AUTO_RELOCK_UPGRADE.md: " +
                "section 9 for a split forward, section 8 for a rollback). This refusal is permanent: record the ids and refresh " +
                "deployments/<net>/VeHemi.json and VeHemiVoteDelegation.json by hand (section 9)."
        );
    }
    const rec = await hre.deployments.getOrNull("VeHemi_Implementation");
    const head = await p.getBlockNumber();
    const from = logsFromBlock(rec, head);
    const ups = await getLogsChunked(hre, { address: veHemiProxy, topics: [UPGRADED_TOPIC, addressTopic(veHemiImpl)] }, from, head);
    if (!ups.length) {
        throw new GateRefusal(
            `No Upgraded(${veHemiImpl}) log from the VeHemi proxy since block ${from}: cannot bind the VeHemi upgrade to the ` +
                `arming transaction ${armTx.transactionHash}. Confirm both Upgraded events in the execution receipt by hand. Refusing to exit 0.`
        );
    }
    // Any later Upgraded log naming another implementation is a VeHemi-leg
    // rollback after the arm, however the proxy got back onto this build.
    const away = (await getLogsChunked(hre, { address: veHemiProxy, topics: [UPGRADED_TOPIC] }, armTx.blockNumber, head)).filter(
        (l) => before(armTx, l) && l.topics[1].toLowerCase() !== addressTopic(veHemiImpl)
    );
    if (away.length) {
        const droppedSince = await getLogsChunked(
            hre,
            { address: veHemiProxy, topics: [DELEGATION_UPDATE_FAILED_TOPIC] },
            away[0].blockNumber,
            head
        );
        const armedBefore = (
            await getLogsChunked(hre, { address: veHemiProxy, topics: [AUTO_RELOCK_ENABLED_TOPIC] }, armTx.blockNumber, away[0].blockNumber)
        ).filter((l) => before(l, away[0]));
        throw new GateRefusal(
            `The VeHemi proxy was upgraded AWAY from this build after the arm (tx ${away[0].transactionHash}, block ` +
                `${away[0].blockNumber}): a VeHemi-leg rollback. AutoRelockEnabled before it: ${tokenIds(armedBefore) || "none"}; ` +
                `DelegationUpdateFailed since it: ${tokenIds(droppedSince) || "none"}. Re-running this script is not a repair.`
        );
    }
    if (ups.some((u) => u.transactionHash.toLowerCase() === armTx.transactionHash.toLowerCase())) {
        console.log(`Forward:                 VeHemi upgraded in the same transaction (${armTx.transactionHash})`);
        return [];
    }
    const last = ups[ups.length - 1];
    if (before(last, armTx)) {
        const w =
            `VeHemi (tx ${last.transactionHash}, block ${last.blockNumber}) and the VVD arm (tx ${armTx.transactionHash}, ` +
            `block ${armTx.blockNumber}) landed in SEPARATE transactions (a split forward). No AutoRelockEnabled before the arm, ` +
            "so no position was armed in the gap, but this is not the reviewed ONE-MultiSend shape.";
        console.warn(`WARNING: ${w}`);
        return [w];
    }
    const veAfter = ups.find((u) => before(armTx, u))!;
    const dropped = (
        await getLogsChunked(
            hre,
            { address: veHemiProxy, topics: [DELEGATION_UPDATE_FAILED_TOPIC] },
            armTx.blockNumber,
            veAfter.blockNumber
        )
    ).filter((l) => before(armTx, l) && before(l, veAfter));
    if (dropped.length) {
        throw new GateRefusal(
            `The VVD was upgraded and armed (tx ${armTx.transactionHash}, block ${armTx.blockNumber}) BEFORE VeHemi (tx ` +
                `${veAfter.transactionHash}, block ${veAfter.blockNumber}). In between, the live VeHemi committed mint / lock / ` +
                "transfer changes whose VVD updates reverted and were dropped (DelegationUpdateFailed, token ids " +
                `${tokenIds(dropped)}): those records are out of step with VeHemi. Each owner must re-delegate with ` +
                "VVD.delegate(id, <delegatee>) (for a token transferred in the gap, the NEW owner). This refusal is " +
                "permanent: record the ids as an incident and refresh deployments/<net>/VeHemi.json and " +
                "VeHemiVoteDelegation.json by hand (docs/AUTO_RELOCK_UPGRADE.md, section 9)."
        );
    }
    const w =
        `the VVD was upgraded and armed (tx ${armTx.transactionHash}, block ${armTx.blockNumber}) BEFORE VeHemi (tx ` +
        `${veAfter.transactionHash}, block ${veAfter.blockNumber}), in separate transactions: direct delegate / ` +
        "delegateBySig / delegateAllFor calls reverted in between; no DelegationUpdateFailed was emitted. Not the reviewed " +
        "ONE-MultiSend shape.";
    console.warn(`WARNING: ${w}`);
    return [w];
}

// Log searches use an adaptive chunk (D1_LOGS_STEP, a positive integer, default
// 10,000 blocks; halved on a provider error while above 500, so the smallest step
// tried from the default is 312, then the error is rethrown) and start at
// D1_LOGS_FROM, or the implementation record's receipt block, or head - 500,000.
// Both inputs are validated (`envInt`).
type LogRef = { blockNumber: number; transactionHash: string; index: number; topics: readonly string[] };
const addressTopic = (a: string) => "0x" + a.toLowerCase().slice(2).padStart(64, "0");
// ethers v6 `Log.index` is the block-wide log index, so (block, index) orders logs.
const before = (a: LogRef, b: LogRef) => a.blockNumber < b.blockNumber || (a.blockNumber === b.blockNumber && a.index < b.index);
const tokenIds = (logs: LogRef[]) => logs.map((l) => BigInt(l.topics[1]).toString()).join(", ");
function logsFromBlock(rec: { receipt?: { blockNumber?: number | string } } | null, head: number): number {
    const env = envInt("D1_LOGS_FROM", 0);
    if (env !== undefined) return env;
    const n = Number(rec?.receipt?.blockNumber ?? Math.max(0, head - 500_000));
    if (!Number.isSafeInteger(n) || n < 0) {
        throw new Error(`Implementation record receipt block ${rec?.receipt?.blockNumber} is not a block number; set D1_LOGS_FROM.`);
    }
    return n;
}
async function getLogsChunked(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    filter: { address: string; topics: (string | null)[] },
    from: number,
    to: number
): Promise<LogRef[]> {
    const p = hre.ethers.provider;
    let step = envInt("D1_LOGS_STEP", 1) ?? 10_000;
    const out: LogRef[] = [];
    for (let b = from; b <= to; ) {
        const end = Math.min(b + step - 1, to);
        let logs;
        try {
            logs = await p.getLogs({ ...filter, fromBlock: b, toBlock: end });
        } catch (e) {
            if (step > 500) {
                step = Math.floor(step / 2);
                continue;
            }
            throw e;
        }
        out.push(...logs);
        b = end + 1;
    }
    return out;
}
// Where the `AutoRelockEnabled` audit starts: the lower of D1_LOGS_FROM and the
// chain's AUTO_RELOCK_AUDIT_FLOOR, whichever are set (the floor only when at or
// below `upTo`), else genesis. So D1_LOGS_FROM can move the start earlier than
// the floor, never later.
// The premise that makes an earlier start unnecessary is READ, not assumed: at
// the start block the VeHemi proxy must be on a live implementation, which
// cannot emit the event.
async function autoRelockAuditFrom(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    veHemiProxy: string,
    upTo: number
): Promise<number> {
    const env = envInt("D1_LOGS_FROM", 0);
    const pinned = AUTO_RELOCK_AUDIT_FLOOR[hre.network.config.chainId ?? 0];
    const floor = pinned !== undefined && pinned <= upTo ? pinned : undefined;
    const from = env === undefined ? floor : floor === undefined ? env : Math.min(env, floor);
    if (from === undefined) return 0;
    if (from > upTo) {
        throw new Error(`D1_LOGS_FROM (${from}) is after block ${upTo}, the end of the AutoRelockEnabled audit. Set it lower.`);
    }
    const at = "0x" + (await hre.ethers.provider.getStorage(veHemiProxy, EIP1967_IMPL_SLOT, from)).slice(-40);
    if (!LIVE_VEHEMI_IMPLS.some((a) => a.toLowerCase() === at.toLowerCase())) {
        throw new Error(
            `The AutoRelockEnabled audit must start at a block where the VeHemi proxy was on a live implementation ` +
                `(${LIVE_VEHEMI_IMPLS.join(", ")}); at block ${from} it was on ${at}. Set D1_LOGS_FROM to such a block, at or ` +
                "before the first upgrade of the VeHemi proxy to any auto-relock build."
        );
    }
    return from;
}

// Pre-flight 5b's audits of the VeHemi proxy's history, exported for
// `deploy/99_safe-txs.ts`: a restored batch reaches the proposer without this
// script's pre-flights. Which audit applies depends on where the VVD proxy is
// (`vvdImplNow`, read by the caller):
//   * On a boundary-dating implementation, with a window word from an earlier
//     armed forward: the proxies were rolled back, and re-forwarding is safe
//     only if nothing was armed since the first forward (rollback limits,
//     docs/AUTO_RELOCK_UPGRADE.md).
//   * On a boundary-dating implementation, with a virgin window word and VeHemi
//     on the live implementation: a first forward, or a VeHemi-only forward
//     that was rolled back. The live implementation never emits
//     AutoRelockEnabled, so any such log means an auto-relock build ran on the
//     VeHemi proxy and armed positions.
//   * On this build's recorded implementation (`vvdBuildImpl`), with VeHemi on
//     the live implementation: the VVD-first recovery state ONLY if VeHemi was
//     never on this build. If it was, VeHemi alone was rolled back, and
//     re-forwarding VeHemi alone is not a repair (the live VeHemi dropped
//     updates and may have written decaying points over armed positions).
// Anywhere else it audits nothing. Pre-flight 5b checks the window word's shape
// and the VVD record itself; this only audits. `refusing` ends the refusal
// message. A refusal is a `GateRefusal`; a provider error propagates as itself.
export async function assertNothingArmedBeforeForward(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    a: { veHemiProxy: string; vvdProxy: string; vvdImplNow: string; vvdBuildImpl?: string },
    refusing: string
): Promise<void> {
    const eq = (x: string, y: string) => x.toLowerCase() === y.toLowerCase();
    const p = hre.ethers.provider;
    const isLiveVeHemi = (x: string) => LIVE_VEHEMI_IMPLS.some((l) => eq(l, x));
    if (BOUNDARY_DATING_VVD_IMPLS.some((x) => eq(x, a.vvdImplNow))) {
        const w = BigInt(await p.getStorage(a.vvdProxy, VVD_WINDOW_SLOT));
        if (w !== 0n) {
            const head = await p.getBlockNumber();
            const from = await autoRelockAuditFrom(hre, a.veHemiProxy, head);
            const armed = await getLogsChunked(hre, { address: a.veHemiProxy, topics: [AUTO_RELOCK_ENABLED_TOPIC] }, from, head);
            if (armed.length) {
                throw new GateRefusal(
                    `VVD slot ${VVD_WINDOW_SLOT} holds ${w}, a window word from an earlier armed forward, AND the VeHemi proxy emitted ` +
                        `AutoRelockEnabled since block ${from} (token ids ${tokenIds(armed)}): a re-forward over a rollback with armed ` +
                        `positions. Re-running this script is not a repair. ${refusing}`
                );
            }
            console.log(`Window premises:         slot 101 = ${w}: window word from an earlier armed forward (rollback), nothing armed since block ${from}; this batch's arm overwrites it`);
            return;
        }
        const veImplNow = "0x" + (await p.getStorage(a.veHemiProxy, EIP1967_IMPL_SLOT)).slice(-40);
        if (!isLiveVeHemi(veImplNow)) return;
        const head = await p.getBlockNumber();
        const from = await autoRelockAuditFrom(hre, a.veHemiProxy, head);
        const armed = await getLogsChunked(hre, { address: a.veHemiProxy, topics: [AUTO_RELOCK_ENABLED_TOPIC] }, from, head);
        if (armed.length) {
            throw new GateRefusal(
                `VeHemi is on the live implementation ${veImplNow} and the VVD on ${a.vvdImplNow}, but the VeHemi proxy ` +
                    `emitted AutoRelockEnabled since block ${from} (token ids ${tokenIds(armed)}): VeHemi was upgraded ` +
                    `alone and rolled back over armed positions. A re-forward is not a repair. ${refusing}`
            );
        }
        console.log(`Window premises:         slot 101 = 0 and VeHemi on the live implementation, nothing armed since block ${from}`);
        return;
    }
    if (a.vvdBuildImpl === undefined || !eq(a.vvdImplNow, a.vvdBuildImpl)) return;
    const veImplNow = "0x" + (await p.getStorage(a.veHemiProxy, EIP1967_IMPL_SLOT)).slice(-40);
    if (!isLiveVeHemi(veImplNow)) return;
    const head = await p.getBlockNumber();
    const from = await autoRelockAuditFrom(hre, a.veHemiProxy, head);
    const wasOff = (await getLogsChunked(hre, { address: a.veHemiProxy, topics: [UPGRADED_TOPIC] }, from, head)).filter(
        (l) => !LIVE_VEHEMI_IMPLS.some((x) => addressTopic(x) === l.topics[1].toLowerCase())
    );
    if (wasOff.length) {
        throw new GateRefusal(
            `The VeHemi proxy was upgraded to ${"0x" + wasOff[0].topics[1].slice(-40)} (tx ${wasOff[0].transactionHash}) ` +
                `and is back on the live implementation ${veImplNow} while the VVD is on this build: a VeHemi-leg ` +
                `rollback. Re-forwarding VeHemi alone is not a repair. ${refusing}`
        );
    }
    const armed = await getLogsChunked(hre, { address: a.veHemiProxy, topics: [AUTO_RELOCK_ENABLED_TOPIC] }, from, head);
    if (armed.length) {
        throw new GateRefusal(
            `The VVD is on this build, VeHemi is on the live implementation, and the VeHemi proxy emitted AutoRelockEnabled ` +
                `since block ${from} (token ids ${tokenIds(armed)}). Re-forwarding VeHemi alone is not a repair. ` +
                refusing
        );
    }
}

// hardhat-deploy rewrites a proxy's record only from a `deploy()` that executes
// the upgrade itself (its `oldDeployment.implementation !== implementation.address`
// branch); a Safe-executed upgrade never reaches it. After a passing post-check
// this mirrors that branch: the implementation, the merged proxy + implementation
// ABI, and the upgrade's execute method. Returns whether it wrote.
async function refreshProxyRecord(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    name: string,
    updateMethod?: string
): Promise<boolean> {
    const { deployments } = hre;
    const proxyRec = await deployments.get(name);
    const implRec = await deployments.get(`${name}_Implementation`);
    if ((proxyRec.implementation ?? "").toLowerCase() === implRec.address.toLowerCase()) return false;
    const proxyArtifact = await deployments.get(`${name}_Proxy`);
    const ctor = proxyArtifact.abi.find((v: { type: string }) => v.type === "constructor");
    const abi = mergeABIs([proxyArtifact.abi, implRec.abi], { check: true, skipSupportsInterface: true }).filter(
        (v: { type: string }) => v.type !== "constructor"
    );
    if (ctor) abi.push(ctor);
    await deployments.save(name, {
        ...proxyRec,
        implementation: implRec.address,
        abi,
        execute: updateMethod ? { methodName: updateMethod, args: [] } : undefined,
        ...(proxyRec.history ? { history: [...proxyRec.history, proxyRec] } : {}),
    });
    return true;
}

// Exported for `deploy/99_safe-txs.ts`, which re-runs it against the chain at
// proposal time. Every refusal is a `GateRefusal`.
export async function assertBatchOrder(
    hre: import("hardhat/types").HardhatRuntimeEnvironment,
    expected: {
        proxyAdmin: string;
        veHemiProxy: string;
        veHemiImpl: string;
        vvdProxy: string;
        vvdImpl: string;
    }
) {
    if (!fs.existsSync(MULTI_SIG_TXS_FILE)) {
        await assertNothingToDoIsTrue(hre, expected, "no Safe batch file was produced by this run");
        console.log(
            "\n=== Safe batch ===\nNothing queued — both proxies already point at these implementations.\n" +
                "  (VERIFIED against the EIP-1967 implementation slot of both proxies, not assumed.)"
        );
        return;
    }
    const batch = JSON.parse(fs.readFileSync(MULTI_SIG_TXS_FILE).toString()) as {
        to: string;
        data: string;
        value: string;
    }[];

    const iface = new Interface(PROXY_ADMIN_ABI);
    const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
    // Both from-implementations are read ONCE, here, outside any try: a provider
    // error propagates as itself instead of being read as a missing leg, and every
    // check below sees the same chain state.
    const slotOf = async (proxy: string) => "0x" + (await hre.ethers.provider.getStorage(proxy, EIP1967_IMPL_SLOT)).slice(-40);
    const veFrom = await slotOf(expected.veHemiProxy);
    const vvdFrom = await slotOf(expected.vvdProxy);
    const legValue = (i: number) => {
        try {
            return BigInt(batch[i].value ?? "0");
        } catch {
            throw new GateRefusal(`Safe batch leg [${i}] carries an unparseable value ${JSON.stringify(batch[i].value)}. REFUSING.`);
        }
    };

    let veHemiIdx = -1;
    let vvdIdx = -1;
    const rows: string[] = [];

    for (let i = 0; i < batch.length; i++) {
        let label = "(not a ProxyAdmin.upgrade)";
        if (typeof batch[i]?.to !== "string" || typeof batch[i]?.data !== "string") {
            throw new GateRefusal(`Safe batch leg [${i}] is malformed (no string to/data). REFUSING.`);
        }
        // Only the decode is guarded; the checks below throw straight out.
        let d = null;
        try {
            d = iface.parseTransaction({ data: batch[i].data });
        } catch {
            /* not decodable: counted as unaccounted below */
        }
        if (d && (d.name === "upgrade" || d.name === "upgradeAndCall") && eq(batch[i].to, expected.proxyAdmin)) {
            const proxy = d.args[0] as string;
            const impl = d.args[1] as string;
            if (eq(proxy, expected.veHemiProxy)) {
                if (!eq(impl, expected.veHemiImpl)) {
                    throw new GateRefusal(
                        `Safe batch upgrades VeHemi to ${impl}, but this build's implementation is ${expected.veHemiImpl}`
                    );
                }
                if (d.name !== "upgrade" || legValue(i) !== 0n) {
                    throw new GateRefusal(
                        `Safe batch upgrades VeHemi with ${d.name}/value ${batch[i].value}; the VeHemi leg must be a plain upgrade() with value 0.`
                    );
                }
                // Only over the live VeHemi. A VeHemi already off it is a split
                // forward (or a run after the forward), and re-upgrading it in the
                // arming transaction would hide the gap from the post-check.
                if (!LIVE_VEHEMI_IMPLS.some((a) => eq(a, veFrom))) {
                    throw new GateRefusal(
                        `Safe batch upgrades VeHemi from ${veFrom}, which is not the live implementation ` +
                            `(${LIVE_VEHEMI_IMPLS.join(", ")}): VeHemi is already off it (a split forward, or a run after the ` +
                            "forward). Audit AutoRelockEnabled from the VeHemi proxy since it left the live implementation " +
                            "(SPLIT FORWARD); see docs/AUTO_RELOCK_UPGRADE.md, section 9. If this run redeployed VeHemi, " +
                            "first restore deployments/<net>/VeHemi_Implementation.json from the commit made right after the " +
                            "proposing run. REFUSING."
                    );
                }
                veHemiIdx = i;
                label = "upgrade(VeHemi proxy → new impl)              ← MUST BE FIRST";
            } else if (eq(proxy, expected.vvdProxy)) {
                if (!eq(impl, expected.vvdImpl)) {
                    throw new GateRefusal(
                        `Safe batch upgrades VVD to ${impl}, but this build's implementation is ${expected.vvdImpl}`
                    );
                }
                // Bind the shape, the payload and the value.
                // The forward VVD leg arms the upgrade-hour window with
                // exactly the four-byte selector, carries no value, and
                // runs only over a boundary-dating implementation.
                if (d.name !== "upgradeAndCall") {
                    throw new GateRefusal(
                        "Safe batch upgrades VVD with a plain upgrade(): the upgrade-hour window would not be armed. " +
                            "The VVD leg must be upgradeAndCall(VVD, impl, armLegacyDatingWindow())."
                    );
                }
                const initData = (d.args[2] as string).toLowerCase();
                if (initData !== VVD_ARM_DATA.toLowerCase()) {
                    throw new GateRefusal(
                        `Safe batch upgrades VVD with data=${initData}; expected exactly ${VVD_ARM_DATA} (armLegacyDatingWindow()).`
                    );
                }
                if (legValue(i) !== 0n) {
                    throw new GateRefusal(
                        `Safe batch upgrades VVD with value=${batch[i].value}; the arm is non-payable and the leg must carry 0.`
                    );
                }
                const fromImpl = vvdFrom;
                if (!BOUNDARY_DATING_VVD_IMPLS.some((a) => eq(a, fromImpl))) {
                    throw new GateRefusal(
                        `Safe batch upgrades VVD from ${fromImpl}, which is not a boundary-dating implementation; ` +
                            `this script arms the upgrade-hour window and runs only over ${BOUNDARY_DATING_VVD_IMPLS.join(", ")}.`
                    );
                }
                vvdIdx = i;
                label = "upgradeAndCall(VoteDelegation proxy → new impl, armLegacyDatingWindow())  ← MUST BE SECOND";
            } else {
                label = `upgrade(${proxy} → ${impl})  ** UNEXPECTED PROXY **`;
            }
        }
        rows.push(`  [${i}] to=${batch[i].to}  ${label}`);
    }

    if (veHemiIdx === -1 && vvdIdx === -1) {
        await assertNothingToDoIsTrue(hre, expected, "the Safe batch contains no ProxyAdmin.upgrade call");
        console.log(
            "\n=== Safe batch ===\nNo upgrade calls queued — both proxies are already current.\n" +
                "  (VERIFIED against the EIP-1967 implementation slot of both proxies, not assumed.)"
        );
        return;
    }
    if (vvdIdx !== -1 && veHemiIdx === -1) {
        // If VeHemi is ALREADY on this build the reason below is false: nothing
        // would brick. This is a split forward, and the gap needs an audit, from a
        // block where VeHemi was still live (`autoRelockAuditFrom`).
        if (eq(veFrom, expected.veHemiImpl)) {
            const head = await hre.ethers.provider.getBlockNumber();
            const ups = await getLogsChunked(
                hre,
                { address: expected.veHemiProxy, topics: [UPGRADED_TOPIC, addressTopic(expected.veHemiImpl)] },
                logsFromBlock(await hre.deployments.getOrNull("VeHemi_Implementation"), head),
                head
            );
            const since = ups.length ? ups[ups.length - 1].blockNumber : undefined;
            const auditFrom = await autoRelockAuditFrom(hre, expected.veHemiProxy, head);
            const armed = await getLogsChunked(hre, { address: expected.veHemiProxy, topics: [AUTO_RELOCK_ENABLED_TOPIC] }, auditFrom, head);
            throw new GateRefusal(
                "\n" + "=".repeat(78) + "\n" +
                "SPLIT FORWARD: THE VeHemi PROXY IS ALREADY ON THIS BUILD; ONLY THE VVD LEG IS QUEUED.\n" +
                "=".repeat(78) + "\n" +
                `  VeHemi proxy ${expected.veHemiProxy} is on ${veFrom} (this build), upgraded at block ${since ?? "<not found>"}.\n` +
                `  AutoRelockEnabled from the VeHemi proxy since block ${auditFrom}: ${armed.length === 0 ? "none" : tokenIds(armed)}\n\n` +
                "  New VeHemi over the live VVD: the window probe fails OPEN, so any holder can arm. The\n" +
                "  live VVD books such a record as decaying weight while its shape is flat; once the VVD\n" +
                "  leg lands, every move of it either reverts or takes its weight out of the delegatee's\n" +
                "  other flat terms. An id disarmed by its owner BEFORE the VVD leg lands is clean.\n" +
                "  Arming stays open until the leg lands, so do not delay it. This script and\n" +
                "  deploy/99 will not propose a one-leg VVD batch (a plain re-run queues nothing;\n" +
                "  deleting the VVD record again deploys ANOTHER implementation and overwrites the\n" +
                "  record the hand-built leg must name: do not; commit\n" +
                "  deployments/<net>/VeHemiVoteDelegation_Implementation.json now). Whatever the\n" +
                `  audit above lists, the completion is ONE upgradeAndCall(${expected.vvdProxy}, ${expected.vvdImpl}, 0x62c0fe7a)\n` +
                "  leg, value 0, built and reviewed by hand and proposed through the Safe UI, with NO\n" +
                "  VeHemi leg; arming stays open until it lands, so run D1_POST_CHECK_ONLY=1 afterwards\n" +
                "  (it re-audits up to the arm). Any id listed that is still armed when the leg lands\n" +
                "  is an incident. REFUSING.\n" +
                "=".repeat(78) + "\n"
            );
        }
        throw new GateRefusal(
            "SAFE BATCH CONTAINS THE VoteDelegation UPGRADE WITHOUT THE VeHemi UPGRADE.\n" +
                "  New VeHemiVoteDelegation calls veHemi.autoRelockRemaining(uint256) (0xf63dc138) at\n" +
                "  importDelegationsFromLegacy, delegateAllFor, retireStrandedFlatTerm and\n" +
                "  _getNormalizedLockedInfo (reached from _delegate; retireStrandedFlatTerm is permissionless) —\n" +
                "  and NONE of the four is inside a `try`. That selector does not exist on the live\n" +
                "  VeHemi implementation, so under this batch every direct delegation write would revert\n" +
                "  and every VeHemi-driven update would be dropped (DelegationUpdateFailed). REFUSING.\n" +
                "  Recovery: while BOTH proxies are still live, delete BOTH\n" +
                "  deployments/<net>/*_Implementation.json records and re-run\n" +
                "  `npx hardhat --network <net> deploy --tags AutoRelockUpgrade`."
        );
    }
    // Half a batch: the VeHemi leg without the VVD leg. hardhat-deploy queues an
    // upgrade only for a newly deployed implementation, so a surviving VVD
    // implementation record that matches this build drops the VVD leg silently.
    // This direction does not brick (the new VeHemi reaches the VVD only through
    // four try/catch sites), but the window probe fails open against the live
    // VVD, so holders can arm records that the live VVD books as decaying weight
    // while their shape is flat. Once the VVD leg lands every move of such a
    // record either reverts or takes its weight out of the delegatee's other
    // flat terms, the last of which can then never be removed; and the upgrade
    // is incomplete. A one-leg VeHemi batch passes only when the VVD proxy is
    // already on this build (read on chain).
    if (veHemiIdx !== -1 && vvdIdx === -1) {
        // "The VVD is already on this build" is checked against the record, and
        // before step 4 runs the record still names the live, boundary-dating
        // implementation: that is the half-batch, not a done VVD leg.
        const vvdLive = vvdFrom;
        if (!eq(vvdLive, expected.vvdImpl) || BOUNDARY_DATING_VVD_IMPLS.some((a) => eq(a, vvdLive))) {
            throw new GateRefusal(
                "\n" + "=".repeat(78) + "\n" +
                "HALF A BATCH: THE VeHemi UPGRADE IS QUEUED AND THE VoteDelegation ONE IS NOT.\n" +
                "=".repeat(78) + "\n" +
                `  VoteDelegation proxy ${expected.vvdProxy}\n` +
                `      implementation on chain     : ${vvdLive}\n` +
                `      this build's implementation : ${expected.vvdImpl}\n\n` +
                "  hardhat-deploy queues an upgrade only for a NEWLY deployed implementation,\n" +
                "  so a surviving deployments/<net>/VeHemiVoteDelegation_Implementation.json\n" +
                "  record silently drops the second half of this upgrade (or this file was\n" +
                "  saved before step 4 ran, and the VVD record still names the live\n" +
                "  implementation). Proposing this batch\n" +
                "  would leave the pair split: not bricked, but auto-relock arming is open\n" +
                "  against the live VVD (the window probe fails open). The live VVD books a\n" +
                "  record armed in the gap as decaying weight while its shape is flat; once the\n" +
                "  VVD leg lands every move of it either reverts or takes its weight out of the\n" +
                "  delegatee's other flat terms, the last of which can then never be removed.\n" +
                "  The upgrade would also be INCOMPLETE, while the transcript would say it\n" +
                "  succeeded. REFUSING.\n\n" +
                "  While BOTH proxies are still on their live implementations, delete BOTH\n" +
                "  implementation records (this run has just written a VeHemi one) and re-run,\n" +
                "  so both are deployed and both upgrades are queued into ONE MultiSend:\n" +
                "      rm deployments/<net>/VeHemi_Implementation.json \\\n" +
                "         deployments/<net>/VeHemiVoteDelegation_Implementation.json\n" +
                "      npx hardhat --network <net> deploy --tags AutoRelockUpgrade\n" +
                "=".repeat(78) + "\n"
            );
        }
    }

    if (veHemiIdx !== -1 && vvdIdx !== -1 && veHemiIdx > vvdIdx) {
        throw new GateRefusal(
            `SAFE BATCH ORDER IS REVERSED (VeHemi at index ${veHemiIdx}, VoteDelegation at index ${vvdIdx}).\n` +
                "  VeHemi MUST land first. The new VVD hard-calls veHemi.autoRelockRemaining from _delegate;\n" +
                "  the new VeHemi reaches the VVD only through four `try … catch` sites\n" +
                "  (_reDelegate, _requireFlatTermRetired, _resolveAutoDelegate, _delegate), so a VeHemi-first gap does not\n" +
                "  brick (though the window probe fails open in it) and a VVD-first gap does. REFUSING to propose."
        );
    }

    // Length. Everything above locates the two legs and checks their targets,
    // payloads and order; a third leg (any `to`, calldata or value) would only be
    // labelled in a console row. So every leg in the file must be one this
    // function accounted for. Not a bare `batch.length !== 2`: a one-leg VeHemi
    // batch is admitted above when the VVD is verified current on chain.
    const accountedLegs = (veHemiIdx !== -1 ? 1 : 0) + (vvdIdx !== -1 ? 1 : 0);
    if (batch.length !== accountedLegs) {
        const unaccounted = rows.filter((_, i) => i !== veHemiIdx && i !== vvdIdx);
        throw new GateRefusal(
            "\n" + "=".repeat(78) + "\n" +
            "SAFE BATCH CONTAINS LEGS THIS GATE DID NOT ACCOUNT FOR.\n" +
            "=".repeat(78) + "\n" +
            `  legs in ${MULTI_SIG_TXS_FILE} : ${batch.length}\n` +
            `  legs asserted by this gate    : ${accountedLegs}` +
            (veHemiIdx !== -1 ? ` (VeHemi upgrade at index ${veHemiIdx})` : "") +
            (vvdIdx !== -1 ? ` (VoteDelegation upgrade at index ${vvdIdx})` : "") + "\n\n" +
            "  UNACCOUNTED LEGS:\n" +
            unaccounted.map((r) => "  " + r).join("\n") + "\n\n" +
            "  A MultiSend is atomic and is signed as ONE transaction. An extra inner call\n" +
            "  executes with the Safe's full authority alongside the upgrades.\n" +
            "  REFUSING to propose. Inspect the file and re-run.\n" +
            "=".repeat(78) + "\n"
        );
    }

    console.log("\n=== Safe batch (ONE MultiSend; inner calls execute in array order) ===");
    let total = 0n;
    for (let i = 0; i < batch.length; i++) {
        let gas = 0n;
        try {
            gas = await hre.ethers.provider.estimateGas({
                from: Addresses.Hemi.GNOSIS_SAFE,
                to: batch[i].to,
                data: batch[i].data,
            });
        } catch {
            /* informational only: estimation can fail on an unfunded fork account */
        }
        total += gas;
        console.log(`${rows[i]}  gas≈${gas.toString()}`);
    }
    console.log(`  inner-call gas total ≈ ${total.toString()}`);
    console.log(
        "  + Safe overhead ≈ 21,000 base + ~9,000 for 3 ECDSA checks + MultiSend calldata.\n" +
            "  Hemi block gas limit 30,000,000 — this batch is ONE Safe transaction.\n" +
            (vvdIdx === -1
                ? "  ORDER: only the VeHemi upgrade is in this batch (VoteDelegation not queued);\n" +
                  "  the VoteDelegation proxy was VERIFIED to be on this build's implementation already.\n"
                : "  ORDER ASSERTED: VeHemi index " +
                  veHemiIdx +
                  " < VoteDelegation index " +
                  vvdIdx +
                  "\n")
    );
}

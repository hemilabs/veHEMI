import fs from "fs";
import { DeployFunction } from "hardhat-deploy/types";
import { MULTI_SIG_TXS_FILE, saveForSafeBatchExecution } from "../helpers/safe";

const ADAPTER = "VeHemiAragonAdapter";
const VOTE_DELEGATION = "VeHemiVoteDelegation";
const VE_HEMI = "VeHemi";

// ERC-165 interface IDs verified against the adapter's supportsInterface().
const IFACE_ID_IVOTES = "0xe90fb3f6";
const IFACE_ID_ERC165 = "0x01ffc9a7";
const IFACE_ID_ERC6372 = "0xda287a1d";

// ── Deployment documentation ───────────────────────────────────────────────
// This script deploys the VeHemiAragonAdapter and configures it as the
// trusted adapter on VeHemiVoteDelegation. Two steps:
//
//   1. Deploy VeHemiAragonAdapter (immutable, not a proxy).
//      Constructor takes the VeHemi proxy address. The adapter reads
//      voteDelegation dynamically from VeHemi, so it automatically
//      picks up any future delegation contract upgrades.
//
//   2. Call setTrustedAdapter(adapterAddress) on VeHemiVoteDelegation.
//      This is an owner-only call (VeHemi's owner = Gnosis Safe).
//      Without this, adapter.delegate() cannot call delegateAllFor().
//
// Prerequisites:
//   - VeHemi proxy is deployed and upgraded to V2 (script 04)
//   - VeHemiVoteDelegation proxy is deployed and upgraded to the
//     Aragon-compatible implementation with autoDelegate, delegateAllFor,
//     hourly checkpoints, and setTrustedAdapter (script 04)
//   - markSeedingStarted + seedBatch(...) + finalizeSeeding have run (script 04)
//
// ── Adapter-bootstrap window ──────────────────────────────────────────────
// Splitting scripts 04 and 05 into two separate Safe proposals creates a
// window where the new VVD is live but `trustedAdapter` is still
// `address(0)`. During the window:
//   - every `_delegate` notify hook is silently skipped
//   - Aragon's subgraph sees ZERO DelegateChanged/DelegateVotesChanged events
//     from the adapter address (on-chain state still mutates)
//   - `delegateAllFor` reverts with `NotTrustedAdapter`, bricking
//     `adapter.delegate(X)` entirely
// The window can stretch days/weeks if the Safe quorum is slow.
//
// FIX: scripts 04 and 05 both queue Safe transactions via
// `saveForSafeBatchExecution`, which appends to a SHARED batch file
// (`multisig.batch.tmp.json`). Script 99 (`runAtTheEnd: true`) then proposes
// the accumulated batch as a SINGLE Safe MultiSend. As long as both scripts
// run in the SAME `hardhat deploy` invocation, the bundling is automatic.
//
// OPERATOR MANDATE: run `npx hardhat --network hemi deploy` (no `--tags`
// filter) so the entire 00→07→99 sequence executes in one invocation. The
// pre-flight check below catches a missed-bundling attempt: if VVD is still
// V1 on-chain AND the Safe batch file is empty when 05 starts, we abort
// rather than create a standalone adapter-registration proposal.

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, execute, read } = deployments;
    const { deployer } = await getNamedAccounts();

    // Only run on Hemi mainnet or localhost
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // ── Pre-flight checks ──────────────────────────────────────────────────
    console.log("=== Pre-flight checks ===");

    const { address: veHemiAddress } = await get(VE_HEMI);
    console.log("VeHemi proxy:           ", veHemiAddress);

    // 1. VeHemi must reference a non-zero VoteDelegation. The adapter reads
    //    this dynamically at every call, so a zero address would brick the
    //    Aragon UX without any easy recovery path.
    const currentVoteDelegation = (await read(VE_HEMI, "voteDelegation")) as string;
    if (currentVoteDelegation === "0x0000000000000000000000000000000000000000") {
        throw new Error("VeHemi.voteDelegation() is the zero address — run script 01 first.");
    }
    console.log("VeHemi.voteDelegation:   OK (", currentVoteDelegation, ")");

    // 2. VeHemi must already hold real positions. Deploying the adapter on
    //    a fresh proxy would expose a totalSupply() of zero to Aragon, which
    //    would render the DAO unusable.
    const totalSupply = (await read(VE_HEMI, "totalVeHemiSupply")) as bigint;
    if (totalSupply === 0n) {
        throw new Error("VeHemi.totalVeHemiSupply() is zero — wrong network or fresh proxy?");
    }
    console.log("VeHemi.totalSupply:      ", totalSupply.toString());

    // 3. Bundling enforcement: ensure script 05 runs with script 04. If VVD
    //    is still V1 on-chain, the V2 upgrade transaction (queued by script
    //    04) MUST already be in the Safe batch file from this same
    //    `hardhat deploy` invocation. Otherwise we would produce a
    //    standalone `setTrustedAdapter` proposal that opens the
    //    adapter-bootstrap window described in the header.
    //
    //    Probe: call `trustedAdapter()` against the live VVD. If it reverts,
    //    VVD is still V1 (selector doesn't exist). If it returns, VVD is V2
    //    and 05 is safe to run standalone (just a one-shot setter).
    let vvdIsV2 = true;
    try {
        await read(VOTE_DELEGATION, "trustedAdapter");
    } catch {
        vvdIsV2 = false;
    }

    if (!vvdIsV2) {
        // VVD is still V1. The V2 upgrade must be queued in this same batch.
        // `helpers/safe.ts` auto-cleans any stale `MULTI_SIG_TXS_FILE` at
        // module-load time (the very first `import` of the helper, before
        // any deploy script body runs), so a non-empty file here means
        // script 04 (or another script earlier in this same invocation) just
        // queued real txs.
        const batchHasContent =
            fs.existsSync(MULTI_SIG_TXS_FILE) &&
            fs.statSync(MULTI_SIG_TXS_FILE).size > 0;
        if (!batchHasContent) {
            throw new Error(
                "\n" +
                "Adapter-bootstrap window detected.\n" +
                "\n" +
                "FIX:   npx hardhat --network hemi deploy   (no `--tags` filter)\n" +
                "\n" +
                "WHY:   VeHemiVoteDelegation is still V1 on-chain AND the Safe batch\n" +
                "       file is empty. Running script 05 now would create a STANDALONE\n" +
                "       `setTrustedAdapter` Safe proposal, leaving an adapter-bootstrap\n" +
                "       window during which `trustedAdapter == address(0)` on the\n" +
                "       upgraded VVD: every `_delegate` notify hook is silently\n" +
                "       skipped (Aragon's subgraph sees zero DelegateChanged events),\n" +
                "       and `delegateAllFor` reverts with `NotTrustedAdapter`,\n" +
                "       bricking `adapter.delegate(X)` entirely.\n" +
                "\n" +
                "       Scripts 04 and 05 must run in the SAME `hardhat deploy`\n" +
                "       invocation so their Safe txs accumulate into\n" +
                "       `" + MULTI_SIG_TXS_FILE + "` and script 99 (`runAtTheEnd`)\n" +
                "       proposes them as ONE Safe MultiSend.\n" +
                "\n" +
                "FILES: deploy/04_upgrade_vehemi_v2.ts  (V2 upgrade + seeding)\n" +
                "       deploy/05_aragon_adapter.ts    (this script)\n" +
                "       deploy/99_safe-txs.ts          (MultiSend proposer)\n" +
                "       helpers/safe.ts                (batch accumulator)\n"
            );
        }
        console.log("Bundling check:          OK (VVD V1 + Safe batch populated → bundled with 04)");
    } else {
        console.log("Bundling check:          OK (VVD already V2 — 05 can run standalone safely)");
    }

    console.log("");

    // Step 1: Deploy the adapter (immutable, no proxy)
    const adapterDeployment = await deploy(ADAPTER, {
        from: deployer,
        log: true,
        args: [veHemiAddress],
    });

    console.log("VeHemiAragonAdapter deployed at:", adapterDeployment.address);

    // ── Post-deploy verification (ERC-165) ─────────────────────────────────
    // Newly-deployed adapter must announce all three interfaces. Verifying
    // here catches accidental ABI breakage from a botched recompile before
    // we ask the Safe to register it.
    const supportsIVotes = (await read(ADAPTER, "supportsInterface", IFACE_ID_IVOTES)) as boolean;
    if (!supportsIVotes) {
        throw new Error(`Adapter does not advertise IVotes (${IFACE_ID_IVOTES})`);
    }
    const supportsErc165 = (await read(ADAPTER, "supportsInterface", IFACE_ID_ERC165)) as boolean;
    if (!supportsErc165) {
        throw new Error(`Adapter does not advertise ERC165 (${IFACE_ID_ERC165})`);
    }
    const supportsErc6372 = (await read(ADAPTER, "supportsInterface", IFACE_ID_ERC6372)) as boolean;
    if (!supportsErc6372) {
        throw new Error(`Adapter does not advertise ERC6372 (${IFACE_ID_ERC6372})`);
    }
    console.log("Adapter interfaces:      OK (IVotes + ERC165 + ERC6372)");

    // Step 2: Set the adapter as trusted on VeHemiVoteDelegation.
    // This call must come from the VeHemi owner (Gnosis Safe).
    const setAdapterFunction = () =>
        execute(
            VOTE_DELEGATION,
            { from: deployer, log: true },
            "setTrustedAdapter",
            adapterDeployment.address
        );

    const multiSigTx = await catchUnknownSigner(setAdapterFunction, { log: true });

    if (multiSigTx) {
        await saveForSafeBatchExecution(multiSigTx);
    }
};

func.tags = [ADAPTER];
func.dependencies = [VE_HEMI, VOTE_DELEGATION, "VeHemiV2Upgrade"];
export default func;

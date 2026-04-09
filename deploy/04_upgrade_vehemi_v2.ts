import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";

// ── Deployment documentation ───────────────────────────────────────────────
// This script upgrades VeHemi from V1 to V2. Two transactions are batched
// for the Gnosis Safe:
//
//   1. upgradeAndCall(proxy, newImpl, "") - upgrades the proxy to the new
//      implementation with NO initializer call. The V2 locked-curve
//      functionality is gated behind `lockedSeedingFinalized` which
//      defaults to false, so the upgrade itself is a no-op — the
//      contract behaves identically to V1 until seeding occurs.
//
//   2. seedAndFinalizeLockedPositions(tokenIds) - seeds all 126
//      active non-transferable positions and enables locked-curve tracking.
//
// Both transactions are saved to the Safe batch file so they execute in a
// single multisig proposal. The seeding is atomic: no multi-step window,
// no deadline management, no risk of partial state.
//
// IMPORTANT: The tokenIds array MUST include ALL active non-transferable
// positions. Omitted positions would permanently understate the locked
// supply. Verify the calldata against on-chain state before execution.

// 126 active non-transferable token IDs as of block ~2026-04-08.
// Sourced from on-chain query: transferableAfter != 0, lock.end > block.timestamp, amount > 0.
// Sorted ascending. Range 28660-28805 (6 of the original 132 have expired).
// IMPORTANT: Re-verify against on-chain state before governance execution.
// prettier-ignore
const LOCKED_TOKEN_IDS: number[] = [
    28660, 28661, 28662, 28663, 28664, 28665, 28666, 28667, 28668, 28669,
    28670, 28671, 28672, 28673, 28674, 28675, 28676, 28677, 28678, 28679,
    28680, 28681, 28682, 28683, 28684, 28685, 28686, 28687, 28688, 28689,
    28690, 28691, 28692, 28693, 28694, 28695, 28696, 28697, 28698, 28699,
    28700, 28705, 28706, 28707, 28708, 28709, 28710, 28711, 28712, 28713,
    28714, 28715, 28716, 28717, 28718, 28719, 28720, 28721, 28726, 28727,
    28728, 28729, 28730, 28731, 28732, 28733, 28734, 28735, 28736, 28737,
    28738, 28739, 28740, 28741, 28742, 28743, 28744, 28745, 28746, 28747,
    28748, 28749, 28750, 28751, 28752, 28753, 28754, 28755, 28756, 28757,
    28758, 28759, 28760, 28761, 28762, 28763, 28764, 28765, 28766, 28771,
    28772, 28773, 28774, 28775, 28776, 28777, 28778, 28779, 28780, 28781,
    28782, 28783, 28784, 28785, 28786, 28787, 28792, 28793, 28794, 28795,
    28796, 28801, 28802, 28803, 28804, 28805,
];

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, execute } = deployments;
    const { deployer } = await getNamedAccounts();

    // Only run on Hemi mainnet or localhost
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // Step 1: Deploy the new VeHemi V2 implementation and upgrade the proxy.
    // No initializer call — V2 locked-curve is dormant until seeding.
    const deployFunction = () =>
        deploy(VE_HEMI, {
            from: deployer,
            log: true,
            args: [Addresses.Hemi.HEMI_TOKEN],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
            }
        });

    const multiSigUpgradeTx = await catchUnknownSigner(deployFunction, { log: true });

    if (multiSigUpgradeTx) {
        await saveForSafeBatchExecution(multiSigUpgradeTx);
    }

    // Step 2: Seed and finalize all non-transferable positions.
    // This activates locked-curve tracking.
    const seedFunction = () =>
        execute(VE_HEMI, { from: deployer, log: true }, "seedAndFinalizeLockedPositions", LOCKED_TOKEN_IDS);

    const multiSigSeedTx = await catchUnknownSigner(seedFunction, { log: true });

    if (multiSigSeedTx) {
        await saveForSafeBatchExecution(multiSigSeedTx);
    }
};

func.tags = ["VeHemiV2Upgrade"];
func.dependencies = [VE_HEMI];
export default func;

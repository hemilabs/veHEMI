import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const ADAPTER = "VeHemiAragonAdapter";
const VOTE_DELEGATION = "VeHemiVoteDelegation";
const VE_HEMI = "VeHemi";

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
//   - VeHemiVoteDelegation proxy is deployed with Aragon-compatible
//     implementation (autoDelegate, delegateAllFor, 1-hour epochs)
//   - seedAndFinalizeLockedPositions has been called (script 04)

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, execute } = deployments;
    const { deployer } = await getNamedAccounts();

    // Only run on Hemi mainnet or localhost
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    const { address: veHemiAddress } = await get(VE_HEMI);
    console.log("VeHemi proxy:", veHemiAddress);

    // Step 1: Deploy the adapter (immutable, no proxy)
    const adapterDeployment = await deploy(ADAPTER, {
        from: deployer,
        log: true,
        args: [veHemiAddress],
    });

    console.log("VeHemiAragonAdapter deployed at:", adapterDeployment.address);

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
func.dependencies = [VE_HEMI, VOTE_DELEGATION];
export default func;

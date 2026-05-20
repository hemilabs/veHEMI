import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";
const RESTAKE_MANAGER = "RestakeManager";
const DELEGATION_MANAGER = "DelegationManager";
const RESTAKE_MANAGER_V2_LIB = "RestakeManagerV2LibImpl";

// ── Deployment atomicity ─────────────────────────────────────────────────
// This script upgrades RestakeManager from V1 to V2 (delegation support).
//
// Two operations are batched for the Gnosis Safe:
//
//   1. Deploy RestakeManagerV2LibImpl (the DELEGATECALL library for V2 features).
//   2. Deploy new RestakeManager V2 implementation (with v2Lib immutable).
//   3. Upgrade RM proxy to the new V2 implementation via upgradeAndCall.
//
// The V2 implementation adds:
//   - DelegationManager lifecycle (propose/accept/cancel)
//   - DM-only agent functions (restakeFor, slashForDelegation, etc.)
//   - Delegation-aware guards on canWithdraw/canTransfer
//   - BPS exclusion + budget checks
//   - Pool NFT tracking
//
// The upgrade is safe even without the DM linked: all V2 delegation functions
// revert with NotDelegationManager() when delegationManager == address(0),
// and existing V1 functions continue to work unchanged.
//
// After this upgrade, 06_delegation_manager.ts can deploy the DM and call
// RM.proposeDelegationManager() to begin the 2-day linking timelock.
//
// Dependency: Requires VeHemi and RestakeManager to be deployed (VeHemi address
// is a constructor immutable). 06_delegation_manager.ts runs AFTER this script
// and handles the proposeDelegationManager step.

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, read } = deployments;
    const { deployer } = await getNamedAccounts();

    // Revert if not on chain ID 43111 (Hemi) or 31337 (Localhost)
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    const { address: veHemiAddress } = await get(VE_HEMI);
    console.log("veHemiAddress:", veHemiAddress);

    // ── Pre-flight: verify RM's veHemi() immutable matches the value the new
    //    impl's constructor will receive. The RM V2 impl re-reads its veHemi
    //    immutable from the constructor arg; a mismatch here would silently
    //    break every V1 call that depends on `veHemi.ownerOf(...)` etc.
    const rmDeployment = await get(RESTAKE_MANAGER).catch(() => null);
    if (rmDeployment) {
        const currentRmVeHemi = (await read(RESTAKE_MANAGER, "veHemi")) as string;
        if (currentRmVeHemi.toLowerCase() !== veHemiAddress.toLowerCase()) {
            throw new Error(
                `RestakeManager.veHemi() mismatch: expected ${veHemiAddress}, got ${currentRmVeHemi}`
            );
        }
        console.log("RestakeManager.veHemi:   OK (matches VeHemi proxy)");
    }

    // ── Step 1: Deploy RestakeManagerV2LibImpl ───────────────────────────
    // This is the concrete deployable contract that wraps RestakeManagerV2Lib.
    // Constructor: constructor(address veHemi_)
    // The RM stores this as an immutable and calls V2 functions via DELEGATECALL.
    console.log("\n--- Step 1: Deploy RestakeManagerV2LibImpl ---");

    const v2LibResult = await deploy(RESTAKE_MANAGER_V2_LIB, {
        from: deployer,
        log: true,
        contract: RESTAKE_MANAGER_V2_LIB,
        args: [veHemiAddress]
    });
    console.log("RestakeManagerV2LibImpl:", v2LibResult.address);

    // ── Step 2: Deploy new RM V2 implementation and upgrade proxy ────────
    // Constructor: constructor(address veHemi_, address v2Lib_)
    // The proxy upgrade is handled atomically by hardhat-deploy.
    // No onUpgrade initializer is needed — V2 storage slots are zero-initialized
    // and the DM lifecycle starts from proposeDelegationManager().
    console.log("\n--- Step 2: Upgrade RestakeManager to V2 ---");

    const upgradeFunction = () =>
        deploy(RESTAKE_MANAGER, {
            from: deployer,
            log: true,
            args: [veHemiAddress, v2LibResult.address],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy"
            }
        });

    const multiSigUpgradeTx = await catchUnknownSigner(upgradeFunction, { log: true });
    if (multiSigUpgradeTx) {
        await saveForSafeBatchExecution(multiSigUpgradeTx);
    }

    const { address: rmAddress } = await get(RESTAKE_MANAGER);
    console.log("RestakeManager proxy (upgraded to V2):", rmAddress);

    // ── Summary ──────────────────────────────────────────────────────────
    console.log("\n=== RestakeManager V2 Upgrade Summary ===");
    console.log("RestakeManagerV2LibImpl:", v2LibResult.address);
    console.log("RestakeManager proxy:", rmAddress);
    console.log("\nNext steps:");
    console.log("  1. Submit Safe batch (99_safe-txs.ts will propose it)");
    console.log("  2. Run 06_delegation_manager.ts to deploy the delegation system");
};

func.tags = ["RestakeManagerV2Upgrade"];
func.dependencies = [VE_HEMI, RESTAKE_MANAGER];
export default func;

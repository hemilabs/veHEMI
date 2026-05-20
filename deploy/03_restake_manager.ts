import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const RESTAKE_MANAGER = "RestakeManager";
const VE_HEMI = "VeHemi";

// ── GlobalConfig for RestakeManager.initialize() ──────────────────────────
// These values are passed as the second argument to initialize(owner_, config_).
//
// GlobalConfig struct fields:
//   globalMaxSlashBps      (uint16) - Max slash any service can request per event.
//   instantSlashCeilingBps (uint16) - Slashes at or below this execute immediately;
//                                     above this threshold they enter a challenge queue.
//   challengePeriod        (uint32) - Duration (seconds) of the challenge window for
//                                     queued slashes. Governance can veto during this time.
//   minUnstakingDelay      (uint32) - Minimum unstaking delay any service must respect.
//                                     Services can set longer but not shorter.
//   minSlashCooldown      (uint32) - Minimum time between slash events per (position,
//                                     service) pair. Services can set longer but not shorter.
//   maxServicesPerPosition (uint8)  - Max simultaneous services a single position
//                                     can restake to.
//
// Rationale for chosen values:
//   - globalMaxSlashBps = 5000 (50%): Limits worst-case per-event loss to half the position.
//   - instantSlashCeilingBps = 500 (5%): Small operational slashes execute instantly;
//     anything above 5% gets a 4-day challenge window for governance review.
//   - challengePeriod = 345600 (4 days): Gives the multisig enough time to review and
//     veto suspicious large slashes. Must be > DM's confiscationDelay (3 days) per CP > CD constraint.
//   - minUnstakingDelay = 604800 (7 days): Prevents restakers from front-running slashes.
//     Services can require longer cooldowns but never shorter than 7 days.
//   - maxServicesPerPosition = 5: Caps worst-case cumulative slash exposure.
//     With globalMaxSlashBps = 5000 (50%) and 5 independent services,
//     the theoretical maximum loss is 1 - (1 - 0.50)^5 ≈ 96.9%.
//     Gas costs in view functions are negligible at this level.
//   - minSlashCooldown = 3600 (1 hour): Prevents rapid-fire slashing by requiring at
//     least 1 hour between slash events per (position, service) pair.
const GLOBAL_CONFIG = {
    globalMaxSlashBps: 5000,       // 50%
    instantSlashCeilingBps: 500,   // 5%
    challengePeriod: 345600,       // 4 days in seconds (must be > DM confiscationDelay of 3 days)
    minUnstakingDelay: 604800,     // 7 days in seconds
    minSlashCooldown: 3600,        // 1 hour in seconds
    maxServicesPerPosition: 5
};

// ── Deployment atomicity ───────────────────────────────────────────────────
// This script and 04_upgrade_vehemi_v2.ts form a single atomic deployment batch.
// They MUST be submitted together in a single Gnosis Safe batch transaction:
//
//   1. 03_restake_manager.ts — deploys RestakeManager behind a proxy and calls
//      initialize(owner_, config_). At this point RestakeManager exists but VeHemi
//      does not yet know about it.
//
//   2. 04_upgrade_vehemi_v2.ts — upgrades VeHemi to V2 implementation and calls
//      initializeV2(restakeManagerAddress). This sets the RestakeManager on VeHemi.
//
// If step 1 executes but step 2 does not:
//   - RestakeManager exists and is initialized, but VeHemi doesn't reference it.
//   - No harm: RM has no power until VeHemi points to it.
//   - Fix: Submit step 2 in a follow-up transaction.
//
// If step 2 executes but step 1 does not:
//   - Not possible: step 2 reads RM address from deployments (get("RestakeManager")).
//
// Both steps use saveForSafeBatchExecution() which collects transactions for the
// Gnosis Safe multisig. The operator SHOULD submit them as a batch but the system
// is safe even if only step 1 executes.

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get } = deployments;
    const { deployer } = await getNamedAccounts();
    // Revert if not on chain ID 43111 (Hemi) or 31337 (Localhost)
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    const { address: veHemiAddress } = await get(VE_HEMI);
    console.log("veHemiAddress", veHemiAddress);

    // hardhat-deploy encodes struct arguments as tuples.
    // The GlobalConfig struct is encoded as a positional tuple matching the Solidity struct field order:
    //   [globalMaxSlashBps, instantSlashCeilingBps, challengePeriod, minUnstakingDelay, minSlashCooldown, maxServicesPerPosition, slashNotificationGasCap]
    const globalConfigTuple = [
        GLOBAL_CONFIG.globalMaxSlashBps,
        GLOBAL_CONFIG.instantSlashCeilingBps,
        GLOBAL_CONFIG.challengePeriod,
        GLOBAL_CONFIG.minUnstakingDelay,
        GLOBAL_CONFIG.minSlashCooldown,
        GLOBAL_CONFIG.maxServicesPerPosition,
        0 // slashNotificationGasCap: 0 triggers MIN_SLASH_NOTIFICATION_GAS (11M) fallback
    ];

    const deployFunction = () =>
        deploy(RESTAKE_MANAGER, {
            from: deployer,
            log: true,
            // constructor(address veHemi_, address v2Lib_)
            // V2Lib is address(0) for the initial V1 deployment — script 07 upgrades
            // the implementation with the real V2Lib address later.
            args: [veHemiAddress, "0x0000000000000000000000000000000000000000"],
            proxy: {
                // Hardhat-deploy will deploy these proxy-related contracts:
                // ProxyAdmin: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/ProxyAdmin.sol
                // TransparentUpgradeableProxy: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
                execute: {
                    init: {
                        methodName: "initialize",
                        // initialize(address owner_, GlobalConfig calldata config_)
                        // Owner is the Gnosis Safe multisig so governance controls the RestakeManager.
                        args: [Addresses.Hemi.GNOSIS_SAFE, globalConfigTuple]
                    }
                }
            }
        });

    const multiSigDeployTx = await catchUnknownSigner(deployFunction, { log: true });

    if (multiSigDeployTx) {
        await saveForSafeBatchExecution(multiSigDeployTx);
    }
};

func.tags = [RESTAKE_MANAGER];
func.dependencies = [VE_HEMI];
export default func;

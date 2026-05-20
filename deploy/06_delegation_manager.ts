import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";
const RESTAKE_MANAGER = "RestakeManager";
const DELEGATE_REWARD_DISTRIBUTOR = "DelegateRewardDistributor";
const DELEGATION_MANAGER = "DelegationManager";

// ── DelegationConfig for DelegationManager.initialize() ──────────────────
// These values are passed as part of the initialize() call.
//
// DelegationConfig struct fields (matches Solidity struct order):
//   globalMinCommBps           (uint16) - Min commission rate any delegate can set, in BPS.
//   globalMaxCommBps           (uint16) - Max commission rate any delegate can set, in BPS.
//   minSelfStakeRatioBps       (uint16) - Min self-stake ratio in BPS.
//   maxServicesPerDelegate     (uint8)  - Max services a delegate can allocate to.
//   commissionActivationDelay  (uint32) - Delay for commission activation / warm-up / self-stake (seconds).
//   minDelegationFloor         (uint96) - Global minimum delegation amount floor (wei).
//   confiscationDelay          (uint32) - Delay before confiscation after freeze (seconds).
//   minDelegationDuration      (uint32) - Minimum active delegation duration (seconds).
//   maxDelegatesPerPosition    (uint8)  - Max delegates a single position can delegate to.
//
// Rationale for chosen values:
//   - globalMinCommBps = 0: No minimum commission — delegates can offer 0% if they choose.
//   - globalMaxCommBps = 5000 (50%): Caps delegate commission at 50% of rewards.
//   - minSelfStakeRatioBps = 1000 (10%): Delegates must self-stake >= 10% of their pool.
//     Must be >= MIN_SELF_STAKE_RATIO_BPS (1000 = 10%).
//   - maxServicesPerDelegate = 16: Limits blast radius and gas costs for cross-service operations.
//   - commissionActivationDelay = 3600 (1 hour): Protective delay for commission changes,
//     warm-up activation, and self-stake additions. Must be >= MIN_COMMISSION_ACTIVATION_DELAY (1 hour).
//   - minDelegationFloor = 1e15 (0.001 ETH): Prevents dust delegations that waste gas.
//     Must be >= MIN_DELEGATION_FLOOR (1e15).
//   - confiscationDelay = 259200 (3 days): Time window for delegates to contest confiscation.
//     NOTE: RM's challengePeriod MUST be > confiscationDelay. RM challengePeriod is 4 days
//     (345600s) which satisfies this constraint (4 days > 3 days).
//     Must be >= MIN_CONFISCATION_DELAY (3 days = 259200).
//   - minDelegationDuration = 3600 (1 hour): Minimum lock before undelegation is allowed.
//     Must be >= MIN_DELEGATION_DURATION (1 hour).
//   - maxDelegatesPerPosition = 20: Caps gas costs for per-position iteration.
//     Must be <= MAX_DELEGATES_PER_POSITION (20).
const DELEGATION_CONFIG = {
    globalMinCommBps: 0,
    globalMaxCommBps: 5000,            // 50%
    minSelfStakeRatioBps: 1000,        // 10%
    maxServicesPerDelegate: 16,
    commissionActivationDelay: 3600,   // 1 hour in seconds
    minDelegationFloor: "1000000000000000", // 1e15 wei (BigInt string for uint96)
    confiscationDelay: 259200,         // 3 days in seconds (RM challengePeriod must be > this)
    minDelegationDuration: 3600,       // 1 hour in seconds
    maxDelegatesPerPosition: 20
};

// ── 10 DM DELEGATECALL libraries ─────────────────────────────────────────
// These are Solidity `library` contracts deployed as standalone bytecode.
// DelegationManager stores their addresses as immutables and calls them via
// explicit delegatecall (NOT Solidity library linking).
const DM_LIBRARIES = [
    "DelegationSettlementLib",
    "DelegationLifecycleLib",
    "DelegationRedelegateLib",
    "DelegationSlashLib",
    "DelegationGovernanceLib",
    "DelegationConfigLib",
    "DelegationServiceLib",
    "DelegationSelfStakeLib",
    "DelegationEmergencyLib",
    "DelegationRewardOpsLib"
] as const;

// ── Deployment atomicity ─────────────────────────────────────────────────
// This script deploys the full delegation system:
//
//   Step 1: Deploy DelegateRewardDistributor (UUPS proxy) with Gnosis Safe as owner.
//   Step 2: Deploy all 10 DM DELEGATECALL libraries.
//   Step 3: Deploy DelegationManager implementation (libraries as immutables).
//   Step 4: Deploy DelegationManager proxy (TransparentProxy), initialize with paused=true.
//   Step 5: DRD.setDelegationManager(DM proxy) — links the two contracts.
//   Step 6: RM.proposeDelegationManager(DM proxy) — starts 2-day timelock.
//
// Steps 1-4 can be executed by the deployer EOA directly.
// Steps 5-6 require the Gnosis Safe (owner of DRD and RM).
//
// After the 2-day timelock, a separate transaction must call
// RM.acceptDelegationManager() to complete the link. This is NOT included
// here because it cannot execute until the timelock elapses.
//
// The DM starts paused. Governance must call unpause() after verifying the
// full deployment and configuration.

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, execute, get } = deployments;
    const { deployer } = await getNamedAccounts();

    // Revert if not on chain ID 43111 (Hemi) or 31337 (Localhost)
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    const { address: veHemiAddress } = await get(VE_HEMI);
    const { address: restakeManagerAddress } = await get(RESTAKE_MANAGER);
    console.log("veHemiAddress:", veHemiAddress);
    console.log("restakeManagerAddress:", restakeManagerAddress);

    // ── Step 1: Deploy DelegateRewardDistributor (UUPS proxy) ────────────
    // Owner is the Gnosis Safe (acts as the TimelockController / governance).
    // The DRD is inert until setDelegationManager() is called in Step 5.
    console.log("\n--- Step 1: Deploy DelegateRewardDistributor ---");

    const drdDeployFunction = () =>
        deploy(DELEGATE_REWARD_DISTRIBUTOR, {
            from: deployer,
            log: true,
            proxy: {
                // UUPS: no ProxyAdmin needed — upgrade authorization is in the
                // implementation's _authorizeUpgrade (onlyOwner).
                proxyContract: "UUPS",
                execute: {
                    init: {
                        methodName: "initialize",
                        // initialize(address owner_)
                        args: [Addresses.Hemi.GNOSIS_SAFE]
                    }
                }
            }
        });

    const multiSigDrdTx = await catchUnknownSigner(drdDeployFunction, { log: true });
    if (multiSigDrdTx) {
        await saveForSafeBatchExecution(multiSigDrdTx);
    }

    const { address: drdAddress } = await get(DELEGATE_REWARD_DISTRIBUTOR);
    console.log("DelegateRewardDistributor proxy:", drdAddress);

    // ── Step 2: Deploy all 10 DM DELEGATECALL libraries ──────────────────
    // Each library is deployed as a standalone contract. Their addresses are
    // passed to the DM constructor as immutables.
    console.log("\n--- Step 2: Deploy DM DELEGATECALL libraries ---");

    const libraryAddresses: Record<string, string> = {};

    for (const libName of DM_LIBRARIES) {
        const result = await deploy(libName, {
            from: deployer,
            log: true,
            contract: libName
        });
        libraryAddresses[libName] = result.address;
        console.log(`  ${libName}:`, result.address);
    }

    // ── Step 3: Deploy DelegationManager implementation ──────────────────
    // Constructor args: veHemi_, restakeManager_, rewardDistributor_, LibraryAddresses
    // The LibraryAddresses struct is encoded as a positional tuple matching the
    // Solidity struct field order.
    console.log("\n--- Step 3: Deploy DelegationManager implementation + proxy ---");

    // LibraryAddresses struct tuple (must match DelegationManager.LibraryAddresses field order):
    //   [settlementLib, lifecycleLib, redelegateLib, slashLib, governanceLib,
    //    configLib, serviceLib, selfStakeLib, emergencyLib, rewardOpsLib]
    const libraryAddressesTuple = [
        libraryAddresses["DelegationSettlementLib"],
        libraryAddresses["DelegationLifecycleLib"],
        libraryAddresses["DelegationRedelegateLib"],
        libraryAddresses["DelegationSlashLib"],
        libraryAddresses["DelegationGovernanceLib"],
        libraryAddresses["DelegationConfigLib"],
        libraryAddresses["DelegationServiceLib"],
        libraryAddresses["DelegationSelfStakeLib"],
        libraryAddresses["DelegationEmergencyLib"],
        libraryAddresses["DelegationRewardOpsLib"]
    ];

    // DelegationConfig struct tuple (must match DelegationConfig field order):
    //   [globalMinCommBps, globalMaxCommBps, minSelfStakeRatioBps, maxServicesPerDelegate,
    //    commissionActivationDelay, minDelegationFloor, confiscationDelay,
    //    minDelegationDuration, maxDelegatesPerPosition]
    const delegationConfigTuple = [
        DELEGATION_CONFIG.globalMinCommBps,
        DELEGATION_CONFIG.globalMaxCommBps,
        DELEGATION_CONFIG.minSelfStakeRatioBps,
        DELEGATION_CONFIG.maxServicesPerDelegate,
        DELEGATION_CONFIG.commissionActivationDelay,
        DELEGATION_CONFIG.minDelegationFloor,
        DELEGATION_CONFIG.confiscationDelay,
        DELEGATION_CONFIG.minDelegationDuration,
        DELEGATION_CONFIG.maxDelegatesPerPosition
    ];

    // ── Step 4: Deploy DM proxy (TransparentProxy) + initialize ──────────
    // Constructor: constructor(veHemi_, restakeManager_, rewardDistributor_, libs)
    // Initializer: initialize(owner_, config_, confiscationRecipient_, startPaused)
    const dmDeployFunction = () =>
        deploy(DELEGATION_MANAGER, {
            from: deployer,
            log: true,
            args: [veHemiAddress, restakeManagerAddress, drdAddress, libraryAddressesTuple],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
                execute: {
                    init: {
                        methodName: "initialize",
                        // initialize(address owner_, DelegationConfig config_, address confiscationRecipient_, bool startPaused)
                        // confiscationRecipient is the Gnosis Safe.
                        // startPaused = true: DM starts paused for safe deployment.
                        args: [
                            Addresses.Hemi.GNOSIS_SAFE,
                            delegationConfigTuple,
                            Addresses.Hemi.GNOSIS_SAFE,
                            true // startPaused
                        ]
                    }
                }
            }
        });

    const multiSigDmTx = await catchUnknownSigner(dmDeployFunction, { log: true });
    if (multiSigDmTx) {
        await saveForSafeBatchExecution(multiSigDmTx);
    }

    const { address: dmAddress } = await get(DELEGATION_MANAGER);
    console.log("DelegationManager proxy:", dmAddress);

    // ── Step 5: DRD.setDelegationManager(DM proxy) ──────────────────────
    // This is a one-time setter on the DRD that links it to the DM.
    // Caller must be DRD owner (Gnosis Safe).
    console.log("\n--- Step 5: DRD.setDelegationManager ---");

    const setDmFunction = () =>
        execute(
            DELEGATE_REWARD_DISTRIBUTOR,
            { from: deployer, log: true },
            "setDelegationManager",
            dmAddress
        );

    const multiSigSetDmTx = await catchUnknownSigner(setDmFunction, { log: true });
    if (multiSigSetDmTx) {
        await saveForSafeBatchExecution(multiSigSetDmTx);
    }

    // ── Step 6: RM.proposeDelegationManager(DM proxy) ───────────────────
    // Starts the 2-day timelock. After timelock elapses, a separate
    // transaction must call RM.acceptDelegationManager().
    // Caller must be RM owner (Gnosis Safe).
    console.log("\n--- Step 6: RM.proposeDelegationManager ---");

    const proposeDmFunction = () =>
        execute(
            RESTAKE_MANAGER,
            { from: deployer, log: true },
            "proposeDelegationManager",
            dmAddress
        );

    const multiSigProposeDmTx = await catchUnknownSigner(proposeDmFunction, { log: true });
    if (multiSigProposeDmTx) {
        await saveForSafeBatchExecution(multiSigProposeDmTx);
    }

    // ── Summary ──────────────────────────────────────────────────────────
    console.log("\n=== Delegation System Deployment Summary ===");
    console.log("DelegateRewardDistributor (UUPS proxy):", drdAddress);
    for (const libName of DM_LIBRARIES) {
        console.log(`  ${libName}:`, libraryAddresses[libName]);
    }
    console.log("DelegationManager (TransparentProxy):", dmAddress);
    console.log("Confiscation recipient:", Addresses.Hemi.GNOSIS_SAFE);
    console.log("DM starts paused:", true);
    console.log("\nNext steps:");
    console.log("  1. Submit Safe batch (99_safe-txs.ts will propose it)");
    console.log("  2. Wait 2 days for RM.proposeDelegationManager timelock");
    console.log("  3. Call RM.acceptDelegationManager() via Safe");
    console.log("  4. Verify all configurations, then call DM.unpause() via Safe");
};

func.tags = [DELEGATION_MANAGER];
func.dependencies = [VE_HEMI, RESTAKE_MANAGER, "RestakeManagerV2Upgrade"];
export default func;

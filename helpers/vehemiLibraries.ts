/**
 * The two DELEGATECALL libraries `src/VeHemi.sol` links against.
 *
 * Deployed from the deployer EOA, not the Safe: both are stateless, ownerless
 * and permissionless, and nothing reaches them until a linked implementation
 * embeds their addresses. Keeping them out of the Safe batch keeps that batch
 * to the two ProxyAdmin legs.
 *
 * Both must be mined before the VeHemi implementation is deployed, because
 * their addresses are compiled into its creation bytecode. `deployments.deploy`
 * awaits each receipt, so sequential awaits are enough.
 *
 * `VeHemiLayoutLib` and `VeHemiTime` are internal-only and produce no link
 * references, so they are not deployed. `assertLinkManifest` fails if that
 * changes.
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { LibraryAddresses, assertLibraryCode } from "./linking";

export const VEHEMI_LIBRARIES = ["VeHemiCurveLib", "VeHemiSupplyLib"] as const;

/**
 * The expected link sites per library, as the compiled artifacts carry them.
 * `assertLinkManifest` aborts the deploy at pre-flight on any difference.
 */
export const VEHEMI_LINK_MANIFEST = {
    VeHemi: { VeHemiCurveLib: 1, VeHemiSupplyLib: 4 },
} as const;

export async function deployVeHemiLibraries(
    hre: HardhatRuntimeEnvironment,
    deployer: string
): Promise<LibraryAddresses> {
    const { deploy } = hre.deployments;
    const libraries: LibraryAddresses = {};

    for (const libName of VEHEMI_LIBRARIES) {
        const result = await deploy(libName, {
            from: deployer,
            log: true,
            contract: libName,
        });
        libraries[libName] = result.address;
        console.log(
            `  ${libName}: ${result.address}` +
                (result.newlyDeployed ? "  (newly deployed)" : "  (reused)")
        );
        await assertLibraryCode(hre, libName, result.address);
    }

    return libraries;
}

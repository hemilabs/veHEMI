import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";
import { deployVeHemiLibraries } from "../helpers/vehemiLibraries";

const VE_HEMI = "VeHemi";

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner } = deployments;
    const { deployer } = await getNamedAccounts();
    // Revert if not on chain ID 43111 (Hemi) or 31337 (Localhost)
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // `src/VeHemi.sol` DELEGATECALLs two external libraries (helpers/vehemiLibraries.ts).
    // Without `libraries:` below, the creation code still holds `__$<hash>$__`
    // placeholders and the deploy fails on invalid hex. The libraries are deployed
    // first because their addresses are compiled into the implementation.
    const libraries = await deployVeHemiLibraries(hre, deployer);

    const deployFunction = () =>
        deploy(VE_HEMI, {
            from: deployer,
            log: true,
            args: [Addresses.Hemi.HEMI_TOKEN],
            libraries,
            proxy: {
                // Hardhat-deploy will deploy these proxy-related contracts:
                // ProxyAdmin: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/ProxyAdmin.sol
                // TransparentUpgradeableProxy: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
                execute: {
                    init: {
                        methodName: "initialize",
                        args: [deployer]
                    }
                }
            }
        });

    const multiSigDeployTx = await catchUnknownSigner(deployFunction, { log: true });

    if (multiSigDeployTx) {
        await saveForSafeBatchExecution(multiSigDeployTx);
    }
};

func.tags = [VE_HEMI];
export default func;

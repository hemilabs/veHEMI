import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy, catchUnknownSigner } = deployments;
    const { deployer } = await getNamedAccounts();

    const deployFunction = () =>
        deploy(VE_HEMI, {
            from: deployer,
            log: true,
            args: [Addresses.HEMI],
            proxy: {
                // Hardhat-deploy will deploy these proxy-related contracts:
                // ProxyAdmin: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/ProxyAdmin.sol
                // TransparentUpgradeableProxy: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol
                owner: Addresses.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
                execute: {
                    init: {
                        methodName: "initialize",
                        args: [Addresses.OWNER]
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

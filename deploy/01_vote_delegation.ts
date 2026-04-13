import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VOTE_DELEGATION = "VeHemiVoteDelegation";
const VE_HEMI = "VeHemi";

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, execute } = deployments;
    const { deployer } = await getNamedAccounts();
    // Revert if not on chain ID 43111 (Hemi) or 31337 (Localhost)
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }
    const { address: veHemiAddress } = await get(VE_HEMI);
    console.log("veHemiAddress", veHemiAddress);

    const deployFunction = () =>
        deploy(VOTE_DELEGATION, {
            from: deployer,
            log: true,
            args: [veHemiAddress],
            proxy: {
                // Hardhat-deploy will deploy these proxy-related contracts:
                // ProxyAdmin: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/ProxyAdmin.sol
                // TransparentUpgradeableProxy: https://github.com/wighawag/hardhat-deploy/blob/v1.0.4/solc_0.8/openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
                execute: {
                    init: {
                        methodName: "initialize",
                        args: []
                    }
                }
            }
        });

    const multiSigDeployTx = await catchUnknownSigner(deployFunction, { log: true });

    if (multiSigDeployTx) {
        await saveForSafeBatchExecution(multiSigDeployTx);
    }
    // update vote delegation
    const doExecute = async () => {
        const { address: voteDelegationAddress } = await get(VOTE_DELEGATION);
        return execute(VE_HEMI, { from: deployer, log: true }, "updateVoteDelegation", voteDelegationAddress);
    };

    const updateVoteDelegation = await catchUnknownSigner(doExecute, { log: true });

    if (updateVoteDelegation) {
        await saveForSafeBatchExecution(updateVoteDelegation);
    }
};

func.tags = [VOTE_DELEGATION];
func.dependencies = [VE_HEMI];
export default func;

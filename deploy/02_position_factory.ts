import { DeployFunction } from "hardhat-deploy/types";

const POSITION_FACTORY = "PositionFactory";
const VE_HEMI = "VeHemi";

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, get } = deployments;
    const { deployer } = await getNamedAccounts();
    // Revert if not on chain ID 43111 (Hemi) or 31337 (Localhost)
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    const { address: veHemiAddress } = await get(VE_HEMI);

    await deploy(POSITION_FACTORY, {
        from: deployer,
        args: [veHemiAddress, deployer],
        log: true
    });
};

func.tags = [POSITION_FACTORY];
func.dependencies = [VE_HEMI];
export default func;

import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { executeBatchUsingSafe } from "../helpers/safe";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    await executeBatchUsingSafe(hre);
};

func.tags = ["safe"];
func.runAtTheEnd = true;

export default func;

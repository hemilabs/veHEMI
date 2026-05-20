import { DeployFunction } from "hardhat-deploy/types";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VOTE_DELEGATION = "VeHemiVoteDelegation";
const VE_HEMI = "VeHemi";

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, execute, read } = deployments;
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
    // Wire VVD into VeHemi.
    //
    // Idempotency: if `veHemi.voteDelegation()` already points at the
    // expected VVD proxy, skip the call. This is the common case on a V2
    // upgrade against an already-wired mainnet — without this guard the
    // execute below reverts with `OwnableUnauthorizedAccount` because the
    // proxy owner is the Safe, not the deployer EOA, and
    // `catchUnknownSigner` only catches hardhat-deploy's pre-check, not
    // an on-chain revert during gas estimation.
    //
    // Sender selection: use the current `VeHemi.owner()`. On a fresh
    // deploy this is the deployer EOA (set at initialize-time), so the
    // call signs locally. On a post-transfer upgrade this is the Safe;
    // hardhat-deploy can't sign for the Safe, `catchUnknownSigner` catches
    // the "no signer for X" pre-check, and the tx is queued to the Safe
    // batch.
    const doExecute = async () => {
        const { address: voteDelegationAddress } = await get(VOTE_DELEGATION);
        const currentVoteDelegation = (await read(VE_HEMI, "voteDelegation")) as string;
        if (currentVoteDelegation.toLowerCase() === voteDelegationAddress.toLowerCase()) {
            console.log(
                `VeHemi.voteDelegation already set to ${voteDelegationAddress} — skipping updateVoteDelegation`
            );
            return undefined;
        }
        const veHemiOwner = (await read(VE_HEMI, "owner")) as string;
        // Explicit `gasLimit` skips hardhat-deploy's automatic
        // `eth_estimateGas`. Estimation against a stale (pre-upgrade)
        // impl would revert before `catchUnknownSigner` ever sees the
        // unknown-Safe-signer condition; with a manual limit, the path
        // routes cleanly to the Safe batch. 100k is generous for a
        // single-SSTORE `onlyOwner` setter.
        return execute(
            VE_HEMI,
            { from: veHemiOwner, log: true, gasLimit: 100_000 },
            "updateVoteDelegation",
            voteDelegationAddress
        );
    };

    const updateVoteDelegation = await catchUnknownSigner(doExecute, { log: true });

    if (updateVoteDelegation) {
        await saveForSafeBatchExecution(updateVoteDelegation);
    }
};

func.tags = [VOTE_DELEGATION];
func.dependencies = [VE_HEMI];
export default func;

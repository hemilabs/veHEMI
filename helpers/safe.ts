import fs from "fs";
import { HardhatRuntimeEnvironment, HttpNetworkConfig } from "hardhat/types";
import chalk from "chalk";
import SafeApiKit from "@safe-global/api-kit";
import Safe from "@safe-global/protocol-kit";
import { MetaTransactionData, OperationType } from "@safe-global/types-kit";
import { Addresses } from "./addresses";
import { impersonateAccount } from ".";

export const MULTI_SIG_TXS_FILE = "multisig.batch.tmp.json";

// Type returned by `hardhat-deploy`'s `catchUnknownSigner` function
type MultiSigTx = {
    from: string;
    to?: string | undefined;
    value?: string | undefined;
    data?: string | undefined;
};

const { log } = console;

export const saveForSafeBatchExecution = async (rawTx: MultiSigTx): Promise<void> => {
    if (!fs.existsSync(MULTI_SIG_TXS_FILE)) {
        fs.closeSync(fs.openSync(MULTI_SIG_TXS_FILE, "w"));
    }

    const file = fs.readFileSync(MULTI_SIG_TXS_FILE);

    const tx = prepareTx(rawTx);

    if (file.length == 0) {
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([tx]));
    } else {
        const current = JSON.parse(file.toString()) as MetaTransactionData[];

        const alreadyStored = current.find(
            (i: MetaTransactionData) => i.to == tx.to && i.data == tx.data && i.value == tx.value
        );

        if (alreadyStored) {
            log(chalk.blue(`This multi-sig transaction is already saved in '${MULTI_SIG_TXS_FILE}'.`));
            return;
        }

        const json = [...current, tx];
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(json));
    }

    log(chalk.blue(`Multi-sig transaction saved in '${MULTI_SIG_TXS_FILE}'.`));
};

export const executeBatchUsingSafe = async (hre: HardhatRuntimeEnvironment): Promise<void> => {
    if (!fs.existsSync(MULTI_SIG_TXS_FILE)) {
        return;
    }

    const file = fs.readFileSync(MULTI_SIG_TXS_FILE);

    const transactions: MetaTransactionData[] = JSON.parse(file.toString());

    log(chalk.blue("Proposing multi-sig batch transaction..."));
    await proposeSafeTransaction(hre, transactions);

    fs.unlinkSync(MULTI_SIG_TXS_FILE);
};

// Parse `hardhat-deploy` tx to `Safe` tx
const prepareTx = ({ to, data, value }: MultiSigTx): MetaTransactionData => {
    if (!to || !data) {
        throw Error("The `to` and `data` args can not be null");
    }

    return { to, data, value: value || "0" };
};

const proposeSafeTransaction = async (hre: HardhatRuntimeEnvironment, txs: MetaTransactionData[]) => {
    const chainId = BigInt(await hre.getChainId());
    const safeAddress = Addresses.GNOSIS_SAFE;

    if (["hardhat", "localhost"].includes(hre.network.name)) {
        for (const tx of txs) {
            const { to, data } = tx;
            const w = await impersonateAccount(safeAddress);
            await w.sendTransaction({ to, data });
        }
        log(chalk.blue("Because it is a test deployment, the transactions were executed by impersonated multi-sig."));
    } else {
        const { deployer: delegateAddress } = await hre.getNamedAccounts();
        const chainName = (await hre.ethers.provider.getNetwork()).name;

        const config = <HttpNetworkConfig>hre.config.networks[chainName];
        const provider = config.url;
        const apiKit = new SafeApiKit({ chainId });

        const protocolKit = await Safe.init({
            provider: provider,
            signer: process.env.DEPLOYER_PRIVATE_KEY!, // Assumes that the deployer is also a delegate
            safeAddress
        });

        const safeTransactionData: MetaTransactionData[] = txs.map((tx) => ({ ...tx, operation: OperationType.Call }));

        const safeTransaction = await protocolKit.createTransaction({
            transactions: safeTransactionData,
            onlyCalls: true
        });

        const safeTxHash = await protocolKit.getTransactionHash(safeTransaction);
        const signature = await protocolKit.signHash(safeTxHash);

        await apiKit.proposeTransaction({
            safeAddress,
            safeTransactionData: safeTransaction.data,
            safeTxHash,
            senderAddress: delegateAddress,
            senderSignature: signature.data
        });

        log(chalk.blue(`MultiSig tx '${safeTxHash}' was proposed.`));
        log(chalk.blue("Wait for tx to confirm (at least 2 confirmations is recommended)."));
        log(chalk.blue("After confirmation, you must run the deployment again."));
        log(
            chalk.blue(
                "That way the `hardhat-deploy` will be able to catch the changes and update `deployments/` files."
            )
        );
    }
};

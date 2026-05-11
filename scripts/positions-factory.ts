import * as fs from "fs/promises";
import { parse } from "csv-parse/sync";
import {
    Contract,
    ethers,
    hexlify,
    JsonRpcProvider,
    parseEther,
    solidityPackedKeccak256,
    stripZerosLeft,
    toBeHex,
    Wallet
} from "ethers";
import { IERC20__factory, PositionFactory__factory, PositionFactory } from "../typechain-types";
import dotenv from "dotenv";

dotenv.config();

const FILE_PATH = "POSITIONS.csv";
const STATUS_BATCH_SIZE = 1000; // Each status update costs ~30k gas, so 1000 should fit in a block
const RPC_URL = "https://rpc.hemi.network/rpc";
const HEMI_TOKEN_ADDRESS = "0x99e3dE3817F6081B2568208337ef83295b7f591D";

// PositionFactory address is read at runtime from deployments/hemi/PositionFactory.json
// (written by hardhat-deploy after `deploy/02_position_factory.ts` runs).
// Override via the POSITION_FACTORY_ADDRESS env var when running against a
// different deployment.
const HEMI_DEPLOYMENT_NETWORK = "hemi";

const LOCAL_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // hardhat/anvil account[0]
const LOCAL_RPC_URL = "http://localhost:8545";

// In local mode the script forks Hemi mainnet (per `anvil --fork-url
// https://rpc.hemi.network/rpc`), so PositionFactory's veHemi argument
// must point at the live VeHemi proxy on Hemi.
const LOCAL_VE_HEMI_ADDRESS = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89";

const { PRIVATE_KEY, NODE_ENV, POSITION_FACTORY_ADDRESS: POSITION_FACTORY_ADDRESS_OVERRIDE } = process.env;

async function resolvePositionFactoryAddress(): Promise<string> {
    if (POSITION_FACTORY_ADDRESS_OVERRIDE) {
        if (!ethers.isAddress(POSITION_FACTORY_ADDRESS_OVERRIDE)) {
            throw new Error(
                `POSITION_FACTORY_ADDRESS env var is not a valid address: ${POSITION_FACTORY_ADDRESS_OVERRIDE}`
            );
        }
        return POSITION_FACTORY_ADDRESS_OVERRIDE;
    }
    const deploymentPath = `deployments/${HEMI_DEPLOYMENT_NETWORK}/PositionFactory.json`;
    try {
        const raw = await fs.readFile(deploymentPath, "utf-8");
        const parsed = JSON.parse(raw) as { address?: string };
        if (!parsed.address || !ethers.isAddress(parsed.address)) {
            throw new Error(`Missing/invalid 'address' field in ${deploymentPath}`);
        }
        return parsed.address;
    } catch (err) {
        throw new Error(
            `Could not resolve PositionFactory address. Either run \`npx hardhat deploy\` ` +
                `to populate ${deploymentPath}, or set POSITION_FACTORY_ADDRESS in the ` +
                `environment. Underlying error: ${(err as Error).message}`
        );
    }
}

enum Status {
    NONE = 0,
    PENDING = 1,
    CREATED = 2
}

type CsvRow = {
    wallet: string;
    amount: string;
    duration: string;
    transferable: string;
    forfeitable: string;
};

async function readCsv(filePath: string) {
    const fileContent = await fs.readFile(filePath, "utf-8");
    const records = parse(fileContent, {
        columns: true
    });
    return records;
}

function chunks(arr: any[], size: number) {
    const new_array = [];
    const tmp = [...arr];
    while (tmp.length) {
        const chunk = tmp.splice(0, size);
        new_array.push(chunk);
    }
    return new_array;
}

const whitelist = async (rows: CsvRow[], factory: PositionFactory) => {
    const batches = chunks(rows, STATUS_BATCH_SIZE);

    console.log(`=== Whitelisting ${rows.length} positions in ${batches.length} batches... ===`);

    let i = 1;
    for (const batch of batches) {
        const users = [];
        const amounts = [];
        const durations = [];
        const transferables = [];
        const forfeitables = [];

        for (const { wallet, amount, duration, transferable, forfeitable } of batch) {
            users.push(wallet);
            amounts.push(BigInt(amount));
            durations.push(BigInt(duration));
            transferables.push(transferable === "true");
            forfeitables.push(forfeitable === "true");
        }

        const tx = await factory.updateStatus(
            users,
            amounts,
            durations,
            transferables,
            forfeitables,
            Status.PENDING,
            true
        );
        console.log(`Batch ${i++} transaction hash: ${tx.hash}`);
        await tx.wait(1);
    }
};

const create = async (rows: CsvRow[], factory: PositionFactory, wallet: Wallet) => {
    console.log(`\n=== Creating veHemi positions... ===`);

    const hemi = new ethers.Contract(HEMI_TOKEN_ADDRESS, IERC20__factory.abi, wallet);
    const approveMaxTx = await hemi.approve(factory.target, ethers.MaxUint256);
    console.log("Hemi infinity approval transaction hash:", approveMaxTx.hash);
    await approveMaxTx.wait(1);

    let i = 1;
    for (const { wallet, amount, duration, transferable, forfeitable } of rows) {
        const transferableBool = transferable === "true";
        const forfeitableBool = forfeitable === "true";
        const hash = ethers.keccak256(
            ethers.solidityPacked(
                ["address", "uint256", "uint256", "bool", "bool"],
                [wallet, BigInt(amount), BigInt(duration), transferableBool, forfeitableBool]
            )
        );

        console.log(
            `\n[${i++}/${rows.length}] Creating position for wallet ${wallet} with amount ${amount} and duration ${duration}...`
        );

        const s = Number(await factory.created(hash)) as Status;

        if (s == Status.CREATED) {
            console.log(`Position was already created. you can workaround this by adding 1 wei to the amount.`);
            continue;
        }

        if (s == Status.NONE) {
            console.log(`Position is not whitelisted.`);
            continue;
        }

        const tx = await factory.create(
            wallet,
            BigInt(amount),
            BigInt(duration),
            transferableBool,
            forfeitableBool
        );
        console.log("Transaction hash:", tx.hash);
        await tx.wait(1);
    }

    const approveZeroTx = await hemi.approve(factory.target, 0);
    console.log("\nHemi remove approval transaction hash:", approveZeroTx.hash);
    await approveZeroTx.wait(1);
};

/**
 * Script to create veHemi positions from a CSV file.
 *
 * Notes:
 * - CSV columns are: "wallet,amount,duration,transferable,forfeitable"
 * - Use `NODE_ENV=local` env var to test script locally
 * - Use `anvil --fork-url https://rpc.hemi.network/rpc --block-time 1` for local tests
 * - `tx.wait(2)` should be enough to avoid nonce issues
 * - Run `npx hardhat compile` when changing the smart contract
 */
const main = async () => {
    console.log("🚀 Starting positions-factory script...");
    console.log(`NODE_ENV: ${NODE_ENV}`);
    console.log(`FILE_PATH: ${FILE_PATH}`);

    let provider: JsonRpcProvider;
    let wallet: Wallet;
    let factory: PositionFactory;

    if (NODE_ENV == "local") {
        console.log("🔧 Running in LOCAL mode");
        provider = new ethers.JsonRpcProvider(LOCAL_RPC_URL);
        wallet = new ethers.Wallet(LOCAL_PRIVATE_KEY, provider);
        factory = await new PositionFactory__factory(wallet).deploy(LOCAL_VE_HEMI_ADDRESS, wallet);
        const deploymentTx = factory.deploymentTransaction()!;
        await deploymentTx.wait(1); // Wait for 1 confirmation instead of 2

        // deal 1M HEMI to our wallet
        const slot = 0; // HEMI balance slot
        const balance = parseEther("1000000");
        const index = stripZerosLeft(hexlify(solidityPackedKeccak256(["uint256", "uint256"], [wallet.address, slot])));
        const value = hexlify(toBeHex(balance, 32));
        await provider.send("hardhat_setStorageAt", [HEMI_TOKEN_ADDRESS, index, value]);
        console.log("✅ Local setup complete - deployed factory and funded wallet");
    } else {
        console.log("🌐 Running in PRODUCTION mode");
        console.log(`RPC_URL: ${RPC_URL}`);

        if (!PRIVATE_KEY) {
            throw new Error("PRIVATE_KEY environment variable is required for production mode");
        }

        const factoryAddress = await resolvePositionFactoryAddress();
        console.log(`POSITION_FACTORY_ADDRESS: ${factoryAddress}`);

        provider = new ethers.JsonRpcProvider(RPC_URL);
        wallet = new ethers.Wallet(PRIVATE_KEY!, provider);
        factory = new ethers.Contract(
            factoryAddress,
            PositionFactory__factory.abi,
            wallet
        ) as PositionFactory & Contract;
        console.log("✅ Production setup complete");
    }

    console.log(`📖 Reading CSV file: ${FILE_PATH}`);
    const rows = (await readCsv(FILE_PATH)) as CsvRow[];
    console.log(`📊 Found ${rows.length} positions to process`);

    await whitelist(rows, factory);
    await create(rows, factory, wallet);

    console.log("🎉 Script completed successfully!");
};

main().catch(console.error);

/**
 * One-shot V2-upgrade Safe MultiSend proposer.
 *
 * Background: the hardhat-deploy flow normally builds and proposes this
 * batch automatically (scripts 04, 05, 99). But if any of those scripts
 * deploys the V2 impls successfully and then later fails (or is
 * interrupted), the local deployment artifacts get updated to point at
 * the new impls — and hardhat-deploy on a re-run sees the artifacts as
 * "already up to date" and skips queuing the `ProxyAdmin.upgrade(...)`
 * calls, leaving the proxy still pointing at V1 on-chain.
 *
 * This script reads the current local artifact state, constructs the
 * full 4-tx MultiSend, and proposes it directly to the Safe Transaction
 * Service via SafeApiKit. No hardhat-deploy involvement.
 *
 * Required env:
 *   PROVIDER_URL              Hemi RPC URL.
 *   DEPLOYER_PRIVATE_KEY      Delegate EOA private key for proposing.
 *   SAFE_API_KEY              Safe Transaction Service API key
 *                             (https://app.safe.global → Settings → API Keys).
 *
 * Run:
 *   npx hardhat --network hemi run scripts/propose-v2-upgrade.ts
 *
 * Output: prints the proposed safeTxHash. Then sign + execute via the
 * Safe UI.
 */

import { ethers } from "hardhat";
import fs from "fs";
import path from "path";
import SafeApiKit from "@safe-global/api-kit";
import Safe from "@safe-global/protocol-kit";
import { MetaTransactionData, OperationType } from "@safe-global/types-kit";
import { Addresses } from "../helpers/addresses";

const PROXY_ADMIN = "0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F";
const VEHEMI_PROXY = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89";
const VVD_PROXY = "0xBF5b2f370370494B8A4575962512dd3ea7c29e2d";
const SAFE_ADDR = Addresses.Hemi.GNOSIS_SAFE;
const HEMI_CHAIN_ID = 43111n;

const iface = new ethers.Interface([
    "function upgrade(address proxy, address implementation)",
    "function markSeedingStarted()",
    "function setTrustedAdapter(address adapter)",
]);

function loadAddress(artifactName: string): string {
    const p = path.join(__dirname, "..", "deployments", "hemi", `${artifactName}.json`);
    const raw = JSON.parse(fs.readFileSync(p, "utf8"));
    if (!raw.address) throw new Error(`${artifactName}: artifact missing 'address'`);
    return raw.address as string;
}

async function main() {
    if (!process.env.PROVIDER_URL) throw new Error("PROVIDER_URL is required");
    if (!process.env.DEPLOYER_PRIVATE_KEY) throw new Error("DEPLOYER_PRIVATE_KEY is required");
    if (!process.env.SAFE_API_KEY) throw new Error("SAFE_API_KEY is required");

    // Read what hardhat-deploy thinks the current V2 impls are.
    const veHemiImpl = loadAddress("VeHemi_Implementation");
    const vvdImpl = loadAddress("VeHemiVoteDelegation_Implementation");
    const adapter = loadAddress("VeHemiAragonAdapter");

    console.log("V2 impls to upgrade to:");
    console.log(`  VeHemi               ${veHemiImpl}`);
    console.log(`  VeHemiVoteDelegation ${vvdImpl}`);
    console.log(`  Adapter              ${adapter}`);
    console.log("");

    // Sanity: confirm the impls actually have bytecode on-chain.
    const provider = ethers.provider;
    for (const [label, addr] of [
        ["VeHemi impl", veHemiImpl],
        ["VVD impl", vvdImpl],
        ["Adapter", adapter],
    ] as const) {
        const code = await provider.getCode(addr);
        if (code === "0x") {
            throw new Error(`${label} at ${addr} has no bytecode on-chain — refusing to propose`);
        }
    }
    console.log("All target addresses have on-chain bytecode ✓");
    console.log("");

    // Build the 4-tx batch in execution order.
    const txs: MetaTransactionData[] = [
        // 1. Upgrade VeHemi proxy → V2 impl
        {
            to: PROXY_ADMIN,
            data: iface.encodeFunctionData("upgrade", [VEHEMI_PROXY, veHemiImpl]),
            value: "0",
            operation: OperationType.Call,
        },
        // 2. Upgrade VVD proxy → V2 impl
        {
            to: PROXY_ADMIN,
            data: iface.encodeFunctionData("upgrade", [VVD_PROXY, vvdImpl]),
            value: "0",
            operation: OperationType.Call,
        },
        // 3. Open the seeding window
        {
            to: VEHEMI_PROXY,
            data: iface.encodeFunctionData("markSeedingStarted", []),
            value: "0",
            operation: OperationType.Call,
        },
        // 4. Wire the Aragon adapter
        {
            to: VVD_PROXY,
            data: iface.encodeFunctionData("setTrustedAdapter", [adapter]),
            value: "0",
            operation: OperationType.Call,
        },
    ];

    console.log("Proposing MultiSend with 4 sub-transactions:");
    for (const [i, tx] of txs.entries()) {
        console.log(`  [${i + 1}] to=${tx.to} data=${tx.data!.slice(0, 10)}...`);
    }
    console.log("");

    // Build + sign + propose via Safe protocol-kit and api-kit (same
    // primitives helpers/safe.ts uses).
    const protocolKit = await Safe.init({
        provider: process.env.PROVIDER_URL!,
        signer: process.env.DEPLOYER_PRIVATE_KEY!,
        safeAddress: SAFE_ADDR,
    });

    const safeTransaction = await protocolKit.createTransaction({
        transactions: txs,
        onlyCalls: true,
    });
    const safeTxHash = await protocolKit.getTransactionHash(safeTransaction);
    const signature = await protocolKit.signHash(safeTxHash);

    const apiKit = new SafeApiKit({
        chainId: HEMI_CHAIN_ID,
        apiKey: process.env.SAFE_API_KEY!,
    });
    const senderAddress = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY!).address;

    await apiKit.proposeTransaction({
        safeAddress: SAFE_ADDR,
        safeTransactionData: safeTransaction.data,
        safeTxHash,
        senderAddress,
        senderSignature: signature.data,
    });

    console.log(`✓ Proposed Safe transaction.`);
    console.log(`  safeTxHash: ${safeTxHash}`);
    console.log(`  senderAddress: ${senderAddress}`);
    console.log(`  Safe UI: https://app.safe.global/transactions/queue?safe=hemi:${SAFE_ADDR}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

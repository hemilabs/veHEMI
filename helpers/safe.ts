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

// Stale-batch defense:
// Script 99 (`runAtTheEnd: true`) unlinks `MULTI_SIG_TXS_FILE` only after a
// successful Safe proposal. If a prior `hardhat deploy` invocation crashed,
// was Ctrl-C'd, or was invoked with a `--tags` filter that excluded 99, the
// file persists to disk. Subsequent runs would silently append to that stale
// batch, potentially mixing yesterday's V2 upgrade tx with today's
// `setTrustedAdapter` — and the bundling pre-flight in
// `deploy/05_aragon_adapter.ts` (which checks "is the batch file non-empty?")
// would falsely report bundling-OK.
//
// Defense: when this module first loads in a Node process and a non-empty batch
// file from a prior run is on disk, move it to `<file>.stale-<time>` and refuse
// to run (a zero-byte leftover is removed silently). The file is moved, not
// deleted: it may be the only record of a queued upgrade, and re-running the
// upgrade does not re-queue it, because hardhat-deploy emits the
// `ProxyAdmin.upgrade` call only for a newly deployed implementation.
// PROPOSE_EXISTING_BATCH=1 (below) carries the file into a run that proposes it.
// Module-load timing (rather than first-save timing) is critical so that even
// `--tags`-filtered runs where no script ends up queuing a Safe tx before
// `deploy/05_aragon_adapter.ts`'s pre-flight gate check still get a clean
// slate. ESM/CJS module cache guarantees this fires exactly once per
// Node process; every deploy script that imports anything from this file
// triggers the check eagerly.
//
// Unproposed-batch exit guard. Armed once this process queues a transaction (or
// carries a batch in with PROPOSE_EXISTING_BATCH=1): if the batch file is still
// on disk when the process exits, nothing finished proposing it (a proposal
// that errored may still have reached the Safe service), so the guard says why
// and sets a non-zero exit status. The usual cause is a `--tags` filter that
// selected a queueing script but not deploy/99. `executeBatchUsingSafe` unlinks
// the file after a successful proposal, so on the happy path the guard is
// silent.
// Assigning `process.exitCode` in an `exit` listener overrides the status even
// after an explicit `process.exit(0)`.
let unproposedBatchGuardArmed = false;
const armUnproposedBatchGuard = (): void => {
    if (unproposedBatchGuardArmed) return;
    unproposedBatchGuardArmed = true;
    process.on("exit", () => {
        if (!fs.existsSync(MULTI_SIG_TXS_FILE)) return;
        let queued = 0;
        try {
            queued = (JSON.parse(fs.readFileSync(MULTI_SIG_TXS_FILE).toString()) as unknown[]).length;
        } catch {
            queued = -1; // unparseable but present: still not proposed
        }
        if (queued === 0) return;
        const bar = "=".repeat(78);
        console.error(
            chalk.red(
                `\n${bar}\n` +
                `THE DEPLOY EXITED WITHOUT CONFIRMING A SAFE PROPOSAL.\n` +
                `${bar}\n` +
                `${queued < 0 ? "An unparseable" : queued} transaction(s) were queued to\n` +
                `'${MULTI_SIG_TXS_FILE}' during this run and the file is still on disk, which\n` +
                `means 'deploy/99_safe-txs.ts' did not finish proposing them. Unless an error\n` +
                `followed "Proposing multi-sig batch transaction...", nothing is pending in the\n` +
                `Safe; if one did, the proposal may have reached the Safe service: check the\n` +
                `Safe queue and its history first. If it is there, propose nothing: get it\n` +
                `executed, then run the post-execution check (for deploy/08,\n` +
                `AUTORELOCK_POST_CHECK_ONLY=1; its first run moves this file to .stale-* and\n` +
                `refuses, so run it again). The proxies have NOT been upgraded by this run.\n\n` +
                `The usual cause is a --tags filter that selected the queueing script but not\n` +
                `script 99: hardhat-deploy filters by tag BEFORE it applies 'runAtTheEnd', so a\n` +
                `'runAtTheEnd' script that carries none of the selected tags never runs.\n\n` +
                `DO NOT "fix" this by running 'deploy --tags safe' on its own afterwards in a\n` +
                `fresh process: without PROPOSE_EXISTING_BATCH=1, any later run refuses to\n` +
                `start while this file is on disk (it moves it to .stale-* and prints what to do).\n\n` +
                `If the Safe holds no such proposal, and deploy/08 printed ORDER ASSERTED or\n` +
                `"ORDER: only the VeHemi upgrade is in this batch" (the VVD-first recovery\n` +
                `leg) for this file in this run, propose it as is:\n` +
                `PROPOSE_EXISTING_BATCH=1 npx hardhat --network <net> deploy --tags safe\n` +
                `Otherwise follow what the next run prints, then run with a tag set that\n` +
                `includes script 99's tags, in ONE process, e.g.  --tags AutoRelockUpgrade\n` +
                `(which also selects 99) or --tags <yourtag>,safe.\n` +
                `${bar}\n`
            )
        );
        process.exitCode = 1;
    });
};

// PROPOSE_EXISTING_BATCH=1 is how a restored batch gets proposed: without it,
// `--tags safe` loads this module, finds the restored file and refuses again.
// Whether a run means to append to an existing batch or to propose it cannot be
// told at module-load time without parsing argv, so the operator declares it,
// and it is announced every time. The exit guard still fires if the run does
// not actually propose.
const PROPOSE_EXISTING = process.env.PROPOSE_EXISTING_BATCH === "1";

if (fs.existsSync(MULTI_SIG_TXS_FILE) && PROPOSE_EXISTING) {
    let n: number | string = "an unparseable number of";
    try {
        n = (JSON.parse(fs.readFileSync(MULTI_SIG_TXS_FILE).toString()) as unknown[]).length;
    } catch {
        /* keep the string */
    }
    log(
        chalk.yellow(
            `\n${"=".repeat(78)}\n` +
            `[batch safety] PROPOSE_EXISTING_BATCH=1 — the stale-batch defence is OFF for\n` +
            `this process. '${MULTI_SIG_TXS_FILE}' (${n} transaction(s)) is being carried\n` +
            `into this run as-is. USE THIS ONLY FOR A RUN THAT PROPOSES AN ALREADY-QUEUED\n` +
            `BATCH AND QUEUES NOTHING OF ITS OWN. Anything this run queues will be MIXED\n` +
            `INTO that batch and signed with it.\n${"=".repeat(78)}\n`
        )
    );
    armUnproposedBatchGuard();
} else if (fs.existsSync(MULTI_SIG_TXS_FILE)) {
    const size = fs.statSync(MULTI_SIG_TXS_FILE).size;
    if (size > 0) {
        const kept = `${MULTI_SIG_TXS_FILE}.stale-${new Date().toISOString().replace(/[:.]/g, "-")}`;
        fs.renameSync(MULTI_SIG_TXS_FILE, kept);
        throw new Error(
            `\n${"=".repeat(78)}\n` +
            `[batch safety] REFUSING TO RUN: a Safe batch from a previous invocation is\n` +
            `on disk (${size} bytes). It has been MOVED, NOT DELETED, to:\n` +
            `    ${kept}\n\n` +
            `That file is the only record of transactions that were queued to the Safe\n` +
            `and not known to be proposed. This process would otherwise have appended to\n` +
            `it (cross-run contamination) or destroyed it.\n\n` +
            `WHAT TO DO\n` +
            `  * Inspect ${kept}. Restore it ONLY if (a) deploy/08 printed ORDER ASSERTED\n` +
            `    for it, it holds BOTH legs, and both proxies are still on their\n` +
            `    live implementations, or (b) it is the VVD-first recovery leg\n` +
            `    (deploy/08 printed "ORDER: only the VeHemi upgrade is in this batch"),\n` +
            `    the VVD proxy is still on that build and VeHemi is still on its\n` +
            `    live implementation. deploy/99 re-checks it against the chain,\n` +
            `    including both proxies' current implementations; never restore a\n` +
            `    .refused-* file. Then restore it with\n` +
            `        mv ${kept} ${MULTI_SIG_TXS_FILE}\n` +
            `    and propose it with\n` +
            `        PROPOSE_EXISTING_BATCH=1 npx hardhat --network <net> deploy --tags safe\n` +
            `    in a run that queues nothing else. (The env var is required: without it\n` +
            `    THIS refusal fires again on the file you just restored.)\n` +
            `  * Otherwise keep it (never rm a batch file: it may be the only record of\n` +
            `    a queued upgrade). FIRST check the Safe queue and its history. If this\n` +
            `    batch, or a docs/AUTO_RELOCK_UPGRADE.md section 9 leg of this upgrade,\n` +
            `    is pending there, change nothing here: get it executed, then run\n` +
            `    AUTORELOCK_POST_CHECK_ONLY=1. If it was already executed, just run that\n` +
            `    check. A pending rollback is never executed on this advice: follow\n` +
            `    section 8 of that file. Only if neither holds: a re-run queues nothing\n` +
            `    unless an implementation is newly deployed. While BOTH proxies are still\n` +
            `    on their live implementations, delete both\n` +
            `    deployments/<net>/*_Implementation.json records first; in any other\n` +
            `    state delete only what docs/AUTO_RELOCK_UPGRADE.md, section 9 says for it.\n` +
            `${"=".repeat(78)}\n`
        );
    }
    fs.unlinkSync(MULTI_SIG_TXS_FILE);
}

// A batch that a gate refused, or that a throw left on disk before any gate
// passed it, must not look restorable: the module-load branch above offers a
// `.stale-*` file for PROPOSE_EXISTING_BATCH=1. Move such a file to `.refused-*`,
// which nothing here offers for restore. deploy/08 calls this on any throw after
// it starts queuing; deploy/99 only on a `GateRefusal`.
export const quarantineRefusedBatch = (): void => {
    if (!fs.existsSync(MULTI_SIG_TXS_FILE)) return;
    const kept = `${MULTI_SIG_TXS_FILE}.refused-${new Date().toISOString().replace(/[:.]/g, "-")}`;
    fs.renameSync(MULTI_SIG_TXS_FILE, kept);
    console.error(chalk.red(`The queued Safe batch was REFUSED or never checked; moved to ${kept}. Do not propose it.`));
};

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

    // From here on, this process owes the operator a proposal.
    armUnproposedBatchGuard();
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
    const safeAddress = Addresses.Hemi.GNOSIS_SAFE;

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
        if (!process.env.SAFE_API_KEY) {
            throw new Error(
                "SAFE_API_KEY env var is required to propose a Safe transaction. " +
                "Get one at https://app.safe.global → Settings → API Keys."
            );
        }
        const apiKit = new SafeApiKit({ chainId, apiKey: process.env.SAFE_API_KEY });

        // Fail here, not deep inside `Safe.init`, when the signer key is unset.
        if (!process.env.DEPLOYER_PRIVATE_KEY) {
            throw new Error(
                "DEPLOYER_PRIVATE_KEY env var is required to sign and propose a Safe transaction. " +
                "It must be the private key of an account that is a delegate on the Safe."
            );
        }

        const protocolKit = await Safe.init({
            provider: provider,
            signer: process.env.DEPLOYER_PRIVATE_KEY, // Assumes that the deployer is also a delegate
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
        // The confirmation count is read from the Safe, not written down: its
        // owners and threshold can change. The read is guarded so it cannot fail
        // a batch that has already been proposed.
        let thresholdNote = "the Safe's CURRENT threshold -- read it in the Safe UI";
        try {
            const threshold = await protocolKit.getThreshold();
            thresholdNote = `${threshold} confirmation(s), the Safe's CURRENT threshold, read on chain`;
        } catch (err) {
            log(chalk.yellow(`Could not read the Safe threshold (${err}). Read it in the Safe UI.`));
        }
        log(
            chalk.blue(
                `Wait for tx to reach ${thresholdNote}; the last of them may be the executing owner's ` +
                    `own, given at execution (sign-and-execute). If this is the deploy/08 auto-relock batch, read ` +
                    `docs/AUTO_RELOCK_UPGRADE.md before executing (no execution timing is needed).`
            )
        );
        log(
            chalk.blue(
                "After execution: for the deploy/08 batch run " +
                    "`AUTORELOCK_POST_CHECK_ONLY=1 npx hardhat --network <net> deploy --tags AutoRelockUpgrade`; " +
                    "for other batches run the deployment again."
            )
        );
        log(
            chalk.blue(
                "For other batches, that re-run lets `hardhat-deploy` catch the changes and update `deployments/` files; " +
                    "for the deploy/08 batch the post-check refreshes deployments/<net>/VeHemi.json and " +
                    "VeHemiVoteDelegation.json itself after a pass."
            )
        );
    }
};

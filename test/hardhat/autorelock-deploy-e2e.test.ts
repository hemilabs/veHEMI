/**
 * Fork E2E for `deploy/08_upgrade_autorelock.ts`.
 *
 * What it proves:
 *  1. The auto-relock implementation can be produced by the repo's own
 *     tooling: both libraries deployed and their addresses embedded, no
 *     unlinked placeholder left, and both implementations' runtime code of
 *     the size attested in test/fixtures/eip170-attestation.json.
 *  2. The queued batch has exactly two legs; replaying them in order from the
 *     Safe moves both proxies, and executing them as ONE Safe MultiSend
 *     (execTransaction -> MultiSendCallOnly 1.4.1) moves both in ONE
 *     transaction (also covered by
 *     test/r31/R31UpgradeWindow.t.sol::test_R31_batchFidelity_execTransaction).
 *  3. Order. `VeHemi` must land BEFORE `VeHemiVoteDelegation`. This is
 *     asserted by execution, in both directions:
 *       * new VVD under OLD VeHemi  → `delegate()` REVERTS
 *       * new VeHemi under OLD VVD  → `delegate()` still works
 *     The first case is why `deploy/08` refuses a reversed batch.
 *  4. The post-execution check and the refusal paths of deploy/08 and
 *     deploy/99 run for real: the read-only check binds both legs to the
 *     arming transaction; pre-flight 5b refuses an unknown window word,
 *     implementation, proxy admin or Initializable state before anything is
 *     deployed; the matcher refuses each
 *     off-shape leg; a refused batch is quarantined and deploy/99 re-checks a
 *     restored one against the chain; a split forward is named and its gap
 *     audited, also when a two-leg batch completes it; a VeHemi-only batch with
 *     the VVD record still live is refused; a VVD-first gap with dropped
 *     VeHemi-driven updates fails the post-check; deploy/99 re-checks only the
 *     transition; a provider error is not a verdict and quarantines nothing;
 *     after the forward the post-check refreshes the proxy records and a plain
 *     re-run refuses; operator inputs are validated and the getLogs halving
 *     runs; the rollback limits of docs/AUTO_RELOCK_UPGRADE.md are enforced,
 *     and D1_LOGS_FROM moves the audit start earlier than the chain's floor,
 *     never later, and never to a block where the VeHemi proxy was on no live
 *     implementation.
 *  5. Gas limits, cold. After the forward each `eth_estimateGas` is its own
 *     transaction, so every slot it touches is cold: `enableAutoRelock` on a
 *     real holder's delegated position and `createLockWithAutoRelock` for a
 *     fresh minter with an auto-delegate each estimate above the removal gas
 *     floor and within the gas limit `VeHemi` documents for them with no
 *     reward distributor installed and the global point current (about 8.8
 *     and about 9.2 million); the body writes `checkpoint()` first, as the
 *     documented figures assume.
 *
 * Skipped unless HEMI_RPC_URL is set.
 */
import { expect } from "chai";
import fs from "fs";
import hre, { ethers, deployments } from "hardhat";
import type { TransactionReceipt } from "ethers";
import { reset } from "@nomicfoundation/hardhat-network-helpers";
import { MULTI_SIG_TXS_FILE } from "../../helpers/safe";
import { Addresses } from "../../helpers/addresses";
import deploy08, { GateRefusal, assertBatchOrder } from "../../deploy/08_upgrade_autorelock";
import deploy99 from "../../deploy/99_safe-txs";

const VEHEMI_PROXY = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89";
const VVD_PROXY = "0xBF5b2f370370494B8A4575962512dd3ea7c29e2d";
const PROXY_ADMIN = "0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
// The EIP-1967 admin slot and the OZ5 Initializable slot (ERC-7201), derived
// here rather than copied from deploy/08.
const ADMIN_SLOT = ethers.toBeHex(BigInt(ethers.id("eip1967.proxy.admin")) - 1n, 32);
const INITIALIZABLE_SLOT = ethers.toBeHex(
    BigInt(ethers.keccak256(ethers.toBeHex(BigInt(ethers.id("openzeppelin.storage.Initializable")) - 1n, 32))) & ~0xffn,
    32
);
const HEMI_CHAIN_ID = 43111;

const VEHEMI_ABI = [
    "function nextTokenId() view returns (uint256)",
    "function ownerOf(uint256) view returns (address)",
    "function autoRelockRemaining(uint256) view returns (uint64)",
    "function totalVeHemiSupply() view returns (uint256)",
    "function enableAutoRelock(uint256)",
    "function transferFrom(address from, address to, uint256 tokenId)",
    "function createLockWithAutoRelock(uint256 amount, uint256 lockDuration, bool transferable, bool forfeitable) returns (uint256)",
    "function rewardDistributor() view returns (address)",
    "function balanceOf(address) view returns (uint256)",
    "function checkpoint()",
];
const VVD_ABI = [
    "function delegation(uint256) view returns (tuple(address delegatee,uint48 end,uint96 bias,uint96 amount,uint64 slope))",
    "function delegate(uint256 delegator, address delegatee)",
    "function getVotes(address) view returns (uint256)",
    "function legacyDatingUntil() view returns (uint64)",
    "function setAutoDelegate(address delegatee)",
    "function autoDelegate(address) view returns (address)",
];
const ERC20_ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
];
// The VVD leg is upgradeAndCall(VVD, impl, armLegacyDatingWindow()).
const PROXY_ADMIN_IFACE = new ethers.Interface([
    "function upgrade(address proxy, address implementation)",
    "function upgradeAndCall(address proxy, address implementation, bytes data) payable",
]);
const ARM_DATA = "0x62c0fe7a";
const VVD_WINDOW_SLOT = 101;
const LIVE_VVD_IMPL = "0xAcAA0d96121C035fC21345551317d66921394128";
const LIVE_VEHEMI_IMPL = "0xf1e3AA617E5011793F759092b59d22247E57b84A";
const MULTISEND_CALL_ONLY = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"; // Safe 1.4.1
const SAFE_ABI = [
    "function getOwners() view returns (address[])",
    "function getThreshold() view returns (uint256)",
    "function nonce() view returns (uint256)",
    "function getTransactionHash(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 _nonce) view returns (bytes32)",
    "function approveHash(bytes32 hashToApprove)",
    "function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) payable returns (bool)",
];
// Pre-flight 5b's (and deploy/99's) refusal after a VeHemi-only forward that
// was rolled back over armed positions; groups: audit start block, token ids.
const VEHEMI_ONLY_ROLLBACK_REFUSAL =
    /VeHemi is on the live implementation .* but the VeHemi proxy emitted AutoRelockEnabled since block (\d+) \(token ids ([0-9, ]+)\): VeHemi was upgraded alone and rolled back over armed positions/;
const UPGRADED_TOPIC = ethers.id("Upgraded(address)");
const EXECUTION_SUCCESS_TOPIC = ethers.id("ExecutionSuccess(bytes32,uint256)");
const DELEGATION_UPDATE_FAILED_TOPIC = ethers.id("DelegationUpdateFailed(uint256)");
// VeHemi's `REMOVAL_GAS_FLOOR`, and the gas limits its NatSpec documents with
// no reward distributor installed.
const REMOVAL_GAS_FLOOR = 8_176_984n;
const ENABLE_GAS_LIMIT = 8_800_000n; // enableAutoRelock: "about 8.8 million"
const CREATE_ARMED_GAS_LIMIT = 9_200_000n; // createLockWithAutoRelock: "about 9.2 million"

const RPC = process.env.HEMI_RPC_URL;
const describeOrSkip = RPC ? describe : describe.skip;

// The expected sizes are read from `test/fixtures/eip170-attestation.json`, not
// hard-coded: it is written only by a passing `scripts/check-eip170.sh` and is
// re-verified by `test/d12/EIP170Gate.t.sol`, so it tracks every change to `src/`.
const EIP170 = JSON.parse(fs.readFileSync("test/fixtures/eip170-attestation.json").toString());
function attestedRuntimeSize(id: string): number {
    const row = EIP170.contracts?.[id];
    if (!row || typeof row.runtimeSize !== "number") {
        throw new Error(`eip170-attestation.json carries no runtimeSize for ${id} -- regenerate it with ./scripts/check-eip170.sh`);
    }
    return row.runtimeSize;
}
const VEHEMI_RUNTIME_SIZE = attestedRuntimeSize("src/VeHemi.sol:VeHemi");
const VVD_RUNTIME_SIZE = attestedRuntimeSize("src/VeHemiVoteDelegation.sol:VeHemiVoteDelegation");

type Batch = { to: string; data: string; value: string }[];

describeOrSkip("Hardhat fork: deploy/08 auto-relock upgrade → Safe MultiSend", function () {
    this.timeout(45 * 60 * 1000);

    it("produces a linked implementation and a VeHemi-first Safe batch, and the batch upgrades both proxies", async () => {
        const batch = await runUpgradeDeploy();
        expect(batch.length).to.equal(2, "the upgrade is ONE MultiSend with exactly two inner calls");
        const leg0 = PROXY_ADMIN_IFACE.parseTransaction({ data: batch[0].data })!;
        const leg1 = PROXY_ADMIN_IFACE.parseTransaction({ data: batch[1].data })!;
        expect(leg0.name).to.equal("upgrade", "leg 0 is the plain VeHemi upgrade");
        expect(leg1.name).to.equal("upgradeAndCall", "leg 1 arms the upgrade-hour window");
        expect((leg1.args[2] as string).toLowerCase()).to.equal(ARM_DATA, "leg 1 data is exactly armLegacyDatingWindow()");
        expect(BigInt(batch[1].value ?? "0")).to.equal(0n, "leg 1 carries no value");

        const veHemiImpl = (await deployments.get("VeHemi_Implementation")).address;
        const vvdImpl = (await deployments.get("VeHemiVoteDelegation_Implementation")).address;

        // The implementation really is the attested size, with no placeholder left.
        const implCode = await ethers.provider.getCode(veHemiImpl);
        expect((implCode.length - 2) / 2).to.equal(
            VEHEMI_RUNTIME_SIZE,
            "VeHemi implementation runtime size (from test/fixtures/eip170-attestation.json)"
        );
        expect(implCode).to.not.match(/__\$/, "no unlinked placeholder may reach the chain");
        expect((await ethers.provider.getCode(vvdImpl)).length / 2 - 1).to.equal(
            VVD_RUNTIME_SIZE,
            "VVD implementation runtime size (from test/fixtures/eip170-attestation.json)"
        );

        // Both libraries exist and their addresses are really embedded.
        for (const lib of ["VeHemiCurveLib", "VeHemiSupplyLib"]) {
            const a = (await deployments.get(lib)).address;
            expect(await ethers.provider.getCode(a)).to.not.equal("0x", `${lib} must have code`);
            expect(implCode.toLowerCase()).to.contain(
                a.slice(2).toLowerCase(),
                `${lib} address must appear in the VeHemi implementation`
            );
        }

        const before = await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT);
        await executeBatch(batch);
        const after = await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT);
        expect(before).to.not.equal(after);
        expect(slotToAddress(after)).to.equal(veHemiImpl.toLowerCase());
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(
            vvdImpl.toLowerCase()
        );
        const ts = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
        const vvdRead = new ethers.Contract(VVD_PROXY, VVD_ABI, ethers.provider);
        expect(await vvdRead.legacyDatingUntil()).to.equal(
            (ts / 3600n) * 3600n + 3600n,
            "the batch armed the upgrade-hour window at the execution block's next boundary"
        );

        // The new selector is live, and a real delegation still works.
        const veHemi = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, ethers.provider);
        const { tokenId, owner } = await findLiveDelegatedPosition();
        expect(await veHemi.autoRelockRemaining(tokenId)).to.equal(0n);

        const signer = await impersonate(owner);
        const vvd = new ethers.Contract(VVD_PROXY, VVD_ABI, signer);
        await (await vvd.delegate(tokenId, owner)).wait();
        console.log(`        ✓ post-upgrade delegate(${tokenId}) succeeded`);

        // The read-only post-execution check. The legs were replayed as TWO
        // transactions here, so the VeHemi binding reports a split forward; nobody
        // armed in the gap, so it is a warning, not a refusal.
        const pc = await postCheck();
        expect(pc.error, pc.error?.message).to.equal(undefined);
        expect(pc.out).to.contain("bound to the arming upgrade tx");
        expect(pc.out).to.contain("landed in SEPARATE transactions (a split forward)");
        expect(pc.out).to.contain("POST-EXECUTION CHECK: PASS WITH WARNINGS (1)");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "no batch file is left on disk (5c refuses to run with one)");
        for (const stage of ["--- Steps 1-2", "Running storage layout pre-flight", "Running EIP-170 pre-flight", "Foundry ⇄ Hardhat build cross-check"]) {
            expect(pc.out).to.not.contain(stage, `the post-check is read-only: no "${stage}"`);
        }
        // After a pass the proxy records carry the new implementation and ABI.
        expect(pc.out).to.contain("VeHemi.json and VeHemiVoteDelegation.json refreshed");
        const veRec = await deployments.get("VeHemi");
        const vvdRec = await deployments.get("VeHemiVoteDelegation");
        expect((veRec.implementation ?? "").toLowerCase()).to.equal(veHemiImpl.toLowerCase());
        expect((vvdRec.implementation ?? "").toLowerCase()).to.equal(vvdImpl.toLowerCase());
        expect(veRec.abi.some((f: { name?: string }) => f.name === "autoRelockRemaining"), "VeHemi ABI refreshed").to.equal(true);
        expect(vvdRec.abi.some((f: { name?: string }) => f.name === "legacyDatingActive"), "VVD ABI refreshed").to.equal(true);
        const again = await postCheck();
        expect(again.out).to.contain("proxy records already current");

        // A plain re-run after the forward refuses before anything is deployed.
        const rr = await capture(() => deploy08(hre));
        expect(rr.error?.message ?? "").to.match(/BOTH proxies are off their live implementations \(VeHemi .*\): the forward has executed/);
        expect(rr.out).to.not.contain("--- Steps 1-2");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
    });

    it("ORDERING, PROVEN BY EXECUTION: VVD-first bricks delegation; VeHemi-first does not", async () => {
        // ── Arm A: apply ONLY the VVD upgrade (i.e. the reversed order,
        //    caught mid-flight). New VVD, old VeHemi.
        const batch = await runUpgradeDeploy();
        const { tokenId, owner } = await findLiveDelegatedPosition();

        await executeBatch([batch[1]]); // VVD only
        const signer = await impersonate(owner);
        const vvd = new ethers.Contract(VVD_PROXY, VVD_ABI, signer);

        let reverted = false;
        try {
            await vvd.delegate.staticCall(tokenId, owner);
        } catch {
            reverted = true;
        }
        expect(reverted).to.equal(
            true,
            "new VeHemiVoteDelegation under the OLD VeHemi must revert every delegate(): " +
                "_delegate → _getNormalizedLockedInfo → veHemi.autoRelockRemaining(), not in a try, " +
                "and that selector does not exist on the live implementation"
        );
        console.log("        ✓ VVD-first: delegate() reverts, as predicted");

        // ── Arm B: now land VeHemi too. The same call must succeed.
        await executeBatch([batch[0]]);
        await vvd.delegate.staticCall(tokenId, owner);
        console.log("        ✓ after VeHemi lands, the same delegate() succeeds");

        // VVD-first in separate transactions with no dropped update is a warning.
        const pc = await postCheck();
        expect(pc.error, pc.error?.message).to.equal(undefined);
        expect(pc.out).to.contain("BEFORE VeHemi");
        expect(pc.out).to.contain("no DelegationUpdateFailed was emitted");
        expect(pc.out).to.contain("POST-EXECUTION CHECK: PASS WITH WARNINGS (1)");
    });

    it("ORDERING, other direction: new VeHemi under the OLD VVD degrades instead of reverting", async () => {
        const batch = await runUpgradeDeploy();
        const { tokenId, owner } = await findLiveDelegatedPosition();

        await executeBatch([batch[0]]); // VeHemi only — old VVD still installed
        const signer = await impersonate(owner);
        const vvd = new ethers.Contract(VVD_PROXY, VVD_ABI, signer);
        await vvd.delegate.staticCall(tokenId, owner);
        console.log("        ✓ VeHemi-first: delegate() still works against the old VoteDelegation");
    });

    it("ONE Safe MultiSend (execTransaction -> MultiSendCallOnly) binds both legs to the arming tx; post-check refusals", async () => {
        const batch = await runUpgradeDeploy();
        const veHemiImpl = (await deployments.get("VeHemi_Implementation")).address;
        const vvdImpl = (await deployments.get("VeHemiVoteDelegation_Implementation")).address;
        const rc = await executeViaSafeMultiSend(batch);
        expect(rc.logs.some((l) => l.topics[0] === EXECUTION_SUCCESS_TOPIC), "ExecutionSuccess").to.equal(true);
        const upgradedIn = (proxy: string) =>
            rc.logs.some((l) => eqAddr(l.address, proxy) && l.topics[0] === UPGRADED_TOPIC);
        expect(upgradedIn(VEHEMI_PROXY) && upgradedIn(VVD_PROXY), "both Upgraded logs in ONE receipt").to.equal(true);
        expect(slotToAddress(await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT))).to.equal(veHemiImpl.toLowerCase());
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(vvdImpl.toLowerCase());
        const ts = BigInt((await ethers.provider.getBlock(rc.blockNumber))!.timestamp);
        expect(await windowWord()).to.equal(nb(ts), "armed at the execution block's next boundary");

        const pc = await postCheck();
        expect(pc.error, pc.error?.message).to.equal(undefined);
        expect(pc.out).to.contain("bound to the arming upgrade tx");
        expect(pc.out).to.contain(`VeHemi upgraded in the same transaction (${rc.hash})`);
        expect(pc.out).to.contain("POST-EXECUTION CHECK: PASS (");

        // The chunked log search gives the same answer at a 1-block step. The
        // audit starts at the chain's floor (5,524,738), so at a later fork pin a
        // 1-block step means one getLogs per block since then: run it only near the floor.
        if (rc.blockNumber - 5_524_738 <= 5_000) {
            process.env.D1_LOGS_STEP = "1";
            const small = await postCheck();
            delete process.env.D1_LOGS_STEP;
            expect(small.error, small.error?.message).to.equal(undefined);
            expect(small.out).to.contain("POST-EXECUTION CHECK: PASS");
        } else {
            console.log(`        (1-block log step skipped: fork is ${rc.blockNumber - 5_524_738} blocks past the audit floor)`);
        }

        // Never with a batch file on disk.
        fs.writeFileSync(MULTI_SIG_TXS_FILE, "[]");
        const onDisk = await postCheck();
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        expect(onDisk.error?.message ?? "").to.match(/D1_POST_CHECK_ONLY: a Safe batch file .* is on disk; refusing/);

        // The fresh-deployment sentinel on the Hemi proxy is refused by name.
        await setWindowWord(1n);
        const sentinel = await postCheck();
        expect(sentinel.error?.message ?? "").to.match(/fresh-deployment sentinel\) on the Hemi proxy/);

        // An unaligned word is refused too.
        await setWindowWord(nb(ts) + 1n);
        const unaligned = await postCheck();
        expect(unaligned.error?.message ?? "").to.match(/is not an hour boundary/);
        await setWindowWord(nb(ts));

        // Operator inputs are validated (and so are really read).
        process.env.D1_LOGS_STEP = "0";
        const zero = await postCheck();
        delete process.env.D1_LOGS_STEP;
        expect(zero.error?.message ?? "").to.contain('D1_LOGS_STEP must be an integer >= 1 (got "0")');
        process.env.D1_POST_CHECK_ONLY = "true";
        const truthy = await capture(() => deploy08(hre));
        delete process.env.D1_POST_CHECK_ONLY;
        expect(truthy.error?.message ?? "").to.contain('D1_POST_CHECK_ONLY must be exactly "1" (got "true")');
        expect(truthy.out).to.not.contain("Running storage layout pre-flight", "no fall-through to the full deploy");

        // The halving runs. A provider that refuses ranges over
        // 2,000 blocks still yields PASS (10,000 -> 5,000 -> 2,500 -> 1,250); one
        // that refuses ranges over 100 gets its own error back once the step is 312.
        process.env.D1_LOGS_FROM = String(rc.blockNumber - 5000);
        let undo = failLargeGetLogs(2000);
        const halved = await postCheck();
        undo();
        expect(halved.error, halved.error?.message).to.equal(undefined);
        expect(halved.out).to.contain("POST-EXECUTION CHECK: PASS (");
        undo = failLargeGetLogs(100);
        const floor = await postCheck();
        undo();
        delete process.env.D1_LOGS_FROM;
        expect(floor.error?.message ?? "").to.contain("injected: eth_getLogs range");

        // After the forward a restored ARMED batch is still re-checked and refused
        // (no arming over a V4 implementation) ...
        const before99 = listRefused();
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([batch[1]]));
        const stale = await capture(() => deploy99(hre));
        expect(stale.error?.message ?? "").to.match(/which is not a boundary-dating implementation/);
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "refused and quarantined");
        for (const f of listRefused().filter((x) => !before99.includes(x))) fs.unlinkSync(f);
        // ... while a later PLAIN VVD upgrade is outside deploy/08's scope and passes through.
        const f = await ethers.getContractFactory("VeHemiVoteDelegation");
        const nextImpl = await f.deploy(VEHEMI_PROXY);
        await nextImpl.waitForDeployment();
        const nextAddr = await nextImpl.getAddress();
        fs.writeFileSync(
            MULTI_SIG_TXS_FILE,
            JSON.stringify([{ to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VVD_PROXY, nextAddr]), value: "0" }])
        );
        const later = await capture(() => deploy99(hre));
        expect(later.error, later.error?.message).to.equal(undefined);
        expect(later.out).to.contain("proposed WITHOUT deploy/08's re-check");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "deploy/99 proposed (executed) it");
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(nextAddr.toLowerCase());
    });

    it("a PLAIN VVD leg is caught by the post-check (NEVER ARMED)", async () => {
        // This body pins the virgin-window path; at a pin after an in-window
        // rollback slot 101 holds the old boundary.
        const batch = await runUpgradeDeploy({ before: () => setWindowWord(0n) });
        const vvdImpl = (await deployments.get("VeHemiVoteDelegation_Implementation")).address;
        await executeBatch([
            batch[0],
            { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VVD_PROXY, vvdImpl]), value: "0" },
        ]);
        expect(await windowWord()).to.equal(0n);
        const pc = await postCheck();
        expect(pc.error?.message ?? "").to.match(/NEVER ARMED/);
    });

    it("a window word left by an earlier armed forward is admitted, overwritten by the arm, and deploy/99 re-checks and executes the batch", async () => {
        // An hour boundary two hours back, as an earlier armed forward would leave it.
        const batch = await runUpgradeDeploy({
            before: async () => setWindowWord(nb(BigInt((await ethers.provider.getBlock("latest"))!.timestamp)) - 7200n),
        });
        expect(lastDeployLog).to.match(/window word from an earlier armed forward \(rollback\), nothing armed since block \d+; this batch's arm overwrites it/);
        const leg1 = PROXY_ADMIN_IFACE.parseTransaction({ data: batch[1].data })!;
        expect(leg1.name).to.equal("upgradeAndCall");
        expect((leg1.args[2] as string).toLowerCase()).to.equal(ARM_DATA);

        // Accepting side: the proposer re-checks the two-leg batch against
        // the chain, then (on the hardhat network) executes it as the Safe.
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(batch));
        const r = await capture(() => deploy99(hre));
        expect(r.error, r.error?.message).to.equal(undefined);
        expect(r.out).to.contain("ORDER ASSERTED");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "deploy/99 consumed the batch");
        const vvdImpl = (await deployments.get("VeHemiVoteDelegation_Implementation")).address;
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(vvdImpl.toLowerCase());
        const ts = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
        expect(await windowWord()).to.equal(nb(ts), "the arm overwrote the old word with this execution's boundary");
        const pc = await postCheck();
        expect(pc.error, pc.error?.message).to.equal(undefined);
        // On the hardhat network deploy/99 replays the legs as two transactions.
        expect(pc.out).to.contain("POST-EXECUTION CHECK: PASS WITH WARNINGS (1)");
    });

    it("an unknown window word is refused before anything is deployed", async () => {
        await setupFork();
        await setWindowWord(7201n);
        const before = listRefused();
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.match(/VVD storage slot 101 is 7201: neither 0 nor an hour boundary/);
        expect(r.out).to.not.contain("--- Steps 1-2");
        expect((await deployments.getOrNull("VeHemiCurveLib")) ?? null).to.equal(null, "no library was deployed");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        expect(listRefused()).to.deep.equal(before, "nothing was queued, so nothing is quarantined");
    });

    it("a VVD proxy on an unknown implementation is refused before anything is deployed", async () => {
        await setupFork();
        const f = await ethers.getContractFactory("VeHemiVoteDelegation");
        const stray = await f.deploy(VEHEMI_PROXY);
        await stray.waitForDeployment();
        await ethers.provider.send("hardhat_setStorageAt", [
            VVD_PROXY,
            IMPL_SLOT,
            ethers.zeroPadValue(await stray.getAddress(), 32),
        ]);
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.match(/Refusing before anything is deployed/);
        expect((await deployments.getOrNull("VeHemiCurveLib")) ?? null).to.equal(null, "no library was deployed");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
    });

    it("pre-flight 5b: a VVD proxy whose EIP-1967 admin is not the ProxyAdmin is refused before anything is deployed", async () => {
        await setupFork();
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, ADMIN_SLOT))).to.equal(PROXY_ADMIN.toLowerCase(), "premise: the live admin");
        const STRAY_ADMIN = "0x00000000000000000000000000000000000ad311";
        await ethers.provider.send("hardhat_setStorageAt", [VVD_PROXY, ADMIN_SLOT, ethers.zeroPadValue(STRAY_ADMIN, 32)]);
        const before = listRefused();
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.match(
            new RegExp(`VVD proxy admin \\(EIP-1967\\) is ${STRAY_ADMIN}, expected the ProxyAdmin ${PROXY_ADMIN}`, "i")
        );
        expect(r.out).to.not.contain("--- Steps 1-2");
        expect((await deployments.getOrNull("VeHemiCurveLib")) ?? null).to.equal(null, "no library was deployed");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        expect(listRefused()).to.deep.equal(before, "nothing was queued, so nothing is quarantined");
    });

    it("pre-flight 5b: a VVD proxy whose Initializable state is not _initialized == 1 is refused before anything is deployed", async () => {
        await setupFork();
        expect(BigInt(await ethers.provider.getStorage(VVD_PROXY, INITIALIZABLE_SLOT))).to.equal(1n, "premise: _initialized == 1");
        // A reinitializer(2) would leave this word.
        await ethers.provider.send("hardhat_setStorageAt", [VVD_PROXY, INITIALIZABLE_SLOT, ethers.toBeHex(2n, 32)]);
        const before = listRefused();
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.contain("VVD Initializable state is 2, expected _initialized == 1 and _initializing == 0");
        expect(r.out).to.not.contain("--- Steps 1-2");
        expect((await deployments.getOrNull("VeHemiCurveLib")) ?? null).to.equal(null, "no library was deployed");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        expect(listRefused()).to.deep.equal(before, "nothing was queued, so nothing is quarantined");
    });

    it("the matcher refuses every off-shape leg; the post-check refuses an unrun forward", async () => {
        await setupFork();
        const pre = await postCheck();
        expect(pre.error?.message ?? "").to.match(/steps 3-4 never deployed this build's implementations/);

        const X = "0x00000000000000000000000000000000000ab0c1";
        const Y = "0x00000000000000000000000000000000000ab0c2";
        const expected = { proxyAdmin: PROXY_ADMIN, veHemiProxy: VEHEMI_PROXY, veHemiImpl: X, vvdProxy: VVD_PROXY, vvdImpl: Y };
        const up = (proxy: string, impl: string, value = "0") => ({
            to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [proxy, impl]), value,
        });
        const upCall = (proxy: string, impl: string, data: string, value = "0") => ({
            to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgradeAndCall", [proxy, impl, data]), value,
        });
        const armed = upCall(VVD_PROXY, Y, ARM_DATA);
        const cases: [string, Batch, RegExp][] = [
            ["VeHemi upgradeAndCall", [upCall(VEHEMI_PROXY, X, "0x"), armed], /the VeHemi leg must be a plain upgrade\(\) with value 0/],
            ["VeHemi value 1", [up(VEHEMI_PROXY, X, "1"), armed], /the VeHemi leg must be a plain upgrade\(\) with value 0/],
            ["VeHemi wrong impl", [up(VEHEMI_PROXY, Y), armed], /Safe batch upgrades VeHemi to .*, but this build's implementation is/],
            ["plain VVD leg", [up(VEHEMI_PROXY, X), up(VVD_PROXY, Y)], /window would not be armed/],
            ["VVD wrong data", [up(VEHEMI_PROXY, X), upCall(VVD_PROXY, Y, ARM_DATA + "00")], /expected exactly 0x62c0fe7a/],
            ["VVD value 1", [up(VEHEMI_PROXY, X), upCall(VVD_PROXY, Y, ARM_DATA, "1")], /the arm is non-payable/],
            ["reversed", [armed, up(VEHEMI_PROXY, X)], /SAFE BATCH ORDER IS REVERSED/],
            ["extra leg", [up(VEHEMI_PROXY, X), armed, { to: VVD_PROXY, data: "0x", value: "0" }], /LEGS THIS GATE DID NOT ACCOUNT FOR/],
            ["VVD-only, VeHemi not upgraded", [armed], /WITHOUT THE VeHemi UPGRADE/],
            // Refusals the deploy/99 re-check relies on.
            ["VeHemi-only, VVD not upgraded", [up(VEHEMI_PROXY, X)], /HALF A BATCH/],
            ["VVD wrong impl", [up(VEHEMI_PROXY, X), upCall(VVD_PROXY, X, ARM_DATA)], /Safe batch upgrades VVD to .*, but this build's implementation is/],
            ["unparseable value", [up(VEHEMI_PROXY, X, "abc"), armed], /carries an unparseable value/],
        ];
        for (const [name, legs, re] of cases) {
            fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(legs));
            const r = await capture(() => assertBatchOrder(hre, expected));
            fs.unlinkSync(MULTI_SIG_TXS_FILE);
            expect(r.error?.message ?? `<accepted>`, name).to.match(re);
        }
        // The accepted shape, as a control for the cases above.
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([up(VEHEMI_PROXY, X), armed]));
        const ok = await capture(() => assertBatchOrder(hre, expected));
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        expect(ok.error, ok.error?.message).to.equal(undefined);
        expect(ok.out).to.contain("ORDER ASSERTED: VeHemi index 0 < VoteDelegation index 1");
        // A VeHemi-only batch whose VVD "is already on this build" only
        // because the record still names the live VVD (step 4 never ran).
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([up(VEHEMI_PROXY, X)]));
        const half = await capture(() => assertBatchOrder(hre, { ...expected, vvdImpl: LIVE_VVD_IMPL }));
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        expect(half.error?.message ?? "").to.match(/HALF A BATCH/);
        expect(half.error instanceof GateRefusal, "a refusal is a GateRefusal").to.equal(true);
        // The VeHemi leg runs only over the live VeHemi.
        await ethers.provider.send("hardhat_setStorageAt", [VEHEMI_PROXY, IMPL_SLOT, ethers.zeroPadValue(X, 32)]);
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([up(VEHEMI_PROXY, X), armed]));
        const veOff = await capture(() => assertBatchOrder(hre, expected));
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        await ethers.provider.send("hardhat_setStorageAt", [VEHEMI_PROXY, IMPL_SLOT, ethers.zeroPadValue(LIVE_VEHEMI_IMPL.toLowerCase(), 32)]);
        expect(veOff.error?.message ?? "").to.match(/Safe batch upgrades VeHemi from .* which is not the live implementation/);
        // From-implementation: the arm runs only over the boundary-dating VVD.
        await ethers.provider.send("hardhat_setStorageAt", [VVD_PROXY, IMPL_SLOT, ethers.zeroPadValue(Y, 32)]);
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([up(VEHEMI_PROXY, X), armed]));
        const from = await capture(() => assertBatchOrder(hre, expected));
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        expect(from.error?.message ?? "").to.match(/which is not a boundary-dating implementation/);

        // Re-check scope: a ProxyAdmin batch that upgrades neither proxy is not
        // deploy/08's and is proposed without its re-check. (Re-checked, this
        // pre-forward state would fail "NEVER ARMED".) ProxyAdmin.owner() is a
        // harmless leg.
        await ethers.provider.send("hardhat_setStorageAt", [VVD_PROXY, IMPL_SLOT, ethers.zeroPadValue(LIVE_VVD_IMPL.toLowerCase(), 32)]);
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([{ to: PROXY_ADMIN, data: "0x8da5cb5b", value: "0" }]));
        const other = await capture(() => deploy99(hre));
        expect(other.error, other.error?.message).to.equal(undefined);
        expect(other.out).to.not.contain("ORDER ASSERTED");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "deploy/99 proposed (executed) it");
    });

    it("a refused one-leg VVD batch is quarantined, and deploy/99 refuses it again when restored", async () => {
        await runUpgradeDeploy();
        await deployments.delete("VeHemiVoteDelegation_Implementation");
        const before = listRefused();
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.match(/WITHOUT THE VeHemi UPGRADE/);
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "the refused batch is not left in place");
        const made = listRefused().filter((f) => !before.includes(f));
        expect(made.length).to.equal(1, "exactly one .refused-* file");

        // Restored anyway, as if it were a `.stale-*` file, and proposed.
        fs.renameSync(made[0], MULTI_SIG_TXS_FILE);
        const vvdBefore = await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT);
        expect(slotToAddress(vvdBefore)).to.equal(LIVE_VVD_IMPL.toLowerCase());
        const p = await capture(() => deploy99(hre));
        expect(p.error?.message ?? "").to.match(/WITHOUT THE VeHemi UPGRADE/);
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        expect(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT)).to.equal(vvdBefore, "nothing was executed");
        for (const f of listRefused().filter((x) => !before.includes(x))) fs.unlinkSync(f);
    });

    it("a split forward is named, its gap audited, and a position armed in the gap fails the post-check", async () => {
        const batch = await runUpgradeDeploy();
        const veHemiImpl = (await deployments.get("VeHemi_Implementation")).address;
        const vvdImpl = (await deployments.get("VeHemiVoteDelegation_Implementation")).address;
        await executeBatch([batch[0]]); // VeHemi only: new VeHemi over the live VVD
        const armedId = await armSomePosition(); // the window probe fails OPEN against the live VVD
        console.log(`        ✓ armed token ${armedId} in the split gap (the window probe fails open against the live VVD)`);

        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([batch[1]]));
        const r = await capture(() =>
            assertBatchOrder(hre, { proxyAdmin: PROXY_ADMIN, veHemiProxy: VEHEMI_PROXY, veHemiImpl, vvdProxy: VVD_PROXY, vvdImpl })
        );
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        expect(r.error?.message ?? "").to.match(/SPLIT FORWARD/);
        expect(r.error?.message ?? "").to.match(new RegExp(`AutoRelockEnabled from the VeHemi proxy since block \\d+: ${armedId}\n`));
        // On this path (deploy/99's re-check, no deploy/08 pre-flight) the
        // log search itself validates D1_LOGS_STEP.
        process.env.D1_LOGS_STEP = "0";
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([batch[1]]));
        const badStep = await capture(() =>
            assertBatchOrder(hre, { proxyAdmin: PROXY_ADMIN, veHemiProxy: VEHEMI_PROXY, veHemiImpl, vvdProxy: VVD_PROXY, vvdImpl })
        );
        fs.unlinkSync(MULTI_SIG_TXS_FILE);
        delete process.env.D1_LOGS_STEP;
        expect(badStep.error?.message ?? "").to.contain('D1_LOGS_STEP must be an integer >= 1 (got "0")');

        await executeBatch([batch[1]]); // the VVD leg, in a LATER transaction
        const pc = await postCheck();
        expect(pc.error?.message ?? "").to.match(/AutoRelockEnabled from the VeHemi proxy BEFORE the VVD arm/);
        expect(pc.error?.message ?? "").to.contain(`token ids ${armedId}.`);
    });

    it("a split forward completed by a TWO-leg batch is refused before proposal and, executed anyway, fails the post-check", async () => {
        // This body pins the virgin-window path; at a pin after an in-window
        // rollback slot 101 holds the old boundary.
        const batch = await runUpgradeDeploy({ before: () => setWindowWord(0n) });
        await executeBatch([batch[0]]); // VeHemi only: new VeHemi over the live VVD
        const armedId = await armSomePosition();
        console.log(`        ✓ armed token ${armedId} in the split gap`);

        // The restore path: the full two-leg batch, re-checked by deploy/99.
        const before = listRefused();
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(batch));
        const g = await capture(() => deploy99(hre));
        expect(g.error?.message ?? "").to.match(/Safe batch upgrades VeHemi from .* which is not the live implementation/);
        expect(g.out).to.not.contain("ORDER ASSERTED");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "refused and quarantined");
        for (const f of listRefused().filter((x) => !before.includes(x))) fs.unlinkSync(f);

        // Proposed by hand anyway: the VeHemi re-upgrade lands in the arming transaction.
        const rc = await executeViaSafeMultiSend(batch);
        expect(rc.logs.some((l) => eqAddr(l.address, VEHEMI_PROXY) && l.topics[0] === UPGRADED_TOPIC), "re-upgrade in the arm tx").to.equal(true);
        const pc = await postCheck();
        expect(pc.error?.message ?? "").to.match(/AutoRelockEnabled from the VeHemi proxy BEFORE the VVD arm/);
        expect(pc.error?.message ?? "").to.contain(`token ids ${armedId}.`);
        expect(pc.out).to.not.contain("POST-EXECUTION CHECK: PASS");
    });

    it("VVD-first in separate transactions: an update the live VeHemi dropped in the gap fails the post-check", async () => {
        const batch = await runUpgradeDeploy();
        await executeBatch([batch[1]]); // VVD only: the new VVD under the live VeHemi
        const { tokenId, rc } = await transferSomePositionDroppingTheUpdate();
        console.log(`        ✓ token ${tokenId} transferred in the gap; the live VeHemi emitted DelegationUpdateFailed`);
        await executeBatch([batch[0]]);
        const pc = await postCheck();
        expect(pc.error?.message ?? "").to.match(/BEFORE VeHemi/);
        expect(pc.error?.message ?? "").to.contain(`(DelegationUpdateFailed, token ids ${tokenId})`);
        expect(
            rc.logs.some((l) => l.topics[0] === DELEGATION_UPDATE_FAILED_TOPIC && BigInt(l.topics[1]) === BigInt(tokenId)),
            "the dropped update names the transferred token"
        ).to.equal(true);
    });

    it("deploy/99 refuses a VeHemi-only batch while the VVD record is live; a provider error is not a verdict", async () => {
        const batch = await runUpgradeDeploy();
        const before = listRefused();

        // The file step 3 saved, with the process killed before step 4
        // overwrote the VVD record (the record still names the live VVD).
        const vvdRec = await deployments.get("VeHemiVoteDelegation_Implementation");
        await deployments.save(
            "VeHemiVoteDelegation_Implementation",
            JSON.parse(fs.readFileSync(`${__dirname}/../../deployments/hemi/VeHemiVoteDelegation_Implementation.json`, "utf8"))
        );
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([batch[0]]));
        const h = await capture(() => deploy99(hre));
        expect(h.error?.message ?? "").to.match(/HALF A BATCH/);
        expect(h.out).to.not.contain("VERIFIED to be on this build's implementation already");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "a gate refusal is quarantined");
        expect(listRefused().length).to.equal(before.length + 1);
        for (const f of listRefused().filter((x) => !before.includes(x))) fs.unlinkSync(f);
        await deployments.save("VeHemiVoteDelegation_Implementation", vvdRec);

        // A provider error during the re-check propagates as itself and leaves
        // a correct batch in place. deploy/99's scope read is the 1st VVD-slot read;
        // assertBatchOrder's is the 2nd.
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(batch));
        let undo = failStorageRead(VVD_PROXY, IMPL_SLOT, 2);
        const e = await capture(() => deploy99(hre));
        undo();
        expect(e.error?.message ?? "").to.contain("injected provider failure");
        expect(e.error instanceof GateRefusal).to.equal(false);
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(true, "not quarantined");
        expect(listRefused()).to.deep.equal(before);
        // The same read inside assertBatchOrder alone: an error, not HALF A BATCH.
        const veHemiImpl = (await deployments.get("VeHemi_Implementation")).address;
        undo = failStorageRead(VVD_PROXY, IMPL_SLOT, 1);
        const a = await capture(() =>
            assertBatchOrder(hre, { proxyAdmin: PROXY_ADMIN, veHemiProxy: VEHEMI_PROXY, veHemiImpl, vvdProxy: VVD_PROXY, vvdImpl: vvdRec.address })
        );
        undo();
        expect(a.error?.message ?? "").to.contain("injected provider failure");
        expect(a.error?.message ?? "").to.not.match(/HALF A BATCH/);
        // Once the provider recovers, the same file is re-checked and proposed (executed).
        const ok = await capture(() => deploy99(hre));
        expect(ok.error, ok.error?.message).to.equal(undefined);
        expect(ok.out).to.contain("ORDER ASSERTED");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
    });
    it("rollback limits: a re-forward over a rollback with armed positions is refused before anything is deployed", async () => {
        const batch = await runUpgradeDeploy();
        await executeViaSafeMultiSend(batch);
        const B = await windowWord();
        await ethers.provider.send("evm_setNextBlockTimestamp", [Number(B) + 1]);
        await ethers.provider.send("evm_mine", []);
        const armedId = await armSomePosition();
        console.log(`        ✓ armed token ${armedId} after the window closed`);
        // The rollback the runbook forbids once anything is armed: both plain legs.
        await executeBatch([
            { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VVD_PROXY, LIVE_VVD_IMPL]), value: "0" },
            { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VEHEMI_PROXY, LIVE_VEHEMI_IMPL]), value: "0" },
        ]);
        expect(await windowWord()).to.equal(B, "the rollback leaves the window word behind");
        // The re-forward recipe: delete both implementation records and re-run.
        await deployments.delete("VeHemi_Implementation");
        await deployments.delete("VeHemiVoteDelegation_Implementation");
        const before = listRefused();
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.contain("a re-forward over a rollback with armed positions");
        expect(r.error?.message ?? "").to.contain(`token ids ${armedId})`);
        expect(r.out).to.not.contain("--- Steps 1-2");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        expect(listRefused()).to.deep.equal(before, "nothing was queued, so nothing is quarantined");
    });

    it("rollback limits: a VeHemi-leg rollback is refused by pre-flight 5b and, re-forwarded by hand anyway, fails the post-check", async () => {
        const batch = await runUpgradeDeploy();
        const veHemiImpl = (await deployments.get("VeHemi_Implementation")).address;
        await executeViaSafeMultiSend(batch);
        // VeHemi alone back on the live implementation; the VVD stays on this build.
        await executeBatch([
            { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VEHEMI_PROXY, LIVE_VEHEMI_IMPL]), value: "0" },
        ]);
        const { tokenId } = await transferSomePositionDroppingTheUpdate();
        console.log(`        ✓ token ${tokenId} transferred under the rolled-back VeHemi; its VVD update was dropped`);
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.match(/a VeHemi-leg\s+rollback/);
        expect(r.out).to.not.contain("--- Steps 1-2");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        // Re-forwarded by hand anyway.
        await executeBatch([
            { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VEHEMI_PROXY, veHemiImpl]), value: "0" },
        ]);
        const pc = await postCheck();
        expect(pc.error?.message ?? "").to.match(/upgraded AWAY from this build after the arm/);
        expect(pc.error?.message ?? "").to.match(new RegExp(`DelegationUpdateFailed since it: [0-9, ]*\\b${tokenId}\\b`));
        expect(pc.out).to.not.contain("POST-EXECUTION CHECK: PASS");
    });

    it("rollback limits: a VeHemi-only forward rolled back over armed positions is refused by pre-flight 5b, also with D1_LOGS_FROM after the arm or before the floor; an audit start on no live implementation is refused", async () => {
        // This body pins the virgin-window path; at a pin after an in-window
        // rollback slot 101 holds the old boundary.
        await runUpgradeDeploy({ before: () => setWindowWord(0n) });
        // The first forward already runs this audit (virgin window word, VeHemi live).
        expect(lastDeployLog).to.match(/slot 101 = 0 and VeHemi on the live implementation, nothing armed since block \d+/);
        const armedId = await armUnderVeHemiOnlyForwardThenRollBack();
        const refusal = VEHEMI_ONLY_ROLLBACK_REFUSAL;
        const before = listRefused();
        // A plain re-run, then the re-forward recipe (both implementation records deleted).
        const plain = await capture(() => deploy08(hre));
        expect(plain.error?.message ?? "").to.match(refusal);
        await deployments.delete("VeHemi_Implementation");
        await deployments.delete("VeHemiVoteDelegation_Implementation");
        const r = await capture(() => deploy08(hre));
        const m = (r.error?.message ?? "").match(refusal);
        expect(m, r.error?.message).to.not.equal(null);
        expect(m![2].split(", ")).to.include(String(armedId));
        expect(r.out).to.not.contain("--- Steps 1-2");
        expect((await deployments.getOrNull("VeHemi_Implementation")) ?? null).to.equal(null, "no implementation was deployed");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false);
        expect(listRefused()).to.deep.equal(before, "nothing was queued, so nothing is quarantined");

        // D1_LOGS_FROM can move the audit start earlier than the chain's floor,
        // never later: set after the arm, it is clamped to the floor and the
        // armed id is still found.
        const head = await ethers.provider.getBlockNumber();
        if (head >= 5_524_738) {
            process.env.D1_LOGS_FROM = String(head);
            const late = await capture(() => deploy08(hre));
            delete process.env.D1_LOGS_FROM;
            const lm = (late.error?.message ?? "").match(refusal);
            expect(lm, late.error?.message).to.not.equal(null);
            expect(Number(lm![1])).to.equal(5_524_738, "the audit start is clamped to the floor, not D1_LOGS_FROM");
            expect(lm![2].split(", ")).to.include(String(armedId));
            expect(late.out).to.not.contain("--- Steps 1-2");
            // Set before the floor it is honoured: the audit starts there.
            process.env.D1_LOGS_FROM = String(5_524_737);
            const early = await capture(() => deploy08(hre));
            delete process.env.D1_LOGS_FROM;
            const em = (early.error?.message ?? "").match(refusal);
            expect(em, early.error?.message).to.not.equal(null);
            expect(Number(em![1])).to.equal(5_524_737, "an earlier D1_LOGS_FROM moves the audit start earlier");
            expect(em![2].split(", ")).to.include(String(armedId));
            expect(early.out).to.not.contain("--- Steps 1-2");
        } else {
            console.log(`        (D1_LOGS_FROM clamp and earlier start skipped: fork head ${head} is below the audit floor)`);
        }

        // An earlier start is safe only if the VeHemi proxy was already on a
        // live implementation there, which cannot emit AutoRelockEnabled. That
        // premise is read: at block 1 the proxy had no implementation at all.
        process.env.D1_LOGS_FROM = "1";
        const genesis = await capture(() => deploy08(hre));
        delete process.env.D1_LOGS_FROM;
        expect(genesis.error?.message ?? "").to.match(
            /must start at a block where the VeHemi proxy was on a live implementation .*; at block 1 it was on 0x0{40}\./
        );
        expect(genesis.out).to.not.contain("--- Steps 1-2");
    });

    it("rollback limits: deploy/99 refuses a restored two-leg batch after a VeHemi-only forward rolled back over armed positions", async () => {
        // This body pins the virgin-window path; at a pin after an in-window
        // rollback slot 101 holds the old boundary.
        const batch = await runUpgradeDeploy({ before: () => setWindowWord(0n) });
        const armedId = await armUnderVeHemiOnlyForwardThenRollBack();
        // The proposing run's two-leg batch, restored (`mv ….stale-<ts> …` and
        // PROPOSE_EXISTING_BATCH=1): deploy/99 re-checks it without deploy/08's
        // pre-flights, and the batch shape alone is still the accepted one.
        const before = listRefused();
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(batch));
        const r = await capture(() => deploy99(hre));
        const m = (r.error?.message ?? "").match(VEHEMI_ONLY_ROLLBACK_REFUSAL);
        expect(m, r.error?.message).to.not.equal(null);
        expect(m![2].split(", ")).to.include(String(armedId));
        expect(r.error?.message ?? "").to.contain("Refusing to propose this batch.");
        expect(r.error instanceof GateRefusal, "a refusal is a GateRefusal").to.equal(true);
        expect(r.out).to.not.contain("ORDER ASSERTED");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "refused and quarantined");
        const made = listRefused().filter((f) => !before.includes(f));
        expect(made.length).to.equal(1, "exactly one .refused-* file");
        for (const f of made) fs.unlinkSync(f);
        expect(slotToAddress(await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT))).to.equal(LIVE_VEHEMI_IMPL.toLowerCase(), "nothing was executed");
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(LIVE_VVD_IMPL.toLowerCase(), "nothing was executed");
    });

    it("rollback limits: deploy/99 refuses a restored VeHemi-only batch after a VeHemi-leg rollback with the VVD on this build", async () => {
        const batch = await runUpgradeDeploy();
        const vvdImpl = (await deployments.get("VeHemiVoteDelegation_Implementation")).address;
        await executeViaSafeMultiSend(batch);
        // VeHemi alone back on the live implementation; the VVD stays on this build.
        await executeBatch([
            { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VEHEMI_PROXY, LIVE_VEHEMI_IMPL]), value: "0" },
        ]);
        expect(slotToAddress(await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT))).to.equal(LIVE_VEHEMI_IMPL.toLowerCase());
        expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(vvdImpl.toLowerCase());
        // A restored one-leg VeHemi batch: the shape the VVD-first recovery
        // proposes, and one `assertBatchOrder` accepts while the VVD is on this build.
        const before = listRefused();
        fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([batch[0]]));
        const r = await capture(() => deploy99(hre));
        expect(r.error?.message ?? "").to.match(
            /and is back on the live implementation .* while the VVD is on this build: a VeHemi-leg\s+rollback\. Re-forwarding VeHemi alone is not a repair\. Refusing to propose this batch\./
        );
        expect(r.error instanceof GateRefusal, "a refusal is a GateRefusal").to.equal(true);
        expect(r.out).to.not.contain("only the VeHemi upgrade is in this batch");
        expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(false, "refused and quarantined");
        const made = listRefused().filter((f) => !before.includes(f));
        expect(made.length).to.equal(1, "exactly one .refused-* file");
        for (const f of made) fs.unlinkSync(f);
        expect(slotToAddress(await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT))).to.equal(LIVE_VEHEMI_IMPL.toLowerCase(), "nothing was executed");
    });

    it("rollback limits, control: the VVD-first recovery state (VeHemi never upgraded) is not mistaken for a VeHemi-leg rollback", async () => {
        const batch = await runUpgradeDeploy();
        await executeBatch([batch[1]]); // the VVD leg alone
        const r = await capture(() => deploy08(hre));
        expect(r.error?.message ?? "").to.not.match(/VeHemi-leg|re-forward over a rollback/);
        expect(r.error?.message ?? "").to.match(/THIS RUN QUEUED NOTHING/);
    });

    it("gas limits, cold: after the forward, enableAutoRelock on a live delegated position and createLockWithAutoRelock with an auto-delegate estimate within the documented limits", async () => {
        const batch = await runUpgradeDeploy();
        await executeViaSafeMultiSend(batch);
        // Arming is refused until the upgrade-hour window closes.
        const B = await windowWord();
        await ethers.provider.send("evm_setNextBlockTimestamp", [Number(B) + 1]);
        await ethers.provider.send("evm_mine", []);
        const veHemiRead = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, ethers.provider);
        expect(await veHemiRead.rewardDistributor()).to.equal(ethers.ZeroAddress, "the documented limits assume no reward distributor");
        // They also assume the global point is current: write it in its own transaction
        // (each estimate below is still its own, cold, transaction).
        await (await new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, await impersonate("0x00000000000000000000000000000000000c0ffe")).checkpoint()).wait();

        // Each estimate below is its own transaction, so every slot it touches is cold.
        // (a) A real holder arms a position that was live and delegated at the fork block.
        const { tokenId, owner, delegatee } = await findArmableDelegatedPosition();
        const asOwner = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, await impersonate(owner));
        const enableGas = await asOwner.enableAutoRelock.estimateGas(tokenId);
        console.log(
            `        enableAutoRelock(${tokenId}) by ${owner} (${await veHemiRead.balanceOf(owner)} position(s), delegated to ${delegatee}): eth_estimateGas ${enableGas}`
        );

        // (b) A fresh minter whose auto-delegate is that delegatee creates an armed lock.
        const minter = "0x00000000000000000000000000000000000c01d1";
        const amount = ethers.parseEther("1000");
        await setHemiBalance(minter, amount);
        const asMinter = await impersonate(minter);
        await (await new ethers.Contract(Addresses.Hemi.HEMI_TOKEN, ERC20_ABI, asMinter).approve(VEHEMI_PROXY, amount)).wait();
        await (await new ethers.Contract(VVD_PROXY, VVD_ABI, asMinter).setAutoDelegate(delegatee)).wait();
        expect(await new ethers.Contract(VVD_PROXY, VVD_ABI, ethers.provider).autoDelegate(minter)).to.equal(delegatee);
        const createGas = await new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, asMinter).createLockWithAutoRelock.estimateGas(
            amount,
            4 * 365 * 86400,
            true,
            false
        );
        console.log(`        createLockWithAutoRelock(1000 HEMI, 4 years) by a fresh minter auto-delegating to ${delegatee}: eth_estimateGas ${createGas}`);

        expect(enableGas > REMOVAL_GAS_FLOOR, `enableAutoRelock estimate ${enableGas} must pass the removal gas floor`).to.equal(true);
        expect(createGas > REMOVAL_GAS_FLOOR, `createLockWithAutoRelock estimate ${createGas} must pass the removal gas floor`).to.equal(true);
        expect(enableGas <= ENABLE_GAS_LIMIT, `enableAutoRelock estimate ${enableGas} exceeds the documented ${ENABLE_GAS_LIMIT}`).to.equal(true);
        expect(
            createGas <= CREATE_ARMED_GAS_LIMIT,
            `createLockWithAutoRelock estimate ${createGas} exceeds the documented ${CREATE_ARMED_GAS_LIMIT}`
        ).to.equal(true);
    });
});

// ── helpers ────────────────────────────────────────────────────────────────

function slotToAddress(slot: string): string {
    return "0x" + slot.slice(-40).toLowerCase();
}

async function impersonate(addr: string) {
    await ethers.provider.send("hardhat_impersonateAccount", [addr]);
    await ethers.provider.send("hardhat_setBalance", [addr, "0x3635C9ADC5DEA00000"]);
    return await ethers.getSigner(addr);
}

async function setupFork() {
    await reset(RPC!, Number(process.env.HEMI_FORK_BLOCK) || undefined);
    const chainId = (await ethers.provider.getNetwork()).chainId;
    expect(chainId).to.equal(BigInt(HEMI_CHAIN_ID));

    // Drop anything a PREVIOUS body deployed. `deployments.run(..., {
    // resetMemory: false })` is required so the mainnet fixtures below survive,
    // but it also keeps last body's records — whose `transactionHash` values do
    // not exist on the freshly-reset fork, so hardhat-deploy's `fetchIfDifferent`
    // stalls resolving them against the remote RPC.
    for (const stale of [
        "VeHemiCurveLib",
        "VeHemiSupplyLib",
        "VeHemi_Implementation",
        "VeHemiVoteDelegation_Implementation",
    ]) {
        try {
            await deployments.delete(stale);
        } catch {
            /* not present on the first body */
        }
    }

    const base = `${__dirname}/../../deployments/hemi`;
    for (const name of [
        "VeHemi",
        "VeHemi_Proxy",
        "VeHemi_Implementation",
        "VeHemiVoteDelegation",
        "VeHemiVoteDelegation_Proxy",
        "VeHemiVoteDelegation_Implementation",
        "DefaultProxyAdmin",
    ]) {
        await deployments.save(name, JSON.parse(fs.readFileSync(`${base}/${name}.json`, "utf8")));
    }
}

/** Fresh fork + a full `deploy/08` run; returns the queued Safe batch.
 *  deploy/08 is called DIRECTLY. Through `deployments.run(["AutoRelockUpgrade"])`
 *  the tag also selects deploy/99, which on the `hardhat` network executes the batch
 *  through an impersonated Safe and deletes the batch file, so the existence check
 *  below could never pass. The file is removed after parsing so the exit guard in
 *  `helpers/safe.ts` stays quiet; the bodies replay the legs themselves. */
let lastDeployLog = "";
async function runUpgradeDeploy(opts?: { before?: () => Promise<void> }): Promise<Batch> {
    await setupFork();
    if (opts?.before) await opts.before();
    if (fs.existsSync(MULTI_SIG_TXS_FILE)) fs.unlinkSync(MULTI_SIG_TXS_FILE);
    const run = await capture(() => deploy08(hre));
    lastDeployLog = run.out;
    if (run.error) throw run.error;
    expect(fs.existsSync(MULTI_SIG_TXS_FILE)).to.equal(true, "deploy/08 must queue a Safe batch");
    const batch = JSON.parse(fs.readFileSync(MULTI_SIG_TXS_FILE).toString()) as Batch;
    fs.unlinkSync(MULTI_SIG_TXS_FILE);
    for (const tx of batch) expect(tx.to.toLowerCase()).to.equal(PROXY_ADMIN.toLowerCase());
    return batch;
}

/** Replay Safe inner calls in array order, from the Safe itself. */
async function executeBatch(txs: Batch) {
    const safe = await impersonate(Addresses.Hemi.GNOSIS_SAFE);
    for (const tx of txs) {
        await (await safe.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ?? 0 })).wait();
    }
}

/** First live token id that still carries a delegation record. */
async function findLiveDelegatedPosition(): Promise<{ tokenId: number; owner: string }> {
    const veHemi = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, ethers.provider);
    const vvd = new ethers.Contract(VVD_PROXY, VVD_ABI, ethers.provider);
    const next = Number(await veHemi.nextTokenId());
    for (let id = next - 1; id > 0 && id > next - 400; id--) {
        try {
            const owner: string = await veHemi.ownerOf(id);
            const d = await vvd.delegation(id);
            if (d[0] !== ethers.ZeroAddress) return { tokenId: id, owner };
        } catch {
            /* burned */
        }
    }
    throw new Error("no live delegated position found in the last 400 ids");
}

/** Newest position, live and delegated at the fork block, whose owner can arm it now. */
async function findArmableDelegatedPosition(): Promise<{ tokenId: number; owner: string; delegatee: string }> {
    const veHemi = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, ethers.provider);
    const vvd = new ethers.Contract(VVD_PROXY, VVD_ABI, ethers.provider);
    const next = Number(await veHemi.nextTokenId());
    for (let id = next - 1; id > 0 && id > next - 400; id--) {
        let owner: string;
        try {
            owner = await veHemi.ownerOf(id);
        } catch {
            continue; // burned
        }
        const delegatee: string = (await vvd.delegation(id))[0];
        if (delegatee === ethers.ZeroAddress) continue;
        try {
            await veHemi.enableAutoRelock.staticCall(id, { from: owner });
        } catch {
            continue;
        }
        return { tokenId: id, owner, delegatee };
    }
    throw new Error("no armable delegated position in the last 400 ids");
}

/** Give `who` exactly `amount` HEMI (OZ ERC20: `_balances` is the mapping at slot 0). */
async function setHemiBalance(who: string, amount: bigint) {
    const slot = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [who, 0]));
    await ethers.provider.send("hardhat_setStorageAt", [Addresses.Hemi.HEMI_TOKEN, slot, ethers.toBeHex(amount, 32)]);
    const hemi = new ethers.Contract(Addresses.Hemi.HEMI_TOKEN, ERC20_ABI, ethers.provider);
    expect(await hemi.balanceOf(who)).to.equal(amount, "the HEMI balance slot is the mapping at slot 0");
}

function eqAddr(a: string, b: string): boolean {
    return a.toLowerCase() === b.toLowerCase();
}

function nb(ts: bigint): bigint {
    return (ts / 3600n) * 3600n + 3600n;
}

async function windowWord(): Promise<bigint> {
    return BigInt(await ethers.provider.getStorage(VVD_PROXY, VVD_WINDOW_SLOT)) & ((1n << 64n) - 1n);
}

async function setWindowWord(w: bigint) {
    await ethers.provider.send("hardhat_setStorageAt", [VVD_PROXY, ethers.toBeHex(VVD_WINDOW_SLOT), ethers.toBeHex(w, 32)]);
}

function listRefused(): string[] {
    return fs.readdirSync(".").filter((f) => f.startsWith(`${MULTI_SIG_TXS_FILE}.refused-`)).sort();
}

/** Run `fn`, tee console output, and return it with any error instead of throwing. */
async function capture(fn: () => Promise<unknown>): Promise<{ out: string; error?: Error }> {
    const lines: string[] = [];
    const orig = { log: console.log, warn: console.warn, error: console.error };
    const tap =
        (k: "log" | "warn" | "error") =>
        (...a: unknown[]) => {
            lines.push(a.map(String).join(" "));
            orig[k](...a);
        };
    console.log = tap("log");
    console.warn = tap("warn");
    console.error = tap("error");
    try {
        await fn();
        return { out: lines.join("\n") };
    } catch (e) {
        // Name the refusal in the log, so the archived run shows which branch fired.
        const first = String((e as Error)?.message ?? e).split("\n").find((l) => l.trim() && !/^=+$/.test(l.trim()));
        orig.log(`        ↳ refused: ${first ?? ""}`);
        return { out: lines.join("\n"), error: e as Error };
    } finally {
        Object.assign(console, orig);
    }
}

/** The documented read-only post-execution check. */
async function postCheck() {
    process.env.D1_POST_CHECK_ONLY = "1";
    try {
        return await capture(() => deploy08(hre));
    } finally {
        delete process.env.D1_POST_CHECK_ONLY;
    }
}

/** The batch as the Safe really runs it: ONE execTransaction delegatecalling
 *  MultiSendCallOnly 1.4.1, signed by `threshold` owners (approved hashes;
 *  the last owner executes). */
async function executeViaSafeMultiSend(txs: Batch): Promise<TransactionReceipt> {
    const packed = ethers.concat(
        txs.map((t) =>
            ethers.solidityPacked(
                ["uint8", "address", "uint256", "uint256", "bytes"],
                [0, t.to, BigInt(t.value ?? "0"), ethers.dataLength(t.data), t.data]
            )
        )
    );
    const msData = new ethers.Interface(["function multiSend(bytes transactions)"]).encodeFunctionData("multiSend", [packed]);
    const SAFE = Addresses.Hemi.GNOSIS_SAFE;
    const safe = new ethers.Contract(SAFE, SAFE_ABI, ethers.provider);
    const owners: string[] = await safe.getOwners();
    const threshold = Number(await safe.getThreshold());
    const Z = ethers.ZeroAddress;
    const h: string = await safe.getTransactionHash(MULTISEND_CALL_ONLY, 0, msData, 1, 0, 0, 0, Z, Z, await safe.nonce());
    const signers = owners.slice(0, threshold);
    for (const o of signers.slice(0, -1)) {
        await (await new ethers.Contract(SAFE, SAFE_ABI, await impersonate(o)).approveHash(h)).wait();
    }
    const sigs = ethers.concat(
        [...signers]
            .sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1))
            .map((o) => ethers.concat([ethers.zeroPadValue(o, 32), ethers.ZeroHash, "0x01"]))
    );
    const executor = new ethers.Contract(SAFE, SAFE_ABI, await impersonate(signers[signers.length - 1]));
    const tx = await executor.execTransaction(MULTISEND_CALL_ONLY, 0, msData, 1, 0, 0, 0, Z, Z, sigs, { gasLimit: 8_000_000 });
    return (await tx.wait()) as TransactionReceipt;
}

/** Transfer the newest position whose transfer the live VeHemi commits
 *  while dropping the VVD update (DelegationUpdateFailed in the receipt). */
async function transferSomePositionDroppingTheUpdate(): Promise<{ tokenId: number; rc: TransactionReceipt }> {
    const RECIPIENT = "0x00000000000000000000000000000000000b0b01";
    const veHemi = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, ethers.provider);
    const next = Number(await veHemi.nextTokenId());
    for (let id = next - 1; id > 0 && id > next - 400; id--) {
        let owner: string;
        try {
            owner = await veHemi.ownerOf(id);
        } catch {
            continue; // burned
        }
        const c = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, await impersonate(owner));
        try {
            await c.transferFrom.staticCall(owner, RECIPIENT, id);
        } catch {
            continue; // not transferable
        }
        const rc = (await (await c.transferFrom(owner, RECIPIENT, id)).wait()) as TransactionReceipt;
        if (rc.logs.some((l) => eqAddr(l.address, VEHEMI_PROXY) && l.topics[0] === DELEGATION_UPDATE_FAILED_TOPIC)) {
            return { tokenId: id, rc };
        }
    }
    throw new Error("no transfer in the last 400 ids dropped its VVD update");
}

/** Make the `nth` read of (`addr`, `slot`) through the provider throw. */
function failStorageRead(addr: string, slot: string, nth: number): () => void {
    const p = ethers.provider as unknown as { getStorage: (...a: unknown[]) => Promise<string> };
    const orig = p.getStorage;
    let n = 0;
    p.getStorage = async function (this: unknown, ...a: unknown[]) {
        if (eqAddr(String(a[0]), addr) && String(a[1]).toLowerCase() === slot.toLowerCase() && ++n === nth) {
            throw new Error("injected provider failure");
        }
        return orig.apply(this, a);
    };
    return () => {
        p.getStorage = orig;
    };
}

/** Make eth_getLogs fail for ranges wider than `max` blocks. */
function failLargeGetLogs(max: number): () => void {
    const p = ethers.provider as unknown as { getLogs: (f: { fromBlock?: unknown; toBlock?: unknown }) => Promise<unknown> };
    const orig = p.getLogs;
    p.getLogs = async function (this: unknown, f: { fromBlock?: unknown; toBlock?: unknown }) {
        const width = Number(f.toBlock) - Number(f.fromBlock) + 1;
        if (width > max) throw new Error(`injected: eth_getLogs range ${width} > ${max}`);
        return orig.call(this, f);
    };
    return () => {
        p.getLogs = orig;
    };
}

/** The state pre-flight 5b and deploy/99 refuse: after `runUpgradeDeploy`,
 *  VeHemi alone is upgraded, a position is armed (the window probe fails open
 *  against the live VVD), and VeHemi alone is rolled back. The VVD never left
 *  the live implementation, so the window word is still 0. Returns the armed id. */
async function armUnderVeHemiOnlyForwardThenRollBack(): Promise<number> {
    const veHemiImpl = (await deployments.get("VeHemi_Implementation")).address;
    await executeBatch([
        { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VEHEMI_PROXY, veHemiImpl]), value: "0" },
    ]);
    const armedId = await armSomePosition();
    console.log(`        ✓ armed token ${armedId} with VeHemi upgraded alone`);
    await executeBatch([
        { to: PROXY_ADMIN, data: PROXY_ADMIN_IFACE.encodeFunctionData("upgrade", [VEHEMI_PROXY, LIVE_VEHEMI_IMPL]), value: "0" },
    ]);
    expect(slotToAddress(await ethers.provider.getStorage(VEHEMI_PROXY, IMPL_SLOT))).to.equal(LIVE_VEHEMI_IMPL.toLowerCase());
    expect(slotToAddress(await ethers.provider.getStorage(VVD_PROXY, IMPL_SLOT))).to.equal(LIVE_VVD_IMPL.toLowerCase());
    expect(await windowWord()).to.equal(0n, "the VVD was never armed, so the window word is still 0");
    return armedId;
}

/** Arm the newest position whose owner can arm it now; returns its id. */
async function armSomePosition(): Promise<number> {
    const veHemi = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, ethers.provider);
    const next = Number(await veHemi.nextTokenId());
    for (let id = next - 1; id > 0 && id > next - 400; id--) {
        let owner: string;
        try {
            owner = await veHemi.ownerOf(id);
        } catch {
            continue; // burned
        }
        const c = new ethers.Contract(VEHEMI_PROXY, VEHEMI_ABI, await impersonate(owner));
        try {
            await c.enableAutoRelock.staticCall(id);
        } catch {
            continue;
        }
        await (await c.enableAutoRelock(id)).wait();
        return id;
    }
    throw new Error("no armable position in the last 400 ids");
}

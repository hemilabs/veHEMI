import fs from "fs";
import { Interface } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { MULTI_SIG_TXS_FILE, executeBatchUsingSafe, quarantineRefusedBatch } from "../helpers/safe";
import {
    BOUNDARY_DATING_VVD_IMPLS,
    EIP1967_IMPL_SLOT,
    GateRefusal,
    LIVE_VEHEMI_IMPLS,
    VVD_ARM_DATA,
    assertBatchOrder,
    assertNothingArmedBeforeForward,
} from "./08_upgrade_autorelock";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    await assertProxyAdminBatchAgainstChain(hre);
    await executeBatchUsingSafe(hre);
};

// Proposal-time re-check. `executeBatchUsingSafe` proposes the file verbatim,
// and a file can reach it without passing deploy/08's gate: restored from
// `.stale-*` with PROPOSE_EXISTING_BATCH=1, or left over from a run that threw.
// A batch with a ProxyAdmin `upgrade`/`upgradeAndCall` leg that targets the
// VeHemi or VVD proxy is therefore re-checked against the chain as it is now:
// first by deploy/08's pre-flight 5b audits (`assertNothingArmedBeforeForward`:
// a batch restored over positions armed before this forward, after a rollback
// or a VeHemi-only forward that was rolled back, or over a rolled-back VeHemi
// leg with the VVD already on this build, is refused), then by deploy/08's
// `assertBatchOrder` (order, targets, payloads, value, both proxies'
// from-implementations, leg count). Both run only while the auto-relock
// transition is incomplete (the VVD on the boundary-dating implementation, or
// VeHemi on the live one) or when the batch itself arms the window
// (`upgradeAndCall(VVD, ..., armLegacyDatingWindow())`). Outside that scope
// deploy/08's matcher is the wrong one (it refuses every plain VVD leg), so later
// upgrades and deploy/04's V2 batch pass through, with a line saying so. A file
// is moved to `.refused-*` only on a `GateRefusal`; a provider error or a missing
// record propagates as itself and leaves the file in place (the exit guard and
// the `.stale-*` path then apply). Batches that upgrade neither proxy (e.g.
// deploy/07's RestakeManager leg) pass through.
// Not covered, so passed through unchecked: a ProxyAdmin leg that is not
// upgrade/upgradeAndCall (e.g. changeProxyAdmin), a leg ethers cannot decode, and
// any batch while the DefaultProxyAdmin/VeHemi/VeHemiVoteDelegation records are
// missing.
const PROXY_ADMIN_IFACE = new Interface([
    "function upgrade(address proxy, address implementation)",
    "function upgradeAndCall(address proxy, address implementation, bytes data) payable",
]);
async function assertProxyAdminBatchAgainstChain(hre: HardhatRuntimeEnvironment) {
    if (!fs.existsSync(MULTI_SIG_TXS_FILE) || fs.statSync(MULTI_SIG_TXS_FILE).size === 0) return;
    const legs = JSON.parse(fs.readFileSync(MULTI_SIG_TXS_FILE).toString()) as { to: string; data: string }[];
    const { get, getOrNull } = hre.deployments;
    const proxyAdmin = await getOrNull("DefaultProxyAdmin");
    const veHemi = await getOrNull("VeHemi");
    const vvd = await getOrNull("VeHemiVoteDelegation");
    if (!proxyAdmin || !veHemi || !vvd) return;
    const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
    let upgradesOurs = false;
    let arms = false;
    for (const l of legs) {
        if (!eq(l.to, proxyAdmin.address)) continue;
        let d;
        try {
            d = PROXY_ADMIN_IFACE.parseTransaction({ data: l.data });
        } catch {
            continue;
        }
        if (!d) continue;
        const proxy = d.args[0] as string;
        if (eq(proxy, veHemi.address) || eq(proxy, vvd.address)) upgradesOurs = true;
        // A payload that starts with the arm's selector counts as arming; trailing
        // bytes are ignored here and refused by `assertBatchOrder`.
        if (d.name === "upgradeAndCall" && eq(proxy, vvd.address) && String(d.args[2]).slice(0, 10).toLowerCase() === VVD_ARM_DATA.toLowerCase()) {
            arms = true;
        }
    }
    if (!upgradesOurs) return;
    // Read outside the try below: a provider error here is not a verdict.
    const slot = async (p: string) => "0x" + (await hre.ethers.provider.getStorage(p, EIP1967_IMPL_SLOT)).slice(-40);
    const veNow = await slot(veHemi.address);
    const vvdNow = await slot(vvd.address);
    const pending =
        BOUNDARY_DATING_VVD_IMPLS.some((a) => eq(a, vvdNow)) || LIVE_VEHEMI_IMPLS.some((a) => eq(a, veNow));
    if (!pending && !arms) {
        console.log(
            `deploy/99: this batch upgrades the VeHemi/VVD proxies while neither is on its pre-upgrade implementation ` +
                `(VeHemi on ${veNow}, VVD on ${vvdNow}) and does not arm the window: outside deploy/08's transition; ` +
                "proposed WITHOUT deploy/08's re-check."
        );
        return;
    }
    try {
        await assertNothingArmedBeforeForward(
            hre,
            {
                veHemiProxy: veHemi.address,
                vvdProxy: vvd.address,
                vvdImplNow: vvdNow,
                vvdBuildImpl: (await getOrNull("VeHemiVoteDelegation_Implementation"))?.address,
            },
            "Refusing to propose this batch."
        );
        await assertBatchOrder(hre, {
            proxyAdmin: proxyAdmin.address,
            veHemiProxy: veHemi.address,
            veHemiImpl: (await get("VeHemi_Implementation")).address,
            vvdProxy: vvd.address,
            vvdImpl: (await get("VeHemiVoteDelegation_Implementation")).address,
        });
    } catch (e) {
        if (e instanceof GateRefusal) quarantineRefusedBatch();
        throw e;
    }
}

// hardhat-deploy filters scripts by tag first and only then moves the
// `runAtTheEnd` ones to the end of the selection: `runAtTheEnd` does not escape
// the filter, so a run that selects a queueing script but not this one queues a
// Safe batch that nothing proposes. This script therefore also carries
// `AutoRelockUpgrade`: `--tags AutoRelockUpgrade` selects deploy/08 and this
// script, and `runAtTheEnd` puts this one last. Any future tag that can queue a
// Safe transaction must be added here; the backstop for forgetting is the
// unproposed-batch exit guard in `helpers/safe.ts`.
func.tags = ["safe", "AutoRelockUpgrade"];
func.runAtTheEnd = true;

export default func;

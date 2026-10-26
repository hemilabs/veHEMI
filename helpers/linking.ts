/**
 * DELEGATECALL-library linking helpers.
 *
 * `src/VeHemi.sol` calls two external libraries at five sites:
 *
 *     VeHemiCurveLib.checkpoint            (VeHemi._checkpoint)           1 site
 *     VeHemiSupplyLib.balanceOfNFTAt       (VeHemi.balanceOfNFTAt)  ┐
 *     VeHemiSupplyLib.supplyBreakdown      (VeHemi.supplyBreakdown) │     4 sites
 *     VeHemiSupplyLib.subcurveSupplyAt     (VeHemi subcurve views)  │
 *     VeHemiSupplyLib.supplyAt             (VeHemi._supplyAt)       ┘
 *
 * solc leaves a 20-byte `__$<hash>$__` placeholder at each site, and the
 * implementation cannot be deployed until each holds a deployed library's address.
 *
 * hardhat-deploy 1.0.4 links the CREATION bytecode only (`getLinkedArtifact`
 * replaces `bytecode` and passes `deployedBytecode` through unchanged):
 *
 *   * Harmless for deployment. The runtime object is embedded verbatim in the
 *     creation object after the constructor prefix, each creation link site is
 *     a runtime link site shifted by the prefix length, and the prefix has no
 *     link site, so linking the creation code links every byte that reaches the
 *     chain. Current sizes are in test/fixtures/eip170-attestation.json.
 *
 *   * Not harmless for verification. The saved record
 *     (`deployments/<net>/VeHemi_Implementation.json`) keeps an UNLINKED
 *     `deployedBytecode`, so comparing `eth_getCode(impl)` against it fails
 *     spuriously. `assertDeployedCodeMatchesLinkedArtifact()` links the runtime
 *     object itself before comparing.
 *
 * A library address with no code fails loudly: the `VeHemiCurveLib.checkpoint`
 * site (no return value) carries solc's EXTCODESIZE guard, and the four
 * `VeHemiSupplyLib` sites return values, so the ABI decoder reverts on empty
 * returndata. A library address holding the WRONG code passes both, which is
 * why `assertLibraryCode()` compares the code itself, not its length.
 */
import { HardhatRuntimeEnvironment } from "hardhat/types";

export type LibraryAddresses = Record<string, string>;
export type LinkSiteCounts = Record<string, number>;

const PLACEHOLDER = /__\$[0-9a-fA-F]{34}\$__/g;

/** solc link references, as they appear in a hardhat artifact. */
type LinkReferences = Record<string, Record<string, { start: number; length: number }[]>>;

/** Flatten a `linkReferences` map into `{ libraryName: siteCount }`. */
export function linkSiteCounts(refs: LinkReferences | undefined): LinkSiteCounts {
    const out: LinkSiteCounts = {};
    for (const file of Object.values(refs ?? {})) {
        for (const [lib, sites] of Object.entries(file)) {
            out[lib] = (out[lib] ?? 0) + sites.length;
        }
    }
    return out;
}

/** Link an arbitrary bytecode object (creation OR runtime) at its own offsets. */
export function linkObject(
    object: string,
    refs: LinkReferences | undefined,
    libraries: LibraryAddresses
): string {
    let out = object;
    for (const file of Object.values(refs ?? {})) {
        for (const [lib, sites] of Object.entries(file)) {
            const addr = libraries[lib];
            if (addr === undefined) {
                throw new Error(`no address supplied for linked library '${lib}'`);
            }
            const body = addr.replace(/^0x/, "").toLowerCase();
            if (body.length !== 40) throw new Error(`bad library address for '${lib}': ${addr}`);
            for (const s of sites) {
                if (s.length !== 20) throw new Error(`unexpected link site length ${s.length}`);
                out = out.slice(0, 2 + s.start * 2) + body + out.slice(2 + (s.start + s.length) * 2);
            }
        }
    }
    return out;
}

/**
 * Neutralise solc's library call protection.
 *
 * A library with `external`/`public` functions starts with a
 * `PUSH20 <own address>; ADDRESS; EQ; …` prologue so it can only be reached by
 * DELEGATECALL. In the artifact that PUSH20 operand is twenty zero bytes; the
 * creation code writes the library's real address there at deploy time, and
 * solc does not list it in `linkReferences`. An artifact-vs-chain comparison
 * therefore differs in exactly these 20 bytes: zero them, then compare.
 */
export function neutralizeLibraryCallProtection(hex: string): string {
    const body = hex.replace(/^0x/, "");
    if (!body.toLowerCase().startsWith("73")) return body;
    if (body.slice(42, 46).toLowerCase() !== "3014") return body;
    return body.slice(0, 2) + "00".repeat(20) + body.slice(42);
}

/**
 * Zero every `immutable` slot in a runtime object.
 *
 * Immutables live in the bytecode: the constructor writes each reserved 32-byte
 * slot of the runtime image before returning it, and the artifact carries zeros
 * there (VeHemi: the HEMI token; VeHemiVoteDelegation: the VeHemi proxy). They
 * are not in `linkReferences`, and hardhat's `Artifact` type does not expose
 * `immutableReferences` (only the build-info has them), so a comparison against
 * the artifact alone fails on every immutable slot.
 */
export function neutralizeImmutables(
    hex: string,
    refs: Record<string, { start: number; length: number }[]>
): string {
    let body = hex.replace(/^0x/, "");
    for (const sites of Object.values(refs ?? {})) {
        for (const s of sites) {
            body = body.slice(0, s.start * 2) + "00".repeat(s.length) + body.slice((s.start + s.length) * 2);
        }
    }
    return body;
}

/** Pull `deployedBytecode.immutableReferences` out of the build-info. */
export async function immutableReferencesOf(
    hre: HardhatRuntimeEnvironment,
    contractName: string
): Promise<Record<string, { start: number; length: number }[]>> {
    const names = await hre.artifacts.getAllFullyQualifiedNames();
    const fullyQualifiedName = names.find((n) => n.endsWith(`:${contractName}`));
    if (!fullyQualifiedName) throw new Error(`no artifact for ${contractName}`);
    const buildInfo = await hre.artifacts.getBuildInfo(fullyQualifiedName);
    if (!buildInfo) return {};
    const [source, name] = fullyQualifiedName.split(":");
    const out = (buildInfo.output.contracts as any)?.[source]?.[name];
    return out?.evm?.deployedBytecode?.immutableReferences ?? {};
}

/** Drop the trailing CBOR metadata blob (last 2 bytes = its length). */
export function stripMetadata(hex: string): string {
    const body = hex.replace(/^0x/, "");
    if (body.length < 6) return body;
    const n = parseInt(body.slice(-4), 16);
    if (!Number.isFinite(n) || n <= 0 || n * 2 + 4 >= body.length) return body;
    return body.slice(0, body.length - (n * 2 + 4));
}

/**
 * Walks every compiled artifact under `src/` and asserts that the set of
 * contracts carrying unresolved link references, and the per-library site
 * count of each, is exactly `expected`. A new external library, a new call
 * site, or a library that became `internal` fails here, at pre-flight, instead
 * of at deploy time.
 */
export async function assertLinkManifest(
    hre: HardhatRuntimeEnvironment,
    expected: Record<string, LinkSiteCounts>
): Promise<void> {
    const names = await hre.artifacts.getAllFullyQualifiedNames();
    const actual: Record<string, LinkSiteCounts> = {};
    for (const fullyQualifiedName of names) {
        if (!fullyQualifiedName.startsWith("src/")) continue;
        const artifact = await hre.artifacts.readArtifact(fullyQualifiedName);
        const counts = linkSiteCounts(artifact.deployedLinkReferences as LinkReferences);
        if (Object.keys(counts).length > 0) actual[artifact.contractName] = counts;
    }
    const canonicalJson = (o: Record<string, LinkSiteCounts>) =>
        JSON.stringify(
            Object.fromEntries(
                Object.entries(o)
                    .sort(([a], [b]) => a.localeCompare(b))
                    .map(([k, v]) => [
                        k,
                        Object.fromEntries(Object.entries(v).sort(([a], [b]) => a.localeCompare(b))),
                    ])
            )
        );
    if (canonicalJson(actual) !== canonicalJson(expected)) {
        throw new Error(
            "LINK MANIFEST MISMATCH — the set of DELEGATECALL libraries changed.\n" +
                `  expected: ${canonicalJson(expected)}\n` +
                `  actual:   ${canonicalJson(actual)}\n` +
                "Every contract listed above must have EVERY library deployed and passed via\n" +
                "`libraries:` in its `deploy(...)` call, or its implementation cannot exist.\n" +
                "Update helpers/vehemiLibraries.ts + the manifest, then re-run."
        );
    }
    const total = Object.values(actual).reduce(
        (n, c) => n + Object.values(c).reduce((m, k) => m + k, 0),
        0
    );
    console.log(
        `Link manifest:           OK (${Object.keys(actual).length} linked contract(s), ${total} link site(s))`
    );
}

/** Assert a deployed library address holds exactly the artifact's runtime code. */
export async function assertLibraryCode(
    hre: HardhatRuntimeEnvironment,
    libName: string,
    address: string
): Promise<void> {
    const code = await hre.ethers.provider.getCode(address);
    if (code === "0x" || code.length <= 2) {
        throw new Error(`library ${libName} at ${address} has NO CODE — refusing to link`);
    }
    const artifact = await hre.artifacts.readArtifact(libName);
    const want = stripMetadata(neutralizeLibraryCallProtection(artifact.deployedBytecode));
    const got = stripMetadata(neutralizeLibraryCallProtection(code));
    if (want !== got) {
        throw new Error(
            `library ${libName} at ${address} holds code that is NOT this build.\n` +
                `  expected ${want.length / 2} B (metadata-stripped, call-protection neutralised), ` +
                `got ${got.length / 2} B`
        );
    }
    const body = code.replace(/^0x/, "");
    if (body.toLowerCase().startsWith("73") && body.slice(42, 46).toLowerCase() === "3014") {
        const guard = "0x" + body.slice(2, 42);
        if (guard.toLowerCase() !== address.toLowerCase()) {
            throw new Error(
                `library ${libName}: call-protection prologue holds ${guard}, not its own address ${address}`
            );
        }
    }
    console.log(
        `  ${libName} code:` +
            " ".repeat(Math.max(1, 20 - libName.length)) +
            `OK (${(code.length - 2) / 2} B at ${address}, call-protection self-address verified)`
    );
}

/**
 * Compare the code actually deployed at `address` against this build's
 * deployedBytecode, LINKED HERE (hardhat-deploy never links that field).
 * Also asserts that no `__$...$__` placeholder survived and that each library
 * address really sits at each of its expected runtime offsets.
 */
export async function assertDeployedCodeMatchesLinkedArtifact(
    hre: HardhatRuntimeEnvironment,
    contractName: string,
    address: string,
    libraries: LibraryAddresses
): Promise<void> {
    const artifact = await hre.artifacts.readArtifact(contractName);
    const refs = artifact.deployedLinkReferences as LinkReferences;
    const linked = linkObject(artifact.deployedBytecode, refs, libraries);
    if (PLACEHOLDER.test(linked)) {
        PLACEHOLDER.lastIndex = 0;
        throw new Error(`${contractName}: placeholders survived linking — refusing to continue`);
    }
    const onchain = await hre.ethers.provider.getCode(address);
    if (onchain === "0x") throw new Error(`${contractName}: no code at ${address}`);
    if (PLACEHOLDER.test(onchain)) {
        PLACEHOLDER.lastIndex = 0;
        throw new Error(`${contractName} at ${address}: DEPLOYED CODE CONTAINS AN UNLINKED PLACEHOLDER`);
    }

    // `immutable`s are written into the runtime image by the constructor, so
    // the artifact's zeros will never equal the chain's values. Zero both.
    const immutableRefs = await immutableReferencesOf(hre, contractName);
    const want = stripMetadata(neutralizeImmutables(linked, immutableRefs));
    const got = stripMetadata(neutralizeImmutables(onchain, immutableRefs));
    if (want !== got) {
        throw new Error(
            `${contractName} at ${address}: deployed code does not match the linked artifact.\n` +
                `  artifact ${want.length / 2} B vs on-chain ${got.length / 2} B ` +
                "(both metadata-stripped and immutable-neutralised)"
        );
    }

    // Every library address must sit at every one of its runtime offsets.
    for (const file of Object.values(refs ?? {})) {
        for (const [lib, sites] of Object.entries(file)) {
            const body = libraries[lib].replace(/^0x/, "").toLowerCase();
            for (const s of sites) {
                const at = onchain.slice(2 + s.start * 2, 2 + (s.start + 20) * 2).toLowerCase();
                if (at !== body) {
                    throw new Error(
                        `${contractName}: expected ${lib} at runtime offset ${s.start}, found 0x${at}`
                    );
                }
            }
        }
    }
    const total = Object.values(linkSiteCounts(refs)).reduce((a, b) => a + b, 0);
    console.log(
        `  ${contractName} code:` +
            " ".repeat(Math.max(1, 18 - contractName.length)) +
            `OK (${(onchain.length - 2) / 2} B, ${total} link site(s) resolved, ` +
            `${Object.values(immutableRefs).reduce((n, v) => n + v.length, 0)} immutable slot(s) neutralised, ` +
            "metadata-stripped match)"
    );
}

/**
 * Bind the Hardhat deploy path to the Foundry build.
 *
 * The sizes and the attestation (`scripts/check-eip170.sh`,
 * `test/fixtures/eip170-attestation.json`) come from Foundry's `out/`; the bytes
 * that reach the chain come from Hardhat's `artifacts/`. This asserts that the
 * two runtime objects are identical once link placeholders are zeroed and the
 * trailing CBOR metadata is stripped. The metadata differs because the two
 * toolchains name source units differently.
 */
export async function assertMatchesFoundryArtifact(
    hre: HardhatRuntimeEnvironment,
    contractName: string,
    foundryPath: string
): Promise<void> {
    const fs = await import("fs");
    if (!fs.existsSync(foundryPath)) {
        // Without `out/` (from `forge build`) this check cannot run, and that must
        // not read as a pass. `ALLOW_MISSING_FOUNDRY_ARTIFACT=1` turns the refusal
        // into a loud skip.
        const msg = `${contractName}: NO Foundry artifact at ${foundryPath} — the bytecode cross-check DID NOT RUN. Run \`forge build\` first.`;
        if (process.env.ALLOW_MISSING_FOUNDRY_ARTIFACT === "1") {
            console.log(`  *** SKIPPED, NOT PASSED *** ${msg}`);
            return;
        }
        throw new Error(msg);
    }
    const forge = JSON.parse(fs.readFileSync(foundryPath).toString());
    const hardhat = await hre.artifacts.readArtifact(contractName);
    const forgeObject: string = forge.deployedBytecode?.object ?? "";
    const forgeRuntime = stripMetadata(forgeObject.replace(/^0x/, "").replace(PLACEHOLDER, "00".repeat(20)));
    PLACEHOLDER.lastIndex = 0;
    const hardhatRuntime = stripMetadata(hardhat.deployedBytecode.replace(/^0x/, "").replace(PLACEHOLDER, "00".repeat(20)));
    PLACEHOLDER.lastIndex = 0;
    if (forgeRuntime !== hardhatRuntime) {
        throw new Error(
            `${contractName}: the Foundry build and the Hardhat build DISAGREE.\n` +
                `  forge   ${forgeRuntime.length / 2} B (metadata-stripped)\n` +
                `  hardhat ${hardhatRuntime.length / 2} B (metadata-stripped)\n` +
                "Every size and attestation in this repo is measured by forge; every byte deployed\n" +
                "is produced by hardhat. They must agree or the measurement describes nothing."
        );
    }
    console.log(
        `  ${contractName}:` +
            " ".repeat(Math.max(1, 23 - contractName.length)) +
            `forge == hardhat (${forgeRuntime.length / 2} B metadata-stripped)`
    );
}

#!/usr/bin/env python3
"""
EIP-170 deployability gate (called by scripts/check-eip170.sh).

WHY THIS EXISTS
  `forge test` does not enforce EIP-170: an over-limit implementation deploys
  inside the test EVM without reverting, and `code_size_limit = 24576` in
  foundry.toml does not change that. A green test run says nothing about
  deployability unless a separate gate does.

WHAT IT DOES
  1. builds (unless --no-build)
  2. discovers every deployable contract compiled from src/ (non-empty
     deployedBytecode) in the forge artifacts -- discovery, not a hand list,
     so a newly added contract is gated automatically
  3. cross-checks the discovered set against test/fixtures/eip170-manifest.txt:
     a manifest entry that disappears (rename/delete) is a coverage regression
     and fails; a new contract is reported and fails until the manifest is
     updated with --update-manifest
  4. enforces EIP-170 (24,576 B runtime) and EIP-3860 (49,152 B initcode)
  5. on success only, writes test/fixtures/eip170-attestation.json binding the
     exact artifacts it measured (per-contract sha256 of the deployedBytecode
     object + a single canonical `digest`) plus a sha256 of the whole src/ tree.
     An over-limit build never produces an attestation, and the in-test gate
     (test/deployability/EIP170Gate.t.sol) fails without a matching one, so
     `forge test` cannot pass on an undeployable artifact.

EXIT 0 = every src/ contract fits and the attestation is current.
EXIT 1 = anything else; outside --verify a failing run deletes the attestation.
EXIT 2 = --verify combined with --update-manifest.

--verify  never writes and never deletes. Compares the attestation it just
          computed with the one on disk and exits 1 on any semantic drift, a
          missing file included. CI and deploy/08 use it; the default
          (stamping) mode is for whoever built and commits the result.
"""
import argparse, hashlib, json, os, subprocess, sys, time

EIP170 = 24576          # max runtime code size
EIP3860 = 49152         # max initcode size
MANIFEST = "test/fixtures/eip170-manifest.txt"
ATTESTATION = "test/fixtures/eip170-attestation.json"


def sh(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)


def discover(root):
    """Every artifact whose compilationTarget lives under src/ and has code."""
    out = os.path.join(root, "out")
    found = {}
    stale = []
    for dirpath, _dirs, files in os.walk(out):
        for fn in files:
            if not fn.endswith(".json"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                with open(p) as fh:
                    a = json.load(fh)
            except Exception:
                continue
            metadata = a.get("metadata") or {}
            target = ((metadata.get("settings") or {}).get("compilationTarget") or {})
            if not target:
                continue
            src = next(iter(target))
            name = target[src]
            if not src.startswith("src/"):
                continue
            # Stale-artifact filter. `forge build` never prunes out/, so an
            # artifact for a deleted source survives and would otherwise be
            # gated (and written into the manifest) as if it still existed.
            # Trust src/ on disk, not out/.
            if not os.path.exists(os.path.join(root, src)):
                stale.append(f"{src}:{name}")
                continue
            runtime_hex = ((a.get("deployedBytecode") or {}).get("object") or "")
            initcode_hex = ((a.get("bytecode") or {}).get("object") or "")
            if len(runtime_hex) <= 2:            # interface / abstract: nothing to deploy
                continue
            contract_id = f"{src}:{name}"
            found[contract_id] = {
                "id": contract_id,
                "artifact": os.path.relpath(p, root),
                "runtimeSize": (len(runtime_hex) - 2) // 2,
                "initcodeSize": (len(initcode_hex) - 2) // 2,
                # sha256 over the artifact's object STRING (placeholders included):
                # deterministic for identical source+settings, and reproducible
                # byte-for-byte inside forge test via sha256(bytes(obj)).
                "runtimeSha256": hashlib.sha256(runtime_hex.encode()).hexdigest(),
            }
    if stale:
        print(f"note: ignored {len(stale)} stale artifact(s) whose src/ file no longer exists: "
              + ", ".join(sorted(stale)[:5]) + ("..." if len(stale) > 5 else ""))
    return found


def src_tree_sha(root):
    h = hashlib.sha256()
    for dirpath, dirs, files in sorted(os.walk(os.path.join(root, "src"))):
        dirs.sort()
        for fn in sorted(files):
            if not fn.endswith(".sol"):
                continue
            p = os.path.join(dirpath, fn)
            h.update(os.path.relpath(p, root).encode())
            with open(p, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()


def canonical_digest(entries):
    """The single scalar the Solidity gate recomputes from out/ and compares.

    blob = for each id in sorted order:  "<id>\n<runtimeSize>\n0x<sha256(obj)>\n"
    digest = sha256(blob).  String-shaped on purpose: `vm.toString` in Solidity
    reproduces it exactly, no ABI-encoding agreement needed between the two
    implementations.
    """
    blob = ""
    for contract_id in sorted(entries):
        e = entries[contract_id]
        blob += f"{contract_id}\n{e['runtimeSize']}\n0x{e['runtimeSha256']}\n"
    return hashlib.sha256(blob.encode()).hexdigest(), blob


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--update-manifest", action="store_true")
    ap.add_argument("--json", action="store_true", help="machine-readable report on stdout")
    # Verify-only mode. The default mode re-stamps the attestation on any drift
    # and returns 0, so a check run after it
    # (test/deployability/EIP170Gate.t.sol) compares out/ with a file just
    # derived from out/ and cannot fail.
    # --verify never writes or deletes the attestation and returns 1 on any
    # semantic difference, a missing file included. Stamping stays the default:
    # a deliberate act by whoever built, not a step of a gate.
    ap.add_argument("--verify", action="store_true",
                    help="verify-only: never write or delete the attestation; "
                         "exit 1 on ANY drift, including a missing attestation")
    args = ap.parse_args()
    if args.verify and args.update_manifest:
        print("EIP-170 GATE: FAIL (--verify and --update-manifest are mutually exclusive: "
              "--update-manifest writes the very file --verify refuses to trust)")
        return 2
    root = os.path.abspath(args.root)
    attestation_path = os.path.join(root, ATTESTATION)

    if not args.no_build:
        r = sh("forge build", root)
        if r.returncode != 0:
            print(r.stdout[-4000:]); print(r.stderr[-4000:])
            print("EIP-170 GATE: FAIL (build failed)")
            if os.path.exists(attestation_path) and not args.verify:
                os.remove(attestation_path)
            return 1

    entries = discover(root)
    if not entries:
        print("EIP-170 GATE: FAIL (no deployable src/ artifact found -- wrong root or empty out/)")
        return 1

    manifest_path = os.path.join(root, MANIFEST)
    manifest = []
    if os.path.exists(manifest_path):
        manifest = [l.split("#")[0].strip() for l in open(manifest_path)]
        manifest = [l for l in manifest if l]

    missing = [m for m in manifest if m not in entries]
    extra = [c for c in sorted(entries) if c not in manifest]

    if args.update_manifest:
        with open(manifest_path, "w") as fh:
            fh.write("# EIP-170 gate coverage manifest: every contract compiled from src/ with\n"
                     "# runtime code. Not all of them are deployed: VeHemiLayoutProbe is a\n"
                     "# compile-only probe for scripts/check-library-layout-mirror.sh, and\n"
                     "# VeHemiLayoutLib and VeHemiTime are internal-only libraries.\n"
                     "# Regenerate: scripts/check-eip170.sh --update-manifest\n")
            for contract_id in sorted(entries):
                fh.write(contract_id + "\n")
        print(f"manifest updated: {manifest_path} ({len(entries)} contracts)")
        missing, extra = [], []

    over = [e for e in entries.values() if e["runtimeSize"] > EIP170]
    over_init = [e for e in entries.values() if e["initcodeSize"] > EIP3860]

    name_width = max(len(c) for c in entries)
    print(f"{'contract':<{name_width}}  {'runtime':>8}  {'margin':>8}  {'initcode':>9}  status")
    for contract_id in sorted(entries):
        e = entries[contract_id]
        margin = EIP170 - e["runtimeSize"]
        status = "OK" if margin >= 0 else f"OVER by {-margin} B"
        print(f"{contract_id:<{name_width}}  {e['runtimeSize']:>8,}  {margin:>8,}  {e['initcodeSize']:>9,}  {status}")

    ok = True
    for e in over:
        print(f"EIP-170 VIOLATION: {e['id']} is {e['runtimeSize']:,} B, "
              f"{e['runtimeSize'] - EIP170:,} B over the {EIP170:,} B limit -- NOT DEPLOYABLE")
        ok = False
    for e in over_init:
        print(f"EIP-3860 VIOLATION: {e['id']} initcode {e['initcodeSize']:,} B > {EIP3860:,} B")
        ok = False
    for m in missing:
        print(f"COVERAGE REGRESSION: manifest lists {m} but no such deployable artifact exists "
              f"(renamed/removed?). Re-run with --update-manifest if intended.")
        ok = False
    for x in extra:
        print(f"UNGATED CONTRACT: {x} is deployable from src/ but absent from the manifest. "
              f"Re-run with --update-manifest to gate it.")
        ok = False

    digest, blob = canonical_digest(entries)
    if not ok:
        if os.path.exists(attestation_path) and not args.verify:
            os.remove(attestation_path)
            print(f"attestation REMOVED: {ATTESTATION} (an undeployable build must not be attested)")
        print("EIP-170 GATE: FAIL")
        if args.json:
            print(json.dumps({"pass": False, "contracts": entries, "digest": digest}, indent=2))
        return 1

    attestation = {
        "_comment": "Written ONLY by a passing scripts/check-eip170.sh. "
                    "test/deployability/EIP170Gate.t.sol recomputes `digest` from out/ and fails on any drift.",
        "limit": EIP170,
        "initcodeLimit": EIP3860,
        "digest": "0x" + digest,
        "srcTreeSha256": "0x" + src_tree_sha(root),
        "contractCount": len(entries),
        "generatedAt": int(time.time()),
        "contracts": {contract_id: entries[contract_id] for contract_id in sorted(entries)},
    }
    # Conditional write: a passing run must not rewrite the file it certifies.
    # `generatedAt` is the only field that moves on a re-cut of an unchanged tree,
    # and nothing reads it. If the attestation on disk agrees on every other
    # field, keep the file (and its original `generatedAt`) and say so.
    prev = None
    try:
        with open(attestation_path) as fh:
            prev = json.load(fh)
    except Exception:
        prev = None
    def _semantic(d):
        return {k: v for k, v in d.items() if k != "generatedAt"}
    if isinstance(prev, dict) and _semantic(prev) == _semantic(attestation):
        attestation["generatedAt"] = prev.get("generatedAt", attestation["generatedAt"])
        print(f"attestation unchanged: {ATTESTATION}  digest=0x{digest[:16]}...  "
              f"srcTree=0x{attestation['srcTreeSha256'][2:18]}...  contracts={len(entries)}"
              f"  (identical but for generatedAt -- NOT rewritten)")
    elif args.verify:
        # --verify: report the drift, write nothing, return 1.
        print(f"EIP-170 GATE: FAIL -- ATTESTATION DRIFT (--verify: nothing was written)")
        if not isinstance(prev, dict):
            print(f"  {ATTESTATION} is MISSING or unreadable. Absent is NOT green.")
        else:
            prev_fields, new_fields = _semantic(prev), _semantic(attestation)
            for k in sorted(set(prev_fields) | set(new_fields)):
                if prev_fields.get(k) != new_fields.get(k):
                    if k == "contracts":
                        prev_contracts, new_contracts = prev_fields.get(k) or {}, new_fields.get(k) or {}
                        for contract_id in sorted(set(prev_contracts) | set(new_contracts)):
                            if prev_contracts.get(contract_id) != new_contracts.get(contract_id):
                                print(f"  contracts[{contract_id}]:")
                                print(f"      on disk : {prev_contracts.get(contract_id)}")
                                print(f"      built   : {new_contracts.get(contract_id)}")
                    else:
                        print(f"  {k}:")
                        print(f"      on disk : {prev_fields.get(k)}")
                        print(f"      built   : {new_fields.get(k)}")
        print("  The artifacts in out/ are NOT the ones the attestation names.")
        print(f"  Re-stamp DELIBERATELY with `./scripts/check-eip170.sh --no-build` "
              f"and say so in the commit; do NOT let a gate do it for you.")
        if args.json:
            print(json.dumps({"pass": False, "drift": True, "contracts": entries,
                              "digest": digest}, indent=2))
        return 1
    else:
        os.makedirs(os.path.dirname(attestation_path), exist_ok=True)
        with open(attestation_path, "w") as fh:
            json.dump(attestation, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"attestation written: {ATTESTATION}  digest=0x{digest[:16]}...  "
              f"srcTree=0x{attestation['srcTreeSha256'][2:18]}...  contracts={len(entries)}")
    print(f"EIP-170 GATE: PASS ({len(entries)} deployable src/ contracts, "
          f"worst margin {min(EIP170 - e['runtimeSize'] for e in entries.values()):,} B)")
    if args.json:
        print(json.dumps({"pass": True, "contracts": entries, "digest": digest}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

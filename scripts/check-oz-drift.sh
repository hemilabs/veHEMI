#!/usr/bin/env bash
# =============================================================================
#  LIBRARY-DRIFT GATE  --  committed solcInputs  vs  installed node_modules
# =============================================================================
#
#  `deployments/hemi/solcInputs/*.json` is the record of what is deployed on
#  Hemi: each bundle carries, inline, the full source text of every file the
#  deployed bytecode was compiled from. `node_modules/` is what `forge build`
#  and `forge test` compile today. This gate requires the two to agree, byte
#  for byte, on every library source.
#
#  scripts/check-storage-layouts.sh cannot see such a drift. OZ 5.x keeps all
#  library state in ERC-7201 namespaced slots, which never appear in a derived
#  contract's `storageLayout`, so the golden fixtures carry no OpenZeppelin
#  entry. An OZ bump (5.3.0 -> 5.4.0, say) moves no golden, keeps `forge build`
#  and `forge test` green, and silently decouples the tested bytes from the
#  deployed ones.
#
#  What it compares:
#    A. every bundle's `@openzeppelin/...` sources (OZ 5.3.0, `contracts` and
#       `contracts-upgradeable`)                         -> node_modules/
#    B. the 0.8.10 bundle's vendored `solc_0.8/...` sources (OZ 4.4.1 /
#       4.5.0-rc.0 plus hardhat-deploy's own
#       `OptimizedTransparentUpgradeableProxy.sol`, which together back the
#       deployed proxies)                       -> node_modules/hardhat-deploy/
#
#  It is a byte comparison and nothing else: no build, no EVM, no network.
#  Zero bundles, or zero sources in scope, is exit 2 (could not run), never a
#  pass.
#
#  usage:  scripts/check-oz-drift.sh [<tree>]        (default: the repo root)
#  exit :  0 no drift | 1 DRIFT (or a source missing from node_modules)
#          2 the instrument could not run (vacuous scope / no node_modules)
# =============================================================================
set -uo pipefail
T="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$T" || { echo "check-oz-drift: no such tree: $T" >&2; exit 2; }

SOLCIN="deployments/hemi/solcInputs"
[ -d "$SOLCIN" ]      || { echo "check-oz-drift: VACUOUS -- no $SOLCIN" >&2; exit 2; }
[ -d "node_modules" ] || { echo "check-oz-drift: VACUOUS -- no node_modules (run npm ci)" >&2; exit 2; }
set -- "$SOLCIN"/*.json
[ -e "$1" ] || { echo "check-oz-drift: VACUOUS -- 0 bundles in $SOLCIN" >&2; exit 2; }

python3 - "$SOLCIN" "$@" <<'PY'
import json, os, sys, glob
solcin = sys.argv[1]
bundles = sorted(glob.glob(os.path.join(solcin, "*.json")))
# prefix in the bundle  ->  where the same file lives in node_modules
ROOTS = (("@openzeppelin/",  "node_modules/"),
         ("solc_0.8/",       "node_modules/hardhat-deploy/"))
checked = drift = missing = 0
for b in bundles:
    try:
        srcs = json.load(open(b))["sources"]
    except Exception as e:
        print("  !! UNREADABLE BUNDLE %s: %s" % (b, e)); sys.exit(2)
    hits = same = 0
    for path in sorted(srcs):
        root = next((r for p, r in ROOTS if path.startswith(p)), None)
        if root is None:
            continue
        hits += 1; checked += 1
        installed = os.path.join(root, path)
        if not os.path.isfile(installed):
            print("  !! MISSING   %-34s %s" % (os.path.basename(b), path))
            print("     the deployed record names a library source that is NOT INSTALLED: %s" % installed)
            missing += 1; continue
        want = srcs[path].get("content")
        got  = open(installed, encoding="utf-8").read()
        if want != got:
            print("  !! DRIFT     %-34s %s" % (os.path.basename(b), path))
            print("     committed %d B vs installed %d B -- the tested bytes and the"
                  " deployed bytes have diverged." % (len(want.encode()), len(got.encode())))
            drift += 1; continue
        same += 1
    print("  %-38s %3d/%-3d library source(s) identical" % (os.path.basename(b), same, hits))
for pkg in ("node_modules/@openzeppelin/contracts",
            "node_modules/@openzeppelin/contracts-upgradeable"):
    pj = os.path.join(pkg, "package.json")
    if os.path.isfile(pj):
        print("  installed %-50s %s" % (pkg, json.load(open(pj))["version"]))
if checked == 0:
    print("  !! VACUOUS -- %d bundle(s) read, 0 library sources in scope. A comparison"
          " gate that compares nothing is not a pass." % len(bundles)); sys.exit(2)
print("  TOTAL: %d library source(s) compared, %d drifted, %d missing" % (checked, drift, missing))
sys.exit(1 if (drift or missing) else 0)
PY
RC=$?
case "$RC" in
  0) echo "OK: committed solcInputs and installed node_modules agree on every library source";;
  1) echo "ERROR: LIBRARY DRIFT -- deployments/hemi/solcInputs no longer describes the"
     echo "       libraries this tree builds and tests against. The storage-layout golden"
     echo "       CANNOT see this (OZ 5.x state is ERC-7201 namespaced; zero OZ entries in"
     echo "       all three fixtures). Re-run \`npm ci\`, or re-record the deployment.";;
  *) echo "ERROR: check-oz-drift could not run (rc=$RC)";;
esac
exit $RC

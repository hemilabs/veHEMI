#!/usr/bin/env bash
#
# Library storage-mirror gate.
#
# `src/lib/VeHemiLayout.sol` re-declares the whole VeHemi proxy storage layout
# as a slot-0-anchored struct, because a DELEGATECALL library cannot inherit
# `VeHemiStorageV3`. That struct is a second source of truth for the live
# proxy's storage. A one-word drift in it (`uint256[37] __gapV2` -> `[38]`)
# still compiles, leaves the VeHemi runtime byte-identical, and passes
# scripts/check-storage-layouts.sh and the layout tests, while every library
# read of slot 64 and above lands one slot off: the libraries would read the
# heartbeat timestamp as R and inflate every armed position's weight. This gate
# is what catches it.
#
# Both sides come from the same `forge build`, through `forge inspect`:
#     A. `forge inspect VeHemi storageLayout`            .storage[]
#     B. `forge inspect VeHemiLayoutProbe storageLayout` members of
#        `t_struct(VeHemiLayout)NN_storage` (the probe's only state variable
#        is the mirror, anchored at slot 0 as the libraries anchor it)
# scripts/mirror-canon.jq renders each side as one TSV row per member: label,
# slot, offset and a recursive canonical type (solc's type label + encoding +
# numberOfBytes, descending through struct members, array bases and mapping
# key/value). The rendering carries no AST ids, so unrelated source edits do
# not move it, and does carry array lengths and integer widths. The two
# renderings must be identical, line for line.
#
# One deliberate equivalence: `contract IFoo` == `address` (same 20 inplace
# bytes; the mirror declares plain `address`). There is no allowlist and no
# "up to slot N" escape: the mirror must cover every VeHemi state variable,
# `__gapV3` included, so a field added to VeHemi and not to the mirror fails.
#
# Also gated:
#     - every `.slot := N` assembly anchor under src/lib must be 0 (at least 3)
#     - VeHemiCurveLib's hardcoded OZ ERC-7201 `_owners` namespace + member index
#
# Exit codes: 0 = mirror matches. 1 = mirror drift. 2 = the gate could not run
# (missing tool, build failure, missing or vacuous layout). A caller must never
# report 2 as a layout regression, and must never treat 2 as success.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$SCRIPT_DIR/mirror-canon.jq"
MIRROR_SRC="src/lib/VeHemiLayout.sol"
MIN_MEMBERS=25            # anti-vacuity floor; the real layout has 29
                          # (the deployed 26 + the 3 auto-relock members;
                          # test/StorageLayoutOnchainAnchor.t.sol pins 29)

err()  { echo "::error::$*" >&2; }
note() { echo "$*"; }

command -v jq    >/dev/null 2>&1 || { err "'jq' is required.";    exit 2; }
command -v forge >/dev/null 2>&1 || { err "'forge' is required."; exit 2; }
[ -f "$CANON" ] || { err "missing $CANON (the canonicaliser)"; exit 2; }
[ -f "$MIRROR_SRC" ] || { err "missing $MIRROR_SRC — is this a VeHemi tree?"; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FAILED=0

# ---------------------------------------------------------- CHECK 0a: build ---
# Build. Incremental is fine and cheap; a build failure is exit 2, NOT drift.
note "Building (incremental) so both artifacts come from the same compilation..."
if ! forge build >"$WORK/build.log" 2>&1; then
  err "'forge build' failed; the mirror gate COULD NOT RUN (this is NOT drift)."
  grep -E '^Error|^error' "$WORK/build.log" | head -5 >&2
  exit 2
fi

# ----------------------------------------- CHECK 0b: one mirror declaration ---
# Exactly one declaration of the mirror struct.
DECLS=$(grep -rlE '^[[:space:]]*struct[[:space:]]+VeHemiLayout[[:space:]]*\{' src/ 2>/dev/null | sort -u)
if [ "$(printf '%s\n' "$DECLS" | grep -c .)" != "1" ]; then
  err "expected exactly ONE 'struct VeHemiLayout' declaration under src/, found:"
  printf '%s\n' "$DECLS" | sed 's/^/::error::  /' >&2
  exit 2
fi

# ------------------------------------------- CHECK 0c: inspect both layouts ---
# Both layouts come from `forge inspect`, not from a hand-picked path under
# out/. forge resolves the artifact for the CURRENT source (and errors on an
# ambiguous contract name, which doubles as the "exactly one probe" check),
# so there is no stale-artifact question to answer and no fixture in the loop.
inspect () { # $1 = contract name, $2 = destination file
  if ! forge inspect "$1" storageLayout --json 2>"$WORK/err-$1" > "$2"; then
    err "'forge inspect $1 storageLayout' failed; the gate COULD NOT RUN."
    sed 's/^/::error::  /' "$WORK/err-$1" >&2
    if [ "$1" = "$PROBE_NAME" ]; then
      err "The mirror is INSPECTABLE ONLY through the probe contract"
      err "(src/lib/VeHemiLayoutProbe.sol)."
      err "This gate REFUSES to report success on an uninspectable mirror."
    fi
    err "If this says the storage layout is missing from the artifact, run"
    err "'forge clean && forge build' (foundry.toml must keep extra_output=[\"storageLayout\"])."
    exit 2
  fi
  if [ ! -s "$2" ] || [ "$(jq -r '(.storage // null) | length' "$2" 2>/dev/null)" = "null" ]; then
    err "'forge inspect $1 storageLayout' produced no usable layout. NOT a drift verdict."
    exit 2
  fi
}
PROBE_NAME=VeHemiLayoutProbe
inspect VeHemi           "$WORK/vehemi.json"
inspect "$PROBE_NAME"    "$WORK/probe.json"

# ---------------------------------------------------- CHECK 0d: probe shape ---
# The probe must be exactly ONE state variable of the mirror struct type at
# slot 0 offset 0 — otherwise the numbers below describe something else.
PROBE_ENTRIES=$(jq -r '.storage | length'      "$WORK/probe.json")
PROBE_TYPE=$(jq -r '.storage[0].type // ""' "$WORK/probe.json")
PROBE_SLOT=$(jq -r '.storage[0].slot // ""' "$WORK/probe.json")
PROBE_OFFSET=$(jq -r '.storage[0].offset // ""' "$WORK/probe.json")
if [ "$PROBE_ENTRIES" != "1" ] || [ "$PROBE_SLOT" != "0" ] || [ "$PROBE_OFFSET" != "0" ] || ! grep -q 't_struct(VeHemiLayout)' <<<"$PROBE_TYPE"; then
  err "the probe is not a single VeHemiLayout at slot 0 offset 0"
  err "  entries=$PROBE_ENTRIES slot=$PROBE_SLOT offset=$PROBE_OFFSET type=$PROBE_TYPE"
  exit 2
fi

# ------------------------------------- CHECK 1: member-by-member comparison ---
jq -r --arg root "contract"            -f "$CANON" "$WORK/vehemi.json" > "$WORK/vehemi.tsv" 2>"$WORK/jq-vehemi.err"
jq -r --arg root "struct:VeHemiLayout" -f "$CANON" "$WORK/probe.json"  > "$WORK/mirror.tsv" 2>"$WORK/jq-mirror.err"
VEHEMI_MEMBERS=$(grep -c . "$WORK/vehemi.tsv"); MIRROR_MEMBERS=$(grep -c . "$WORK/mirror.tsv")
if [ "$VEHEMI_MEMBERS" -lt "$MIN_MEMBERS" ] || [ "$MIRROR_MEMBERS" -lt "$MIN_MEMBERS" ]; then
  err "VACUOUS INPUT: VeHemi rendered $VEHEMI_MEMBERS members, mirror rendered $MIRROR_MEMBERS (floor $MIN_MEMBERS)."
  err "The gate COULD NOT RUN. jq stderr:"; sed 's/^/::error::  /' "$WORK/jq-vehemi.err" "$WORK/jq-mirror.err" >&2
  exit 2
fi
if grep -q 'MISSING_TYPE\|DEPTH_LIMIT' "$WORK/vehemi.tsv" "$WORK/mirror.tsv"; then
  err "a type could not be resolved (MISSING_TYPE / DEPTH_LIMIT) — gate COULD NOT RUN."
  grep -n 'MISSING_TYPE\|DEPTH_LIMIT' "$WORK/vehemi.tsv" "$WORK/mirror.tsv" | head -5 >&2
  exit 2
fi

if ! diff -u --label "VeHemi (compiled)" --label "VeHemiLayout mirror (compiled)" \
        "$WORK/vehemi.tsv" "$WORK/mirror.tsv" > "$WORK/diff.txt"; then
  FAILED=1
  err "LIBRARY STORAGE-MIRROR DRIFT — src/lib/VeHemiLayout.sol does not match VeHemi."
  echo "" >&2
  sed 's/^/    /' "$WORK/diff.txt" >&2
  echo "" >&2
  err "Every DELEGATECALL library addresses proxy storage through this struct."
  err "A mismatch means live reads/writes land on the WRONG SLOT. Fix the struct"
  err "(or, if VeHemi's own layout changed on purpose, update BOTH)."
else
  note "OK: VeHemiLayout mirrors all $VEHEMI_MEMBERS VeHemi state variables (label/slot/offset/type, recursive)"
fi

# -------------------------------------------------- CHECK 2: slot-0 anchors ---
# Anchors. A perfect struct read from `slot := 1` is just as fatal.
ANCHORS=0; ANCHOR_BAD=0
while IFS= read -r hit; do
  ANCHORS=$((ANCHORS+1))
  n=$(sed -E 's/.*\.slot[[:space:]]*:=[[:space:]]*([0-9]+).*/\1/' <<<"$hit")
  if [ "$n" != "0" ]; then
    err "$hit — a VeHemiLayout anchor must be slot 0"; FAILED=1; ANCHOR_BAD=1
  fi
done < <(grep -rnE '\.slot[[:space:]]*:=[[:space:]]*[0-9]+' src/lib/ 2>/dev/null || true)
if [ "$ANCHOR_BAD" -eq 1 ]; then
  : # already reported
elif [ "$ANCHORS" -lt 3 ]; then
  err "expected >= 3 slot-0 anchors under src/lib, found $ANCHORS — the anchor"
  err "check has gone vacuous (did the libraries stop anchoring, or move?)."
  FAILED=1
else
  note "OK: $ANCHORS slot-0 anchors under src/lib"
fi

# -------------------------------------- CHECK 3: OZ ERC-7201 _owners offset ---
# VeHemiCurveLib hardcodes OZ's ERC-7201 ERC721 namespace and the member index
# of `_owners` inside it. This is the only check on that offset, so a missing OZ
# source or a value that cannot be extracted fails (`FAILED=1`) rather than
# dropping the check silently.
OZ_ERC721_SOURCE=node_modules/@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol
if [ ! -f "$OZ_ERC721_SOURCE" ] || ! grep -q 'ERC721StorageLocation\|0x' "$OZ_ERC721_SOURCE"; then
  err "The OZ _owners offset check (CHECK 3) has gone vacuous: $OZ_ERC721_SOURCE is missing or"
  err "carries no ERC-7201 namespace constant. This is the ONLY check on"
  err "VeHemiCurveLib's hardcoded _owners offset; it must not pass by being absent."
  err "(npm ci not run, or OZ moved?)"
  FAILED=1
else
  OZ_NAMESPACE=$(grep -oE '0x[0-9a-fA-F]{64}' "$OZ_ERC721_SOURCE" | head -1)
  OWNERS_INDEX=$(awk '/struct ERC721Storage/,/^    }/' "$OZ_ERC721_SOURCE" \
           | grep -E '^\s+(mapping|string|uint|address|bool|bytes)' | grep -n '_owners' | cut -d: -f1)
  if [ -z "$OZ_NAMESPACE" ] || [ -z "$OWNERS_INDEX" ]; then
    err "The OZ _owners offset check (CHECK 3) has gone vacuous: could not extract"
    err "the ERC-7201 namespace (OZ_NAMESPACE='${OZ_NAMESPACE:-}') or the \`_owners\`"
    err "member index (OWNERS_INDEX='${OWNERS_INDEX:-}') from $OZ_ERC721_SOURCE -- did the struct"
    err "or the constant get renamed upstream?"
    FAILED=1
  else
    OWNERS_OFFSET=$((OWNERS_INDEX-1))
    grep -q "$OZ_NAMESPACE" src/lib/VeHemiCurveLib.sol || {
      err "VeHemiCurveLib's ERC-7201 namespace constant does not match $OZ_ERC721_SOURCE ($OZ_NAMESPACE)"; FAILED=1; }
    grep -qE "\+[[:space:]]*$OWNERS_OFFSET\)" src/lib/VeHemiCurveLib.sol || {
      err "VeHemiCurveLib hardcodes a different _owners member index; OZ has it at member offset $OWNERS_OFFSET"; FAILED=1; }
    [ "$FAILED" -eq 1 ] || note "OK: OZ ERC-7201 _owners offset (namespace $OZ_NAMESPACE, member offset $OWNERS_OFFSET)"
  fi
fi

exit $FAILED

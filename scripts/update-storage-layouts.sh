#!/usr/bin/env bash
#
# Regenerate the committed storage layout golden fixtures.
#
# Run this script after making an INTENTIONAL change to any upgradeable
# contract's storage layout (adding a new field, extending the gap, introducing
# a VeHemiStorageV4, etc.).
#
# The regenerated fixtures are NORMALIZED: AST IDs are stripped so unrelated
# source edits do not produce spurious fixture diffs. The same normalization
# is applied by check-storage-layouts.sh on the forge inspect side, so both
# inputs to the CI diff use the identical transformation.
#
# Workflow:
#   1. Edit storage contract source.
#   2. Run this script.
#   3. Inspect `git diff test/fixtures/storage-layouts/` and confirm the change
#      is append-only: no existing slot shifted, no existing type changed, and
#      no struct gained or lost a member. A member appended into a struct's
#      free padding moves neither `numberOfBytes` nor any existing member
#      offset, so this diff is the only place the shell gates show it; the
#      member-count pins in `test/StorageLayoutGolden.t.sol` fail until you
#      bump them deliberately.
#   4. Commit source + fixture diff in the same PR.
#
# Each fixture is written to a scratch file and moved into place only when
# `forge inspect` and the normalization both succeed: redirecting straight into
# the fixture would truncate it to zero bytes on a failing `forge inspect`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_normalize-storage-layout.sh
source "$SCRIPT_DIR/_normalize-storage-layout.sh"

# Required tools. Missing these produces a clearer error than a pipe failure.
command -v jq >/dev/null 2>&1 || { echo "ERROR: 'jq' is required. Install via apt/brew."; exit 2; }
command -v forge >/dev/null 2>&1 || { echo "ERROR: 'forge' is required. See https://getfoundry.sh"; exit 2; }
echo "Using $(jq --version) and $(forge --version 2>/dev/null | head -1)"

CONTRACTS=("VeHemi" "VeHemiVoteDelegation" "VeHemiAragonAdapter")
FIXTURES_DIR="test/fixtures/storage-layouts"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$FIXTURES_DIR"

# `forge inspect <C> storageLayout` reads the storage layout out of the
# compilation artifact. After an incremental build the artifact can be present
# without the layout, and forge exits 1. Clean first — a full rebuild is cheap
# relative to shipping a corrupt proxy layout.
echo "Running 'forge clean && forge build' so every artifact carries a storage layout..."
forge clean >/dev/null 2>&1 || true
forge build >/dev/null 2>&1 || { echo "ERROR: 'forge build' failed. Fixtures left UNTOUCHED."; exit 2; }

for c in "${CONTRACTS[@]}"; do
  if ! forge inspect "$c" storageLayout --json 2>"$WORKDIR/err-$c" > "$WORKDIR/raw-$c.json"; then
    echo "ERROR: 'forge inspect $c storageLayout' failed:"
    sed 's/^/       /' "$WORKDIR/err-$c"
    echo "       Committed fixtures left UNTOUCHED."
    exit 2
  fi
  if [ ! -s "$WORKDIR/raw-$c.json" ] || [ "$(jq -r '.storage | length' "$WORKDIR/raw-$c.json" 2>/dev/null)" = "null" ]; then
    echo "ERROR: 'forge inspect $c storageLayout' produced no usable layout."
    echo "       Committed fixtures left UNTOUCHED."
    exit 2
  fi
  normalize < "$WORKDIR/raw-$c.json" > "$WORKDIR/norm-$c.json"
  [ -s "$WORKDIR/norm-$c.json" ] || { echo "ERROR: normalization of $c produced an empty file. Fixtures UNTOUCHED."; exit 2; }
  mv "$WORKDIR/norm-$c.json" "$FIXTURES_DIR/$c.json"
  echo "Regenerated: $FIXTURES_DIR/$c.json"
done

echo ""
echo "Review the diff with:"
echo "  git diff $FIXTURES_DIR/"
echo ""
echo "Ensure all changes are APPEND-ONLY (no existing slot shifted or re-typed,"
echo "and no struct gained or lost a member)."
echo ""
echo "NOTE: the fixture is REGENERABLE, so this diff is not itself a safety gate."
echo "      Gates that a regeneration cannot launder:"
echo "        test/StorageLayoutOnchainAnchor.t.sol (append-only vs the DEPLOYED layout; its append test pins VeHemi slots 64-66 and VVD slots 100-102 by hand)"
echo "        test/StorageLayoutGolden.t.sol hard-coded pins (entry counts, the V3 block, struct member counts, numberOfBytes) and test/G08Zero.t.sol Z7 (slot 65)"
echo "      test/StorageLayoutCompiledParity.t.sol only catches a fixture that was NOT regenerated."

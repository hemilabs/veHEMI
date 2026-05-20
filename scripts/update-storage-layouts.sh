#!/usr/bin/env bash
#
# Regenerate the committed storage layout golden fixtures.
#
# Run this script after making an INTENTIONAL change to any upgradeable
# contract's storage layout (adding a new field, extending the gap, introducing
# a VeHemiStorageV3, etc.).
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
#      is append-only (no existing slot shifted, no existing type changed).
#   4. Commit source + fixture diff in the same PR.

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

mkdir -p "$FIXTURES_DIR"

for c in "${CONTRACTS[@]}"; do
  forge inspect "$c" storageLayout --json 2>/dev/null \
    | normalize > "$FIXTURES_DIR/$c.json"
  echo "Regenerated: $FIXTURES_DIR/$c.json"
done

echo ""
echo "Review the diff with:"
echo "  git diff $FIXTURES_DIR/"
echo ""
echo "Ensure all changes are APPEND-ONLY (no existing slot shifted or re-typed)."

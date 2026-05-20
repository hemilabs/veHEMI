#!/usr/bin/env bash
#
# Storage layout CI gate.
#
# Compares the current `forge inspect <Contract> storageLayout` output against a
# committed golden fixture under test/fixtures/storage-layouts/. Any drift fails
# the build.
#
# Rationale: Solidity storage layout is load-bearing for upgradeable proxies.
# Changes to storage-contract inheritance order, field insertions, or type
# widths all manifest as layout shifts. This script catches any such shift at
# PR time, before merge.
#
# Normalization: AST IDs inside `t_struct(...)NN_storage` and similar keys
# change on every unrelated source edit. Both this script and
# update-storage-layouts.sh apply the shared `normalize` function (see
# scripts/_normalize-storage-layout.sh) so the committed fixture is stable
# and Foundry tests that read it can pin stripped keys.
#
# Regenerating goldens (after an intentional layout change):
#   ./scripts/update-storage-layouts.sh
# then commit the diff under test/fixtures/storage-layouts/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_normalize-storage-layout.sh
source "$SCRIPT_DIR/_normalize-storage-layout.sh"

# Required tools. Missing these produces a clearer error than a pipe failure.
command -v jq >/dev/null 2>&1 || { echo "ERROR: 'jq' is required. Install via apt/brew."; exit 2; }
command -v forge >/dev/null 2>&1 || { echo "ERROR: 'forge' is required. See https://getfoundry.sh"; exit 2; }
# Log versions to CI output for debugging dev/CI divergence.
echo "Using $(jq --version) and $(forge --version 2>/dev/null | head -1)"

CONTRACTS=("VeHemi" "VeHemiVoteDelegation" "VeHemiAragonAdapter")
FIXTURES_DIR="test/fixtures/storage-layouts"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
FAILED=0

for c in "${CONTRACTS[@]}"; do
  golden="$FIXTURES_DIR/$c.json"
  if [ ! -f "$golden" ]; then
    echo "ERROR: Missing golden fixture: $golden"
    echo "       Run scripts/update-storage-layouts.sh to create it."
    FAILED=1
    continue
  fi

  # Suppress foundry's stderr warnings (e.g. "unknown scripts config").
  forge inspect "$c" storageLayout --json 2>/dev/null \
    | normalize > "$WORKDIR/current-$c.json"
  # Committed fixtures are already normalized by update-storage-layouts.sh,
  # so normalizing again is a no-op but makes the script tolerant to old
  # pre-normalized fixtures during the migration window.
  normalize < "$golden" > "$WORKDIR/golden-$c.json"

  if ! diff -u "$WORKDIR/golden-$c.json" "$WORKDIR/current-$c.json"; then
    echo ""
    echo "ERROR: Storage layout regression detected in $c"
    echo "       If the change is intentional, regenerate the golden fixture:"
    echo "         ./scripts/update-storage-layouts.sh"
    echo "       Then inspect the diff under test/fixtures/storage-layouts/ and"
    echo "       ensure it is append-only (no existing slot shifted or re-typed)."
    FAILED=1
  else
    echo "OK: $c storage layout matches golden fixture"
  fi
done

exit $FAILED

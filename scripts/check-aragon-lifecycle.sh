#!/usr/bin/env bash
# =============================================================================
# Aragon lifecycle gate. CI runs it as
#   scripts/rpc-retry.sh scripts/check-aragon-lifecycle.sh .
#
#   bash scripts/check-aragon-lifecycle.sh [tree]
#
# It runs the 14 tests of `VeHemiAragonAdapterForkTest` -- DAO creation,
# proposal creation, voting, tallying, execution, quorum defeat, support defeat,
# minProposerVotingPower and delegated-power aggregation -- through the real
# AragonOSx v1.4.0 DAOFactory on Ethereum mainnet, and refuses to report a pass
# it did not earn. It guards three ways the suite can pass while checking nothing:
#
#   Guard 1  ETH_RPC_URL unset: every test `vm.skip`s and forge prints
#            "14 passed". The gate refuses to start without ETH_RPC_URL and
#            fails on skipped > 0.
#
#   Guard 2  The fork block: below block 23,341,186 TokenVoting release 1 /
#            build 4 is not yet published in the PluginRepo, so setUp reverts
#            and forge shows one red row (the DAOFactory has had code since
#            21,995,355). The gate checks the block against that floor over RPC
#            before spending fork time, so a wrong block reads as a one-line
#            diagnosis instead of 14 reverts.
#
#   Guard 3  An empty selection: `forge test --list` prints bare names but
#            `--match-test` matches signatures, so a mistyped filter selects
#            nothing and exits 0. The gate asserts that `--list` returns exactly
#            EXPECTED_TESTS tests before running them.
#
# `https://eth.drpc.org` is a free Ethereum mainnet archive endpoint and is
# enough for ETH_RPC_URL. FORK_NODE_URL is not used here.
#
# Every failure exits 3. A transport failure keeps the endpoint's own error
# text in its message, so scripts/rpc-retry.sh can tell it from a red tree.
# =============================================================================
set -uo pipefail
TREE="${1:-.}"
cd "$TREE"

EXPECTED_TESTS=14
CONTRACT="${ARAGON_LIFECYCLE_CONTRACT:-VeHemiAragonAdapterForkTest}"
COMPUTE_UNITS_PER_SECOND="${ARAGON_LIFECYCLE_COMPUTE_UNITS_PER_SECOND:-40}"
# Chain 1: PluginRepo 0xb740..287f buildCount(1) reaches 4 at this block.
# Below it, `createDao` with versionTag (1,4) reverts in setUp.
BUILD4_FLOOR=23341186
DAO_FACTORY=0x246503df057A9a85E0144b6867a828c99676128B
TOKEN_VOTING_REPO=0xb7401cD221ceAFC54093168B814Cc3d42579287f
DEFAULT_FORK_BLOCK=26000000

fail(){ echo "ARAGON-LIFECYCLE FAIL: $*"; exit 3; }

# ---- Guard 1: the endpoint must exist -------------------------------------
[ -n "${ETH_RPC_URL:-}" ] || fail "ETH_RPC_URL is unset.  With it unset this suite reports
        '14 passed' having executed NOTHING.  A free Ethereum-mainnet archive
        endpoint is enough: ETH_RPC_URL=https://eth.drpc.org"

# Keep `cast`'s stderr. Discarding it would report an endpoint timeout as a
# chain fact ("buildCount(1)= ...; need >= 4"). The endpoint's own words go into
# the failure text, where scripts/rpc-retry.sh looks for them.
CAST_ERR_FILE=$(mktemp); trap 'rm -f "$CAST_ERR_FILE"' EXIT
CHAIN_ID=$(cast chain-id --rpc-url "$ETH_RPC_URL" 2>"$CAST_ERR_FILE") || fail "ETH_RPC_URL does not answer eth_chainId -- the endpoint's own words: $(cat "$CAST_ERR_FILE")"
[ "$CHAIN_ID" = "1" ] || fail "ETH_RPC_URL is chain $CHAIN_ID; this suite needs Ethereum mainnet (chain 1).
        (The Hemi fork suites use HEMI_RPC_URL / chain 43111 -- different variable, different chain.)"

# ---- Guard 2: the block ---------------------------------------------------
FORK_BLOCK="${ETH_FORK_BLOCK:-$DEFAULT_FORK_BLOCK}"
if [ "$FORK_BLOCK" = "0" ]; then
  echo "ARAGON-LIFECYCLE WARN: ETH_FORK_BLOCK=0 -- forking at HEAD.  This run is NOT"
  echo "                       reproducible and a change to Aragon's mainnet deployment can"
  echo "                       turn it red without the diff moving.  Set ETH_FORK_BLOCK"
  echo "                       to a fixed block."
  FORK_BLOCK=$(cast block-number --rpc-url "$ETH_RPC_URL")
fi
[ "$FORK_BLOCK" -ge "$BUILD4_FLOOR" ] || fail "ETH_FORK_BLOCK=$FORK_BLOCK is below the measured floor $BUILD4_FLOOR.
        TokenVoting release 1 build 4 does not exist in the PluginRepo at that block,
        so every test dies in setUp and forge reports ONE red row, not 14."
CODE=$(cast code "$DAO_FACTORY" --block "$FORK_BLOCK" --rpc-url "$ETH_RPC_URL" 2>"$CAST_ERR_FILE") || fail "cast code on the DAOFactory did not complete at block $FORK_BLOCK -- the endpoint's own words: $(cat "$CAST_ERR_FILE")"
[ "${#CODE}" -gt 2 ] || fail "DAOFactory $DAO_FACTORY has no code at block $FORK_BLOCK
        (is the endpoint an archive node?  known to work: https://eth.drpc.org)"
BUILDS_RAW=$(cast call "$TOKEN_VOTING_REPO" 'buildCount(uint8)(uint256)' 1 --block "$FORK_BLOCK" --rpc-url "$ETH_RPC_URL" 2>"$CAST_ERR_FILE") || fail "cast call buildCount(1) did not complete at block $FORK_BLOCK -- the endpoint's own words: $(cat "$CAST_ERR_FILE")"
BUILDS=$(echo "$BUILDS_RAW" | awk '{print $1}')
[ -n "$BUILDS" ] && [ "$BUILDS" -ge 4 ] || fail "PluginRepo buildCount(1)=$BUILDS at block $FORK_BLOCK; need >= 4"
echo "ARAGON-LIFECYCLE  chain 1 (Ethereum mainnet), fork block $FORK_BLOCK, DAOFactory code ${#CODE} hex chars, buildCount(1)=$BUILDS"

# ---- the stale-artifact rule: BUILD before a filtered run -----------------
forge build >/dev/null 2>&1 || fail "forge build failed"

# ---- Guard 3: the selection must be non-empty -----------------------------
LISTED=$(forge test --list --match-contract "$CONTRACT" 2>/dev/null | grep -cE '^    test')
[ "$LISTED" = "$EXPECTED_TESTS" ] || fail "--list selected $LISTED tests for $CONTRACT, expected $EXPECTED_TESTS.
        An empty or short selection exits 0 and reads as a pass."

# ---- run ------------------------------------------------------------------
OUT=$(ETH_FORK_BLOCK="$FORK_BLOCK" FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=64 \
      FOUNDRY_INVARIANT_SHRINK_RUN_LIMIT=0 FOUNDRY_FUZZ_RUNS=16 \
      forge test --match-contract "$CONTRACT" --threads 1 \
                 --compute-units-per-second "$COMPUTE_UNITS_PER_SECOND" -vv 2>&1)
echo "$OUT" | sed 's/^/    /'

LINE=$(echo "$OUT" | grep -E '^Suite result' | tail -1)
[ -n "$LINE" ] || fail "no 'Suite result' line -- the run produced no suite at all"
PASSED=$(echo "$LINE" | sed -nE 's/.* ([0-9]+) passed.*/\1/p')
FAILED=$(echo "$LINE" | sed -nE 's/.* ([0-9]+) failed.*/\1/p')
SKIPPED=$(echo "$LINE" | sed -nE 's/.* ([0-9]+) skipped.*/\1/p')
echo "ARAGON-LIFECYCLE  passed=$PASSED failed=$FAILED skipped=$SKIPPED (expected $EXPECTED_TESTS / 0 / 0)"
[ "$SKIPPED" = "0" ] || fail "$SKIPPED test(s) SKIPPED.  A skip is not a pass."
[ "$FAILED" = "0" ] || fail "$FAILED test(s) FAILED."
[ "$PASSED" = "$EXPECTED_TESTS" ] || fail "passed=$PASSED, expected $EXPECTED_TESTS."

echo "ARAGON-LIFECYCLE OK  --  $EXPECTED_TESTS/$EXPECTED_TESTS Aragon lifecycle tests executed"
echo "                     against the real AragonOSx v1.4.0 DAOFactory on Ethereum mainnet"
echo "                     at block $FORK_BLOCK.  Nothing skipped."

#!/usr/bin/env bash
# =============================================================================
# RPC retry wrapper for the fork gates (CI wraps
# scripts/check-aragon-lifecycle.sh).
#
#   scripts/rpc-retry.sh <command> [args...]
#
# The free public endpoint `https://eth.drpc.org` intermittently answers
#
#   HTTP error 408 with body: {"message":"Request timeout on the free plan,
#   please upgrade to paid plan","code":30}
#
# Foundry's own `retries` (default, or set on an `[rpc_endpoints]` alias) is a
# rate-limit retry: it retries a 429 but does not retry a 408 at all. So the
# retry lives one level up: re-run the whole command, and only for the
# transport class.
#
# A retry that retries everything turns a real red into an intermittent green.
# This one retries only when the failed output carries a transport signature
# (TRANSPORT_RE below). A command that failed because a body failed, the block
# was below the floor, or the selection was empty is propagated at once, on
# attempt 1, with its own exit code.
#
# Exhausted retries exit 75 (EX_TEMPFAIL), never the command's own code:
# rc 1/3 = the tree is red; rc 75 = the endpoint was unreachable and nothing
# was checked.
#
# env:
#   RPC_RETRY_ATTEMPTS   total attempts, default 4
#   RPC_RETRY_BACKOFF    seconds before retry 1; doubled each time, default 5
#                        (4 attempts => waits 5 s, 10 s, 20 s = 35 s)
#   RPC_RETRY_VERBOSE    1 => echo the classifier's verdict on every attempt
# =============================================================================
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: rpc-retry.sh <command> [args...]" >&2; exit 64; }

ATTEMPTS="${RPC_RETRY_ATTEMPTS:-4}"
BACKOFF="${RPC_RETRY_BACKOFF:-5}"

# ---- SIGNATURES -------------------------------------------------------------
# Transport failures as forge and cast print them (the Aragon gate's own
# "does not answer eth_chainId" included). Add to this only from a captured log.
TRANSPORT_RE='HTTP error (40[0-9]|41[0-9]|42[0-9]|43[0-9]|5[0-9][0-9])|Request timeout on the free plan|Max retries exceeded|could not instantiate forked environment|does not answer eth_chainId|error sending request|operation timed out|connection closed before message completed|Connection refused|dns error|tcp connect error|request timed out|502 Bad Gateway|503 Service|504 Gateway'

i=1
while :; do
    OUT=$("$@" 2>&1)
    RC=$?
    printf '%s\n' "$OUT"
    if [ "$RC" -eq 0 ]; then
        [ "$i" -gt 1 ] && echo "rpc-retry: OK on attempt $i of $ATTEMPTS (the earlier attempt(s) failed on transport, not on the tree)"
        exit 0
    fi
    if printf '%s' "$OUT" | grep -qE "$TRANSPORT_RE"; then
        CLASS=TRANSPORT
    else
        CLASS=REAL
    fi
    [ "${RPC_RETRY_VERBOSE:-0}" = "1" ] && echo "rpc-retry: attempt $i rc=$RC class=$CLASS"
    if [ "$CLASS" = "REAL" ]; then
        echo "rpc-retry: attempt $i failed rc=$RC with NO transport signature."
        echo "rpc-retry: this is a REAL failure -- NOT retried, propagating rc $RC."
        exit "$RC"
    fi
    if [ "$i" -ge "$ATTEMPTS" ]; then
        echo "::error::rpc-retry: $ATTEMPTS/$ATTEMPTS attempts all failed on RPC TRANSPORT."
        echo "rpc-retry: the endpoint was unreachable or rate-limited throughout."
        echo "rpc-retry: NOTHING ABOUT THE TREE WAS CHECKED.  Exiting 75 (EX_TEMPFAIL),"
        echo "rpc-retry: deliberately NOT the command's own rc $RC, so a caller cannot"
        echo "rpc-retry: read an instrument death as the tree's guilt."
        exit 75
    fi
    echo "rpc-retry: attempt $i failed rc=$RC on RPC TRANSPORT; sleeping ${BACKOFF}s then retrying."
    sleep "$BACKOFF"
    BACKOFF=$((BACKOFF * 2))
    i=$((i + 1))
done

#!/usr/bin/env bash
# EIP-170 deployability gate (entry point; the logic is scripts/eip170_gate.py).
#
# `forge build` exits 0 on an over-limit contract, and `forge test` deploys it
# and exits 0 too. This is the check that says whether an artifact can exist on
# chain.
#
#   ./scripts/check-eip170.sh                    build + gate + write attestation
#   ./scripts/check-eip170.sh --no-build         gate the artifacts already in out/
#   ./scripts/check-eip170.sh --no-build --verify
#                                                verify only: write nothing, exit 1
#                                                on any attestation drift, a missing
#                                                attestation included. CI and
#                                                deploy/08 use --verify.
#   ./scripts/check-eip170.sh --update-manifest  re-cut the coverage manifest
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/eip170_gate.py" --root "$ROOT" "$@"

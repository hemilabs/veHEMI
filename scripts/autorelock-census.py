#!/usr/bin/env python3
"""Pre-sign census of the live VeHemiVoteDelegation state for the auto-relock upgrade.

Read-only: eth_call, eth_getLogs and eth_getStorageAt at one pinned block. Run it at the
block you will sign at, BEFORE the upgrade executes, and refuse to sign unless it prints
`CENSUS: CLEAN` and exits 0 (docs/AUTO_RELOCK_UPGRADE.md, section 4). It checks the four
premises of the upgrade-hour window and of the auto-relock accounting on the live VVD:

  P1  every delegatee checkpoint has fixedBias == 0
  P2  no delegations[id] record is flat-shaped (slope == 0 && bias > 0)
  P3  every checkpoint timestamp is an hour boundary, strictly increasing per array
      (so at most one checkpoint per hour)
  P4  each delegatee's last checkpoint is at most 4 years old, and its totalAmount and
      normalizedSlope equal the sums of amount and slope over that delegatee's records
      that end after that checkpoint; a delegatee with live records and an EMPTY
      checkpoint array is a violation (P4_empty)

Completeness: delegatees are enumerated from the token records AND from every
DelegateChanged log since the VVD proxy's deployment block; the enumeration may not start
later than that block, must be non-empty and must contain every current delegatee. Every
errored or short RPC result is counted (errors_records, errors_arrays, errors_logs).

Identity, checked FIRST: the endpoint must report Hemi mainnet (chain id 43111), and at BLOCK
the VVD proxy's implementation slot must hold the live implementation
0xAcAA0d96121C035fC21345551317d66921394128: P1-P4 are premises about the state that
implementation books, and they do not apply once the VVD runs another one. A failure stops
the run with INCOMPLETE (exit 3) before anything else is read. The VeHemi slot is recorded,
not asserted.

Exit codes: 0 CLEAN; 2 NOT CLEAN (a premise is violated or an RPC result was lost);
3 INCOMPLETE (the enumeration cannot be trusted, or the identity check failed) or bad usage.
Any other exit status (a crash: the endpoint unreachable after the retries, `cast` missing,
a non-integer BLOCK) is not a verdict and never CLEAN.

Usage:   python3 scripts/autorelock-census.py BLOCK OUT [FROM_BLOCK]
  BLOCK       the pinned block (mandatory)
  OUT         output JSON (mandatory; deleted first, written atomically with the verdict;
              OUT.records.json holds every record read)
  FROM_BLOCK  first block of the DelegateChanged enumeration (default 0; must be <= the
              VVD proxy's deployment block)
Needs `cast` (Foundry) on PATH. RPC: $HEMI_RPC_URL, default https://rpc.hemi.network/rpc
(public, rate-limited: the script batches and backs off). The summary records the block
hash, the chain id, both proxies' implementation slots at BLOCK and this script's sha256
(the early-exit summary of a failed identity check has no block hash).
"""
import hashlib, json, os, sys, time, urllib.request
SCRIPT_SHA256 = hashlib.sha256(open(__file__, "rb").read()).hexdigest()
RPC_ERRORS = {"records": 0, "arrays": 0, "logs": 0}
RPC_URL = os.environ.get("HEMI_RPC_URL", "https://rpc.hemi.network/rpc"); USER_AGENT = "veHEMI-census-readonly/1.0"
VVD = "0xBF5b2f370370494B8A4575962512dd3ea7c29e2d"; VEHEMI = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89"
if len(sys.argv) < 3 or len(sys.argv) > 4:
    print("usage: autorelock-census.py BLOCK OUT [FROM_BLOCK]  (no defaults, no override file)", flush=True); sys.exit(3)
BLOCK = int(sys.argv[1])
BLOCK_TAG = hex(BLOCK)
OUT = sys.argv[2]
VVD_DEPLOY_BLOCK = 2527716  # deployments/hemi/VeHemiVoteDelegation_Proxy.json receipt.blockNumber
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
HEMI_CHAIN_ID = 43111
LIVE_VVD_IMPL = "0xAcAA0d96121C035fC21345551317d66921394128"  # the live implementation (deploy/08 LIVE_VVD_IMPLS)
for f in (OUT, OUT + ".records.json"):
    if os.path.exists(f): os.remove(f)
_id = [0]
def rpc(reqs):
    base = _id[0]; _id[0] += len(reqs)
    payload = [{"jsonrpc": "2.0", "id": base + 1 + i, "method": m, "params": p} for i, (m, p) in enumerate(reqs)]
    body = json.dumps(payload).encode()
    for a in range(10):
        try:
            r = urllib.request.urlopen(urllib.request.Request(RPC_URL, data=body, headers={"Content-Type": "application/json", "User-Agent": USER_AGENT}), timeout=120)
            res = json.loads(r.read()); d = {x["id"]: x for x in res}
            out = [d[base + 1 + i] for i in range(len(reqs))]
            if any("error" in x and "rate" in json.dumps(x["error"]).lower() for x in out): raise RuntimeError("rate")
            return out
        except Exception as e:
            time.sleep(4 + 4 * a)
    raise RuntimeError("rpc fail")
def call(to, data): return ("eth_call", [{"to": to, "data": data}, BLOCK_TAG])
def encode_uint(n): return hex(n)[2:].rjust(64, "0")
def addr(a): return a.lower()[2:].rjust(64, "0")
# 0. identity, before anything else is read
def ok(r): return "error" not in r and isinstance(r.get("result"), str)
def slot_addr(r): return "0x" + r["result"][2:].rjust(64, "0")[-40:] if ok(r) else None
chain_id_reply = rpc([("eth_chainId", [])])[0]
chain_id = int(chain_id_reply["result"], 16) if ok(chain_id_reply) else None
impls = {k: slot_addr(rpc([("eth_getStorageAt", [a, IMPL_SLOT, BLOCK_TAG])])[0]) for k, a in (("vvd", VVD), ("vehemi", VEHEMI))}
early = []
if chain_id is None: early.append("identity read failed (RPC error on eth_chainId)")
elif chain_id != HEMI_CHAIN_ID: early.append(f"chain id {chain_id} is not Hemi mainnet {HEMI_CHAIN_ID}")
if None in impls.values(): early.append(f"identity read failed (RPC error on eth_getStorageAt at {BLOCK}; is the endpoint archive-capable?)")
elif impls["vvd"].lower() != LIVE_VVD_IMPL.lower(): early.append(f"VVD implementation at block {BLOCK} is {impls['vvd']}, not the live implementation {LIVE_VVD_IMPL}")
if early:
    verdict = "INCOMPLETE: " + "; ".join(early)
    summary = {"block": BLOCK, "chain_id": chain_id, "impl_slots": impls, "verdict": verdict, "exit_code": 3, "script_sha256": SCRIPT_SHA256}
    print(json.dumps(summary), flush=True)
    tmp = OUT + ".tmp"; json.dump({"summary": summary}, open(tmp, "w")); os.replace(tmp, OUT)
    print("CENSUS:", verdict, flush=True); sys.exit(3)
# 1. token ids
import subprocess
def sel(sig): return subprocess.check_output(["cast", "sig", sig]).decode().strip()
SEL_DELEGATIONS = sel("delegations(uint256)")
SEL_GET_DELEGATION_CHECKPOINTS = sel("getDelegationCheckpoints(address)")
next_token_id = int(rpc([call(VEHEMI, sel("nextTokenId()"))])[0]["result"], 16)
print("nextTokenId", next_token_id, flush=True)
records = {}; delegatees = set()
ids = list(range(1, next_token_id)); BATCH = 40
for k in range(0, len(ids), BATCH):
    chunk = ids[k:k + BATCH]
    res = rpc([call(VVD, SEL_DELEGATIONS + encode_uint(i)) for i in chunk])
    for i, r in zip(chunk, res):
        result_hex = (r.get("result") or "0x")[2:]
        if "error" in r or len(result_hex) < 320:
            RPC_ERRORS["records"] += 1; print("ERROR record", i, json.dumps(r)[:200], flush=True); continue
        words = [int(result_hex[j:j + 64], 16) for j in range(0, 320, 64)]
        delegatee = "0x" + result_hex[24:64]
        if int(delegatee, 16) == 0: continue
        records[i] = {"delegatee": delegatee, "end": words[1], "bias": words[2], "amount": words[3], "slope": words[4]}
        delegatees.add(delegatee)
    if k % 2000 == 0: print("ids", k, len(records), flush=True)
    time.sleep(0.25)
# 2. delegatees from DelegateChanged logs (topic2/topic3 are from/to when indexed)
DELEGATE_CHANGED_TOPIC = subprocess.check_output(["cast", "keccak", "DelegateChanged(uint256,address,address)"]).decode().strip()
enumeration_from_block = int(sys.argv[3]) if len(sys.argv) > 3 else 0
step = 50000; logged_delegatees = set(); b = enumeration_from_block; failed_ranges = []
while b <= BLOCK:
    e = min(b + step - 1, BLOCK)
    r = rpc([("eth_getLogs", [{"address": VVD, "fromBlock": hex(b), "toBlock": hex(e), "topics": [DELEGATE_CHANGED_TOPIC]}])])[0]
    if "error" in r:
        if step == 1000:
            RPC_ERRORS["logs"] += 1; failed_ranges.append([b, e]); print("ERROR logs", b, e, json.dumps(r["error"])[:200], flush=True)
            b = e + 1; continue
        step = max(1000, step // 4); continue
    for lg in r["result"]:
        for t in lg["topics"][2:4]:
            logged_delegatees.add("0x" + t[26:])
        if len(lg["topics"]) < 4 and len(lg["data"]) >= 130:
            log_data = lg["data"][2:]
            for j in (0, 64):
                logged_delegatees.add("0x" + log_data[j + 24:j + 64])
    b = e + 1
logged_delegatees.discard("0x" + "0" * 40)
print("current delegatees", len(delegatees), "from logs", len(logged_delegatees), flush=True)
all_delegatees = sorted(delegatees | logged_delegatees)
delegatees_missing_from_logs = sorted(delegatees - logged_delegatees)
# 3. arrays
violations = {"P1": [], "P3_align": [], "P3_order": [], "P4_old": [], "P4_amount": [], "P4_slope": [], "P4_empty": []}
records_by_delegatee = {}
for i, r in records.items(): records_by_delegatee.setdefault(r["delegatee"], []).append(r)
block_header = rpc([("eth_getBlockByNumber", [BLOCK_TAG, False])])[0]["result"]
block_timestamp = int(block_header["timestamp"], 16)
max_checkpoints = 0; total_checkpoints = 0
for k in range(0, len(all_delegatees), 20):
    chunk = all_delegatees[k:k + 20]
    res = rpc([call(VVD, SEL_GET_DELEGATION_CHECKPOINTS + addr(delegatee)) for delegatee in chunk])
    for delegatee, r in zip(chunk, res):
        result_hex = (r.get("result") or "0x")[2:]
        if "error" in r or len(result_hex) < 128:
            RPC_ERRORS["arrays"] += 1; print("ERROR array", delegatee, json.dumps(r)[:200], flush=True); continue
        n = int(result_hex[64:128], 16)
        if len(result_hex) < 128 + n * 320:
            RPC_ERRORS["arrays"] += 1; print("ERROR short array", delegatee, n, len(result_hex), flush=True); continue
        total_checkpoints += n; max_checkpoints = max(max_checkpoints, n)
        checkpoints = []
        for j in range(n):
            offset = 128 + j * 320
            words = [int(result_hex[offset + word_offset:offset + word_offset + 64], 16) for word_offset in range(0, 320, 64)]
            checkpoints.append({"normalizedBias": words[0], "fixedBias": words[1], "totalAmount": words[2], "normalizedSlope": words[3], "timestamp": words[4]})
        prev = -1
        for checkpoint in checkpoints:
            if checkpoint["fixedBias"] != 0: violations["P1"].append((delegatee, checkpoint["timestamp"]))
            if checkpoint["timestamp"] % 3600 != 0: violations["P3_align"].append((delegatee, checkpoint["timestamp"]))
            if checkpoint["timestamp"] <= prev: violations["P3_order"].append((delegatee, prev, checkpoint["timestamp"]))
            prev = checkpoint["timestamp"]
        if not checkpoints and any(r["end"] > block_timestamp for r in records_by_delegatee.get(delegatee, [])):
            violations["P4_empty"].append(delegatee)
        if checkpoints:
            if block_timestamp - checkpoints[-1]["timestamp"] > 126230400: violations["P4_old"].append((delegatee, checkpoints[-1]["timestamp"]))
            last_ts = checkpoints[-1]["timestamp"]
            active_amount = sum(r["amount"] for r in records_by_delegatee.get(delegatee, []) if r["end"] > last_ts)
            active_slope = sum(r["slope"] for r in records_by_delegatee.get(delegatee, []) if r["end"] > last_ts)
            if checkpoints[-1]["totalAmount"] != active_amount: violations["P4_amount"].append((delegatee, checkpoints[-1]["totalAmount"], active_amount))
            if checkpoints[-1]["normalizedSlope"] != active_slope: violations["P4_slope"].append((delegatee, checkpoints[-1]["normalizedSlope"], active_slope))
    if k % 1000 == 0: print("arrays", k, flush=True)
    time.sleep(0.25)
flat_ids = [i for i, r in records.items() if r["slope"] == 0 and r["bias"] > 0]
problem_count = sum(RPC_ERRORS.values()) + len(flat_ids) + sum(len(v) for v in violations.values())
incomplete = []
if enumeration_from_block > VVD_DEPLOY_BLOCK: incomplete.append(f"enumeration starts at {enumeration_from_block} > VVD deployment block {VVD_DEPLOY_BLOCK}")
if len(logged_delegatees) == 0: incomplete.append("no DelegateChanged delegatee found")
if delegatees_missing_from_logs: incomplete.append(f"{len(delegatees_missing_from_logs)} current delegatee(s) absent from the DelegateChanged enumeration")
if len(records) == 0 or total_checkpoints == 0 or len(all_delegatees) == 0: incomplete.append("records/checkpoints/delegatees read == 0")
if chain_id != HEMI_CHAIN_ID: incomplete.append(f"chain id {chain_id} is not Hemi mainnet {HEMI_CHAIN_ID}")
if impls["vvd"].lower() != LIVE_VVD_IMPL.lower(): incomplete.append(f"VVD implementation at BLOCK is {impls['vvd']}, not the live implementation {LIVE_VVD_IMPL}")
if incomplete: verdict, exit_code = "INCOMPLETE: " + "; ".join(incomplete), 3
elif problem_count: verdict, exit_code = f"NOT CLEAN ({problem_count})", 2
else: verdict, exit_code = "CLEAN", 0
summary = {"block": BLOCK, "block_hash": block_header["hash"], "chain_id": chain_id, "impl_slots": impls, "block_timestamp": block_timestamp,
           "enumeration_from_block": enumeration_from_block, "delegatees_from_logs": len(logged_delegatees), "delegatees_missing_from_logs": len(delegatees_missing_from_logs),
           "records": len(records), "delegatees_current": len(delegatees), "delegatees_all": len(all_delegatees),
           "checkpoints_total": total_checkpoints, "max_checkpoints_per_delegatee": max_checkpoints, "P2": len(flat_ids), **{k: len(v) for k, v in violations.items()},
           **{"errors_" + k: v for k, v in RPC_ERRORS.items()}, "failed_log_ranges": failed_ranges,
           "verdict": verdict, "exit_code": exit_code, "script_sha256": SCRIPT_SHA256}
print(json.dumps(summary), flush=True)
def write_atomic(path, obj):
    tmp = path + ".tmp"
    json.dump(obj, open(tmp, "w")); os.replace(tmp, path)
write_atomic(OUT + ".records.json", records)
write_atomic(OUT, {"summary": summary, "P2_ids": flat_ids[:200], "delegatees_missing_from_logs": delegatees_missing_from_logs[:200],
                   "violations": {k: v[:200] for k, v in violations.items()}})
print("CENSUS:", verdict, flush=True)
sys.exit(exit_code)

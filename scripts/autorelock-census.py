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
the VVD proxy's implementation slot must hold the live writer
0xAcAA0d96121C035fC21345551317d66921394128: P1-P4 are premises about the state that
implementation books, and they do not apply once the VVD runs another one. A failure stops
the run with INCOMPLETE (exit 3) before anything else is read. The VeHemi slot is recorded,
not asserted.

Exit codes: 0 CLEAN; 2 NOT CLEAN (a premise is violated or an RPC result was lost);
3 INCOMPLETE (the enumeration cannot be trusted, or the identity check failed) or bad usage.
Any other exit status (a crash: the endpoint unreachable after the retries, `cast` missing,
a non-integer BLOCK) is not a verdict and never CLEAN.

Usage:   python3 scripts/autorelock-census.py BLOCK OUT [LO]
  BLOCK  the pinned block (mandatory)
  OUT    output JSON (mandatory; deleted first, written atomically with the verdict;
         OUT.records.json holds every record read)
  LO     first block of the DelegateChanged enumeration (default 0; must be <= the VVD
         proxy's deployment block)
Needs `cast` (Foundry) on PATH. RPC: $HEMI_RPC_URL, default https://rpc.hemi.network/rpc
(public, rate-limited: the script batches and backs off). The summary records the block
hash, the chain id, both proxies' implementation slots at BLOCK and this script's sha256
(the early-exit summary of a failed identity check has no block hash).
"""
import hashlib, json, os, sys, time, urllib.request
SCRIPT_SHA256 = hashlib.sha256(open(__file__, "rb").read()).hexdigest()
ERR = {"records": 0, "arrays": 0, "logs": 0}
EP = os.environ.get("HEMI_RPC_URL", "https://rpc.hemi.network/rpc"); UA = "veHEMI-census-readonly/1.0"
VVD = "0xBF5b2f370370494B8A4575962512dd3ea7c29e2d"; VH = "0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89"
if len(sys.argv) < 3 or len(sys.argv) > 4:
    print("usage: autorelock-census.py BLOCK OUT [LO]  (no defaults, no override file)", flush=True); sys.exit(3)
BLOCK = int(sys.argv[1])
TAG = hex(BLOCK)
OUT = sys.argv[2]
VVD_DEPLOY_BLOCK = 2527716  # deployments/hemi/VeHemiVoteDelegation_Proxy.json receipt.blockNumber
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
HEMI_CHAIN_ID = 43111
LIVE_VVD_IMPL = "0xAcAA0d96121C035fC21345551317d66921394128"  # the boundary-dating writer (deploy/08 BOUNDARY_DATING_VVD_IMPLS)
for f in (OUT, OUT + ".records.json"):
    if os.path.exists(f): os.remove(f)
_id = [0]
def rpc(reqs):
    base = _id[0]; _id[0] += len(reqs)
    payload = [{"jsonrpc": "2.0", "id": base + 1 + i, "method": m, "params": p} for i, (m, p) in enumerate(reqs)]
    body = json.dumps(payload).encode()
    for a in range(10):
        try:
            r = urllib.request.urlopen(urllib.request.Request(EP, data=body, headers={"Content-Type": "application/json", "User-Agent": UA}), timeout=120)
            res = json.loads(r.read()); d = {x["id"]: x for x in res}
            out = [d[base + 1 + i] for i in range(len(reqs))]
            if any("error" in x and "rate" in json.dumps(x["error"]).lower() for x in out): raise RuntimeError("rate")
            return out
        except Exception as e:
            time.sleep(4 + 4 * a)
    raise RuntimeError("rpc fail")
def call(to, data): return ("eth_call", [{"to": to, "data": data}, TAG])
def u(n): return hex(n)[2:].rjust(64, "0")
def addr(a): return a.lower()[2:].rjust(64, "0")
# 0. identity, before anything else is read
def ok(r): return "error" not in r and isinstance(r.get("result"), str)
def slot_addr(r): return "0x" + r["result"][2:].rjust(64, "0")[-40:] if ok(r) else None
_c = rpc([("eth_chainId", [])])[0]
chain_id = int(_c["result"], 16) if ok(_c) else None
impls = {k: slot_addr(rpc([("eth_getStorageAt", [a, IMPL_SLOT, TAG])])[0]) for k, a in (("vvd", VVD), ("vehemi", VH))}
early = []
if chain_id is None: early.append("identity read failed (RPC error on eth_chainId)")
elif chain_id != HEMI_CHAIN_ID: early.append(f"chain id {chain_id} is not Hemi mainnet {HEMI_CHAIN_ID}")
if None in impls.values(): early.append(f"identity read failed (RPC error on eth_getStorageAt at {BLOCK}; is the endpoint archive-capable?)")
elif impls["vvd"].lower() != LIVE_VVD_IMPL.lower(): early.append(f"VVD implementation at block {BLOCK} is {impls['vvd']}, not the live writer {LIVE_VVD_IMPL}")
if early:
    verdict = "INCOMPLETE: " + "; ".join(early)
    summary = {"block": BLOCK, "chain_id": chain_id, "impl_slots": impls, "verdict": verdict, "rc": 3, "script_sha256": SCRIPT_SHA256}
    print(json.dumps(summary), flush=True)
    tmp = OUT + ".tmp"; json.dump({"summary": summary}, open(tmp, "w")); os.replace(tmp, OUT)
    print("CENSUS:", verdict, flush=True); sys.exit(3)
# 1. token ids
import subprocess
def sel(sig): return subprocess.check_output(["cast", "sig", sig]).decode().strip()
SEL_DELEGATIONS = sel("delegations(uint256)")
SEL_CPS = sel("getDelegationCheckpoints(address)")
nt = int(rpc([call(VH, sel("nextTokenId()"))])[0]["result"], 16)
print("nextTokenId", nt, flush=True)
records = {}; delegatees = set()
ids = list(range(1, nt)); B = 40
for k in range(0, len(ids), B):
    ch = ids[k:k + B]
    res = rpc([call(VVD, SEL_DELEGATIONS + u(i)) for i in ch])
    for i, r in zip(ch, res):
        h = (r.get("result") or "0x")[2:]
        if "error" in r or len(h) < 320:
            ERR["records"] += 1; print("ERROR record", i, json.dumps(r)[:200], flush=True); continue
        w = [int(h[j:j + 64], 16) for j in range(0, 320, 64)]
        d = "0x" + h[24:64]
        if int(d, 16) == 0: continue
        records[i] = {"d": d, "end": w[1], "bias": w[2], "amount": w[3], "slope": w[4]}
        delegatees.add(d)
    if k % 2000 == 0: print("ids", k, len(records), flush=True)
    time.sleep(0.25)
# 2. historical delegatees from DelegateChanged logs (topic2/topic3 are from/to when indexed)
TOPIC = subprocess.check_output(["cast", "keccak", "DelegateChanged(uint256,address,address)"]).decode().strip()
lo = int(sys.argv[3]) if len(sys.argv) > 3 else 0
step = 50000; hist = set(); b = lo; failed_ranges = []
while b <= BLOCK:
    e = min(b + step - 1, BLOCK)
    r = rpc([("eth_getLogs", [{"address": VVD, "fromBlock": hex(b), "toBlock": hex(e), "topics": [TOPIC]}])])[0]
    if "error" in r:
        if step == 1000:
            ERR["logs"] += 1; failed_ranges.append([b, e]); print("ERROR logs", b, e, json.dumps(r["error"])[:200], flush=True)
            b = e + 1; continue
        step = max(1000, step // 4); continue
    for lg in r["result"]:
        for t in lg["topics"][2:4]:
            hist.add("0x" + t[26:])
        if len(lg["topics"]) < 4 and len(lg["data"]) >= 130:
            dd = lg["data"][2:]
            for j in (0, 64):
                hist.add("0x" + dd[j + 24:j + 64])
    b = e + 1
hist.discard("0x" + "0" * 40)
print("current delegatees", len(delegatees), "historical", len(hist), flush=True)
allD = sorted(delegatees | hist)
missing_from_hist = sorted(delegatees - hist)
# 3. arrays
viol = {"P1": [], "P3_align": [], "P3_order": [], "P4_old": [], "P4_amount": [], "P4_slope": [], "P4_empty": []}
byD = {}
for i, r in records.items(): byD.setdefault(r["d"], []).append(r)
blk = rpc([("eth_getBlockByNumber", [TAG, False])])[0]["result"]
now = int(blk["timestamp"], 16)
maxlen = 0; total_el = 0
for k in range(0, len(allD), 20):
    ch = allD[k:k + 20]
    res = rpc([call(VVD, SEL_CPS + addr(d)) for d in ch])
    for d, r in zip(ch, res):
        h = (r.get("result") or "0x")[2:]
        if "error" in r or len(h) < 128:
            ERR["arrays"] += 1; print("ERROR array", d, json.dumps(r)[:200], flush=True); continue
        n = int(h[64:128], 16)
        if len(h) < 128 + n * 320:
            ERR["arrays"] += 1; print("ERROR short array", d, n, len(h), flush=True); continue
        total_el += n; maxlen = max(maxlen, n)
        els = []
        for j in range(n):
            o = 128 + j * 320
            w = [int(h[o + q:o + q + 64], 16) for q in range(0, 320, 64)]
            els.append({"nb": w[0], "fb": w[1], "amt": w[2], "slope": w[3], "ts": w[4]})
        prev = -1
        for e_ in els:
            if e_["fb"] != 0: viol["P1"].append((d, e_["ts"]))
            if e_["ts"] % 3600 != 0: viol["P3_align"].append((d, e_["ts"]))
            if e_["ts"] <= prev: viol["P3_order"].append((d, prev, e_["ts"]))
            prev = e_["ts"]
        if not els and any(r["end"] > now for r in byD.get(d, [])):
            viol["P4_empty"].append(d)
        if els:
            if now - els[-1]["ts"] > 126230400: viol["P4_old"].append((d, els[-1]["ts"]))
            lt = els[-1]["ts"]
            liveAmt = sum(r["amount"] for r in byD.get(d, []) if r["end"] > lt)
            liveSlope = sum(r["slope"] for r in byD.get(d, []) if r["end"] > lt)
            if els[-1]["amt"] != liveAmt: viol["P4_amount"].append((d, els[-1]["amt"], liveAmt))
            if els[-1]["slope"] != liveSlope: viol["P4_slope"].append((d, els[-1]["slope"], liveSlope))
    if k % 1000 == 0: print("arrays", k, flush=True)
    time.sleep(0.25)
p2 = [i for i, r in records.items() if r["slope"] == 0 and r["bias"] > 0]
bad = sum(ERR.values()) + len(p2) + sum(len(v) for v in viol.values())
incomplete = []
if lo > VVD_DEPLOY_BLOCK: incomplete.append(f"enumeration starts at {lo} > VVD deployment block {VVD_DEPLOY_BLOCK}")
if len(hist) == 0: incomplete.append("no DelegateChanged delegatee found")
if missing_from_hist: incomplete.append(f"{len(missing_from_hist)} current delegatee(s) absent from the DelegateChanged enumeration")
if len(records) == 0 or total_el == 0 or len(allD) == 0: incomplete.append("records/elements/delegatees read == 0")
if chain_id != HEMI_CHAIN_ID: incomplete.append(f"chain id {chain_id} is not Hemi mainnet {HEMI_CHAIN_ID}")
if impls["vvd"].lower() != LIVE_VVD_IMPL.lower(): incomplete.append(f"VVD implementation at BLOCK is {impls['vvd']}, not the live writer {LIVE_VVD_IMPL}")
if incomplete: verdict, rc = "INCOMPLETE: " + "; ".join(incomplete), 3
elif bad: verdict, rc = f"NOT CLEAN ({bad})", 2
else: verdict, rc = "CLEAN", 0
summary = {"block": BLOCK, "block_hash": blk["hash"], "chain_id": chain_id, "impl_slots": impls, "now": now,
           "enum_from": lo, "delegatees_hist": len(hist), "missing_from_hist": len(missing_from_hist),
           "records": len(records), "delegatees_current": len(delegatees), "delegatees_all": len(allD),
           "elements": total_el, "max_len": maxlen, "P2": len(p2), **{k: len(v) for k, v in viol.items()},
           **{"errors_" + k: v for k, v in ERR.items()}, "failed_log_ranges": failed_ranges,
           "verdict": verdict, "rc": rc, "script_sha256": SCRIPT_SHA256}
print(json.dumps(summary), flush=True)
def write_atomic(path, obj):
    tmp = path + ".tmp"
    json.dump(obj, open(tmp, "w")); os.replace(tmp, path)
write_atomic(OUT + ".records.json", records)
write_atomic(OUT, {"summary": summary, "P2_ids": p2[:200], "missing_from_hist": missing_from_hist[:200],
                   "viol": {k: v[:200] for k, v in viol.items()}})
print("CENSUS:", verdict, flush=True)
sys.exit(rc)

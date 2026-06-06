# E5: per-log-line enrichment oracle. Joins the app's enriched stdout
# (JSON lines {"oracle_log": "idN", "trace_id": ...}) against the true
# server trace per id from the OBI text printer, and classifies every line:
#   correct      injected trace_id == that request's server trace
#   WRONG-TRACE  injected trace_id belongs to ANOTHER request's trace
#   wrong-other  injected trace_id matches no oracle server trace
#   unenriched   no trace_id injected (zero ctx or non-JSON path)
# Usage: analyze_e5.py <app_log> <obi_spans_log>
import json
import re
import sys
from collections import defaultdict

TP = re.compile(r"traceparent=\[00-([0-9a-f]{32})-")
LINE = re.compile(r"\) HTTP\(subType=\d+\) \d+ \S+ (\S+)")
SRV = re.compile(r"/oracle/(id\d+)$")

servers = {}
for line in open(sys.argv[2]):
    m, l = TP.search(line), LINE.search(line)
    if not m or not l:
        continue
    mm = SRV.search(l.group(1).split("(")[0])
    if mm:
        servers[mm.group(1)] = m.group(1)
trace_to_id = {v: k for k, v in servers.items()}

logs = {}
dup = defaultdict(int)
for line in open(sys.argv[1], errors="replace"):
    # docker compose logs prefix: "app-1  | {json}"
    i = line.find("{")
    if i < 0:
        continue
    try:
        obj = json.loads(line[i:])
    except json.JSONDecodeError:
        continue
    if not isinstance(obj, dict) or "oracle_log" not in obj:
        continue
    lid = obj["oracle_log"]
    if lid in logs:
        dup[lid] += 1
    logs[lid] = obj.get("trace_id")

correct = wrong = wrong_other = unenriched = no_log = 0
wrong_pairs = []
for sid, tr in sorted(servers.items()):
    if sid not in logs:
        no_log += 1
        continue
    injected = logs[sid]
    if injected is None:
        unenriched += 1
    elif injected == tr:
        correct += 1
    elif injected in trace_to_id:
        wrong += 1
        wrong_pairs.append((sid, trace_to_id[injected]))
    else:
        wrong_other += 1

n = len(servers)
print(f"oracle server spans: {n}, oracle log lines: {len(logs)}")
print(f"  enriched with OWN trace (correct):   {correct}")
print(f"  enriched with ANOTHER request trace: {wrong} {wrong_pairs[:10]}")
print(f"  enriched with unknown trace:         {wrong_other}")
print(f"  unenriched (no trace_id injected):   {unenriched}")
print(f"  server span without log line:        {no_log}")
if dup:
    print(f"  duplicate log lines: {sum(dup.values())}")
if n:
    print(f"VERDICT: correct={100.0*correct/n:.2f}% wrong-trace={100.0*wrong/n:.2f}% "
          f"unenriched={100.0*unenriched/n:.2f}% (of {n})")

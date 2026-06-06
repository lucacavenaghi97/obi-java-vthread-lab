#!/usr/bin/env python3
# Verdicts for the raw-TCP and DNS oracle arms.
#
#   analyze_tcpdns.py tcp <spans.log> <driver_out.txt>
#     Per raw-TCP request id, the /echo/{id} HTTPClient span must carry a
#     nonzero parent (the kernel-side TCP server context) and a trace id not
#     shared with any other request id (cross-wire detector).
#
#   analyze_tcpdns.py dns <spans.log>
#     Each DNS span for "downstream." must join an /oracle/{id} request trace
#     and be parented to that request's server span.
import re
import sys
from collections import defaultdict

mode, spans_path = sys.argv[1], sys.argv[2]
TP = r"traceparent=\[00-([0-9a-f]{32})-([0-9a-f]{16})\[([0-9a-f]{16})\]-(\d\d)\]"
ZERO = "0000000000000000"

echo_client = {}  # id -> set((trace, parent))
oracle_server = {}  # trace -> server span id
dns_spans = []

for line in open(spans_path, errors="replace"):
    m = re.search(TP, line)
    if not m:
        continue
    trace, span, parent, _flags = m.groups()
    em = re.search(r"GET /echo/([a-z]*id\d+)\(", line)
    if em and "HTTPClient" in line:
        echo_client.setdefault(em.group(1), set()).add((trace, parent))
        continue
    om = re.search(r"GET /oracle/[a-z0-9]+\(", line)
    if om and "HTTP(" in line:
        oracle_server[trace] = span
        continue
    if "DNS(" in line and "downstream." in line:
        dns_spans.append((trace, span, parent))

if mode == "tcp":
    driven = [l.split()[0] for l in open(sys.argv[3]) if l.strip().endswith("OK")]
    trace_owners = defaultdict(set)
    orphan, missing, multi = [], [], []
    for rid in driven:
        pairs = echo_client.get(rid)
        if not pairs:
            missing.append(rid)
            continue
        traces = {t for t, _ in pairs}
        if len(traces) > 1:
            multi.append(rid)
        for t in traces:
            trace_owners[t].add(rid)
        if all(p == ZERO for _, p in pairs):
            orphan.append(rid)
    crosswired = {t: o for t, o in trace_owners.items() if len(o) > 1}
    cw_ids = set().union(*crosswired.values()) if crosswired else set()
    bad = set(orphan) | cw_ids | set(multi)
    correct = [r for r in driven if r not in bad and r not in missing]
    print(f"raw-TCP driven OK: {len(driven)}")
    print(f"  client span found:            {len(driven) - len(missing)}")
    print(f"  correct (own trace, parented): {len(correct)}")
    print(f"  CROSS-WIRED (shared trace):    {len(cw_ids)} {sorted(cw_ids)[:6]}")
    print(f"  orphaned (zero parent):        {len(orphan)} {orphan[:6]}")
    print(f"  multi-trace ids:               {len(multi)}")
    print(f"  missing client span:           {len(missing)}")
    denom = len(driven) - len(missing)
    pct = 100.0 * len(correct) / denom if denom else 0.0
    print(f"VERDICT tcp: {len(correct)}/{denom} = {pct:.2f}% correct")
else:
    attributed = sum(1 for t, _s, _p in dns_spans if t in oracle_server)
    correct = sum(1 for t, _s, p in dns_spans if oracle_server.get(t) == p)
    orphan = sum(1 for _t, _s, p in dns_spans if p == ZERO)
    foreign = len(dns_spans) - attributed
    print(f"DNS spans for downstream.: {len(dns_spans)} (oracle traces: {len(oracle_server)})")
    print(f"  joined an oracle trace:        {attributed}")
    print(f"  parented to ITS server span:   {correct}")
    print(f"  orphaned (zero parent):        {orphan}")
    print(f"  foreign/unmatched trace:       {foreign}")
    pct = 100.0 * correct / len(dns_spans) if dns_spans else 0.0
    print(f"VERDICT dns: {correct}/{len(dns_spans)} = {pct:.2f}% correctly parented")

# E3 per-request oracle. Unlike ../../repro/analyze.py (orphan rate = trace
# membership, blind to wrong-server attribution), this matches every client
# span to ITS OWN request through the unique path id and classifies:
#   ok            same trace AND parented to that request's server span
#   wrong_parent  same trace, different parent span (flagged, not failed)
#   CROSS-WIRED   client landed in ANOTHER request's trace (the failure mode
#                 the orphan metric cannot see)
#   orphan        client trace matches no oracle server trace
import re
import sys
from collections import defaultdict

TP = re.compile(r"traceparent=\[00-([0-9a-f]{32})-([0-9a-f]{16})\[([0-9a-f]{16})\]")
# printer: "... (dur[dur]) HTTP(subType=0) 200 GET /oracle/id5(route) [...]"
LINE = re.compile(r"\) (HTTP|HTTPClient)\(subType=\d+\) (\d+) (\S+) (\S+)")

servers = {}  # id -> (trace, span)
clients = {}  # id -> (trace, span, parent)
dup_srv = defaultdict(int)
dup_cli = defaultdict(int)

for line in open(sys.argv[1]):
    m = TP.search(line)
    l = LINE.search(line)
    if not m or not l:
        continue
    kind, path = l.group(1), l.group(4).split("(")[0]
    tr, sp, pa = m.groups()
    if kind == "HTTP":
        mm = re.search(r"/(?:oracle|oracle-tls|mixed-pt)/(id\d+)$", path)
        if mm:
            if mm.group(1) in servers:
                dup_srv[mm.group(1)] += 1
            servers[mm.group(1)] = (tr, sp)
    else:
        mm = re.search(r"/echo/(?:pt-)?(id\d+)$", path)
        if mm:
            if mm.group(1) in clients:
                dup_cli[mm.group(1)] += 1
            clients[mm.group(1)] = (tr, sp, pa)

trace_to_id = {v[0]: k for k, v in servers.items()}
ok = wrong_parent = cross = orphan = missing_client = 0
cross_pairs = []
for sid, (tr, sp) in sorted(servers.items()):
    c = clients.get(sid)
    if c is None:
        missing_client += 1
        continue
    ctr, csp, cpa = c
    if ctr == tr:
        if cpa == sp:
            ok += 1
        else:
            wrong_parent += 1
    elif ctr in trace_to_id:
        cross += 1
        cross_pairs.append((sid, trace_to_id[ctr]))
    else:
        orphan += 1

n = len(servers)
print(f"oracle server spans: {n}")
print(f"oracle client spans: {len(clients)}")
print(f"  correctly stitched (same trace AND parent == server span): {ok}")
print(f"  same trace, unexpected parent:                             {wrong_parent}")
print(f"  CROSS-WIRED to another request's trace:                    {cross} {cross_pairs[:10]}")
print(f"  orphaned (trace matches no oracle server):                 {orphan}")
print(f"  server with no client span found:                          {missing_client}")
if dup_srv or dup_cli:
    print(f"  duplicate spans per id: srv={sum(dup_srv.values())} cli={sum(dup_cli.values())}")
if n:
    bad = cross + orphan + wrong_parent
    print(f"VERDICT: {ok}/{n} = {100.0 * ok / n:.2f}% correct; "
          f"misattributed={cross} orphaned={orphan} ({100.0 * bad / n:.2f}% bad)")

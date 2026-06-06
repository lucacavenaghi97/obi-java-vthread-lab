import re, sys

TP = re.compile(r"traceparent=\[00-([0-9a-f]{32})-([0-9a-f]{16})\[([0-9a-f]{16})\]")
servers = {}      # trace_id -> set(server span ids)
clients = []      # (trace_id, span_id, parent_id)

for line in open(sys.argv[1]):
    m = TP.search(line)
    if not m:
        continue
    tr, sp, pa = m.groups()
    if ") HTTP(subType" in line and "/work" in line:
        servers.setdefault(tr, set()).add(sp)
    elif ") HTTPClient(subType" in line:
        clients.append((tr, sp, pa))

n = len(clients)
correct = sum(1 for tr, sp, pa in clients if tr in servers and pa in servers[tr])
orphan = sum(1 for tr, sp, pa in clients if tr not in servers)
nsrv = sum(len(v) for v in servers.values())
print(f"server spans (/work): {nsrv}")
print(f"client spans:         {n}")
if n:
    print(f"  correctly nested:   {correct}")
    print(f"  orphaned:           {orphan}")
    print(f"  broken correlation: {n - correct}/{n} = {100*(n-correct)/n:.1f}%")

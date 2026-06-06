# E4 analysis: per-cell median/min/max, pre-registered deltas first, noise
# floor from the jtpin-vt-all null replicates (repeats 1-10 of that cell).
# CPU columns are cgroup cpu.stat snapshots "usage;user;system" (usec) taken
# at measure start/end; reported as CPU-seconds per 1000 requests.
import csv
import os
import re
import statistics as st
import sys

rows = list(csv.DictReader(open(sys.argv[1] if len(sys.argv) > 1 else "results/e4.csv")))

# this hey build prints "99%% in 0.0779 secs", which defeated the in-run awk;
# re-extract latencies from the saved raw outputs.
def hey_latencies(kind, threads, mode, rep):
    path = f"results/hey_{kind}-{threads}-{mode}-r{rep}.txt"
    if not os.path.exists(path):
        return {}
    out = {}
    for line in open(path):
        m = re.match(r"\s+(\d+)%+ in ([0-9.]+) secs", line)
        if m:
            out["p" + m.group(1)] = float(m.group(2))
    return out

def usec(triple):
    return [int(x) for x in triple.split(";")]

def cell(rows, kind, threads, mode):
    out = []
    for r in rows:
        if (r["kind"], r["threads"], r["mode"]) != (kind, threads, mode):
            continue
        rps = float(r["rps"] or 0)
        if rps == 0 and not kind.startswith("churn"):
            continue
        n_req = rps * 60
        a0, a1 = usec(r["app0"]), usec(r["app1"])
        o0, o1 = usec(r["obi0"]), usec(r["obi1"])
        lat = hey_latencies(kind, threads, mode, r["rep"])
        out.append({
            "rps": rps,
            "p50": lat.get("p50", 0.0), "p99": lat.get("p99", 0.0),
            "app_cpu_s": (a1[0] - a0[0]) / 1e6,
            "obi_cpu_s": (o1[0] - o0[0]) / 1e6,
            "cpu_per_kreq": ((a1[0] - a0[0]) + (o1[0] - o0[0])) / 1e6 / (n_req / 1000) if n_req else 0,
            "freq": float(r["freq"] or 0),
        })
    return out

def fmt(vals):
    if not vals:
        return "n/a"
    if len(vals) == 1:
        return f"{vals[0]:.1f}"
    return f"{st.median(vals):.1f} [{min(vals):.1f}..{max(vals):.1f}]"

KINDS = ["noobi", "jtpin", "fix"]
print("== cells (median [min..max] over repeats) ==")
print(f"{'cell':24} {'rps':>22} {'p99(s)':>10} {'cpu_s/kreq':>20} {'freq':>8}")
for mode in ["all", "disabled"]:
    for threads in ["pt", "vt"]:
        for kind in KINDS:
            if kind == "noobi" and mode == "disabled":
                continue
            c = cell(rows, kind, threads, mode)
            if not c:
                continue
            print(f"{kind+'-'+threads+'-'+mode:24}"
                  f" {fmt([x['rps'] for x in c]):>22}"
                  f" {st.median([x['p99'] for x in c]):>10.4f}"
                  f" {fmt([x['cpu_per_kreq']*1000 for x in c]):>20}"
                  f" {st.median([x['freq'] for x in c]):>8.0f}")

# noise floor: spread of jtpin-vt-all across ALL its repeats (incl. nulls)
null = [x["rps"] for x in cell(rows, "jtpin", "vt", "all")]
if len(null) >= 4:
    med = st.median(null)
    floor = max(abs(v - med) for v in null) / med * 100
    print(f"\n== noise floor (jtpin-vt-all, n={len(null)}): +/-{floor:.1f}% on throughput ==")

def delta(kind_a, kind_b, threads, mode, metric):
    a = [x[metric] for x in cell(rows, kind_a, threads, mode)]
    b = [x[metric] for x in cell(rows, kind_b, threads, mode)]
    if not a or not b:
        return None
    return (st.median(a) - st.median(b)) / st.median(b) * 100

print("\n== PRE-REGISTERED comparisons ==")
for threads, label in [("vt", "cost of being correct under VT"),
                       ("pt", "added-code tax on platform threads")]:
    for mode in ["all", "disabled"]:
        d_rps = delta("fix", "jtpin", threads, mode, "rps")
        d_cpu = delta("fix", "jtpin", threads, mode, "cpu_per_kreq")
        if d_rps is None:
            continue
        print(f"fix vs jtpin {threads}/{mode} ({label}):"
              f" throughput {d_rps:+.1f}%, cpu/req {d_cpu:+.1f}%")

print("\n== context (OBI baseline) ==")
for threads in ["pt", "vt"]:
    d = delta("jtpin", "noobi", threads, "all", "rps")
    if d is not None:
        print(f"jtpin vs noobi {threads}/all: throughput {d:+.1f}%")

print("\n== churn (60s, 64 VTs on 2 carriers, no HTTP): CPU seconds ==")
for kind in ["churn-jtpin", "churn-fix"]:
    c = [r for r in rows if r["kind"] == kind]
    if not c:
        continue
    app = [(usec(r["app1"])[0] - usec(r["app0"])[0]) / 1e6 for r in c]
    obi = [(usec(r["obi1"])[0] - usec(r["obi0"])[0]) / 1e6 for r in c]
    print(f"{kind}: app {fmt(app)} s, obi {fmt(obi)} s (over 60 s window)")

print("\n== non-Java tax (nginx-only) ==")
for kind in ["nonjava-jtpin", "nonjava-fix"]:
    c = [r for r in rows if r["kind"] == kind]
    if not c:
        continue
    rps = [float(r["rps"]) for r in c]
    obi = [(usec(r["obi1"])[0] - usec(r["obi0"])[0]) / 1e6 for r in c]
    print(f"{kind}: rps {fmt(rps)}, obi cpu {fmt(obi)} s")

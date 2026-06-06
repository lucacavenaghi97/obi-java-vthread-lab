# Overhead of the #2242 fix: methodology

A first draft was reviewed adversarially from three angles (statistics /
systems / domain). This version
incorporates every blocker and major. Review verdicts kept: interleaved
ABCABC repeats, 3x2 matrix structure, cleaned-patch-only benchmarking,
teardown-per-repeat honesty - all confirmed sound.

## Changes vs v1 (what the review caught)

1. **Baseline image is `obi-jt-pin` (main 3a24937a + ONLY the #2259 pin),
   not `obi-main-clean`.** The working tree carries the #2259 java_tasks
   pin alongside #2242; benchmarking fix vs pristine-main would conflate
   the two. With obi-jt-pin both arms share #2259 and the delta is #2242
   alone. Assert the running image id per arm (docker inspect) before
   driving load; fail loudly on mismatch.
2. **BPF prog stats demoted from "precise answer" to corroborating
   bound.** All ioctl ops live in ONE multiplexed sys_ioctl kprobe and the
   translate helper is inlined into shared programs; per-prog run_time_ns
   cannot isolate the fix. Report it only as "the total eBPF-side time did
   not move outside noise". Optional precision tool if a maintainer asks:
   BPF_PROG_TEST_RUN microbench of an isolated translate-only program (not
   in the default plan).
3. **Mount/unmount rate via a separate CALIBRATION pass, not run_cnt.**
   The sys_ioctl kprobe counts every ioctl on the host. Instead: BEFORE the
   final patch has no counting printks, run a short BPF_DEBUG=true pass
   per workload and count "Java VT mount/unmount" lines per request. The
   rate is a property of workload+JDK, not of the build, so calibrating
   with the debug build is valid. Never mix the debug pass into timing.
4. **Workload risk: /bench may produce ~0 unmounts.** VTs only unmount
   when they actually park; sub-ms loopback I/O may not. The calibration
   pass (3) decides: if events/request ~0 on /bench, the throughput delta
   is vacuous and the workload moves to /bench-park (1ms sleep variant,
   documented as forcing one park per request) for the VT arms. Both
   endpoints to be added to the app (no-sleep /bench/{id}; /bench-park/{id}
   with Thread.sleep(1)).
5. **Worst-case event-rate arm added (churn).** /churn?seconds=60&vts=64
   on the 2-thread custom scheduler with NO HTTP load, fix vs jt-pin
   baseline: app+OBI CPU per 1000 mount/unmount events. This bounds the
   pure per-event cost at a rate (~tens of k events/s) far above any
   realistic request workload.
6. **Non-Java tax arm added.** OBI watching nginx only (no Java app), driver
   on nginx directly, fix vs jt-pin: the translate-lookup miss on an empty
   map is exactly what non-Java users pay. cpu/throughput + bpf-stats bound.
7. **Both context-propagation modes.** all (the mode where the fix matters,
   inherited from the oracle harness) AND default-disabled (what most users
run): the
   main request matrix runs under both; noobi arms are mode-independent.
8. **Trace printer OFF in timed runs.** The text printer's per-span cost
   scales with throughput and differs between main-vt (broken/orphaned
   spans) and fix-vt (correct spans) - direct bias. Timed arms run with no
   printer and no exporter; span correctness is the oracle's job, a separate
   untimed sanity request confirms instrumentation is live per arm.
9. **Readiness polling instead of blind 35s.** Per repeat: poll OBI logs
   for the "instrumenting process" line for the app pid, then one probe
   request must produce instrumentation evidence, then start warmup clock.
10. **Driver: hey, installed and pinned** (none present on the box; go
    install github.com/rakyll/hey@latest with ~/.local/go, record version).
    One persistent process per cell: hey -z 60s -c 40. The oracle harness's
    seq|xargs|curl pattern is a fork-per-request loop and would benchmark
    curl startup. Driver pinned away from app cores (taskset) and checked
    for self-saturation in the dry run.
11. **Latency framing.** Closed-loop c=40 p50/p90/p99 reported as "service
    time under closed-loop concurrency 40", never as open-loop SLO latency
    (coordinated omission). Headline metrics are throughput and
    CPU-per-request; p99 is secondary.
12. **Noise floor measured, not assumed.** Before the matrix: 5 repeats of
    the SAME cell (jtpin-vt) as null replicates; the observed spread IS the
    noise floor, replacing the v1 "<2% is noise" guess. Pre-registered
    headline comparisons (decided NOW, before any data):
      (a) fix-vt vs jtpin-vt, throughput + app-CPU-per-request
      (b) fix-pt vs jtpin-pt, throughput + app-CPU-per-request
    Everything else is context, reported in the appendix table only.
    fix-vt vs jtpin-vt is labeled "cost of being correct under VT" (the
    arms do different correlation work); fix-pt vs jtpin-pt is the clean
    "added-code tax" (translate miss only, no mount/unmount traffic).
13. **Frequency drift logged.** /proc/cpuinfo MHz sampled (1 Hz) during
    every cell; if same-cell frequency spread exceeds the inter-arm delta,
    the delta is reported as noise. Governor performance + no_turbo for
    the run window if sudo is available (interactive password session:
    sysctl kernel.bpf_stats_enabled=1, scaling_governor, intel_pstate
    no_turbo); otherwise run without and rely on interleaving + frequency
    logging, stated in the writeup.
14. **CPU-bound check + TIME_WAIT watch.** Dry run confirms app CPU is the
    bottleneck (not driver/loopback/ephemeral ports: ss -s watched; if
    TIME_WAIT approaches the ephemeral range, enable downstream keep-alive
    and re-check). Equal throughput is only evidence of equal cost in a
    CPU-bound regime.
15. **CPU attribution caveat stated.** eBPF prog time is charged to the
    triggering task (the app), not OBI: app-cgroup cpu.stat delta = agent
    + eBPF + JVM work; OBI-cgroup = OBI userspace only. Report user/system
    split and CPU-per-request; sum app+OBI as "total OBI-attributable CPU".
    Quiesce the box (no stray containers - check docker ps) before runs.

## Final matrix

Request workload (hey -z 60s -c 40, 30s warmup, 5 interleaved repeats):

| cells | modes |
|---|---|
| noobi-pt, noobi-vt | (no OBI - mode-independent) |
| jtpin-pt, jtpin-vt, fix-pt, fix-vt | context_propagation: all AND disabled |

Plus: 5 null replicates of jtpin-vt (noise floor); churn arm (fix/jtpin,
60s, no HTTP); non-Java arm (nginx-only, fix/jtpin, both modes optional ->
all only); calibration pass (BPF_DEBUG build, /bench vs /bench-park
vs /oracle events-per-request).

Estimated machine time ~2.5-3h. Deliverables: run.sh with preflight
(driver present, images asserted, box quiesced, readiness polling),
analyze.py (medians, min-max, noise-floor comparison, pre-registered
deltas first), results/, and the two headline sentences for the
maintainer comment with the measured noise floor attached.

## Calibration results (2026-06-06, results/calibration.txt)

VT=true, JRE 21, 50 req @ P=8 per endpoint, BPF_DEBUG mount/unmount printk
counts; idle baseline 3 events / 10 s (negligible):

| workload | mounts/req |
|---|---|
| /bench (no sleep) | **2.56** |
| /bench-park (1ms sleep) | 3.90 |
| /oracle (50ms sleep) | 4.70 |

Decision: /bench is NOT vacuous (sub-ms loopback I/O still parks the VT
~2.5x per request) and becomes the PRIMARY workload; /bench-park is kept
as a sensitivity arm. Expected ioctl traffic on fix-vt: ~5.1 ioctls/req
(2.56 pairs). The domain reviewer's vacuity concern is settled by data.

## Execution prerequisites (blocking)

- [x] /bench/{id} + /bench-park/{id} endpoints added to the repro app
- [x] hey installed (on PATH or via HEY=)
- [x] calibration pass done (table above)
- [ ] task #8 done (cleaned patch, docker-generate, image rebuilt)
- [x] no sudo needed: governor/no_turbo (and bpf_stats if ever wanted) are
      set through a --privileged container writing the host /sys, see
      preflight in run.sh; restored on exit
- [x] run.sh + analyze.py + compose overrides written (run.sh, analyze.py,
      docker-compose.{e4,jtpin,nonjava}.yml)

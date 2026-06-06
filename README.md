# obi-java-vthread-lab

Experiment harness behind the fix for
[opentelemetry-ebpf-instrumentation#2242](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/issues/2242):
OBI's Java trace correlation is keyed by kernel thread id and breaks under
Java virtual threads. This repo contains the reproducer, the per-request
correctness oracle, the overhead benchmark and the log-enricher measurements
that motivated and validated the fix, with the raw results of the runs cited
in the PR.

Everything here runs against an OBI checkout you point at via `OBI_REPO`
(main reproduces the problems; the fix branch shows them resolved).

## The problem, in three layers

Each layer was found by falsifying a previous fix attempt:

1. On egress the carrier kernel tid differs from the tid that read the
   request (measured ~92% of requests under contention), so tid-keyed
   lookups miss and the downstream client span orphans.
2. The thread-pool instrumentation actively poisons `java_tasks` under
   virtual threads: Loom re-submits the same per-VT `runContinuation`
   lambda through the instrumented Executor surface on every unpark, from
   platform threads, writing stale submitter tids onto carrier tids.
3. The dominant one: tid-keyed `server_traces` self-destructs at read time.
   Two in-flight virtual threads that read on the same carrier tid build
   identical trace keys, and the conflicting-span branch invalidates the
   live entry. This is why agent-only fixes cannot work.

Baseline breakage: 63-68% of downstream client spans orphaned or
cross-wired at concurrency 40. The fix re-keys Java correlation by the
virtual thread's logical id, reported by the agent on mount/unmount.

## Layout

| directory | what it is |
|---|---|
| `reproducer/` | minimal three-container reproduction (Spring Boot app, nginx downstream, OBI); the repro behind the issue report |
| `oracle/` | per-request oracle: unique path ids on both sides, every client span classified as correctly-stitched / cross-wired / orphaned; arms for JDK 21/25, platform threads, a mixed shared-carrier discriminator and TLS |
| `overhead/` | closed-loop overhead benchmark with a pre-registered comparison plan, interleaved cells, measured noise floor, a synthetic churn worst case and a non-Java arm; `METHODOLOGY.md` documents the design |
| `log-enricher/` | per-log-line enrichment correctness measurements that motivated suppressing `traces_ctx_v1` writes under virtual threads |

Each directory has its own README with the full design, run instructions
and results tables. `results/` subdirectories contain the raw outputs of
the runs cited in the PR.

## Headline results

Per-request oracle (concurrency 40, parent span id verified):

| arm | result |
|---|---|
| JDK 21, virtual threads, 2000 req | 0 cross-wired, 1 orphan |
| JDK 25 runtime, same agent bytecode, 2000 req | 0 cross-wired, 1 orphan |
| platform threads (regression canary), 2000 req | clean, no change |
| mixed: 64 churning VTs + 800 platform pool-handoff requests on the same two OS threads | 800/800 correct, map empty post-quiesce |
| TLS downstream, virtual threads, 1000 req | 998/1000 correct, 0 cross-wired |
| raw TCP (generic-TCP keying), 800 req, virtual threads | 800/800, server_traces empty post-quiesce (34.5% on unpatched baseline) |
| DNS resolutions on virtual threads | 24/24 parented to their request (31.8% on unpatched baseline) |

Overhead (fix vs baseline, throughput noise floor +/-22.8%): no measurable
cost on any arm; details and the honest churn worst case in
`overhead/METHODOLOGY.md` and the PR.

Log enricher under virtual threads: 0% correct lines and 19% wrong-trace
lines on main; translation alone makes recency worse (48% wrong); the fix
suppresses the writes (0% wrong, platform untouched). Numbers in
`log-enricher/README.md`.

## Pre-existing upstream bugs found along the way

- `java_tasks` map not shared with the tpinjector program: ~95% of plain
  executor pool-handoff client spans orphaned with context propagation
  enabled, zero virtual threads involved. Filed as
  [#2259](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/issues/2259),
  fixed by
  [#2260](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/2260).
- Blocking-SSLSocket read path: client spans lost on keep-alive TLS
  connections (~92% missing) and responses never parsed, platform threads
  included, VT-independent. Root cause identified (read-side advice fails
  on a classloader visibility issue); to be filed upstream with a fix.
  Evidence in `oracle/results/`.

## Reproducing

Prerequisites: Linux with BTF (`/sys/kernel/btf/vmlinux`), docker compose,
python3, root/privileged containers,
[hey](https://github.com/rakyll/hey) for the benchmark, host `bpftool` for
the mixed-arm map check, `openssl` for the TLS certs.

```sh
# the checkout the OBI images are built from
export OBI_REPO=/path/to/opentelemetry-ebpf-instrumentation

# minimal reproduction, both arms
cd reproducer && ./verify.sh

# correctness oracle (generate the TLS certs once)
cd oracle && ./tls/gen-certs.sh && ./run.sh

# overhead matrix (also needs the baseline image, see below)
cd overhead && ./run.sh

# enricher measurements
cd log-enricher && ./run.sh
```

The oracle control arms and the benchmark baseline use unpatched OBI
images built once from a main checkout:

```sh
git -C "$OBI_MAIN" checkout main
docker build -t obi-jt-pin -f \
  "$OBI_MAIN/internal/test/integration/components/obi/Dockerfile-with-javaagent" "$OBI_MAIN"
docker tag obi-jt-pin obi-main-clean
```

(Historical note: during the investigation `obi-main-clean` predated the
#2260 pin fix and `obi-jt-pin` carried it; with #2260 merged, current main
serves as both.)

## License

Apache-2.0

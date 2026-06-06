# Per-request oracle (correct stitching, not just zero orphans)

Closes the metric blind spot of the basic reproducer: an orphan-rate metric only checks trace
MEMBERSHIP, so a client span stitched to the WRONG request's trace counts as
healthy. Here every request carries a unique id as a PATH segment on both
sides (`/oracle/{id}` server, `/echo/{id}` downstream), and the analyzer
classifies each pair as correctly-stitched / cross-wired / orphaned. Ids must
be path segments because OBI strips query strings from span paths
(`pkg/internal/.../http_transform.go`).

An adversarial design review forced three changes over the first draft:
path-segment ids (not query), a shared-carrier mixed arm (a FixedThreadPool
endpoint alone would pass regardless of the fix, since pool threads are never
carriers), and host-side bpftool (the map is not pinned for in-container
userspace and the OBI image has no bpftool).

## Arms (run.sh)

| arm | config | proves |
|---|---|---|
| vt21 | VT=true, JRE 21, N=2000 @ P40 | the main claim: every client span parented to ITS OWN server span under heavy carrier migration |
| vt25 | VT=true, JRE 25 (same 21-bytecode) | the mount/unmount seam + fix behavior on current JDK |
| pt21 | VT=false, JRE 21 | regression canary on the classic platform path |
| mixed | VT=false + custom-scheduler churn | the VT_UNMOUNT cleanup specifically (see below) |

### The mixed arm

A single 2-thread pool is used BOTH as the (reflection-injected, JDK-internal)
scheduler of 64 sleeping virtual threads (continuous mount/unmount churn, no
spans) AND as a plain executor running the downstream call of
`/mixed-pt/{id}` requests handled on platform Tomcat threads. Without the
unmount cleanup, a stale `java_vt_threads[carrier]` entry re-keys the platform
task's egress to a dead VT id, so its client span orphans or cross-wires;
with the cleanup, correlation flows through the classic `java_tasks`
pool-handoff edge. Afterwards (churn deadline passed) `bpftool map dump name
java_vt_threads` on the HOST must show no entries for those carriers: deletes,
not LRU eviction, empty the map.

Note the VT side of the mixed arm is NOT a correctness signal: with
VT=false the server read happens on a Tomcat platform thread while a custom-
scheduler VT would egress under its synthetic id with no linking edge
(VT-submitted pool handoffs are deliberately untracked by the fix's Loom guards).
Only the `/mixed-pt` results and the map dump count.

## What the oracle does NOT cover (measured separately)

- The log-enricher channel (`obi_ctx`/`traces_ctx_v1`) is keyed by raw
  pid_tgid and stays untranslated under VTs; measured in `../log-enricher/`.
- DNS client spans (untranslated connect-time key) and unix-domain-socket
  workloads (extra_id mismatch) keep their pre-existing behavior.
- Overhead: measured in `../overhead/`.

## Run

    ./run.sh                 # all four arms, ~25 min with warm images
    ARMS="vt21 mixed" ./run.sh
    N=4000 ./run.sh          # more power

Requires the same stack as `../reproducer/verify.sh` (Docker, BTF,
privileged), `OBI_REPO` pointing at the checkout to build, TLS certs
generated once with `tls/gen-certs.sh`,
plus host bpftool for the mixed-arm map check. Span logs land in
/tmp/e3_spans_<arm>.log (raw copies of this run are in results/); `analyze_oracle.py` prints the verdict per arm.

Power: pre-fix, the conflicting-span invalidation alone hit ~half the
requests at this concurrency (16/30) and total breakage was 63-68%, so even a
fix that left a 0.5% residual would show ~10 bad ids in 2000. A clean 0/2000
bounds the residual below ~0.15% (95% CI, rule of three).

## RESULTS (2026-06-06, single run per arm, raw outputs in results/)

| arm | correct | cross-wired | orphaned | missing-client |
|---|---|---|---|---|
| vt21 | 1988/1997 = 99.55% | **0** | 1 (0.05%) | 8 |
| vt25 | 1986/1993 = 99.65% | **0** | 1 (0.05%) | 6 |
| pt21 | 1991/1998 = 99.65% | **0** | 0 | 7 |
| mixed (first run) | 58/800 = 7.25% | 206 | 535 | 1 (see below: pre-existing upstream bug, fix exonerated) |
| **mixed RERUN (working tree + the verified java_tasks pin)** | **799/799 = 100.00%** | **0** | **0** | 0 |

The mixed RERUN (results/arm-mixed-rerun-with-jtpin.txt) is the span-level
validation of the VT_UNMOUNT cleanup the adversarial review demanded: 800
platform pool-handoff requests executing on the SAME 2 OS threads that
simultaneously carried 64 churning virtual threads, 100.00% correctly
stitched, post-quiesce map empty. With a broken unmount, stale entries would
have re-keyed those egresses onto dead VT ids.

- The headline: **zero wrong-server attributions in ~4000 oracle
  requests under virtual threads (JDK 21 AND 25)**, with full parent-span-id
  verification. This converts the early prototype's "0 orphans" into "correctly
  stitched". Baseline was 63-68% broken.
- The ~0.3-0.4% "missing-client" rows are spans absent from the OBI text-log
  capture across ALL arms including platform (printer/log loss under burst,
  not correlation); the lone vt21/vt25 orphan (id regex excludes the warmup)
  is within the same capture-noise band.
- "duplicate spans per id" (srv 0-7, cli 1-6 per arm) appear in every arm
  including platform: printer-level duplication, not correlation artifacts.

### The mixed arm: fix exonerated, NEW pre-existing upstream bug found

The mixed arm scored 92.6% bad, but the diagnosis (results/mixed-diagnosis.txt)
proves this is NOT the VT fix:

1. **No-churn baseline: 93.75% bad** (400 `/mixed-pt` through the shared
   2-thread pool with ZERO virtual threads ever created, `java_vt_threads`
   empty, all #2242 guards inert). Statistically identical to the churn run:
   the breakage is entirely pre-existing pool-handoff behavior.
2. Root cause (structural, verified in the objects): `bpf/maps/java_tasks.h`
   has NO `OBI_PIN_INTERNAL`, but `tpinjector.c` includes `trace_parent.h`
   and therefore compiles `find_parent_java_trace` against its own PRIVATE,
   always-empty `java_tasks` copy. Under
   `OTEL_EBPF_BPF_CONTEXT_PROPAGATION=all` the tpinjector sk_msg program
   decides the client tp, its chain walk can never succeed, and any request
   whose egress runs on a different thread than the server read (classic
   executor handoff!) orphans; keepalive connection reuse turns some of those
   into adjacent-id cross-wires. `server_traces` IS pinned, which is why the
   same-thread and VT-translated paths work.
   **CONFIRMED ON PRISTINE MAIN (3a24937a, worktree build, image
   obi-main-clean, results/mainctl.txt): pool handoff 95.24% bad (19/399
   correct, 317 orphan, 63 cross-wired) while the same-thread control on the
   SAME deployment is 100.00% correct (199/199).**
   **FIX VERIFIED (results/jtpin-fix-validation.txt, patch in
   results/jtpin-fix.patch): main + ONLY `__uint(pinning, OBI_PIN_INTERNAL)`
   on java_tasks (2 lines) takes the same pool-handoff load to 400/400 =
   100.00% correct, same-thread control unchanged at 100%.** Filed upstream
   as issue #2259 and fixed by PR #2260 (merged). The obi-main-clean docker
   image is the unpatched baseline; obi-jt-pin is the main+pin build used as
   the baseline by `../overhead/`.
3. **The unmount cleanup is validated by the map lifecycle instead**: during
   churn a 60-dump burst caught entries 11/60 times (custom-scheduler VT
   mounts DO emit; entries are transient by design, the carriers are
   unmounted ~80-90% of each 1ms sleep cycle), and post-quiesce the map is
   `[]`. Without VT_UNMOUNT the last mount of each carrier would persist
   forever (nothing else deletes; LRU at 10000 entries never evicts 2).

UPDATE: with the java_tasks pin applied (now upstream via #2260), the mixed
arm was RERUN and is 799/799 = 100.00% correct
(table above). The unmount cleanup is now proven BOTH by map lifecycle AND at
span level under shared-carrier churn. Every arm is green.

## TLS arms: third pre-existing upstream finding

Motivation: JDK TLS is pure JSSE (no OpenSSL), so OBI sees Java TLS payloads
ONLY via the java agent ioctl path (java_tls.c TCP_SEND/TCP_RECV) - a keying
path the plain-HTTP arms never exercised end to end. Harness: nginx TLS
downstream (self-signed, generate with tls/gen-certs.sh), additive
/oracle-tls/{id} endpoint with a
trust-all HttpsURLConnection (SSLSocket path), arms in run.sh.

| arm | OBI | keep-alive | correct | cross | orphan | missing-client |
|---|---|---|---|---|---|---|
| tlsc21 (VT, TLS downstream) | fix | yes | 26/1000 | 0 | 0 | **955** |
| ptls21 (PT, TLS downstream) | fix | yes | 27/1000 | 0 | 0 | **954** |
| tlss21 (VT, TLS server+downstream) | fix | yes | 9/999 | 0 | 0 | **978** |
| ptls control (PT, TLS downstream) | **main-clean** | yes | 21/398 | 0 | 0 | **367** |
| ptls-close (PT, TLS downstream) | fix | **no (close per req)** | **300/300 = 100.00%** | 0 | 0 | 0 |
| **tlsc-close-vt (VT, TLS downstream)** | fix | **no (close per req)** | **998/1000 = 99.80%** | **0** | **0** | 2 (printer noise) |

Reading:

1. **TLS-under-VT keying VALIDATED end to end** (tlsc-close-vt): 998/1000
   correctly stitched, 0 cross-wired, 0 orphaned, with virtual threads at
   P=40 and every client span delivered through the java agent ioctl path
   (JSSE is pure Java: kprobes only ever see ciphertext). The 2 missing are
   within the same printer capture-noise band as every other arm. This was
   the last untested keying surface of the fix.
2. **The missing-client wall is a PRE-EXISTING upstream bug, strictly
   keep-alive-bound** (control rows): on pristine main, platform threads,
   ~92% of HttpsURLConnection requests over reused TLS connections produce
   NO client span; only the first request per SSLSocket is captured. Forcing
   connection close per request (nginx-echo-close.conf +
   docker-compose.nokeepalive.yml) takes the SAME app/OBI from 5-7% to 100%
   span coverage. Second facet: the TLS RESPONSE is never parsed on this
   path - every captured client span is 499/responseLen:0 even on fresh
   sockets (stitching still works via the request side). The upstream Java
   TLS integration tests use netty/WebClient (SSLEngine), which is why CI
   never sees the blocking-SSLSocket path. Root cause identified (the
   read-side advice fails on a classloader visibility issue); to be filed
   upstream separately.
3. **No evidence of fix-induced breakage on TLS**: fix arms match the main
   control within noise in the keep-alive runs, and the close runs are clean
   on both PT and VT.

# Log enricher / traces_ctx_v1: scoping decision and measurements (#2242)

Date: 2026-06-06. The scoping analysis below was produced by four parallel
code mappers cross-checked by three adversarial reviewers; the key outputs
are summarized here and then verified empirically.

## DECISION: scope the enricher OUT of the #2242 patch, with explicit framing

No code change to the enricher or to `traces_ctx_v1` goes into the #2242 PR.
The maintainer conversation states the situation honestly (wording points
below). A follow-up upstream issue would cover "log
enrichment under user-space-scheduled threads", which has OTEP implications
beyond this fix.

## What was established (adversarially verified)

1. **No synthetic-key leak (skeptic could NOT refute).** All 45
   `obi_ctx__*` call sites across bpf/ take a RAW `u64 pid_tgid`;
   `java_vt_translate_tid` mutates only `pid_key_t.tid` (a disjoint type on
   a disjoint path) and has exactly 3 call sites, all feeding
   `server_traces`/parent lookups. `traces_ctx_v1` is the ONLY
   `LIBBPF_PIN_BY_NAME` map in the tree (everything the fix touches is
   `OBI_PIN_INTERNAL`, which is an in-process Go share, not a bpffs pin).
   The OTEP-spec'd external surface is byte-identical under the fix.

2. **OTEP contract (PR 4855 / devdocs/trace-profile-correlation.md):** key
   is `(u64) pid_tgid`, consumers are profilers; the spec text never
   defines kernel-thread stability and never mentions virtual/green
   threads. Writing synthetic ids there would be a spec conversation, not a
   patch detail. Another reason to scope out.

3. **Pre-fix, enrichment under Java VTs is already broken (skeptic could
   NOT refute).** Two independent break paths: (a) `obi_ctx__set` runs at
   request-READ time on the reading thread; the VT can log from a different
   carrier with zero remounts involved; (b) the conflict branch
   (trace_lifecycle.h:140, pre-fix) freezes `traces_ctx_v1[carrier]` at the
   FIRST colliding VT's tp - deterministic stale-hits. Bonus finding:
   logback AsyncAppender breaks enrichment even for platform-thread apps
   (the write() runs on the appender worker thread). The in-repo
   log-enricher Java test is platform-threads-only, so CI cannot see any of
   this.

4. **The fix DOES change enricher-visible behavior for concurrent VTs
   (skeptic REFUTED "unchanged"; this is the one nuance to report).** Two
   deltas, both indirect:
   - *Delta 1 (recency vs frozen):* post-fix the conflict branch stops
     firing, so `obi_ctx__set` runs for every concurrent VT and
     `traces_ctx_v1[carrier]` tracks the MOST-RECENT request on that
     carrier instead of the first. Concrete A-B-A ordering exists where
     post-fix enrichment is newly wrong and pre-fix was accidentally right;
     the symmetric ordering (logger is the last mounted VT) is newly right.
     Neither policy is correct-per-line; it is a different wrong answer,
     not a regression of a working feature.
   - *Delta 2 (fewer refreshes):* the Loom guards suppress the
     `k_ioctl_java_threads` obi_ctx refresh for VT tasks (the same relay
     that was poisoning `java_tasks` pre-fix). Strictly fewer enricher
     refreshes for VT handlers; what remains is the request-read write.
   - For ALL non-VT workloads (platform Java, Go, Python, Node, Ruby) the
     translate sites are no-ops and enricher behavior is byte-identical
     (verified claim, not just absence of evidence).

## Critic gaps and answers

- **A. Acceptance metric:** #2242's acceptance is SPAN-based by
  construction: the issue was filed on span-level orphaning and the
  baseline breakage (63-68%) is measured on spans. Enrichment is a
  separate correctness surface; stated explicitly in the PR so nobody
  assumes the oracle numbers cover it.
- **B. The recency tradeoff never run empirically:** agreed - planned as the
  empirical check below, BEFORE the maintainer conversation, so the
  "different wrong answer, no working config regressed" sentence is
  measured, not inferred.
- **C. No VT enricher test exists upstream:** belongs to the follow-up
  issue on VT-aware enrichment; not fixable inside #2242.
- **D. LRU pressure on stale entries:** folded into the follow-up issue;
  does not affect the scope decision (16K entries, LRU, stale entries are
  bounded; correctness, not leak).

## Empirical check (2026-06-06): the recency tradeoff confirmed, suppression added

Harness (files here, reuses the oracle triangle): app logs one JSON line per
/oracle/{id} request AFTER the downstream call; OBI runs with the log
enricher enabled via mounted YAML (obi-e5.yml + docker-compose.e5.yml;
YAML-only feature, no env toggle) plus the text printer; analyze_e5.py
joins enriched-stdout trace_id vs the true server trace per id. 600
req/arm at P=40. Two harness gotchas burned into the override comments:
compose resolves relative volume paths against the PROJECT dir (use
E5_CONFIG absolute), and the enricher silently disables itself without a
/sys/fs/bpf mount (pinned-maps WARN in the OBI log).

| arm | correct | wrong-trace | unenriched |
|---|---|---|---|
| vt + main (pre-fix) | **0.00%** | 18.67% | 81.33% |
| vt + fix (translation only) | 0.17% | **47.75%** | 51.92% |
| pt + main | 100.00% | 0 | 0 |
| pt + fix | 100.00% | 0 | 0 |

Reading:
- **Pre-fix enrichment under VT is fully broken** (0% correct), and not
  just silently: ~19% of log lines carry ANOTHER request's trace id.
  The "log enrichment was never correct under VT" sentence is now
  measured, not inferred.
- **The recency effect is real and goes the bad way**: with the conflict-branch
  freeze gone, more writes land and the carrier entry tracks the most
  recent request, converting misses into wrong attributions (19% -> 48%).
  Platform arms are untouched (100% both).
- **Decision (added to the patch, validated below): suppress traces_ctx_v1
  writes while a VT is mounted** (java_vt_translate_tid now returns
  whether it translated; obi_ctx__set at trace_lifecycle.h:146/:178 is
  skipped for VT-keyed requests). Wrong data is worse than no data on an
  OTEP correlation surface read by profilers and the log enricher. Under
  VT this gives 0% wrong / ~100% honest-absence, strictly better than both
  main (19% wrong) and translation-only (48% wrong); platform behavior is
  byte-identical. Maintainers can drop the guard if they prefer
  fresh-by-recency; these numbers make the tradeoff explicit.
- **Rerun with suppression (results/*-suppress*): exactly as designed.**

| arm (suppression build) | correct | wrong-trace | unenriched |
|---|---|---|---|
| vt + fix | 0.00% | **0.00%** | 100.00% |
| pt + fix | **100.00%** | 0 | 0 |

  And the span-level oracle on the SAME vtfix run (analyze_oracle.py over
  the arm's printer log): **599/599 = 100.00% correctly stitched, 0
  cross-wired, 0 orphaned, 0 missing** - the suppression does not touch
  span correlation, and this is the cleanest oracle run of the whole
  investigation.

Follow-up hardening added with the same invariant (validated by a
vtfix+mixed rerun): the obi_ctx__del in delete_server_trace is also
VT-guarded (a VT-handled request completing must not erase a platform
request's live entry on a shared carrier), and sys_exit now clears
java_vt_threads (a carrier dying without unmount must not leave a stale
entry to re-key a recycled tid). The sys_exit obi_ctx__del stays
UNguarded: own-tid cleanup at thread death is always correct.

## Maintainer-conversation wording points (for the #2242 comment draft)

- The fix repairs SPAN correlation; it does not touch `traces_ctx_v1` (the
  OTEP profiler-correlation surface), whose raw pid_tgid keying is
  inherently approximate under user-space scheduling (VTs today, goroutine
  M-multiplexing tomorrow).
- Log enrichment for VT apps was not correct before the fix and is not
  correct after it; measured numbers above (pre vs post) included.
- Propose a follow-up issue for enrichment under user-space-scheduled
  threads (needs an OTEP-level answer for the key semantics; options:
  translate writer+reader inside OBI behind the same internal map, or spec
  a logical-thread key extension).

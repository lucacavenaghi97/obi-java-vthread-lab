# Minimal reproduction: virtual-thread trace-correlation gap in OBI

A small Spring Boot service handles a request, yields its carrier with a short
sleep, then makes a synchronous downstream HTTP call on the same thread. With
platform threads OBI nests the downstream client span under the server trace.
With virtual threads (`spring.threads.virtual.enabled=true`) the request handler
runs on a virtual thread whose carrier kernel thread can change between the read
and the egress, so OBI's tid-based correlation misses and the downstream call is
emitted as a separate root trace.

This is the repro pasted into upstream issue
https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/issues/2242.

## Layout

- `app/` a single-endpoint Spring Boot app (Java 21). `/work` does the
  sleep-then-synchronous-egress; `/thread-info` reports whether the handler runs
  on a virtual thread. The handler also reads its own kernel tid from
  `/proc/thread-self/stat` at entry and before the egress, so carrier migration
  is visible in the response (`"migrated"`).
- `downstream` an nginx returning 200.
- `obi` built from this OBI checkout, printing spans to stdout (text printer).

## Prerequisites

- Docker, a Linux host with BTF (`/sys/kernel/btf/vmlinux`), root/privileged.
- `OBI_REPO=/path/to/opentelemetry-ebpf-instrumentation`: the checkout OBI is
  built from (main reproduces the bug; the fix branch shows it resolved).

## Run

Platform threads (baseline):

    OBI_REPO=/path/to/obi VT=false docker compose up -d --build

Virtual threads:

    OBI_REPO=/path/to/obi VT=true docker compose up -d --build

Then drive some concurrent load (the bug needs carrier contention, so use
concurrency above the number of CPU cores):

    seq 1 400 | xargs -P 40 -I{} \
      curl -fsS "localhost:18080/work?url=http://downstream/" -o /dev/null

Inspect OBI's spans:

    docker compose logs obi | grep "traceparent=\[00-"

For a server request to `/work`, the line for the downstream `HTTPClient` call
should carry the same trace id and a parent equal to the server span id. With
virtual threads under load, most downstream calls instead get a fresh trace id
and a zero parent.

`verify.sh` runs both arms and prints the comparison.

## Verified result (2026-06-04, 14-core host, kernel 6.17, OBI @ 3193b9a0)

| config | carrier migration | broken correlation |
|---|---|---|
| platform threads | 0% (0/400) | 0.2% |
| virtual threads | 91.5% (366/400) | 63.3% |

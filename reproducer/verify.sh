#!/usr/bin/env bash
# Runs both arms (platform threads, then virtual threads) and prints the comparison.
set -u
cd "$(dirname "$0")"
: "${OBI_REPO:?point OBI_REPO at an opentelemetry-ebpf-instrumentation checkout}"
DC="docker compose"

run() {
  arm=$1
  echo "================ VT=$arm ================"
  $DC down >/dev/null 2>&1
  if ! VT=$arm $DC up -d --build > /tmp/repro_build_${arm}.log 2>&1; then
    echo "BUILD/UP FAILED (see /tmp/repro_build_${arm}.log); last lines:"
    tail -25 /tmp/repro_build_${arm}.log
    return 1
  fi
  for i in $(seq 1 120); do curl -fsS localhost:18080/thread-info >/dev/null 2>&1 && break; sleep 1; done
  echo "thread-info: $(curl -fsS localhost:18080/thread-info)"
  echo "waiting 35s for OBI discovery + java agent injection..."
  sleep 35
  curl -fsS "localhost:18080/work?url=http://downstream/" -o /dev/null 2>/dev/null   # warmup
  seq 1 400 | xargs -P 40 -I{} curl -fsS "localhost:18080/work?url=http://downstream/" -o /tmp/repro_resp_${arm}_{} 2>/dev/null
  sleep 12
  $DC logs obi 2>&1 | grep -E "traceparent=\[00-" | grep -E "/work|HTTPClient" > /tmp/repro_spans_${arm}.log
  echo "carrier migration (from app): $(grep -l '"migrated":true' /tmp/repro_resp_${arm}_* 2>/dev/null | wc -l)/$(ls /tmp/repro_resp_${arm}_* 2>/dev/null | wc -l)"
  python3 analyze.py /tmp/repro_spans_${arm}.log
  $DC down >/dev/null 2>&1
  rm -f /tmp/repro_resp_${arm}_*
}

run false
run true
echo "DONE"

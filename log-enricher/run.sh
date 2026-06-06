#!/usr/bin/env bash
# Log-enricher correctness per log line, pre-fix vs post-fix, VT vs PT.
# Arms: vtfix vtmain ptfix ptmain. Measures the Delta-1 tradeoff (frozen-first
# vs fresh-by-recency traces_ctx_v1[carrier]) found by the adversarial review;
# see README.md. Uses the oracle triangle + the enricher override YAML.
set -u
cd "$(dirname "$0")"
: "${OBI_REPO:?point OBI_REPO at an opentelemetry-ebpf-instrumentation checkout (the fix branch)}"
E3=../oracle
export E5_CONFIG="$(pwd)/obi-e5.yml"
N=${N:-600}
P=${P:-40}

arm() {
  name=$1 vt=$2 ctl=$3
  files="-f $E3/docker-compose.yml -f ./docker-compose.e5.yml"
  [ "$ctl" = main ] && files="$files -f $E3/docker-compose.mainctl.yml"
  DC="docker compose $files"
  echo "================ arm=$name (VT=$vt, OBI=$ctl) ================"
  export VT=$vt JRE_IMAGE=eclipse-temurin:21-jre SSL_SERVER=false
  $DC down >/dev/null 2>&1
  if ! $DC up -d --build > /tmp/e5_build_${name}.log 2>&1; then
    echo "BUILD/UP FAILED:"; tail -20 /tmp/e5_build_${name}.log; return 1
  fi
  for i in $(seq 1 120); do curl -fsS localhost:18080/thread-info >/dev/null 2>&1 && break; sleep 1; done
  echo "thread-info: $(curl -fsS localhost:18080/thread-info)"
  echo "waiting 35s for OBI discovery + agent injection..."
  sleep 35
  curl -fsS "localhost:18080/oracle/warmup0" -o /dev/null 2>/dev/null
  echo "driving $N /oracle requests at P=$P..."
  seq 1 $N | xargs -P $P -I{} curl -fsS "localhost:18080/oracle/id{}" -o /dev/null 2>/dev/null
  sleep 12
  $DC logs app  2>&1 > /tmp/e5_applog_${name}.log
  $DC logs obi  2>&1 | grep -E "traceparent=\[00-" > /tmp/e5_spans_${name}.log
  python3 analyze_e5.py /tmp/e5_applog_${name}.log /tmp/e5_spans_${name}.log
  $DC down >/dev/null 2>&1
}

for a in ${ARMS:-vtmain vtfix ptmain ptfix}; do
  case "$a" in
    vtfix)  arm vtfix  true  fix ;;
    vtmain) arm vtmain true  main ;;
    ptfix)  arm ptfix  false fix ;;
    ptmain) arm ptmain false main ;;
    *) echo "unknown arm: $a" ;;
  esac
done
echo DONE

#!/usr/bin/env bash
# Per-request oracle, four plain arms:
#   vt21   VT=true,  JRE 21 - the main claim: correct stitching, not just 0 orphans
#   vt25   VT=true,  JRE 25 - forward-compat of the mount/unmount seam
#   pt21   VT=false, JRE 21 - regression canary
#   mixed  VT=false, JRE 21 - shared-carrier discriminator for the unmount fix:
#          VT churn on a custom 2-thread scheduler + platform tasks on the SAME
#          pool; ends with a java_vt_threads map-emptiness check (host bpftool)
# TLS arms (JDK TLS is pure JSSE: payloads reach OBI only via the java agent
# ioctl path in java_tls.c, which the plain arms never exercise for keying):
#   tlsc21 VT=true,  JRE 21 - HTTPS downstream (SSLSocket egress)
#   ptls21 VT=false, JRE 21 - HTTPS downstream, platform regression canary
#   tlss21 VT=true,  JRE 21 - HTTPS server AND downstream (SSLEngine ingress)
set -u
cd "$(dirname "$0")"
: "${OBI_REPO:?point OBI_REPO at an opentelemetry-ebpf-instrumentation checkout (the fix branch)}"
DC="docker compose"
N=${N:-2000}
P=${P:-40}
MIXED_N=${MIXED_N:-800}

arm() {
  name=$1 vt=$2 jre=$3 endpoint=${4:-oracle} ssl_server=${5:-false}
  echo "================ arm=$name (VT=$vt, JRE=$jre, endpoint=$endpoint, ssl_server=$ssl_server) ================"
  base="http://localhost:18080" curlopts="-fsS"
  if [ "$ssl_server" = true ]; then base="https://localhost:18080" curlopts="-fsSk"; fi
  VT=$vt JRE_IMAGE=$jre SSL_SERVER=$ssl_server $DC down >/dev/null 2>&1
  if ! VT=$vt JRE_IMAGE=$jre SSL_SERVER=$ssl_server $DC up -d --build > /tmp/e3_build_${name}.log 2>&1; then
    echo "BUILD/UP FAILED (see /tmp/e3_build_${name}.log); last lines:"
    tail -25 /tmp/e3_build_${name}.log
    return 1
  fi
  for i in $(seq 1 120); do curl $curlopts "$base/thread-info" >/dev/null 2>&1 && break; sleep 1; done
  echo "thread-info: $(curl $curlopts "$base/thread-info")"
  echo "waiting 35s for OBI discovery + java agent injection..."
  sleep 35
  curl $curlopts "$base/$endpoint/warmup0" -o /dev/null 2>/dev/null

  if [ "$name" = mixed ]; then
    echo "churn: $(curl -fsS 'localhost:18080/churn?seconds=60&vts=64' || echo 'FAILED (reflection?)')"
    sleep 2
    echo "driving $MIXED_N /mixed-pt requests under churn..."
    seq 1 $MIXED_N | xargs -P 20 -I{} curl -fsS "localhost:18080/mixed-pt/id{}" -o /dev/null 2>/dev/null
  else
    echo "driving $N /$endpoint requests at concurrency $P..."
    seq 1 $N | xargs -P $P -I{} curl $curlopts "$base/$endpoint/id{}" -o /dev/null 2>/dev/null
  fi
  sleep 12
  $DC logs obi 2>&1 | grep -E "traceparent=\[00-" > /tmp/e3_spans_${name}.log
  python3 analyze_oracle.py /tmp/e3_spans_${name}.log

  if [ "$name" = mixed ]; then
    echo "--- waiting for churn deadline, then dumping java_vt_threads (expect no entries) ---"
    sleep 55
    if command -v bpftool >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo bpftool map dump name java_vt_threads || true
    else
      echo "host bpftool unavailable (or sudo needs a password); while this arm is still up, run:"
      echo "  sudo bpftool map dump name java_vt_threads"
      if [ -t 0 ]; then
        echo "press enter to tear down..."
        read -r _
      fi
    fi
  fi
  VT=$vt JRE_IMAGE=$jre SSL_SERVER=$ssl_server $DC down >/dev/null 2>&1
}

for a in ${ARMS:-vt21 vt25 pt21 mixed}; do
  case "$a" in
    vt21)   arm vt21   true  eclipse-temurin:21-jre ;;
    vt25)   arm vt25   true  eclipse-temurin:25-jre ;;
    pt21)   arm pt21   false eclipse-temurin:21-jre ;;
    mixed)  arm mixed  false eclipse-temurin:21-jre ;;
    # TLS arms: downstream over HTTPS (java agent SSLSocket egress path).
    tlsc21) arm tlsc21 true  eclipse-temurin:21-jre oracle-tls false ;;
    ptls21) arm ptls21 false eclipse-temurin:21-jre oracle-tls false ;;
    # full TLS: Tomcat serves HTTPS too (SSLEngine ingress path).
    tlss21) arm tlss21 true  eclipse-temurin:21-jre oracle-tls true ;;
    *) echo "unknown arm: $a" ;;
  esac
done
echo "DONE"

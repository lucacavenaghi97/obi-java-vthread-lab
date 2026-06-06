#!/usr/bin/env bash
# Red/green companions for the raw-TCP and DNS oracle arms (the fix arm for
# TCP runs inline; this script runs tcp-main red + dns-fix/dns-main).
set -u
cd "$(dirname "$0")"
JTPIN="-f docker-compose.yml -f ../overhead/docker-compose.jtpin.yml"
NOKA="-f docker-compose.yml -f docker-compose.nokeepalive.yml"
DNSOPTS=" -Dnetworkaddress.cache.ttl=0 -Dsun.net.inetaddr.ttl=0"

up_wait() { # compose-files...
  docker compose $1 down >/dev/null 2>&1
  if ! docker compose $1 up -d --build > /tmp/tcpdns_build.log 2>&1; then
    echo "BUILD/UP FAILED"; tail -15 /tmp/tcpdns_build.log; exit 1
  fi
  for i in $(seq 1 120); do curl -fsS localhost:18080/thread-info >/dev/null 2>&1 && break; sleep 1; done
  echo "thread-info: $(curl -fsS localhost:18080/thread-info)"
  sleep 35
}

echo "================ arm=tcp-main (obi-jt-pin baseline, VT=true) ================"
export VT=true JRE_IMAGE=eclipse-temurin:21-jre SSL_SERVER=false EXTRA_JAVA_OPTS=""
up_wait "$JTPIN"
python3 driver_tcp.py 800 40 tcpmainid > results/tcp-main-driver.txt 2>&1
echo "driven OK: $(grep -c OK results/tcp-main-driver.txt)"
sleep 15
docker compose $JTPIN logs obi 2>&1 | grep -aE "traceparent=\[00-" > results/tcp-main-spans.log
python3 analyze_tcpdns.py tcp results/tcp-main-spans.log results/tcp-main-driver.txt | tee results/tcp-main-verdict.txt
docker compose $JTPIN down >/dev/null 2>&1

echo "================ arm=dns-fix (working tree, VT=true, no keep-alive, ttl=0) ================"
export EXTRA_JAVA_OPTS="$DNSOPTS"
up_wait "$NOKA"
seq 1 400 | xargs -P 40 -I{} curl -fsS "localhost:18080/oracle/id{}" -o /dev/null 2>/dev/null
sleep 15
docker compose $NOKA logs obi 2>&1 | grep -aE "traceparent=\[00-" > results/dns-fix-spans.log
python3 analyze_tcpdns.py dns results/dns-fix-spans.log | tee results/dns-fix-verdict.txt
docker compose $NOKA down >/dev/null 2>&1

echo "================ arm=dns-main (obi-jt-pin baseline, VT=true, no keep-alive, ttl=0) ================"
up_wait "$NOKA -f ../overhead/docker-compose.jtpin.yml"
seq 1 400 | xargs -P 40 -I{} curl -fsS "localhost:18080/oracle/id{}" -o /dev/null 2>/dev/null
sleep 15
docker compose $NOKA -f ../overhead/docker-compose.jtpin.yml logs obi 2>&1 | grep -aE "traceparent=\[00-" > results/dns-main-spans.log
python3 analyze_tcpdns.py dns results/dns-main-spans.log | tee results/dns-main-verdict.txt
docker compose $NOKA -f ../overhead/docker-compose.jtpin.yml down >/dev/null 2>&1
echo "DONE"

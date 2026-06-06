#!/usr/bin/env bash
# Calibration pass (METHODOLOGY.md items 3/4): measure the ACTUAL
# VT_MOUNT/VT_UNMOUNT rate per request for each candidate workload, BEFORE
# timing runs (the counter IS the debug printk). Decides
# whether /bench is vacuous (~0 unmounts on sub-ms loopback) and /bench-park
# is needed for the VT arms. Run with a BPF_DEBUG build of the fix.
set -u
cd "$(dirname "$0")"
E3=../oracle
N=${N:-50}
DC="docker compose -f $E3/docker-compose.yml"

export VT=true JRE_IMAGE=eclipse-temurin:21-jre SSL_SERVER=false BPF_DEBUG=true
$DC down >/dev/null 2>&1
$DC up -d --build > /tmp/e4cal_build.log 2>&1 || { echo "UP FAILED"; tail -20 /tmp/e4cal_build.log; exit 1; }
for i in $(seq 1 120); do curl -fsS localhost:18080/thread-info >/dev/null 2>&1 && break; sleep 1; done
echo "thread-info: $(curl -fsS localhost:18080/thread-info)"
sleep 35
curl -fsS localhost:18080/oracle/warmup0 -o /dev/null 2>/dev/null
OBI=$(docker ps --format '{{.Names}}' | grep obi)
docker exec $OBI sh -c 'mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null; true'

capture() { # name, driver-cmd...
  name=$1; shift
  docker exec -d $OBI sh -c "cat /sys/kernel/tracing/trace_pipe > /tmp/cal_${name}.log 2>&1 & echo \$! > /tmp/cal.pid"
  sleep 1
  "$@"
  sleep 2
  docker exec $OBI sh -c 'kill $(cat /tmp/cal.pid) 2>/dev/null'
  docker cp $OBI:/tmp/cal_${name}.log /tmp/e4cal_${name}.log 2>/dev/null
  m=$(grep -c "Java VT mount" /tmp/e4cal_${name}.log 2>/dev/null || echo 0)
  u=$(grep -c "Java VT unmount" /tmp/e4cal_${name}.log 2>/dev/null || echo 0)
  echo "[$name] mounts=$m unmounts=$u"
}

idle() { sleep 10; }
drive() { seq 1 $N | xargs -P 8 -I{} curl -fsS "localhost:18080/$1/id{}" -o /dev/null 2>/dev/null; }

capture idle idle
capture bench      drive bench
capture benchpark  drive bench-park
capture oracle     drive oracle

echo "---"
echo "events/request (subtract idle baseline scaled by wall time; idle=10s):"
for n in bench benchpark oracle; do
  m=$(grep -c "Java VT mount" /tmp/e4cal_${n}.log 2>/dev/null || echo 0)
  echo "  $n: $m mounts / $N req = $(python3 -c "print(f'{$m/$N:.2f}')") per req"
done
$DC down >/dev/null 2>&1
echo DONE

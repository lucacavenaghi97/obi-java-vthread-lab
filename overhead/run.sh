#!/usr/bin/env bash
# Overhead timed matrix, per METHODOLOGY.md. Request cells:
#   {noobi, jtpin, fix} x {pt, vt} x {prop all|disabled}  (noobi mode-free)
# 5 interleaved repeats (cell order rotates inside each repeat), plus 5 null
# replicates of jtpin-vt-all, a churn arm and a non-Java arm (see run order
# at the bottom). Output: results/e4.csv + per-cell hey/freq logs.
set -u
cd "$(dirname "$0")"
: "${OBI_REPO:?point OBI_REPO at an opentelemetry-ebpf-instrumentation checkout (the fix branch)}"
E3=../oracle
HEY=${HEY:-$(command -v hey || true)}
WARMUP=${WARMUP:-30s}
MEASURE=${MEASURE:-60s}
CONC=${CONC:-40}
REPEATS=${REPEATS:-5}
ENDPOINT=${ENDPOINT:-bench/bench0}
CSV=results/e4.csv
mkdir -p results

JRE=eclipse-temurin:21-jre

dc_files() { # obi-kind
  local f="-f $E3/docker-compose.yml -f ./docker-compose.e4.yml"
  [ "$1" = jtpin ] && f="$f -f ./docker-compose.jtpin.yml"
  echo "$f"
}

priv() { docker run --rm --privileged ubuntu:24.04 sh -c "$1"; }

preflight() {
  [ -x "$HEY" ] || { echo "FATAL: hey not found at $HEY"; exit 1; }
  docker image inspect obi-jt-pin >/dev/null 2>&1 || { echo "FATAL: obi-jt-pin image missing"; exit 1; }
  local stray
  stray=$(docker ps --format '{{.Names}}' | grep -v '^$' || true)
  [ -n "$stray" ] && { echo "FATAL: containers running, quiesce first: $stray"; exit 1; }
  # performance governor + no turbo, via privileged container (no sudo needed)
  priv 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done; echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor' || echo "WARN: governor setup failed, continuing (interleaving + freq log compensate)"
  echo "preflight OK (hey: $($HEY 2>&1 | head -1 | cut -c1-20)...)"
}

restore_cpu() {
  priv 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > $g; done; echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null; true' || true
}

cpu_stat() { # container-name -> "usage_usec user_usec system_usec"
  local id
  id=$(docker inspect --format '{{.Id}}' "$1" 2>/dev/null) || { echo "0 0 0"; return; }
  awk '/usage_usec|user_usec|system_usec/{printf "%s ", $2}' \
    "/sys/fs/cgroup/system.slice/docker-${id}.scope/cpu.stat" 2>/dev/null || echo "0 0 0"
}

wait_ready() { # vt obi-kind  -> waits for app + (if obi) instrumentation
  for i in $(seq 1 120); do curl -fsS localhost:18080/thread-info >/dev/null 2>&1 && break; sleep 1; done
  if [ "$1" != noobi ]; then
    local obi_cont
    obi_cont=$(docker ps --format '{{.Names}}' | grep obi)
    for i in $(seq 1 90); do
      docker logs "$obi_cont" 2>&1 | grep -q "instrumenting process" && break; sleep 1
    done
    sleep 5
    curl -fsS "localhost:18080/$ENDPOINT" -o /dev/null 2>/dev/null
    sleep 3
  fi
}

assert_image() { # expected-tag
  local obi_cont running expected
  obi_cont=$(docker ps --format '{{.Names}}' | grep obi)
  running=$(docker inspect --format '{{.Image}}' "$obi_cont")
  expected=$(docker image inspect --format '{{.Id}}' "$1")
  [ "$running" = "$expected" ] || { echo "FATAL: obi runs $running, expected $1=$expected"; exit 1; }
}

run_cell() { # kind(noobi|jtpin|fix) threads(pt|vt) mode(all|disabled) repeat
  local kind=$1 threads=$2 mode=$3 rep=$4
  local name="${kind}-${threads}-${mode}-r${rep}"
  local vt=false; [ "$threads" = vt ] && vt=true
  echo "--- cell $name ---"
  export VT=$vt JRE_IMAGE=$JRE SSL_SERVER=false BPF_DEBUG=false CTXPROP=$mode
  local DC="docker compose $(dc_files "$kind")"
  $DC down >/dev/null 2>&1
  if [ "$kind" = noobi ]; then
    $DC up -d app downstream > /tmp/e4_up.log 2>&1 || { echo "UP FAILED"; tail -5 /tmp/e4_up.log; return 1; }
  elif [ "$kind" = fix ]; then
    $DC up -d --build > /tmp/e4_up.log 2>&1 || { echo "UP FAILED"; tail -5 /tmp/e4_up.log; return 1; }
    assert_image hatest-obi-b
  else
    $DC up -d > /tmp/e4_up.log 2>&1 || { echo "UP FAILED"; tail -5 /tmp/e4_up.log; return 1; }
    assert_image obi-jt-pin
  fi
  wait_ready "$kind"

  taskset -c 12,13 $HEY -z $WARMUP -c $CONC -t 0 "http://localhost:18080/$ENDPOINT" > /dev/null 2>&1

  local app_cont obi_cont="" a0 o0="0 0 0"
  app_cont=$(docker ps --format '{{.Names}}' | grep 'app')
  [ "$kind" != noobi ] && obi_cont=$(docker ps --format '{{.Names}}' | grep obi)
  ( while :; do awk '/MHz/{s+=$4;n++}END{print s/n}' /proc/cpuinfo; sleep 1; done > /tmp/e4_freq_$name.log 2>/dev/null ) &
  local fpid=$!
  a0=$(cpu_stat "$app_cont"); [ -n "$obi_cont" ] && o0=$(cpu_stat "$obi_cont")

  taskset -c 12,13 $HEY -z $MEASURE -c $CONC -t 0 "http://localhost:18080/$ENDPOINT" > "results/hey_$name.txt" 2>&1

  local a1 o1="0 0 0"
  a1=$(cpu_stat "$app_cont"); [ -n "$obi_cont" ] && o1=$(cpu_stat "$obi_cont")
  kill $fpid 2>/dev/null; wait $fpid 2>/dev/null
  cp /tmp/e4_freq_$name.log "results/freq_$name.log" 2>/dev/null

  local rps p50 p90 p99
  rps=$(awk '/Requests\/sec/{print $2}' "results/hey_$name.txt")
  p50=$(awk '/50% in/{print $3}' "results/hey_$name.txt")
  p90=$(awk '/90% in/{print $3}' "results/hey_$name.txt")
  p99=$(awk '/99% in/{print $3}' "results/hey_$name.txt")
  local freq
  freq=$(awk '{s+=$1;n++}END{if(n)print s/n; else print 0}' "results/freq_$name.log")
  local obi_rss=0
  [ -n "$obi_cont" ] && obi_rss=$(docker stats --no-stream --format '{{.MemUsage}}' "$obi_cont" | cut -d/ -f1 | tr -d ' ')
  echo "$kind,$threads,$mode,$rep,$rps,$p50,$p90,$p99,$(echo $a0 | tr ' ' ';'),$(echo $a1 | tr ' ' ';'),$(echo $o0 | tr ' ' ';'),$(echo $o1 | tr ' ' ';'),$freq,$obi_rss" >> $CSV
  echo "    rps=$rps p99=$p99 freq=$freq"
  $DC down >/dev/null 2>&1
}

run_churn() { # kind repeat
  local kind=$1 rep=$2 name="churn-${kind}-r${rep}"
  echo "--- $name ---"
  export VT=false JRE_IMAGE=$JRE SSL_SERVER=false BPF_DEBUG=false CTXPROP=all
  local DC="docker compose $(dc_files "$kind")"
  $DC down >/dev/null 2>&1
  if [ "$kind" = fix ]; then $DC up -d --build >/dev/null 2>&1; assert_image hatest-obi-b
  else $DC up -d >/dev/null 2>&1; assert_image obi-jt-pin; fi
  wait_ready "$kind"
  local app_cont obi_cont
  app_cont=$(docker ps --format '{{.Names}}' | grep 'app')
  obi_cont=$(docker ps --format '{{.Names}}' | grep obi)
  curl -fsS "localhost:18080/churn?seconds=70&vts=64" >/dev/null
  sleep 5
  local a0 o0 a1 o1
  a0=$(cpu_stat "$app_cont"); o0=$(cpu_stat "$obi_cont")
  sleep 60
  a1=$(cpu_stat "$app_cont"); o1=$(cpu_stat "$obi_cont")
  echo "churn-$kind,vt,all,$rep,0,0,0,0,$(echo $a0 | tr ' ' ';'),$(echo $a1 | tr ' ' ';'),$(echo $o0 | tr ' ' ';'),$(echo $o1 | tr ' ' ';'),0,0" >> $CSV
  $DC down >/dev/null 2>&1
}

run_nonjava() { # kind repeat : OBI watches nginx only
  local kind=$1 rep=$2 name="nonjava-${kind}-r${rep}"
  echo "--- $name ---"
  export VT=false JRE_IMAGE=$JRE SSL_SERVER=false BPF_DEBUG=false CTXPROP=all
  export OTEL_EBPF_OPEN_PORT_OVERRIDE=80
  local DC="docker compose $(dc_files "$kind") -f ./docker-compose.nonjava.yml"
  $DC down >/dev/null 2>&1
  if [ "$kind" = fix ]; then $DC up -d --build downstream obi >/dev/null 2>&1; assert_image hatest-obi-b
  else $DC up -d downstream obi >/dev/null 2>&1; assert_image obi-jt-pin; fi
  local port
  port=$(docker port "$(docker ps --format '{{.Names}}' | grep downstream)" 80 2>/dev/null | head -1 | cut -d: -f2)
  sleep 20
  taskset -c 12,13 $HEY -z $WARMUP -c $CONC -t 0 "http://localhost:${port}/echo/x" >/dev/null 2>&1
  local obi_cont o0 o1
  obi_cont=$(docker ps --format '{{.Names}}' | grep obi)
  o0=$(cpu_stat "$obi_cont")
  taskset -c 12,13 $HEY -z $MEASURE -c $CONC -t 0 "http://localhost:${port}/echo/x" > "results/hey_$name.txt" 2>&1
  o1=$(cpu_stat "$obi_cont")
  local rps
  rps=$(awk '/Requests\/sec/{print $2}' "results/hey_$name.txt")
  echo "nonjava-$kind,pt,all,$rep,$rps,0,0,0,0;0;0,0;0;0,$(echo $o0 | tr ' ' ';'),$(echo $o1 | tr ' ' ';'),0,0" >> $CSV
  $DC down >/dev/null 2>&1
}

trap restore_cpu EXIT
preflight
echo "kind,threads,mode,rep,rps,p50,p90,p99,app0,app1,obi0,obi1,freq,obi_rss" > $CSV

# interleaved: rotate cell order each repeat so drift decorrelates from arms
CELLS=(noobi-pt-all noobi-vt-all jtpin-pt-all jtpin-vt-all fix-pt-all fix-vt-all jtpin-pt-disabled jtpin-vt-disabled fix-pt-disabled fix-vt-disabled)
for rep in $(seq 1 $REPEATS); do
  n=${#CELLS[@]}
  for i in $(seq 0 $((n-1))); do
    c=${CELLS[$(( (i + rep - 1) % n ))]}
    IFS=- read -r kind threads mode <<< "$c"
    run_cell "$kind" "$threads" "$mode" "$rep"
  done
done

# null replicates (noise floor): 5 more of jtpin-vt-all
for rep in $(seq 6 10); do run_cell jtpin vt all "$rep"; done

# churn worst case + non-Java tax
for rep in 1 2 3; do run_churn jtpin "$rep"; run_churn fix "$rep"; done
for rep in 1 2 3; do run_nonjava jtpin "$rep"; run_nonjava fix "$rep"; done

restore_cpu
echo DONE

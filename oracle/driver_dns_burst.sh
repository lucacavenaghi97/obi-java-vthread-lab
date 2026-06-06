#!/usr/bin/env bash
# 12 bursts, 31s apart: each burst forces one fresh DNS resolve (default
# 30s positive TTL) on a different request's virtual thread.
pfx=$1
for b in $(seq 1 12); do
  seq 1 10 | xargs -P 10 -I{} curl -fsS "localhost:18080/oracle/${pfx}b${b}n{}" -o /dev/null 2>/dev/null
  sleep 31
done
echo BURSTS-DONE

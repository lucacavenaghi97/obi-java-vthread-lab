#!/usr/bin/env python3
# Drives N raw-TCP oracle requests at concurrency P against the repro app's
# 9090 line protocol. Prints "id local_port" per request for the analyzer.
import socket
import sys
from concurrent.futures import ThreadPoolExecutor

N = int(sys.argv[1]) if len(sys.argv) > 1 else 800
P = int(sys.argv[2]) if len(sys.argv) > 2 else 40
PREFIX = sys.argv[3] if len(sys.argv) > 3 else "tcpid"


def one(i):
    rid = f"{PREFIX}{i}"
    try:
        s = socket.create_connection(("127.0.0.1", 19090), timeout=15)
        port = s.getsockname()[1]
        s.sendall(f"{rid}\n".encode())
        reply = s.makefile().readline().strip()
        s.close()
        ok = reply.startswith(f"ok {rid} ")
        return f"{rid} {port} {'OK' if ok else 'BAD:' + reply}"
    except Exception as e:
        return f"{rid} - ERR:{e}"


with ThreadPoolExecutor(max_workers=P) as ex:
    for line in ex.map(one, range(1, N + 1)):
        print(line)

#!/usr/bin/env python3
"""best-effort flood 를 받아 버리는 싱크. 받은 패킷 수만 센다.

싱크가 없으면 수신 커널이 패킷마다 ICMP port unreachable 을 돌려보내 역방향 트래픽이 생긴다.
"""

import argparse
import json
import signal
import socket
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=5001)
    p.add_argument("--stats-file", default="")
    args = p.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(0.5)
    count = 0
    nbytes = 0
    stop = False

    def _stop(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    while not stop:
        try:
            data = sock.recv(65535)
            count += 1
            nbytes += len(data)
        except TimeoutError:
            continue
    print(f"udp_sink: received {count} pkts, {nbytes} bytes", file=sys.stderr)
    if args.stats_file:
        with open(args.stats_file, "w") as f:
            json.dump({"received": count, "bytes": nbytes}, f)


if __name__ == "__main__":
    main()

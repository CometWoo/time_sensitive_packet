#!/usr/bin/env python3
"""be_flood.py — best-effort UDP 경쟁 트래픽 생성기 (토큰 버킷 페이싱)

병목 링크(예: tbf 20 Mbit/s) 보다 높은 속도(예: 30 Mbit/s)로 대형 UDP 패킷을 밀어 넣어
qdisc 안에 **지속적인 backlog** 를 만든다. 우선순위 qdisc 가 효과를 내려면 이런
경쟁이 있어야 한다 — 경쟁 트래픽 없이 단일 흐름만 흘리면 어떤 qdisc 든 큐가 비어
있어서 차이가 날 수 없다 (docs/adr/0006-testbed-needs-contention.md).

사용법:
  python3 be_flood.py --target 10.10.2.2 --port 5001 --rate-mbps 30 --size 1400 --duration 15
"""
import argparse
import socket
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    p.add_argument("--port", type=int, default=5001)
    p.add_argument("--rate-mbps", type=float, default=30.0, help="제공 부하 (Mbit/s, 0 = 최대 속도)")
    p.add_argument("--size", type=int, default=1400, help="UDP payload 크기 (bytes)")
    p.add_argument("--duration", type=float, default=15.0, help="지속 시간 (초)")
    p.add_argument("--so-priority", type=int, default=-1, help="SO_PRIORITY (기본 미설정 = 0)")
    p.add_argument("--stats-file", default="", help="종료 시 통계 JSON 저장 경로")
    args = p.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    if args.so_priority >= 0:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, args.so_priority)
    payload = b"\x42" * args.size
    target = (socket.gethostbyname(args.target), args.port)

    per_pkt_ns = 0 if args.rate_mbps <= 0 else int(args.size * 8 / (args.rate_mbps * 1e6) * 1e9)
    sent = errors = 0
    t0 = time.time_ns()
    deadline = t0 + int(args.duration * 1e9)
    next_tx = t0
    print(f"be_flood -> {target}, {args.rate_mbps} Mbit/s, {args.size}B, {args.duration}s "
          f"({1e9 / per_pkt_ns if per_pkt_ns else float('inf'):.0f} pkt/s)")
    try:
        while True:
            now = time.time_ns()
            if now >= deadline:
                break
            if per_pkt_ns:
                if now < next_tx:
                    wait = next_tx - now
                    if wait > 300_000:
                        time.sleep((wait - 150_000) / 1e9)
                    continue
                next_tx += per_pkt_ns
                if now - next_tx > 50_000_000:      # 50 ms 이상 뒤처지면 리셋 (burst 방지)
                    next_tx = now
            try:
                sock.sendto(payload, target)
                sent += 1
            except OSError:
                errors += 1
    except KeyboardInterrupt:
        pass
    elapsed = max((time.time_ns() - t0) / 1e9, 1e-9)
    mbps = sent * args.size * 8 / elapsed / 1e6
    print(f"be_flood 종료: sent={sent} errors={errors} elapsed={elapsed:.2f}s achieved={mbps:.1f} Mbit/s")
    if args.stats_file:
        import json
        with open(args.stats_file, "w") as f:
            json.dump({"sent": sent, "errors": errors, "elapsed_s": elapsed, "achieved_mbps": mbps,
                       "offered_mbps": args.rate_mbps, "size": args.size}, f)


if __name__ == "__main__":
    main()

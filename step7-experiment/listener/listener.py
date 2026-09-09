#!/usr/bin/env python3
"""listener.py — UDP 패킷 수신 및 latency / jitter / DSCP 측정

측정 지표 (논문 §V 와 동일한 정의):
  - Bandwidth : 수신 바이트 / 수신 구간(초)
  - Latency   : recv_ns - send_ns  (송신 타임스탬프는 패킷 헤더에 실려 옴)
                ※ 서로 다른 호스트라면 두 시계의 오프셋이 포함된다 (PTP/NTP 필요).
                   같은 호스트(netns 테스트베드)에서는 같은 시계라 절대값이 유효하다.
  - Jitter    : Jitter(i) = t_i - (t_{i-1} + T),  T = 송신 간격
  - TOS/DSCP  : --record-tos 일 때 IP_RECVTOS 로 수신 IP TOS 바이트 기록
                (eBPF DSCP 마킹이 실제로 와이어에 실렸는지 end-to-end 검증)

사용법:
  python3 listener.py --port 6000 --interval 1 --output results.csv [--record-tos] [--ready-file F]
"""
import argparse
import csv
import os
import socket
import struct
import time

PKT_HEADER_FMT = "!IQ"          # [seq(u32)][send_time_ns(u64)] network byte order
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)


def set_cpu_affinity(cpu_id):
    try:
        os.sched_setaffinity(0, {cpu_id})
        print(f"CPU affinity: CPU {cpu_id}")
    except Exception as e:  # noqa: BLE001 — 격리 코어가 없는 환경에서도 계속 진행
        print(f"CPU affinity 설정 실패: {e} (무시하고 계속)")


SO_TIMESTAMPNS_NEW = getattr(socket, "SO_TIMESTAMPNS_NEW", 64)   # Linux, asm-generic/socket.h
SCM_TIMESTAMPNS_NEW = SO_TIMESTAMPNS_NEW


def recv_one(sock, record_tos, kernel_ts):
    """(data, tos, kernel_recv_ns) 반환. 사용하지 않는 항목은 None."""
    if not record_tos and not kernel_ts:
        data, _addr = sock.recvfrom(65535)
        return data, None, None
    data, ancdata, _flags, _addr = sock.recvmsg(65535, socket.CMSG_SPACE(4) + socket.CMSG_SPACE(16))
    tos = -1 if record_tos else None
    kts = None
    for level, ctype, cdata in ancdata:
        if level == socket.IPPROTO_IP and ctype == socket.IP_TOS:
            tos = cdata[0]
        elif level == socket.SOL_SOCKET and ctype == SCM_TIMESTAMPNS_NEW and len(cdata) >= 16:
            sec, nsec = struct.unpack("qq", cdata[:16])     # struct __kernel_timespec
            kts = sec * 1_000_000_000 + nsec
    return data, tos, kts


def main():
    parser = argparse.ArgumentParser(description="TSN Listener — UDP 수신 및 측정")
    parser.add_argument("--port", type=int, default=6000, help="수신 포트 (기본: 6000)")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="예상 송신 간격 (ms, jitter 계산용)")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="마지막 패킷 후 이 시간(초) 동안 수신이 없으면 종료")
    parser.add_argument("--output", default="results.csv", help="결과 CSV 경로")
    parser.add_argument("--cpu", type=int, default=-1, help="CPU affinity (기본: 미설정)")
    parser.add_argument("--record-tos", action="store_true",
                        help="IP_RECVTOS 로 수신 TOS(DSCP<<2|ECN) 를 tos 컬럼에 기록 (Linux)")
    parser.add_argument("--ready-file", default="",
                        help="bind 완료 후 이 파일을 생성 (오케스트레이션용)")
    parser.add_argument("--kernel-ts", action="store_true",
                        help="SO_TIMESTAMPNS_NEW 로 커널 RX 타임스탬프를 recv_kernel_ns 컬럼에 추가 기록 "
                             "(latency_ms 는 그대로 사용자 공간 recv_ns 기준 — 기존 결과와 정의 동일)")
    parser.add_argument("--quiet", action="store_true", help="진행 로그 생략")
    args = parser.parse_args()

    expected_interval_ns = int(args.interval * 1e6)

    if args.cpu >= 0:
        set_cpu_affinity(args.cpu)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # SO_REUSEADDR 은 쓰지 않는다: 이전 listener 가 살아 있으면 조용히 포트를 나눠 갖는 대신 bind 가 실패해야 한다
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    if args.record_tos:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_RECVTOS, 1)
    if args.kernel_ts:
        sock.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS_NEW, 1)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(args.timeout)

    if args.ready_file:
        os.makedirs(os.path.dirname(args.ready_file) or ".", exist_ok=True)
        with open(args.ready_file, "w") as f:
            f.write(str(os.getpid()))

    print(f"Listener 시작: 0.0.0.0:{args.port}  (interval={args.interval}ms, timeout={args.timeout}s, "
          f"record_tos={args.record_tos})")

    results = []
    prev_recv_ns = None
    total_bytes = 0
    start_time = None

    try:
        while True:
            try:
                data, tos, kernel_ns = recv_one(sock, args.record_tos, args.kernel_ts)
            except TimeoutError:
                if results:
                    print(f"타임아웃 — 수신 완료 ({len(results)} 패킷)")
                    break
                if not args.quiet:
                    print("대기 중... (패킷 미수신)")
                continue

            recv_ns = time.time_ns()
            if start_time is None:
                start_time = recv_ns
            if len(data) < PKT_HEADER_SIZE:
                continue

            seq, send_ns = struct.unpack(PKT_HEADER_FMT, data[:PKT_HEADER_SIZE])
            pkt_size = len(data)
            total_bytes += pkt_size

            latency_ms = (recv_ns - send_ns) / 1e6
            jitter_us = 0.0
            if prev_recv_ns is not None:
                jitter_us = (recv_ns - (prev_recv_ns + expected_interval_ns)) / 1e3
            prev_recv_ns = recv_ns

            row = {
                "seq": seq,
                "send_ns": send_ns,
                "recv_ns": recv_ns,
                "latency_ms": latency_ms,
                "jitter_us": jitter_us,
                "pkt_size": pkt_size,
            }
            if args.record_tos:
                row["tos"] = tos
            if args.kernel_ts:
                row["recv_kernel_ns"] = kernel_ns if kernel_ns is not None else -1
            results.append(row)

            if not args.quiet and len(results) % 1000 == 0:
                elapsed = (recv_ns - start_time) / 1e9
                bw = total_bytes / elapsed if elapsed > 0 else 0
                print(f"  수신: {len(results)} pkts, BW: {bw/1024:.1f} KB/s, "
                      f"latency: {latency_ms:.3f}ms, jitter: {jitter_us:.1f}us")
    except KeyboardInterrupt:
        print("중단됨")

    sock.close()
    if not results:
        print("수신된 패킷 없음")
        return

    elapsed_s = max((results[-1]["recv_ns"] - results[0]["recv_ns"]) / 1e9, 1e-9)
    latencies = sorted(r["latency_ms"] for r in results)
    jitters = sorted(abs(r["jitter_us"]) for r in results[1:])
    n = len(latencies)
    # 손실은 고유 seq 기준으로: 중복은 손실을 가리지 않고, 재정렬은 '최대 seq 보다 작은 seq' 로 센다
    seqs = [r["seq"] for r in results]
    unique = len(set(seqs))
    expected = max(seqs) - min(seqs) + 1
    loss = expected - unique
    dups = len(seqs) - unique
    reorders = 0
    max_seen = -1
    for s in seqs:
        if s < max_seen:
            reorders += 1
        else:
            max_seen = s

    print("-" * 60)
    print(f"총 수신: {len(results)} 패킷, 구간 {elapsed_s:.2f}s, "
          f"BW {total_bytes / elapsed_s / 1024:.1f} KB/s, 손실 {loss}/{expected} ({loss / expected * 100:.2f}%), "
          f"중복 {dups}, 재정렬 {reorders}")
    print(f"Latency (ms): p50={latencies[n // 2]:.3f} p99={latencies[int(n * 0.99)]:.3f} max={latencies[-1]:.3f}")
    if jitters:
        m = len(jitters)
        print(f"Jitter (us):  p50={jitters[m // 2]:.1f} p99={jitters[int(m * 0.99)]:.1f} max={jitters[-1]:.1f}")
    if args.record_tos:
        dist = {}
        for r in results:
            dist[r["tos"]] = dist.get(r["tos"], 0) + 1
        print("TOS 분포 (tos: count): " + ", ".join(f"0x{k:02x}(dscp {k >> 2}): {v}" for k, v in sorted(dist.items())))

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)
    print(f"결과 저장: {args.output}")


if __name__ == "__main__":
    main()

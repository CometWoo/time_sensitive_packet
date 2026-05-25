#!/usr/bin/env python3
"""listener.py — UDP 패킷 수신 및 latency/jitter 측정

논문 측정 지표:
  - Bandwidth: 초당 평균 수신 데이터량 (bytes/s)
  - Latency: 송신 타임스탬프와 수신 시각의 차이
  - Jitter: Jitter(i) = t_i - (t_{i-1} + T)
    여기서 t_i는 i번째 패킷 수신 시각, T는 전송 간격 (1ms)

사용법:
  python3 listener.py --port 5000 --interval 1 --output results.csv
"""
import argparse
import socket
import struct
import time
import sys
import os
import csv

PKT_HEADER_FMT = "!IQ"
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)


def set_cpu_affinity(cpu_id):
    try:
        os.sched_setaffinity(0, {cpu_id})
        print(f"CPU affinity 설정: CPU {cpu_id}")
    except Exception as e:
        print(f"CPU affinity 설정 실패: {e}")


def main():
    parser = argparse.ArgumentParser(description="TSN Listener — UDP 수신 및 측정")
    parser.add_argument("--port", type=int, default=5000, help="수신 포트 (기본: 5000)")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="예상 전송 간격 (ms, jitter 계산용)")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="수신 대기 타임아웃 (초)")
    parser.add_argument("--output", default="results.csv",
                        help="결과 CSV 파일 (기본: results.csv)")
    parser.add_argument("--cpu", type=int, default=-1,
                        help="CPU affinity")
    args = parser.parse_args()

    expected_interval_ns = int(args.interval * 1e6)  # ms → ns

    if args.cpu >= 0:
        set_cpu_affinity(args.cpu)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(args.timeout)

    print(f"Listener 시작: 0.0.0.0:{args.port}")
    print(f"  예상 간격: {args.interval}ms, 타임아웃: {args.timeout}s")
    print("-" * 60)

    results = []
    prev_recv_ns = None
    total_bytes = 0
    start_time = None

    try:
        while True:
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                if results:
                    print(f"\n타임아웃 — 수신 완료 ({len(results)} 패킷)")
                    break
                else:
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

            # Latency 계산 (주의: 두 VM 간 시계 오차 포함)
            latency_ns = recv_ns - send_ns
            latency_ms = latency_ns / 1e6

            # Jitter 계산: Jitter(i) = t_i - (t_{i-1} + T)
            jitter_us = 0.0
            if prev_recv_ns is not None:
                expected_recv = prev_recv_ns + expected_interval_ns
                jitter_ns = recv_ns - expected_recv
                jitter_us = jitter_ns / 1e3  # ns → μs

            prev_recv_ns = recv_ns

            results.append({
                "seq": seq,
                "send_ns": send_ns,
                "recv_ns": recv_ns,
                "latency_ms": latency_ms,
                "jitter_us": jitter_us,
                "pkt_size": pkt_size,
            })

            # 진행 상황
            if len(results) % 1000 == 0:
                elapsed = (recv_ns - start_time) / 1e9
                bw = total_bytes / elapsed if elapsed > 0 else 0
                print(f"  수신: {len(results)} pkts, "
                      f"BW: {bw/1024:.1f} KB/s, "
                      f"Latency: {latency_ms:.3f}ms, "
                      f"Jitter: {jitter_us:.1f}μs")

    except KeyboardInterrupt:
        print("\n중단됨")

    sock.close()

    if not results:
        print("수신된 패킷 없음")
        return

    # 통계 계산
    elapsed_s = (results[-1]["recv_ns"] - results[0]["recv_ns"]) / 1e9
    latencies = [r["latency_ms"] for r in results]
    jitters = [abs(r["jitter_us"]) for r in results[1:]]  # 첫 패킷 jitter 제외

    print("-" * 60)
    print(f"총 수신: {len(results)} 패킷")
    print(f"소요 시간: {elapsed_s:.2f}s")
    print(f"Bandwidth: {total_bytes / elapsed_s / 1024:.2f} KB/s")
    print(f"Latency (ms): min={min(latencies):.3f}, "
          f"median={sorted(latencies)[len(latencies)//2]:.3f}, "
          f"max={max(latencies):.3f}, "
          f"avg={sum(latencies)/len(latencies):.3f}")
    if jitters:
        print(f"Jitter (μs): min={min(jitters):.1f}, "
              f"median={sorted(jitters)[len(jitters)//2]:.1f}, "
              f"max={max(jitters):.1f}, "
              f"avg={sum(jitters)/len(jitters):.1f}")

    # 손실률
    if results:
        expected = results[-1]["seq"] - results[0]["seq"] + 1
        loss = expected - len(results)
        print(f"패킷 손실: {loss}/{expected} ({loss/expected*100:.2f}%)")

    # CSV 저장
    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=results[0].keys())
        writer.writeheader()
        writer.writerows(results)
    print(f"\n결과 저장: {args.output}")


if __name__ == "__main__":
    main()

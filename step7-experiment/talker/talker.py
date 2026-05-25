#!/usr/bin/env python3
"""talker.py — 1ms 간격 UDP 패킷 전송기

논문 실험 구성:
  - 1ms 간격으로 UDP 패킷 전송
  - 각 패킷에 시퀀스 번호와 전송 타임스탬프 포함
  - listener가 수신하여 latency/jitter 측정

사용법:
  python3 talker.py --target <listener_ip> --port 5000 --interval 1 --count 10000
"""
import argparse
import socket
import struct
import time
import sys
import os

# 패킷 형식: [seq_num(4B)][send_time_ns(8B)][padding]
PKT_HEADER_FMT = "!IQ"  # network byte order: uint32 + uint64
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)


def set_cpu_affinity(cpu_id):
    """프로세스를 특정 CPU에 바인딩 (isolcpus와 함께 사용)"""
    try:
        os.sched_setaffinity(0, {cpu_id})
        print(f"CPU affinity 설정: CPU {cpu_id}")
    except Exception as e:
        print(f"CPU affinity 설정 실패: {e} (무시하고 계속)")


def set_realtime_priority(priority=50):
    """실시간 스케줄링 우선순위 설정 (SCHED_FIFO)"""
    try:
        param = os.sched_param(priority)
        os.sched_setscheduler(0, os.SCHED_FIFO, param)
        print(f"RT 스케줄러 설정: SCHED_FIFO, priority={priority}")
    except PermissionError:
        print("RT 스케줄러 설정 실패: root 권한 필요 (무시하고 계속)")
    except Exception as e:
        print(f"RT 스케줄러 설정 실패: {e}")


def main():
    parser = argparse.ArgumentParser(description="TSN Talker — UDP 패킷 전송기")
    parser.add_argument("--target", required=True, help="Listener IP 주소")
    parser.add_argument("--port", type=int, default=5000, help="대상 포트 (기본: 5000)")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="전송 간격 (ms, 기본: 1.0)")
    parser.add_argument("--count", type=int, default=10000,
                        help="전송 패킷 수 (기본: 10000)")
    parser.add_argument("--size", type=int, default=128,
                        help="패킷 크기 (bytes, 기본: 128)")
    parser.add_argument("--cpu", type=int, default=-1,
                        help="CPU affinity (기본: -1 = 미설정)")
    parser.add_argument("--realtime", action="store_true",
                        help="SCHED_FIFO 실시간 스케줄링 사용")
    parser.add_argument("--vlan-priority", type=int, default=-1,
                        help="SO_PRIORITY 설정 (VLAN PCP 매핑)")
    parser.add_argument("--log", default="",
                        help="전송 로그 파일 경로 (CSV)")
    args = parser.parse_args()

    interval_s = args.interval / 1000.0
    payload_size = max(args.size - PKT_HEADER_SIZE, 0)
    padding = b'\x00' * payload_size

    # CPU affinity 및 RT 스케줄링
    if args.cpu >= 0:
        set_cpu_affinity(args.cpu)
    if args.realtime:
        set_realtime_priority()

    # 소켓 생성
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # VLAN 우선순위 설정 (SO_PRIORITY → skb->priority → mqprio TC 매핑)
    if args.vlan_priority >= 0:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, args.vlan_priority)
        print(f"SO_PRIORITY 설정: {args.vlan_priority}")

    target = (args.target, args.port)
    log_file = None
    if args.log:
        log_file = open(args.log, "w")
        log_file.write("seq,send_time_ns,scheduled_time_ns,actual_send_ns,drift_us\n")

    print(f"Talker 시작: {args.target}:{args.port}")
    print(f"  간격: {args.interval}ms, 패킷 수: {args.count}, 크기: {args.size}B")
    print(f"  예상 소요시간: {args.count * interval_s:.1f}s")
    print("-" * 50)

    sent = 0
    errors = 0
    start_time = time.time_ns()

    try:
        for seq in range(args.count):
            scheduled_ns = start_time + int(seq * interval_s * 1e9)

            # 정확한 간격 대기 (busy-wait for precision)
            now = time.time_ns()
            while now < scheduled_ns:
                if scheduled_ns - now > 500_000:  # 0.5ms 이상 남으면 sleep
                    time.sleep((scheduled_ns - now - 200_000) / 1e9)
                now = time.time_ns()

            send_time_ns = time.time_ns()
            header = struct.pack(PKT_HEADER_FMT, seq, send_time_ns)
            pkt = header + padding

            try:
                sock.sendto(pkt, target)
                sent += 1
            except Exception as e:
                errors += 1
                if errors <= 5:
                    print(f"전송 오류 #{seq}: {e}")

            if log_file:
                drift_us = (send_time_ns - scheduled_ns) / 1000.0
                log_file.write(f"{seq},{send_time_ns},{scheduled_ns},{send_time_ns},{drift_us:.2f}\n")

            # 진행 상황
            if (seq + 1) % 1000 == 0:
                elapsed = (time.time_ns() - start_time) / 1e9
                rate = (seq + 1) / elapsed
                print(f"  진행: {seq+1}/{args.count} ({rate:.0f} pkt/s)")

    except KeyboardInterrupt:
        print("\n중단됨")

    elapsed = (time.time_ns() - start_time) / 1e9
    print("-" * 50)
    print(f"전송 완료: {sent}/{args.count} (오류: {errors})")
    print(f"소요 시간: {elapsed:.2f}s")
    print(f"평균 전송률: {sent/elapsed:.1f} pkt/s")

    if log_file:
        log_file.close()
        print(f"로그 저장: {args.log}")

    sock.close()


if __name__ == "__main__":
    main()

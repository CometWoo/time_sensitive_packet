#!/usr/bin/env python3
"""talker.py — 고정 간격(기본 1 ms) UDP 패킷 전송기

각 패킷 헤더에 [seq(u32)][send_time_ns(u64)] 를 실어 보내고, listener 가
latency / jitter 를 계산한다.

주의 — 목적지 이름 해석:
  socket.sendto() 에 호스트 이름을 넘기면 파이썬은 **매 호출마다 getaddrinfo()** 를
  수행한다. K8s 안에서 Service 이름을 그대로 쓰면 패킷마다 CoreDNS 왕복이
  send_time_ns 스탬프 이후에 끼어들어 latency 측정에 섞인다. 그래서 시작 시
  한 번만 해석한 IP 로 보낸다 (docs/adr/0008-talker-resolve-once.md).

사용법:
  python3 talker.py --target <ip|name> --port 6000 --interval 1 --count 10000 [--so-priority 6] [--tos 0xb8]
"""
import argparse
import os
import socket
import struct
import time

PKT_HEADER_FMT = "!IQ"
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)


def set_cpu_affinity(cpu_id):
    try:
        os.sched_setaffinity(0, {cpu_id})
        print(f"CPU affinity: CPU {cpu_id}")
    except Exception as e:  # noqa: BLE001
        print(f"CPU affinity 설정 실패: {e} (무시하고 계속)")


def set_realtime_priority(priority=50):
    try:
        os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(priority))
        print(f"RT 스케줄러: SCHED_FIFO priority={priority}")
    except PermissionError:
        print("RT 스케줄러 설정 실패: CAP_SYS_NICE 필요 (무시하고 계속)")
    except Exception as e:  # noqa: BLE001
        print(f"RT 스케줄러 설정 실패: {e}")


def main():
    parser = argparse.ArgumentParser(description="TSN Talker — UDP 패킷 전송기")
    parser.add_argument("--target", required=True, help="Listener IP 또는 호스트 이름 (시작 시 1회 해석)")
    parser.add_argument("--port", type=int, default=6000, help="목적지 UDP 포트 (기본 6000 = TS 포트)")
    parser.add_argument("--interval", type=float, default=1.0, help="송신 간격 (ms)")
    parser.add_argument("--count", type=int, default=10000, help="송신 패킷 수")
    parser.add_argument("--size", type=int, default=128, help="패킷 크기 (bytes, 헤더 12B 포함)")
    parser.add_argument("--cpu", type=int, default=-1, help="CPU affinity (기본 미설정)")
    parser.add_argument("--realtime", action="store_true", help="SCHED_FIFO 사용")
    parser.add_argument("--so-priority", "--vlan-priority", dest="so_priority", type=int, default=-1,
                        help="SO_PRIORITY 값 (skb->priority). 0..6 은 권한 불필요. "
                             "※ veth 를 건너면 0 으로 리셋됨 (호스트 qdisc 에는 전달되지 않음)")
    parser.add_argument("--tos", type=lambda v: int(v, 0), default=-1,
                        help="IP_TOS 값 (예: 0xb8 = DSCP EF). 애플리케이션이 직접 DSCP 를 찍을 때")
    parser.add_argument("--start-delay", type=float, default=0.0, help="송신 시작 전 대기(초)")
    parser.add_argument("--log", default="", help="송신 드리프트 로그 CSV 경로")
    parser.add_argument("--quiet", action="store_true", help="진행 로그 생략")
    parser.add_argument("--strict-pacing", action="store_true",
                        help="송신 수/실효 속도가 목표의 95 %% 미만이면 exit 3 (기본: 경고만)")
    args = parser.parse_args()

    interval_s = args.interval / 1000.0
    padding = b"\x00" * max(args.size - PKT_HEADER_SIZE, 0)

    if args.cpu >= 0:
        set_cpu_affinity(args.cpu)
    if args.realtime:
        set_realtime_priority()

    # 이름 해석은 딱 한 번
    target_ip = socket.getaddrinfo(args.target, args.port, socket.AF_INET, socket.SOCK_DGRAM)[0][4][0]
    target = (target_ip, args.port)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.so_priority >= 0:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, args.so_priority)
        print(f"SO_PRIORITY={args.so_priority}")
    if args.tos >= 0:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, args.tos)
        print(f"IP_TOS=0x{args.tos:02x} (DSCP {args.tos >> 2})")

    log_file = None
    if args.log:
        os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)
        log_file = open(args.log, "w")
        log_file.write("seq,send_time_ns,scheduled_time_ns,drift_us\n")

    print(f"Talker: {args.target} -> {target_ip}:{args.port}, interval={args.interval}ms, "
          f"count={args.count}, size={args.size}B, 예상 {args.count * interval_s:.1f}s")
    if args.start_delay > 0:
        time.sleep(args.start_delay)

    # 페이싱은 CLOCK_MONOTONIC(NTP 스텝에 영향받지 않음), 패킷 스탬프는 CLOCK_REALTIME(수신측과 비교용)
    sent = errors = 0
    drifts_us = []               # 예정 시각 대비 실제 송신 시각 (송신 페이싱 품질)
    interval_ns = int(interval_s * 1e9)
    start_mono = time.monotonic_ns()
    start_wall = time.time_ns()
    try:
        for seq in range(args.count):
            scheduled_ns = start_mono + seq * interval_ns
            now = time.monotonic_ns()
            while now < scheduled_ns:
                if scheduled_ns - now > 500_000:
                    time.sleep((scheduled_ns - now - 200_000) / 1e9)   # 0.5 ms 이상 남으면 sleep
                now = time.monotonic_ns()                              # 마지막 ~200 us 는 busy-wait
            drifts_us.append((now - scheduled_ns) / 1000.0)

            send_time_ns = time.time_ns()
            try:
                sock.sendto(struct.pack(PKT_HEADER_FMT, seq, send_time_ns) + padding, target)
                sent += 1
            except OSError as e:
                errors += 1
                if errors <= 5:
                    print(f"전송 오류 #{seq}: {e}")

            if log_file:
                log_file.write(f"{seq},{send_time_ns},{start_wall + seq * interval_ns},{drifts_us[-1]:.2f}\n")
            if not args.quiet and (seq + 1) % 1000 == 0:
                elapsed = (time.monotonic_ns() - start_mono) / 1e9
                print(f"  진행: {seq + 1}/{args.count} ({(seq + 1) / elapsed:.0f} pkt/s)")
    except KeyboardInterrupt:
        print("중단됨")

    elapsed = max((time.monotonic_ns() - start_mono) / 1e9, 1e-9)
    achieved = sent / elapsed
    target_rate = 1.0 / interval_s
    print(f"전송 완료: {sent}/{args.count} (오류 {errors}), {elapsed:.2f}s, {achieved:.1f} pkt/s (목표 {target_rate:.0f})")
    if drifts_us:
        d = sorted(drifts_us)
        n = len(d)
        stalls = sum(1 for v in drifts_us if v > 10_000)
        print(f"송신 페이싱 드리프트 (us): p50={d[n // 2]:.1f} p99={d[int(n * 0.99)]:.1f} max={d[-1]:.1f}; "
              f"10 ms 초과 스톨 {stalls}회")
    if log_file:
        log_file.close()
    sock.close()

    # 데이터 품질 게이트: 목표의 95 % 미만이면 실험이 교란된 것 (DNS/CFS quota/CPU 경쟁 신호)
    if sent < args.count or achieved < 0.95 * target_rate:
        print(f"WARNING: 페이싱 실패 — 송신 {sent}/{args.count}, 실효 {achieved:.0f}/{target_rate:.0f} pkt/s. "
              "이 run 의 latency/jitter 는 송신측 교란을 포함합니다.")
        if args.strict_pacing:
            raise SystemExit(3)


if __name__ == "__main__":
    main()

# explain_04 — talker.py (SO_PRIORITY, SO_TXTIME, 전송 로직)

> 대상 파일: `step7-experiment/talker/talker.py` (K8s 주입본은 `step7-experiment/k8s/talker-job.yaml`)
> Host-s(master)에서 1ms 간격으로 UDP 패킷을 송신하는 talker.

## 코드

```python
#!/usr/bin/env python3
"""talker.py — 1ms 간격 UDP 패킷 전송기"""
import argparse, socket, struct, time, sys, os

# 패킷 형식: [seq_num(4B)][send_time_ns(8B)][padding]
PKT_HEADER_FMT = "!IQ"
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)

def set_cpu_affinity(cpu_id):
    """프로세스를 특정 CPU에 바인딩 (isolcpus와 함께 사용)"""
    try:
        os.sched_setaffinity(0, {cpu_id})
        print(f"CPU affinity 설정: CPU {cpu_id}")
    except Exception as e:
        print(f"CPU affinity 설정 실패: {e} (무시하고 계속)")

def set_realtime_priority(priority=50):
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
    parser.add_argument("--target", required=True)
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--interval", type=float, default=1.0)   # ms
    parser.add_argument("--count", type=int, default=10000)
    parser.add_argument("--size", type=int, default=128)
    parser.add_argument("--cpu", type=int, default=-1)
    parser.add_argument("--realtime", action="store_true")
    parser.add_argument("--vlan-priority", type=int, default=-1)
    parser.add_argument("--log", default="")
    args = parser.parse_args()

    interval_s = args.interval / 1000.0
    payload_size = max(args.size - PKT_HEADER_SIZE, 0)
    padding = b'\x00' * payload_size

    if args.cpu >= 0:
        set_cpu_affinity(args.cpu)
    if args.realtime:
        set_realtime_priority()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # SO_PRIORITY → skb->priority → prio qdisc band 0 매핑
    if args.vlan_priority >= 0:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, args.vlan_priority)
        print(f"SO_PRIORITY 설정: {args.vlan_priority}")

    target = (args.target, args.port)
    start_time = time.time_ns()
    sent = errors = 0
    for seq in range(args.count):
        scheduled_ns = start_time + int(seq * interval_s * 1e9)
        now = time.time_ns()
        while now < scheduled_ns:                 # sleep + spin 하이브리드 페이싱
            if scheduled_ns - now > 500_000:
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
    sock.close()

if __name__ == "__main__":
    main()
```

K8s 호출 인자 (`talker-job.yaml`):
```yaml
args:
  - "--target=listener-svc.tsn-experiment.svc.cluster.local"
  - "--port=5000"
  - "--interval=1"
  - "--count=10000"
  - "--size=128"
  - "--cpu=2"             # isolcpus=2,3 격리 코어에 고정 (2026-06 추가)
  - "--log=/data/talker-log.csv"
  - "--vlan-priority=3"   # SO_PRIORITY=3 → prio qdisc band 0 (TSN)
```

> ⚠️ **SO_TXTIME 미사용**: 이 talker는 `SO_TXTIME`/`SCM_TXTIME`(전송 시각 지정)을
> 설정하지 않고 `sock.sendto()`로 즉시 전송한다. 따라서 ETF qdisc의 시간 기반
> 스케줄링은 적용되지 않으며(그래서 ETF를 메인 경로에서 제거함), 페이싱은 순수히
> userspace의 sleep+spin 으로만 이뤄진다.

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **talker.py (SO_PRIORITY, SO_TXTIME, 전송 로직)** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `main()`의 송신 루프: `scheduled_ns` 계산과 sleep+spin 하이브리드 페이싱이 1ms 간격을 어떻게 맞추는지, 왜 단순 `time.sleep(0.001)`로는 부족한지.
   - `sock.setsockopt(SOL_SOCKET, SO_PRIORITY, 3)`: 이 한 줄이 `skb->priority=3`으로 전파되어 prio qdisc band 0 분류로 이어지는 메커니즘.
   - `set_cpu_affinity()`/`set_realtime_priority()`: isolcpus 격리 코어 바인딩과 SCHED_FIFO의 의미.
   - 패킷 포맷 `"!IQ"`(seq 4B + send_time_ns 8B)와 `struct.pack`의 역할.
2. 코드, 문법 부분 설명
   - `time.time_ns()`(CLOCK_REALTIME)와 busy-wait 임계값(500_000/200_000 ns)의 의미.
   - **SO_TXTIME을 쓰지 않는다는 점**과 그 결과(ETF 미동작)를 명확히 설명하고, 만약 SO_TXTIME을 쓰려면 `sendmsg`+`SCM_TXTIME` cmsg가 어떻게 필요한지.
   - `struct.calcsize`, `argparse`, try/except graceful degradation.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `talker-job.yaml`이 ConfigMap으로 이 스크립트를 주입하고 `--vlan-priority=3 --cpu=2`로 실행한다.
   - 송신 패킷이 egress.c(eg)의 분류와 prio qdisc(band 0)를 거친다.
   - 수신측 `listener.py`가 `send_time_ns`를 읽어 latency를 계산한다.
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - SO_PRIORITY=3이 prio qdisc와 결합해 어떻게 p99 latency/jitter 개선을 만드는지, 그리고 송신 페이싱 정확도가 jitter 측정에 미치는 영향을 설명해줘.

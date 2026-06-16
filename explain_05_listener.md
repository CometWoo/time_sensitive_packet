# explain_05 — listener.py (수신, jitter 계산, 결과 출력)

> ⚠️ **2026-06 재설계 반영**: 수신 포트가 **6000** 으로 바뀌었다(아래 본문 5000 → 6000).
> 단일 프로그램 설계에서 **수신측 BPF 는 없으며, listener.py 가 유일한 수신측 측정기**이다
> (jitter/latency 계산·CSV 저장). 그 외 로직은 동일하다.

---

> 대상 파일: `step7-experiment/listener/listener.py` (K8s 주입본은 `step7-experiment/k8s/listener-deployment.yaml`)
> Host-r(worker01)에서 UDP 패킷을 수신하고 latency/jitter를 측정해 CSV로 저장한다.

## 코드

```python
#!/usr/bin/env python3
"""listener.py — UDP 패킷 수신 및 latency/jitter 측정"""
import argparse, socket, struct, time, sys, os, csv

PKT_HEADER_FMT = "!IQ"
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)

def main():
    parser = argparse.ArgumentParser(description="TSN Listener — UDP 수신 및 측정")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--interval", type=float, default=1.0)   # ms (jitter 기대 간격 T)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--output", default="results.csv")
    parser.add_argument("--cpu", type=int, default=-1)
    args = parser.parse_args()

    expected_interval_ns = int(args.interval * 1e6)   # T (ns)
    if args.cpu >= 0:
        os.sched_setaffinity(0, {args.cpu})

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(args.timeout)

    results = []
    prev_recv_ns = None
    total_bytes = 0
    start_time = None

    while True:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            if results: break
            else: continue

        recv_ns = time.time_ns()
        if start_time is None: start_time = recv_ns
        if len(data) < PKT_HEADER_SIZE: continue

        seq, send_ns = struct.unpack(PKT_HEADER_FMT, data[:PKT_HEADER_SIZE])
        pkt_size = len(data); total_bytes += pkt_size

        # Latency (주의: 두 VM 간 시계 오차 포함 → 분석 시 1st percentile 정규화)
        latency_ms = (recv_ns - send_ns) / 1e6

        # Jitter(i) = t_i - (t_{i-1} + T)
        jitter_us = 0.0
        if prev_recv_ns is not None:
            expected_recv = prev_recv_ns + expected_interval_ns
            jitter_us = (recv_ns - expected_recv) / 1e3
        prev_recv_ns = recv_ns

        results.append({"seq": seq, "send_ns": send_ns, "recv_ns": recv_ns,
                        "latency_ms": latency_ms, "jitter_us": jitter_us,
                        "pkt_size": pkt_size})

    sock.close()
    if not results: return

    # 통계 + CSV 저장
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=results[0].keys())
        writer.writeheader(); writer.writerows(results)

if __name__ == "__main__":
    main()
```

K8s 호출 인자 (`listener-deployment.yaml`):
```yaml
args:
  - "--port=5000"
  - "--interval=1"
  - "--timeout=60"
  - "--cpu=2"            # isolcpus 격리 코어 고정 (2026-06 추가)
  - "--output=/data/results.csv"
```

> 논문 수식 ↔ 코드 대응:
> `expected_interval_ns = T` / `expected_recv = prev_recv_ns + T` / `jitter = recv_ns - expected_recv`
> → **Jitter(i) = t_i − (t_{i-1} + T)** 와 줄 단위로 일치.

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **listener.py (수신, jitter 계산, 결과 출력)** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `main()`의 수신 루프: `recvfrom` → `struct.unpack`으로 seq/send_ns 추출 → latency/jitter 계산 → results 누적 → CSV 저장의 전체 흐름.
   - latency 계산 `(recv_ns - send_ns)/1e6`이 왜 두 VM 간 clock skew를 포함하는지, 분석 단계(`compare_results.py`/`plot-results.py`)의 1st percentile 정규화가 왜 필요한지.
   - jitter 계산이 논문 수식 `Jitter(i) = t_i - (t_{i-1} + T)`와 어떻게 1:1 대응되는지 줄 단위로.
   - 소켓 옵션 `SO_REUSEADDR`, `settimeout`의 의미.
2. 코드, 문법 부분 설명
   - `struct.unpack("!IQ", ...)`(network byte order, uint32+uint64), `time.time_ns()`.
   - `socket.timeout` 예외로 수신 종료를 판단하는 로직, `csv.DictWriter` 저장.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `listener-deployment.yaml`이 ConfigMap으로 주입하고 `--cpu=2 --timeout=60`으로 실행한다.
   - 출력 `/data/results.csv`를 `deploy-experiment.sh`가 `kubectl cp`로 호스트의 `step8-measurement/results/<mode>_cpu<N>.csv`로 회수한다.
   - 그 CSV가 `plot-results.py`(Figure 2~6)와 `compare_results.py`의 입력이 된다.
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - 이 스크립트가 실험의 **핵심 측정기**이며(pkt_stats는 보조 가시성), latency p50/p99/max와 jitter p50/p99가 어떻게 baseline vs proposed 비교로 이어지는지 설명해줘.

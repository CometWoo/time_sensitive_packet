#!/usr/bin/env python3
"""generate-sample-data.py — 그래프 테스트용 샘플 데이터 생성

실제 실험 전에 그래프 코드가 올바르게 동작하는지 확인하기 위한
합성 데이터 생성. 논문 결과를 기반으로 현실적인 분포를 모방.

논문 보고 수치:
  - Cilium idle: median latency ~1.601ms
  - Cilium 99%:  median latency ~21.288ms, P99 ~24.199ms
  - Proposed idle: median latency ~1.935ms
  - Proposed 99%:  median latency ~17.234ms, P99 ~17.279ms
"""
import os
import csv
import numpy as np
from pathlib import Path

RESULTS_DIR = Path("results")
RESULTS_DIR.mkdir(exist_ok=True)

CPU_LOADS = [10, 30, 50, 70, 90, 99]
N_PACKETS = 5000
INTERVAL_MS = 1.0

# 논문 기반 파라미터
PARAMS = {
    "baseline": {
        10:  {"lat_median": 1.6,  "lat_std": 0.3,  "jitter_std": 50},
        30:  {"lat_median": 2.5,  "lat_std": 0.8,  "jitter_std": 100},
        50:  {"lat_median": 5.0,  "lat_std": 2.0,  "jitter_std": 300},
        70:  {"lat_median": 10.0, "lat_std": 4.0,  "jitter_std": 800},
        90:  {"lat_median": 16.0, "lat_std": 5.0,  "jitter_std": 1500},
        99:  {"lat_median": 21.3, "lat_std": 4.0,  "jitter_std": 3000},
    },
    "proposed": {
        10:  {"lat_median": 1.9,  "lat_std": 0.2,  "jitter_std": 30},
        30:  {"lat_median": 2.2,  "lat_std": 0.3,  "jitter_std": 40},
        50:  {"lat_median": 3.0,  "lat_std": 0.5,  "jitter_std": 60},
        70:  {"lat_median": 5.0,  "lat_std": 1.0,  "jitter_std": 100},
        90:  {"lat_median": 10.0, "lat_std": 1.5,  "jitter_std": 200},
        99:  {"lat_median": 17.2, "lat_std": 1.0,  "jitter_std": 300},
    },
}


def generate_data(mode, cpu_load):
    params = PARAMS[mode][cpu_load]
    np.random.seed(hash((mode, cpu_load)) % 2**31)

    latencies = np.random.lognormal(
        mean=np.log(params["lat_median"]),
        sigma=params["lat_std"] / params["lat_median"] * 0.5,
        size=N_PACKETS,
    )
    latencies = np.maximum(latencies, 0.1)

    jitters = np.random.normal(0, params["jitter_std"], size=N_PACKETS)

    interval_ns = INTERVAL_MS * 1e6
    base_time = 1_000_000_000_000  # 가상 시작 시각

    rows = []
    for i in range(N_PACKETS):
        send_ns = int(base_time + i * interval_ns)
        recv_ns = int(send_ns + latencies[i] * 1e6)
        rows.append({
            "seq": i,
            "send_ns": send_ns,
            "recv_ns": recv_ns,
            "latency_ms": round(latencies[i], 6),
            "jitter_us": round(jitters[i], 2),
            "pkt_size": 128,
        })

    path = RESULTS_DIR / f"{mode}_cpu{cpu_load}.csv"
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    return path


print("샘플 데이터 생성 중...")
for mode in ["baseline", "proposed"]:
    for cpu in CPU_LOADS:
        path = generate_data(mode, cpu)
        print(f"  {path}")

print(f"\n샘플 데이터 생성 완료: {RESULTS_DIR}/")
print("그래프 생성: python3 plot-results.py")

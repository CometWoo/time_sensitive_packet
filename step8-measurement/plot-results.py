#!/usr/bin/env python3
"""plot-results.py — 논문 Figure 2~6 재현 그래프 생성

논문의 그래프:
  Figure 2: Throughput under 10% and 99% CPU utilization (box plot)
  Figure 3: Latency comparison among six CPU utilization (box plot)
  Figure 4: Jitter under 10% and 99% CPU utilization (box plot)
  Figure 5: Jitter comparison among six CPU utilization (box plot)
  Figure 6: CDF under 10% and 99% CPU utilization

사용법:
  python3 plot-results.py [결과 디렉토리]
  기본 디렉토리: ./results/
"""
import os
import sys
import csv
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

RESULTS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("results")
OUTPUT_DIR = Path("figures")
OUTPUT_DIR.mkdir(exist_ok=True)

CPU_LOADS = [10, 30, 50, 70, 90, 99]
SOLUTIONS = {"baseline": "Cilium", "proposed": "Our Solution"}
COLORS = {"baseline": "#4EABD1", "proposed": "#E8734A"}


def load_results(mode, cpu_load):
    """CSV 결과 파일 로드"""
    path = RESULTS_DIR / f"{mode}_cpu{cpu_load}.csv"
    if not path.exists():
        return None

    data = {"latency_ms": [], "jitter_us": [], "pkt_size": [], "seq": []}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            data["latency_ms"].append(float(row["latency_ms"]))
            data["jitter_us"].append(float(row["jitter_us"]))
            data["pkt_size"].append(int(row["pkt_size"]))
            data["seq"].append(int(row["seq"]))
    return data


def compute_bandwidth(data, interval_ms=1.0):
    """대역폭 계산 (KB/s)"""
    if not data or not data["pkt_size"]:
        return []
    total_bytes = sum(data["pkt_size"])
    duration_s = len(data["pkt_size"]) * interval_ms / 1000.0
    bw_kbps = total_bytes / duration_s / 1024.0

    # 1초 단위 bandwidth 계산
    pkts_per_sec = int(1000.0 / interval_ms)
    bw_list = []
    for i in range(0, len(data["pkt_size"]), pkts_per_sec):
        chunk = data["pkt_size"][i:i + pkts_per_sec]
        if chunk:
            bw_list.append(sum(chunk) / 1024.0)
    return bw_list


def figure2_throughput():
    """Figure 2: Throughput under 10% and 99% CPU utilization"""
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Figure 2: Throughput under 10% and 99% CPU utilization", fontsize=14)

    for idx, cpu in enumerate([10, 99]):
        ax = axes[idx]
        bw_data = []
        labels = []
        colors = []

        for mode, label in SOLUTIONS.items():
            data = load_results(mode, cpu)
            if data:
                bw = compute_bandwidth(data)
                bw_data.append(bw)
                labels.append(label)
                colors.append(COLORS[mode])

        if bw_data:
            bp = ax.boxplot(bw_data, labels=labels, patch_artist=True, widths=0.5)
            for patch, color in zip(bp["boxes"], colors):
                patch.set_facecolor(color)
                patch.set_alpha(0.7)

        ax.set_title(f"CPU {cpu}% utilization")
        ax.set_ylabel("Throughput (KB/s)")
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "fig2_throughput.png", dpi=150, bbox_inches="tight")
    print(f"  저장: {OUTPUT_DIR / 'fig2_throughput.png'}")
    plt.close()


def figure3_latency_comparison():
    """Figure 3: Latency comparison among six CPU utilization"""
    fig, ax = plt.subplots(figsize=(14, 6))
    fig.suptitle("Figure 3: Latency comparison among six CPU utilization", fontsize=14)

    positions = []
    all_data = []
    all_colors = []
    tick_positions = []
    tick_labels = []

    for i, cpu in enumerate(CPU_LOADS):
        base_pos = i * 3
        for j, (mode, label) in enumerate(SOLUTIONS.items()):
            data = load_results(mode, cpu)
            if data:
                all_data.append(data["latency_ms"])
                positions.append(base_pos + j)
                all_colors.append(COLORS[mode])
        tick_positions.append(base_pos + 0.5)
        tick_labels.append(f"{cpu}%")

    if all_data:
        bp = ax.boxplot(all_data, positions=positions, patch_artist=True, widths=0.6)
        for patch, color in zip(bp["boxes"], all_colors):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels)
    ax.set_xlabel("CPU Utilization")
    ax.set_ylabel("Latency (ms)")
    ax.grid(True, alpha=0.3, axis="y")

    # 범례
    from matplotlib.patches import Patch
    legend_patches = [Patch(facecolor=COLORS[m], alpha=0.7, label=l)
                      for m, l in SOLUTIONS.items()]
    ax.legend(handles=legend_patches, loc="upper left")

    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "fig3_latency.png", dpi=150, bbox_inches="tight")
    print(f"  저장: {OUTPUT_DIR / 'fig3_latency.png'}")
    plt.close()


def figure4_jitter():
    """Figure 4: Jitter under 10% and 99% CPU utilization"""
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Figure 4: Jitter under 10% and 99% CPU utilization", fontsize=14)

    for idx, cpu in enumerate([10, 99]):
        ax = axes[idx]
        jitter_data = []
        labels = []
        colors = []

        for mode, label in SOLUTIONS.items():
            data = load_results(mode, cpu)
            if data:
                jitters = [abs(j) for j in data["jitter_us"][1:]]  # 첫 패킷 제외
                jitter_data.append(jitters)
                labels.append(label)
                colors.append(COLORS[mode])

        if jitter_data:
            bp = ax.boxplot(jitter_data, labels=labels, patch_artist=True, widths=0.5)
            for patch, color in zip(bp["boxes"], colors):
                patch.set_facecolor(color)
                patch.set_alpha(0.7)

        ax.set_title(f"CPU {cpu}% utilization")
        ax.set_ylabel("Jitter (μs)")
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "fig4_jitter.png", dpi=150, bbox_inches="tight")
    print(f"  저장: {OUTPUT_DIR / 'fig4_jitter.png'}")
    plt.close()


def figure5_jitter_comparison():
    """Figure 5: Jitter comparison among six CPU utilization"""
    fig, ax = plt.subplots(figsize=(14, 6))
    fig.suptitle("Figure 5: Jitter comparison among six CPU utilization", fontsize=14)

    positions = []
    all_data = []
    all_colors = []
    tick_positions = []
    tick_labels = []

    for i, cpu in enumerate(CPU_LOADS):
        base_pos = i * 3
        for j, (mode, label) in enumerate(SOLUTIONS.items()):
            data = load_results(mode, cpu)
            if data:
                jitters = [abs(j_val) for j_val in data["jitter_us"][1:]]
                all_data.append(jitters)
                positions.append(base_pos + j)
                all_colors.append(COLORS[mode])
        tick_positions.append(base_pos + 0.5)
        tick_labels.append(f"{cpu}%")

    if all_data:
        bp = ax.boxplot(all_data, positions=positions, patch_artist=True, widths=0.6)
        for patch, color in zip(bp["boxes"], all_colors):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels)
    ax.set_xlabel("CPU Utilization")
    ax.set_ylabel("Jitter (μs)")
    ax.grid(True, alpha=0.3, axis="y")

    from matplotlib.patches import Patch
    legend_patches = [Patch(facecolor=COLORS[m], alpha=0.7, label=l)
                      for m, l in SOLUTIONS.items()]
    ax.legend(handles=legend_patches, loc="upper left")

    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "fig5_jitter_comparison.png", dpi=150, bbox_inches="tight")
    print(f"  저장: {OUTPUT_DIR / 'fig5_jitter_comparison.png'}")
    plt.close()


def figure6_cdf():
    """Figure 6: CDF under 10% and 99% CPU utilization"""
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Figure 6: CDF of Latency under 10% and 99% CPU utilization", fontsize=14)

    for idx, cpu in enumerate([10, 99]):
        ax = axes[idx]

        for mode, label in SOLUTIONS.items():
            data = load_results(mode, cpu)
            if data:
                latencies = sorted(data["latency_ms"])
                n = len(latencies)
                cdf = np.arange(1, n + 1) / n
                ax.plot(latencies, cdf, label=label, color=COLORS[mode], linewidth=2)

                # 99% 지점 표시
                p99_idx = int(n * 0.99)
                p99_val = latencies[p99_idx] if p99_idx < n else latencies[-1]
                ax.axhline(y=0.99, color="gray", linestyle="--", alpha=0.3)
                ax.plot(p99_val, 0.99, "o", color=COLORS[mode], markersize=6)
                ax.annotate(f"P99={p99_val:.1f}ms",
                            xy=(p99_val, 0.99),
                            xytext=(p99_val + 0.5, 0.92),
                            fontsize=8,
                            arrowprops=dict(arrowstyle="->", color=COLORS[mode]))

        ax.set_title(f"CPU {cpu}% utilization")
        ax.set_xlabel("Latency (ms)")
        ax.set_ylabel("CDF")
        ax.set_ylim(0, 1.02)
        ax.legend(loc="lower right")
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "fig6_cdf.png", dpi=150, bbox_inches="tight")
    print(f"  저장: {OUTPUT_DIR / 'fig6_cdf.png'}")
    plt.close()


def summary_table():
    """논문 결과와 비교 가능한 요약 테이블 출력"""
    print("\n" + "=" * 70)
    print(" 결과 요약")
    print("=" * 70)
    print(f"{'CPU':>4} {'Solution':>12} {'Median Lat':>11} {'P99 Lat':>9} "
          f"{'Med Jitter':>11} {'BW (KB/s)':>10}")
    print("-" * 70)

    for cpu in CPU_LOADS:
        for mode, label in SOLUTIONS.items():
            data = load_results(mode, cpu)
            if data:
                lat = sorted(data["latency_ms"])
                jit = sorted([abs(j) for j in data["jitter_us"][1:]])
                bw = compute_bandwidth(data)
                median_lat = lat[len(lat) // 2]
                p99_lat = lat[int(len(lat) * 0.99)]
                median_jit = jit[len(jit) // 2] if jit else 0
                avg_bw = np.mean(bw) if bw else 0
                print(f"{cpu:>3}% {label:>12} {median_lat:>10.3f}ms "
                      f"{p99_lat:>8.3f}ms {median_jit:>10.1f}μs {avg_bw:>9.1f}")


def main():
    print("========================================")
    print(" 논문 Figure 2-6 재현 그래프 생성")
    print(f" 결과 디렉토리: {RESULTS_DIR}")
    print(f" 출력 디렉토리: {OUTPUT_DIR}")
    print("========================================")

    # 결과 파일 확인
    found = 0
    for mode in SOLUTIONS:
        for cpu in CPU_LOADS:
            path = RESULTS_DIR / f"{mode}_cpu{cpu}.csv"
            if path.exists():
                found += 1
    print(f"\n결과 파일: {found}/{len(SOLUTIONS) * len(CPU_LOADS)}개 발견")

    if found == 0:
        print("\n결과 파일이 없습니다. 먼저 실험을 실행하세요:")
        print("  bash run-full-experiment.sh")
        print("\n또는 샘플 데이터로 그래프 테스트:")
        print("  python3 generate-sample-data.py")
        sys.exit(1)

    print("\n그래프 생성 중...")
    figure2_throughput()
    figure3_latency_comparison()
    figure4_jitter()
    figure5_jitter_comparison()
    figure6_cdf()
    summary_table()

    print(f"\n모든 그래프가 {OUTPUT_DIR}에 저장되었습니다.")


if __name__ == "__main__":
    main()

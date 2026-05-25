#!/usr/bin/env python3
"""plot-results.py — 실험 결과 시각화 (논문 Figure 2~6 재현)

개선 사항:
  - Latency/Jitter는 동적 범위가 매우 크므로 percentile 기반 bar chart 사용
  - p50/p99/max를 grouped bar로 한눈에 비교
  - 데이터가 없는 CPU 부하는 X축에서 자동 생략
  - 로그 스케일로 long-tail 분포도 가독성 확보

논문의 그래프:
  Figure 2: Throughput under low/high CPU utilization
  Figure 3: Latency percentiles across CPU utilizations
  Figure 4: Jitter under low/high CPU utilization
  Figure 5: Jitter percentiles across CPU utilizations
  Figure 6: CDF under low/high CPU utilization

사용법:
  python3 plot-results.py [결과_디렉토리]
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

CPU_LOADS_ALL = [10, 30, 50, 70, 90, 99]
SOLUTIONS = {"baseline": "Cilium (Baseline)", "proposed": "Cilium + eBPF + prio (Proposed)"}
COLORS = {"baseline": "#4EABD1", "proposed": "#E8734A"}

plt.rcParams.update({
    "font.size": 11,
    "axes.titlesize": 13,
    "axes.labelsize": 12,
    "legend.fontsize": 10,
    "figure.titlesize": 14,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
})


def load_results(mode, cpu_load, normalize_skew=True):
    """CSV 결과 로드.
    normalize_skew=True: master/worker 간 시계 오차 보정.
        latency_ms의 1st percentile을 0으로 맞춤 (min 근방을 baseline으로).
        이렇게 하면 절대 latency가 음수가 되지 않고 상대 변동만 보임.
    """
    path = RESULTS_DIR / f"{mode}_cpu{cpu_load}.csv"
    if not path.exists():
        return None
    data = {"latency_ms": [], "jitter_us": [], "pkt_size": [], "seq": []}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            data["latency_ms"].append(float(row["latency_ms"]))
            data["jitter_us"].append(float(row["jitter_us"]))
            data["pkt_size"].append(int(row["pkt_size"]))
            data["seq"].append(int(row["seq"]))
    if normalize_skew and data["latency_ms"]:
        # 1st percentile을 baseline으로 사용 (최소값은 outlier에 취약)
        skew = float(np.percentile(data["latency_ms"], 1))
        data["latency_ms"] = [v - skew for v in data["latency_ms"]]
        data["_clock_skew_ms"] = skew  # 보정에 사용한 오프셋 기록
    return data


def get_available_cpu_loads():
    """baseline + proposed 둘 다 있는 CPU 부하만 반환"""
    return [c for c in CPU_LOADS_ALL
            if (RESULTS_DIR / f"baseline_cpu{c}.csv").exists()
            and (RESULTS_DIR / f"proposed_cpu{c}.csv").exists()]


def get_partial_cpu_loads():
    """한쪽이라도 데이터 있는 CPU 부하 반환"""
    return [c for c in CPU_LOADS_ALL
            if (RESULTS_DIR / f"baseline_cpu{c}.csv").exists()
            or (RESULTS_DIR / f"proposed_cpu{c}.csv").exists()]


def select_comparison_cpu_loads():
    """비교 그래프(fig 2/4/6)용 CPU 부하 선택.
    - low:     baseline+proposed 둘 다 있는 최저
    - high:    baseline+proposed 둘 다 있는 최고
    - extreme: 한쪽이라도 있는 최고 (high와 다를 때만 추가)
    중복 제거 후 정렬해서 반환.
    """
    both = get_available_cpu_loads()
    partial = get_partial_cpu_loads()
    selected = set()
    if both:
        selected.add(both[0])   # low
        selected.add(both[-1])  # high (both 있는 최고)
    if partial:
        selected.add(partial[-1])  # extreme (한쪽이라도 있는 최고)
    if not selected and partial:
        selected.update([partial[0], partial[-1]])
    return sorted(selected)


def percentile(values, p):
    return float(np.percentile(values, p)) if len(values) else 0.0


def figure2_throughput():
    """Figure 2: Throughput across selected CPU utilizations
    Low / High (둘 다 있는 최고) / Extreme (proposed만이라도) 3개 패널"""
    targets = select_comparison_cpu_loads()
    if not targets:
        return
    fig, axes = plt.subplots(1, len(targets), figsize=(6 * len(targets), 5))
    if len(targets) == 1:
        axes = [axes]
    fig.suptitle("Figure 2: Throughput (KB/s)")

    for ax, cpu in zip(axes, targets):
        modes, bws, colors = [], [], []
        for mode, label in SOLUTIONS.items():
            d = load_results(mode, cpu)
            if not d or not d["pkt_size"]:
                continue
            total_bytes = sum(d["pkt_size"])
            duration_s = max((len(d["pkt_size"]) - 1) * 0.001, 0.001)
            bws.append(total_bytes / duration_s / 1024.0)
            modes.append(label.split(" (")[0])
            colors.append(COLORS[mode])

        if not modes:
            ax.text(0.5, 0.5, "No data", ha="center", va="center", transform=ax.transAxes)
            continue
        bars = ax.bar(modes, bws, color=colors, edgecolor="black", linewidth=0.8)
        for bar, val in zip(bars, bws):
            ax.text(bar.get_x() + bar.get_width() / 2, val, f"{val:.1f}",
                    ha="center", va="bottom", fontsize=10)
        ax.set_title(f"CPU {cpu}% utilization")
        ax.set_ylabel("Bandwidth (KB/s)")
        ax.set_ylim(0, max(bws) * 1.18 if bws else 1)

    plt.tight_layout()
    out = OUTPUT_DIR / "fig2_throughput.png"
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"  저장: {out}")
    plt.close()


def grouped_percentile_bars(metric_key, metric_label, unit, percentiles,
                             fig_title, fig_name, use_log=False):
    """공통: CPU 부하 × 모드 × percentile을 grouped bar로"""
    avail = get_partial_cpu_loads()
    if not avail:
        print(f"  [{fig_name}] 데이터 없음 — 건너뜀")
        return

    n_modes = len(SOLUTIONS)
    n_pct = len(percentiles)
    n_cpu = len(avail)
    bar_width = 0.8 / (n_modes * n_pct)
    x_base = np.arange(n_cpu)

    fig, ax = plt.subplots(figsize=(max(10, n_cpu * 2.2), 6))
    fig.suptitle(fig_title)

    pct_hatches = {"p50": "", "p99": "//", "max": "xx", "p95": "..", "p90": ""}

    for m_idx, (mode, full_label) in enumerate(SOLUTIONS.items()):
        color = COLORS[mode]
        short = "Baseline" if mode == "baseline" else "Proposed"
        for p_idx, p_name in enumerate(percentiles):
            offset = (m_idx * n_pct + p_idx) * bar_width - 0.4 + bar_width / 2
            x = x_base + offset
            heights = []
            for cpu in avail:
                d = load_results(mode, cpu)
                if not d:
                    heights.append(0)
                    continue
                values = d[metric_key]
                if metric_key == "jitter_us":
                    values = [abs(v) for v in values[1:]]
                if p_name == "max":
                    heights.append(max(values) if values else 0)
                else:
                    p_val = int(p_name[1:])
                    heights.append(percentile(values, p_val))

            bars = ax.bar(
                x, heights, width=bar_width,
                color=color, alpha=0.85 - p_idx * 0.18,
                edgecolor="black", linewidth=0.5,
                hatch=pct_hatches.get(p_name, ""),
                label=f"{short} {p_name}",
            )
            for bar, val in zip(bars, heights):
                if val > 0:
                    ax.text(bar.get_x() + bar.get_width() / 2, val,
                            f"{val:.1f}" if val < 100 else f"{val:.0f}",
                            ha="center", va="bottom",
                            fontsize=7,
                            rotation=90 if n_cpu > 4 else 0)

    ax.set_xticks(x_base)
    ax.set_xticklabels([f"{c}%" for c in avail])
    ax.set_xlabel("CPU Utilization")
    ax.set_ylabel(f"{metric_label} ({unit}{'  log' if use_log else ''})")
    if use_log:
        ax.set_yscale("log")
    ax.legend(loc="upper left", ncol=2, framealpha=0.92)
    ax.grid(True, axis="y", alpha=0.3, which="both")

    plt.tight_layout()
    out = OUTPUT_DIR / fig_name
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"  저장: {out}")
    plt.close()


def figure3_latency():
    grouped_percentile_bars(
        metric_key="latency_ms",
        metric_label="Latency",
        unit="ms",
        percentiles=["p50", "p99", "max"],
        fig_title="Figure 3: Latency p50 / p99 / max across CPU loads (lower is better)",
        fig_name="fig3_latency.png",
        use_log=True,
    )


def figure4_jitter_subset():
    """Figure 4: Jitter at low / high(both) / extreme(any) CPU loads — up to 3 panels"""
    targets = select_comparison_cpu_loads()
    if not targets:
        return
    fig, axes = plt.subplots(1, len(targets), figsize=(7 * len(targets), 5))
    if len(targets) == 1:
        axes = [axes]
    fig.suptitle("Figure 4: Jitter p50 vs p99 (μs, log scale)")

    for ax, cpu in zip(axes, targets):
        modes_short, p50s, p99s, colors = [], [], [], []
        for mode, full_label in SOLUTIONS.items():
            d = load_results(mode, cpu)
            if not d:
                continue
            jit = [abs(v) for v in d["jitter_us"][1:]]
            modes_short.append("Baseline" if mode == "baseline" else "Proposed")
            p50s.append(percentile(jit, 50))
            p99s.append(percentile(jit, 99))
            colors.append(COLORS[mode])

        if not modes_short:
            ax.text(0.5, 0.5, "No data", ha="center", va="center", transform=ax.transAxes)
            continue

        x = np.arange(len(modes_short))
        w = 0.35
        b1 = ax.bar(x - w/2, p50s, w, color=colors, alpha=0.85,
                    edgecolor="black", linewidth=0.5, label="p50 (median)")
        b2 = ax.bar(x + w/2, p99s, w, color=colors, alpha=0.55,
                    edgecolor="black", linewidth=0.5, hatch="//", label="p99")
        for bars, vals in [(b1, p50s), (b2, p99s)]:
            for bar, v in zip(bars, vals):
                ax.text(bar.get_x() + bar.get_width() / 2, v, f"{v:.0f}",
                        ha="center", va="bottom", fontsize=9)
        ax.set_xticks(x)
        ax.set_xticklabels(modes_short)
        ax.set_title(f"CPU {cpu}% utilization")
        ax.set_ylabel("Jitter (μs, log)")
        ax.set_yscale("log")
        ax.legend(loc="upper right")

    plt.tight_layout()
    out = OUTPUT_DIR / "fig4_jitter.png"
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"  저장: {out}")
    plt.close()


def figure5_jitter_all():
    grouped_percentile_bars(
        metric_key="jitter_us",
        metric_label="Jitter",
        unit="μs",
        percentiles=["p50", "p99"],
        fig_title="Figure 5: Jitter p50 / p99 across CPU loads",
        fig_name="fig5_jitter_comparison.png",
        use_log=True,
    )


def figure6_cdf():
    """Figure 6: CDF at low / high(both) / extreme(any) CPU loads — up to 3 panels"""
    targets = select_comparison_cpu_loads()
    if not targets:
        return
    fig, axes = plt.subplots(1, len(targets), figsize=(7 * len(targets), 5))
    if len(targets) == 1:
        axes = [axes]
    fig.suptitle("Figure 6: Latency CDF (curve closer to top-left = better)")

    for ax, cpu in zip(axes, targets):
        plotted = False
        for mode, label in SOLUTIONS.items():
            d = load_results(mode, cpu)
            if not d:
                continue
            lat = np.sort(d["latency_ms"])
            cdf = np.arange(1, len(lat) + 1) / len(lat)
            ax.plot(lat, cdf, color=COLORS[mode], linewidth=2.0, label=label)
            plotted = True
        if not plotted:
            ax.text(0.5, 0.5, "No data", ha="center", va="center", transform=ax.transAxes)
            continue
        ax.set_xscale("log")
        ax.set_xlabel("Latency (ms, log)")
        ax.set_ylabel("Cumulative probability")
        ax.set_title(f"CPU {cpu}% utilization")
        ax.set_ylim(0, 1.02)
        ax.legend(loc="lower right")
        ax.grid(True, which="both", alpha=0.3)

    plt.tight_layout()
    out = OUTPUT_DIR / "fig6_cdf.png"
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"  저장: {out}")
    plt.close()


def print_summary():
    print()
    print("=" * 92)
    print(" 결과 요약")
    print("=" * 92)
    print(f"{'CPU':>5} {'Solution':<10} {'p50_lat':>10} {'p99_lat':>10} {'max_lat':>10} {'p50_jit':>10} {'p99_jit':>10}")
    print("-" * 92)
    for cpu in get_partial_cpu_loads():
        for mode, _label in SOLUTIONS.items():
            d = load_results(mode, cpu)
            if not d:
                continue
            lat = d["latency_ms"]
            jit = [abs(v) for v in d["jitter_us"][1:]]
            short = "Baseline" if mode == "baseline" else "Proposed"
            print(f"{cpu:>4}% {short:<10} "
                  f"{percentile(lat,50):>9.2f}ms "
                  f"{percentile(lat,99):>9.2f}ms "
                  f"{max(lat):>9.2f}ms "
                  f"{percentile(jit,50):>9.1f}μs "
                  f"{percentile(jit,99):>9.1f}μs")
    print()
    avail = get_available_cpu_loads()
    if avail:
        print("개선율 (proposed vs baseline):")
        for cpu in avail:
            b = load_results("baseline", cpu)
            p = load_results("proposed", cpu)
            bl_p99 = percentile(b["latency_ms"], 99)
            pr_p99 = percentile(p["latency_ms"], 99)
            bl_max = max(b["latency_ms"])
            pr_max = max(p["latency_ms"])
            def pct(a, b_):
                return f"{(a-b_)/a*100:+.1f}%" if a > 0 else "n/a"
            print(f"  CPU {cpu:>2}%: p99 latency {bl_p99:>7.2f} -> {pr_p99:>7.2f}ms ({pct(bl_p99, pr_p99)}) | "
                  f"max {bl_max:>7.1f} -> {pr_max:>7.1f}ms ({pct(bl_max, pr_max)})")
    else:
        print("(주의: baseline+proposed 둘 다 있는 CPU 부하가 없어 개선율 계산 불가)")


def main():
    print(f"결과 디렉토리: {RESULTS_DIR}")
    print(f"비교 가능 CPU 부하 (baseline+proposed): {get_available_cpu_loads() or '(없음)'}")
    print(f"전체 사용 가능 CPU 부하              : {get_partial_cpu_loads() or '(없음)'}")
    print()
    print("주의: master/worker 간 시계가 동기화되지 않은 경우 절대 latency는")
    print("      clock skew를 포함합니다. 이 스크립트는 1st percentile을 0으로 보정해")
    print("      상대 latency 분포로 표시합니다 (비교 자체는 동일하게 유효).")
    print()
    print("그래프 생성 중...")
    figure2_throughput()
    figure3_latency()
    figure4_jitter_subset()
    figure5_jitter_all()
    figure6_cdf()
    print_summary()
    print()
    print(f"그래프 저장 위치: {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()

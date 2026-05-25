#!/usr/bin/env python3
"""Compare baseline vs proposed latency/jitter statistics.

VM간 시계 오차로 latency가 음수가 되는 경우를 자동 보정:
  1st percentile을 0으로 정규화 (각 모드별로 별도 적용).
이렇게 하면 절대값은 의미가 없어지지만 동일한 보정이 양쪽에 들어가서
상대 비교는 그대로 유효.
"""
import csv
import sys
import statistics
from pathlib import Path

RESULTS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("step8-measurement/results")
CPU_LOADS_ALL = [10, 30, 50, 70, 90, 99]


def load_csv(path, normalize=True):
    """CSV 로드. normalize=True면 latency를 1st percentile로 정규화."""
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return rows
    if normalize:
        lats = sorted(float(r["latency_ms"]) for r in rows)
        n = len(lats)
        skew = lats[max(0, int(n * 0.01))]  # 1st percentile
        for r in rows:
            r["latency_ms"] = str(float(r["latency_ms"]) - skew)
    return rows


def stats(values):
    s = sorted(values)
    n = len(s)
    return {
        "min":  s[0],
        "p50":  s[n // 2],
        "p90":  s[int(n * 0.9)],
        "p99":  s[int(n * 0.99)],
        "max":  s[-1],
        "mean": sum(s) / n,
        "stdev": statistics.stdev(s) if n > 1 else 0.0,
    }


# CPU 부하 자동 감지
available_cpu = sorted(set(
    int(p.stem.split("_cpu")[1])
    for mode in ("baseline", "proposed")
    for p in RESULTS_DIR.glob(f"{mode}_cpu*.csv")
))
if not available_cpu:
    print(f"결과 파일이 없습니다: {RESULTS_DIR}")
    sys.exit(1)

print(f"결과 디렉토리: {RESULTS_DIR}")
print(f"감지된 CPU 부하: {available_cpu}")
print(f"(latency는 1st percentile을 0으로 정규화 — VM간 시계 오차 보정)")
print()
print(f"{'mode':<10} {'cpu%':<6} {'metric':<10} {'p50':>10} {'p90':>10} {'p99':>10} {'max':>10} {'mean':>10} {'stdev':>10}")
print("-" * 102)

for cpu in available_cpu:
    for mode in ["baseline", "proposed"]:
        path = RESULTS_DIR / f"{mode}_cpu{cpu}.csv"
        if not path.exists():
            print(f"{mode:<10} {cpu}%     (missing)")
            continue
        rows = load_csv(path, normalize=True)
        lat = [float(r["latency_ms"]) for r in rows]
        jit = [abs(float(r["jitter_us"])) for r in rows[1:]]
        ls, js = stats(lat), stats(jit)
        print(f"{mode:<10} {cpu}%     {'lat_ms':<10} "
              f"{ls['p50']:>10.3f} {ls['p90']:>10.3f} {ls['p99']:>10.3f} {ls['max']:>10.3f} {ls['mean']:>10.3f} {ls['stdev']:>10.3f}")
        print(f"{mode:<10} {cpu}%     {'jit_us':<10} "
              f"{js['p50']:>10.1f} {js['p90']:>10.1f} {js['p99']:>10.1f} {js['max']:>10.1f} {js['mean']:>10.1f} {js['stdev']:>10.1f}")
    print()

# Improvement summary (baseline vs proposed 둘 다 있는 경우만)
print("=" * 102)
print("개선율 (proposed vs baseline, 음수 % = 개선)")
print("=" * 102)
for cpu in available_cpu:
    bp = RESULTS_DIR / f"baseline_cpu{cpu}.csv"
    pp = RESULTS_DIR / f"proposed_cpu{cpu}.csv"
    if not (bp.exists() and pp.exists()):
        print(f"  CPU {cpu}%: (baseline/proposed 중 하나 누락 — 비교 불가)")
        continue
    br = load_csv(bp, normalize=True)
    pr = load_csv(pp, normalize=True)
    blat = sorted(float(r["latency_ms"]) for r in br)
    plat = sorted(float(r["latency_ms"]) for r in pr)
    bjit = sorted(abs(float(r["jitter_us"])) for r in br[1:])
    pjit = sorted(abs(float(r["jitter_us"])) for r in pr[1:])
    nb, np_ = len(blat), len(plat)

    def imp(before, after):
        if before <= 0:
            return "n/a"
        d = (after - before) / before * 100
        return f"{d:+.1f}%"

    print(f"  CPU {cpu:>2}%: "
          f"lat p99 {blat[int(nb*0.99)]:>7.2f} → {plat[int(np_*0.99)]:>7.2f}ms ({imp(blat[int(nb*0.99)], plat[int(np_*0.99)])})  | "
          f"lat max {blat[-1]:>7.1f} → {plat[-1]:>7.1f}ms ({imp(blat[-1], plat[-1])})  | "
          f"jit p99 {bjit[int(len(bjit)*0.99)]:>7.0f} → {pjit[int(len(pjit)*0.99)]:>7.0f}μs ({imp(bjit[int(len(bjit)*0.99)], pjit[int(len(pjit)*0.99)])})")

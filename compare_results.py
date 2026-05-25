#!/usr/bin/env python3
"""Compare baseline vs proposed latency/jitter statistics."""
import csv
import sys
import statistics
from pathlib import Path

RESULTS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("step8-measurement/results")

def load(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    return rows

def stats(values):
    s = sorted(values)
    n = len(s)
    return {
        "n": n,
        "min": s[0],
        "p50": s[n // 2],
        "p90": s[int(n * 0.9)],
        "p99": s[int(n * 0.99)],
        "max": s[-1],
        "mean": sum(s) / n,
        "stdev": statistics.stdev(s) if n > 1 else 0.0,
    }

cpu_loads = [10]  # add more as we generate them
print(f"{'mode':<10} {'cpu%':<6} {'metric':<10} {'min':>10} {'p50':>10} {'p90':>10} {'p99':>10} {'max':>10} {'mean':>10} {'stdev':>10}")
print("-" * 110)

for cpu in cpu_loads:
    for mode in ["baseline", "proposed"]:
        path = RESULTS_DIR / f"{mode}_cpu{cpu}.csv"
        if not path.exists():
            print(f"{mode:<10} {cpu:<6} (file missing: {path})")
            continue
        rows = load(path)
        lat = [float(r["latency_ms"]) for r in rows]
        jit = [abs(float(r["jitter_us"])) for r in rows[1:]]
        ls = stats(lat)
        js = stats(jit)
        print(f"{mode:<10} {cpu:<6} {'lat_ms':<10} {ls['min']:>10.3f} {ls['p50']:>10.3f} {ls['p90']:>10.3f} {ls['p99']:>10.3f} {ls['max']:>10.3f} {ls['mean']:>10.3f} {ls['stdev']:>10.3f}")
        print(f"{mode:<10} {cpu:<6} {'jit_us':<10} {js['min']:>10.1f} {js['p50']:>10.1f} {js['p90']:>10.1f} {js['p99']:>10.1f} {js['max']:>10.1f} {js['mean']:>10.1f} {js['stdev']:>10.1f}")

# Improvement summary
print()
print("=== Improvement (proposed vs baseline) ===")
for cpu in cpu_loads:
    bp = RESULTS_DIR / f"baseline_cpu{cpu}.csv"
    pp = RESULTS_DIR / f"proposed_cpu{cpu}.csv"
    if not (bp.exists() and pp.exists()):
        continue
    br = load(bp)
    pr = load(pp)
    blat = sorted(float(r["latency_ms"]) for r in br)
    plat = sorted(float(r["latency_ms"]) for r in pr)
    bjit = sorted(abs(float(r["jitter_us"])) for r in br[1:])
    pjit = sorted(abs(float(r["jitter_us"])) for r in pr[1:])
    n_b = len(blat)
    n_p = len(plat)
    def pct(a, b):
        if a == 0: return "n/a"
        return f"{(a-b)/a*100:+.1f}%"
    print(f"CPU {cpu}%: latency p99 {blat[int(n_b*0.99)]:.3f} -> {plat[int(n_p*0.99)]:.3f} ({pct(blat[int(n_b*0.99)], plat[int(n_p*0.99)])})")
    print(f"CPU {cpu}%: jitter  p99 {bjit[int(len(bjit)*0.99)]:.1f} -> {pjit[int(len(pjit)*0.99)]:.1f} ({pct(bjit[int(len(bjit)*0.99)], pjit[int(len(pjit)*0.99)])})")

"""Shared fixtures: synthetic CSV writers that mimic both testbed naming schemes."""

from __future__ import annotations

import csv
from pathlib import Path

import numpy as np
import pytest

INTERVAL_NS = 1_000_000  # 1 ms send interval, as in the real testbed


def write_run_csv(
    path: Path,
    latency_ms: np.ndarray,
    seq: np.ndarray | None = None,
    pkt_size: int = 128,
    tos: np.ndarray | None = None,
    t0_ns: int = 1_700_000_000_000_000_000,
) -> Path:
    """Write a CSV with the testbed columns derived from a latency vector."""
    n = latency_ms.size
    if seq is None:
        seq = np.arange(n)
    send_ns = t0_ns + np.asarray(seq) * INTERVAL_NS
    recv_ns = send_ns + (latency_ms * 1e6).astype(np.int64)
    gaps = np.diff(recv_ns)
    jitter_us = np.concatenate([[0.0], (gaps - INTERVAL_NS) / 1e3])
    header = ["seq", "send_ns", "recv_ns", "latency_ms", "jitter_us", "pkt_size"]
    if tos is not None:
        header.append("tos")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for i in range(n):
            row = [
                int(seq[i]),
                int(send_ns[i]),
                int(recv_ns[i]),
                f"{latency_ms[i]:.6f}",
                f"{jitter_us[i]:.3f}",
                pkt_size,
            ]
            if tos is not None:
                row.append(int(tos[i]))
            w.writerow(row)
    return path


def lognormal_latency(rng: np.random.Generator, n: int, scale: float) -> np.ndarray:
    """Heavy-tailed positive latencies (ms) resembling the real distributions."""
    return scale * rng.lognormal(mean=0.0, sigma=0.6, size=n) + 0.5


@pytest.fixture
def legacy_dir(tmp_path: Path) -> Path:
    """``<mode>_cpu<N>.csv`` files with baseline slower than proposed; cpu99 proposed-only."""
    rng = np.random.default_rng(1)
    d = tmp_path / "legacy"
    for cpu in (10, 50):
        write_run_csv(d / f"baseline_cpu{cpu}.csv", lognormal_latency(rng, 600, 2.0))
        write_run_csv(d / f"proposed_cpu{cpu}.csv", lognormal_latency(rng, 600, 1.0))
    write_run_csv(d / "proposed_cpu99.csv", lognormal_latency(rng, 600, 1.5))
    return d


@pytest.fixture
def newstyle_dir(tmp_path: Path) -> Path:
    """``<cond>_run<k>.csv`` files with 3 runs each and a tos column."""
    rng = np.random.default_rng(2)
    d = tmp_path / "newstyle"
    for k in range(1, 4):
        n = 500
        write_run_csv(
            d / f"pfifo_run{k}.csv",
            lognormal_latency(rng, n, 2.0),
            tos=np.full(n, 0),
        )
        write_run_csv(
            d / f"prio_class_run{k}.csv",
            lognormal_latency(rng, n, 1.0),
            tos=np.full(n, 46 << 2),  # EF
        )
        write_run_csv(
            d / f"pfifo_fast_noclass_run{k}.csv",
            lognormal_latency(rng, n, 1.5),
            tos=np.full(n, 0),
        )
    return d

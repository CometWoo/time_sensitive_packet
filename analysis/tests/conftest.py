"""Synthetic listener CSVs."""

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
    """Heavy-tailed positive latencies in ms."""
    return scale * rng.lognormal(mean=0.0, sigma=0.6, size=n) + 0.5


@pytest.fixture
def run_dir(tmp_path: Path) -> Path:
    """Three runs each: fifo (slow), pfifo_fast_noclsf, prio_clsf (fast, DSCP EF)."""
    rng = np.random.default_rng(2)
    d = tmp_path / "runs"
    n = 500
    for k in range(1, 4):
        write_run_csv(d / f"fifo_run{k}.csv", lognormal_latency(rng, n, 2.0), tos=np.zeros(n))
        write_run_csv(
            d / f"prio_clsf_run{k}.csv", lognormal_latency(rng, n, 1.0), tos=np.full(n, 46 << 2)
        )
        write_run_csv(
            d / f"pfifo_fast_noclsf_run{k}.csv", lognormal_latency(rng, n, 1.5), tos=np.zeros(n)
        )
    return d

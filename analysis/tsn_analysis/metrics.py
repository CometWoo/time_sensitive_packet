"""Per-run descriptive metrics: percentiles, loss, throughput, inter-arrival, DSCP.

Percentile method
-----------------
Every percentile in this package goes through :func:`percentile`, which calls
``numpy.percentile(..., method="linear")``.  The legacy scripts mixed two
definitions: ``sorted(x)[int(n * 0.99)]`` (a nearest-rank variant that is
biased upward by up to one sample and jumps discretely) and numpy's default.
``linear`` is Hyndman & Fan type 7 - the same definition R, Excel, pandas and
numpy use by default - it interpolates between neighbouring order statistics,
so it is continuous in the data and unbiased for the median.  With n = 10000
the two definitions differ by at most one sample, which matters only in the
extreme tail (p99.9, max).  The ``method`` parameter is exposed so a reader can
check sensitivity (e.g. ``method="nearest"`` or ``"inverted_cdf"``).
"""

from __future__ import annotations

from typing import Any

import numpy as np

from tsn_analysis.loader import Run

LATENCY_PERCENTILES: tuple[float, ...] = (50.0, 90.0, 99.0, 99.9)


def _pct_label(q: float) -> str:
    """``99.0 -> "p99"``, ``99.9 -> "p99.9"``."""
    return f"p{q:g}"


def percentile(
    values: np.ndarray, q: float | list[float] | tuple[float, ...], method: str = "linear"
) -> float | np.ndarray:
    """Percentile(s) of ``values`` (``q`` in 0..100) using ``numpy.percentile``.

    Returns a float for a scalar ``q`` and an array otherwise.  Empty input
    yields ``nan``.
    """
    arr = np.asarray(values, dtype=np.float64)
    if arr.size == 0:
        if np.isscalar(q):
            return float("nan")
        return np.full(len(q), np.nan)
    out = np.percentile(arr, q, method=method)
    return float(out) if np.isscalar(q) else np.asarray(out, dtype=np.float64)


def distribution_summary(
    values: np.ndarray,
    percentiles: tuple[float, ...] = LATENCY_PERCENTILES,
    method: str = "linear",
) -> dict[str, float]:
    """Summary of a 1-D sample: n, min, requested percentiles, max, mean, std.

    ``std`` is the sample standard deviation (ddof=1); for n < 2 it is ``nan``.
    """
    arr = np.asarray(values, dtype=np.float64)
    out: dict[str, float] = {"n": float(arr.size)}
    if arr.size == 0:
        for key in ("min", *[_pct_label(q) for q in percentiles], "max", "mean", "std"):
            out[key] = float("nan")
        return out
    pcts = percentile(arr, list(percentiles), method=method)
    out["min"] = float(arr.min())
    for q, v in zip(percentiles, pcts, strict=True):
        out[_pct_label(q)] = float(v)
    out["max"] = float(arr.max())
    out["mean"] = float(arr.mean())
    out["std"] = float(arr.std(ddof=1)) if arr.size > 1 else float("nan")
    return out


def latency_summary(latency_ms: np.ndarray, method: str = "linear") -> dict[str, float]:
    """p50 / p90 / p99 / p99.9 / max / mean / std of one-way latency in ms."""
    return distribution_summary(latency_ms, LATENCY_PERCENTILES, method)


def jitter_values(jitter_us: np.ndarray) -> np.ndarray:
    """Jitter sample used for statistics: ``abs(jitter_us[1:])``.

    The first row of every run carries ``jitter = 0`` by construction (no
    previous packet), so it is dropped; the sign only encodes whether the
    inter-arrival gap grew or shrank, and TSN cares about the magnitude.
    """
    arr = np.asarray(jitter_us, dtype=np.float64)
    return np.abs(arr[1:])


def jitter_summary(jitter_us: np.ndarray, method: str = "linear") -> dict[str, float]:
    """Percentile summary of ``abs(jitter_us[1:])`` in microseconds."""
    return distribution_summary(jitter_values(jitter_us), LATENCY_PERCENTILES, method)


def loss_summary(seq: np.ndarray) -> dict[str, float]:
    """Packet loss, duplicates and reorders derived from the sequence numbers.

    * ``expected``   = ``max(seq) - min(seq) + 1`` (the sender's counter range);
    * ``received``   = number of rows;
    * ``unique``     = number of distinct sequence numbers;
    * ``duplicates`` = ``received - unique``;
    * ``lost``       = ``expected - unique`` (a duplicate does not recover a loss);
    * ``reorders``   = rows whose ``seq`` is smaller than the running maximum of
      the sequence numbers received before them (late arrivals).
    """
    arr = np.asarray(seq, dtype=np.int64)
    if arr.size == 0:
        return {
            "expected": 0.0,
            "received": 0.0,
            "unique": 0.0,
            "lost": 0.0,
            "loss_pct": float("nan"),
            "duplicates": 0.0,
            "reorders": 0.0,
        }
    expected = int(arr.max() - arr.min() + 1)
    unique = int(np.unique(arr).size)
    received = int(arr.size)
    lost = expected - unique
    running_max = np.maximum.accumulate(arr)
    reorders = int(np.count_nonzero(arr[1:] < running_max[:-1]))
    return {
        "expected": float(expected),
        "received": float(received),
        "unique": float(unique),
        "lost": float(lost),
        "loss_pct": 100.0 * lost / expected if expected else float("nan"),
        "duplicates": float(received - unique),
        "reorders": float(reorders),
    }


def throughput_kbps(pkt_size: np.ndarray, recv_ns: np.ndarray) -> float:
    """Received throughput in kilobit/s: ``8 * total_bytes / recv_span_s``.

    The span is measured between the first and last *received* timestamp of
    the run, so a run that stalls (or loses its final packets) is reported
    honestly.  The legacy script assumed ``(n - 1) * send_interval`` which
    silently ignored loss and any pause in delivery.  Returns ``nan`` when the
    span is zero (fewer than two packets or identical timestamps).
    """
    sizes = np.asarray(pkt_size, dtype=np.float64)
    ts = np.asarray(recv_ns, dtype=np.int64)
    if sizes.size < 2 or ts.size < 2:
        return float("nan")
    span_s = float(ts.max() - ts.min()) / 1e9
    if span_s <= 0:
        return float("nan")
    return 8.0 * float(sizes.sum()) / span_s / 1000.0


def inter_arrival_summary(recv_ns: np.ndarray, method: str = "linear") -> dict[str, float]:
    """Summary of consecutive receive gaps ``diff(recv_ns)`` in microseconds."""
    ts = np.asarray(recv_ns, dtype=np.int64)
    gaps_us = np.diff(ts).astype(np.float64) / 1e3
    return distribution_summary(gaps_us, (50.0, 90.0, 99.0, 99.9), method)


def dscp_distribution(tos: np.ndarray | None) -> dict[str, Any] | None:
    """Histogram of received DSCP values (``dscp = tos >> 2``) and ECN bits.

    Returns ``None`` when the run has no ``tos`` column.  Cells with a missing
    value (-1) are counted separately under ``"missing"`` so the distribution
    still sums to the row count.
    """
    if tos is None:
        return None
    arr = np.asarray(tos, dtype=np.int64)
    valid = arr[arr >= 0]
    dscp_vals, dscp_counts = np.unique(valid >> 2, return_counts=True)
    ecn_vals, ecn_counts = np.unique(valid & 0x3, return_counts=True)
    tos_vals, tos_counts = np.unique(valid, return_counts=True)
    return {
        "dscp": {int(k): int(v) for k, v in zip(dscp_vals, dscp_counts, strict=True)},
        "ecn": {int(k): int(v) for k, v in zip(ecn_vals, ecn_counts, strict=True)},
        "tos": {int(k): int(v) for k, v in zip(tos_vals, tos_counts, strict=True)},
        "missing": int(arr.size - valid.size),
        "dominant_dscp": int(dscp_vals[np.argmax(dscp_counts)]) if valid.size else None,
    }


def run_metrics(run: Run, method: str = "linear") -> dict[str, Any]:
    """All per-run metrics in one dict (latency, jitter, loss, throughput, ...)."""
    return {
        "name": run.name,
        "condition": run.condition,
        "run_index": run.run_index,
        "factors": dict(run.factors),
        "n": len(run),
        "clock_skew_ms": run.clock_skew_ms,
        "latency_ms": latency_summary(run.latency_ms, method),
        "jitter_us": jitter_summary(run.jitter_us, method),
        "loss": loss_summary(run.seq),
        "throughput_kbps": throughput_kbps(run.pkt_size, run.recv_ns),
        "inter_arrival_us": inter_arrival_summary(run.recv_ns, method),
        "dscp": dscp_distribution(run.tos),
    }

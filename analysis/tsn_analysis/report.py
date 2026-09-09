"""Summary dictionary, Markdown rendering and JSON output for a results directory."""

from __future__ import annotations

import json
import math
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import numpy as np

from tsn_analysis.dataset import Cell, build_dataset
from tsn_analysis.metrics import (
    LATENCY_PERCENTILES,
    distribution_summary,
    dscp_distribution,
    latency_summary,
    loss_summary,
    throughput_kbps,
)
from tsn_analysis.stats import compare, per_run_aggregate

DEFAULT_BASELINE_CANDIDATES: tuple[str, ...] = ("baseline", "pfifo")

# (label, sample attribute on Cell, statistic) used for every comparison row.
COMPARISON_METRICS: tuple[tuple[str, str, str], ...] = (
    ("latency_p50_ms", "latency_ms", "p50"),
    ("latency_p99_ms", "latency_ms", "p99"),
    ("jitter_p99_us", "jitter_us", "p99"),
)


def choose_baseline(conditions: Sequence[str], requested: str | None = None) -> str:
    """Pick the reference condition.

    An explicit ``requested`` name must exist.  Otherwise the first of
    ``baseline``, ``pfifo`` that is present is used, falling back to the
    alphabetically first condition.
    """
    if requested is not None:
        if requested not in conditions:
            raise ValueError(f"baseline {requested!r} not among conditions {list(conditions)}")
        return requested
    for cand in DEFAULT_BASELINE_CANDIDATES:
        if cand in conditions:
            return cand
    if not conditions:
        raise ValueError("no conditions found")
    return sorted(conditions)[0]


def _aggregate_loss(cell: Cell) -> dict[str, float]:
    per_run = [loss_summary(r.seq) for r in cell.runs]
    keys = ("expected", "received", "unique", "lost", "duplicates", "reorders")
    total = {k: float(sum(d[k] for d in per_run)) for k in keys}
    total["loss_pct"] = (
        100.0 * total["lost"] / total["expected"] if total["expected"] else float("nan")
    )
    return total


def _aggregate_dscp(cell: Cell) -> dict[str, Any] | None:
    per_run = [dscp_distribution(r.tos) for r in cell.runs]
    per_run = [d for d in per_run if d is not None]
    if not per_run:
        return None
    merged: dict[str, Any] = {"dscp": {}, "ecn": {}, "tos": {}, "missing": 0}
    for d in per_run:
        for field in ("dscp", "ecn", "tos"):
            for k, v in d[field].items():
                merged[field][k] = merged[field].get(k, 0) + v
        merged["missing"] += d["missing"]
    merged["dominant_dscp"] = (
        max(merged["dscp"], key=merged["dscp"].get) if merged["dscp"] else None
    )
    return merged


def cell_summary(cell: Cell, method: str = "linear", ci: float = 0.95) -> dict[str, Any]:
    """Descriptive metrics of one cell (pooled over its runs)."""
    tps = [throughput_kbps(r.pkt_size, r.recv_ns) for r in cell.runs]
    gaps_us = (
        np.concatenate([np.diff(r.recv_ns) for r in cell.runs]).astype(np.float64) / 1e3
        if cell.runs
        else np.array([])
    )
    out: dict[str, Any] = {
        "condition": cell.condition,
        "factor": cell.factor_key,
        "factors": dict(cell.factors),
        "runs": [r.name for r in cell.runs],
        "n_runs": cell.n_runs,
        "n_packets": int(cell.latency_ms.size),
        "clock_skew_ms": [r.clock_skew_ms for r in cell.runs],
        "latency_ms": latency_summary(cell.latency_ms, method),
        "jitter_us": distribution_summary(cell.jitter_us, LATENCY_PERCENTILES, method),
        "loss": _aggregate_loss(cell),
        "throughput_kbps": {
            "mean": float(np.nanmean(tps)) if tps else float("nan"),
            "per_run": [float(t) for t in tps],
        },
        "inter_arrival_us": distribution_summary(gaps_us, LATENCY_PERCENTILES, method),
        "dscp": _aggregate_dscp(cell),
    }
    if cell.n_runs > 1:
        out["per_run"] = {
            "latency_p99_ms": per_run_aggregate(
                [r.latency_ms for r in cell.runs], "p99", ci, method
            ),
            "jitter_p99_us": per_run_aggregate(
                [np.abs(r.jitter_us[1:]) for r in cell.runs], "p99", ci, method
            ),
        }
    return out


def compare_cells(
    base_cell: Cell,
    other: Cell,
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    method: str = "linear",
) -> dict[str, dict[str, Any]]:
    """Run :func:`tsn_analysis.stats.compare` for every entry of ``COMPARISON_METRICS``.

    Latency samples of skew-normalised cells are handed over as raw per-run
    arrays plus the skew percentile so the bootstrap re-estimates the offset
    in every resample (see :mod:`tsn_analysis.stats`); jitter never needs it.
    """
    out: dict[str, dict[str, Any]] = {}
    for label, attr, stat in COMPARISON_METRICS:
        if attr == "latency_ms":
            (va, sp), (vb, _) = base_cell.latency_samples(), other.latency_samples()
        else:
            va, vb, sp = getattr(base_cell, attr), getattr(other, attr), None
        out[label] = compare(va, vb, stat, n_boot, ci, seed, method=method, skew_percentile=sp)
    return out


def build_summary(
    results_dir: str | Path,
    baseline: str | None = None,
    normalize_skew: bool = False,
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    method: str = "linear",
) -> dict[str, Any]:
    """Compute every table the CLI/README needs for ``results_dir``.

    ``comparisons`` holds, for each non-baseline condition and each factor
    where both it and the baseline have data, :func:`tsn_analysis.stats.compare`
    results for latency p50/p99 and jitter p99.  ``method`` (a
    ``numpy.percentile`` method) is used for every percentile in the output,
    descriptive tables and comparison point estimates alike.
    """
    ds = build_dataset(results_dir, normalize_skew=normalize_skew)
    base = choose_baseline(ds.conditions, baseline)
    cells = [
        cell_summary(ds.cells[(c, f)], method, ci)
        for f in ds.factor_keys
        for c in ds.conditions
        if (c, f) in ds.cells
    ]
    comparisons: list[dict[str, Any]] = []
    for f in ds.factor_keys:
        base_cell = ds.get(base, f)
        if base_cell is None:
            continue
        for c in ds.conditions:
            if c == base:
                continue
            other = ds.get(c, f)
            if other is None:
                continue
            comparisons.append(
                {
                    "condition": c,
                    "factor": f,
                    "baseline": base,
                    "metrics": compare_cells(base_cell, other, n_boot, ci, seed, method),
                }
            )
    return {
        "results_dir": str(Path(results_dir)),
        "normalize_skew": normalize_skew,
        "percentile_method": method,
        "baseline": base,
        "conditions": ds.conditions,
        "factors": [
            {"key": k, "label": ds.factor_label(k), "factors": ds.factor_values[k]}
            for k in ds.factor_keys
        ],
        "bootstrap": {"n_boot": n_boot, "ci": ci, "seed": seed},
        "cells": cells,
        "comparisons": comparisons,
    }


# ----------------------------------------------------------------------------
# Markdown rendering
# ----------------------------------------------------------------------------


def _fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "-"
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return "nan"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def _fmt_signed(value: float) -> str:
    if math.isnan(value):
        return "nan"
    return f"{value:+.2f}"


def _fmt_p(p: float) -> str:
    if math.isnan(p):
        return "nan"
    if p < 1e-300:
        return "<1e-300"
    return f"{p:.2e}" if p < 0.01 else f"{p:.2f}"


def _table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> list[str]:
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines.extend("| " + " | ".join(r) + " |" for r in rows)
    return lines


def _factor_label(summary: dict[str, Any], key: str) -> str:
    for f in summary["factors"]:
        if f["key"] == key:
            return f["label"]
    return key


def render_markdown(summary: dict[str, Any]) -> str:
    """Render :func:`build_summary` output as ASCII Markdown tables."""
    lines: list[str] = ["# TSN measurement summary", ""]
    lines.append(f"- results dir: `{summary['results_dir']}`")
    lines.append(f"- baseline condition: `{summary['baseline']}`")
    lines.append(f"- conditions: {', '.join(summary['conditions'])}")
    lines.append(f"- percentile method: numpy `{summary['percentile_method']}`")
    if summary["normalize_skew"]:
        lines.append(
            "- latency normalised: per-run 1st percentile subtracted "
            "(two-clock skew correction; absolute values are NOT end-to-end latency). "
            "Each run is shifted by its own p1, so cross-condition comparisons are of the "
            "distribution above each run's floor; a constant location difference between "
            "conditions cannot be recovered. Latency CIs re-estimate the p1 offset inside "
            "every bootstrap resample."
        )
    else:
        lines.append("- latency as recorded (no clock-skew normalisation)")
    bs = summary["bootstrap"]
    lines.append(
        f"- CIs: {bs['ci'] * 100:.0f}% percentile bootstrap, "
        f"n_boot={bs['n_boot']}, seed={bs['seed']}"
    )
    lines.append("")

    pct_cols = ("p50", "p90", "p99", "p99.9", "max", "mean", "std")
    lines += ["## Latency (ms)", ""]
    rows = []
    for c in summary["cells"]:
        s = c["latency_ms"]
        rows.append(
            [c["condition"], _factor_label(summary, c["factor"]), str(c["n_runs"]),
             str(c["n_packets"])] + [_fmt(s[k]) for k in pct_cols]
        )
    lines += _table(["condition", "factor", "runs", "n", *pct_cols], rows)
    lines.append("")

    lines += ["## Jitter |dt| (us)", ""]
    rows = []
    for c in summary["cells"]:
        s = c["jitter_us"]
        rows.append(
            [c["condition"], _factor_label(summary, c["factor"])] + [_fmt(s[k]) for k in pct_cols]
        )
    lines += _table(["condition", "factor", *pct_cols], rows)
    lines.append("")

    lines += ["## Loss, throughput, DSCP", ""]
    lines.append(
        "throughput kbps = 8 * received bytes / (last recv - first recv) in kbit/s, i.e. the "
        "rate actually delivered over the run's receive span (NOT (n-1) * send interval). "
        "gap p50 is the median receive gap; compare it with the intended send interval to see "
        "whether the talker kept its pacing - a larger gap means lower throughput, not loss."
    )
    lines.append("")
    rows = []
    for c in summary["cells"]:
        loss = c["loss"]
        dscp = c["dscp"]
        dscp_txt = "-" if dscp is None else _fmt(dscp["dominant_dscp"])
        rows.append(
            [
                c["condition"],
                _factor_label(summary, c["factor"]),
                _fmt(loss["expected"], 0),
                _fmt(loss["received"], 0),
                _fmt(loss["lost"], 0),
                _fmt(loss["loss_pct"]),
                _fmt(loss["duplicates"], 0),
                _fmt(loss["reorders"], 0),
                _fmt(c["throughput_kbps"]["mean"]),
                _fmt(c["inter_arrival_us"]["p50"]),
                _fmt(c["inter_arrival_us"]["p99"]),
                dscp_txt,
            ]
        )
    lines += _table(
        ["condition", "factor", "expected", "received", "lost", "loss %", "dup", "reorder",
         "throughput kbps", "gap p50 us", "gap p99 us", "DSCP"],
        rows,
    )
    lines.append("")

    per_run_rows = []
    for c in summary["cells"]:
        if "per_run" not in c:
            continue
        for label, agg in c["per_run"].items():
            per_run_rows.append(
                [c["condition"], _factor_label(summary, c["factor"]), label, str(agg["n_runs"]),
                 _fmt(agg["mean"]), _fmt(agg["std"]),
                 f"[{_fmt(agg['ci_low'])}, {_fmt(agg['ci_high'])}]"]
            )
    if per_run_rows:
        lines += ["## Per-run aggregate (mean of per-run statistic, t-interval when >= 3 runs)", ""]
        lines += _table(["condition", "factor", "metric", "runs", "mean", "std", "CI"],
                        per_run_rows)
        lines.append("")

    lines += [f"## Comparisons vs `{summary['baseline']}`", ""]
    lines.append(
        "improvement % = (baseline - condition) / baseline * 100; positive = lower = better. "
        "p from two-sided Mann-Whitney U; delta = Cliff's delta (positive = baseline slower). "
        "p and delta compare whole distributions, so they repeat across latency statistics."
    )
    if summary["normalize_skew"]:
        lines.append(
            "Latency rows compare per-run p1-shifted distributions (tail above each run's "
            "own floor); location differences between conditions are not observable here. "
            "Latency CIs include the sampling variance of the p1 offset (joint bootstrap)."
        )
    lines.append("")
    rows = []
    for cmp in summary["comparisons"]:
        for label, m in cmp["metrics"].items():
            b, p = m["baseline"], m["proposed"]
            rows.append(
                [
                    cmp["condition"],
                    _factor_label(summary, cmp["factor"]),
                    label,
                    f"{_fmt(b['point'])} [{_fmt(b['low'])}, {_fmt(b['high'])}]",
                    f"{_fmt(p['point'])} [{_fmt(p['low'])}, {_fmt(p['high'])}]",
                    _fmt_signed(m["improvement_pct"]) + "%",
                    _fmt_p(m["p_value"]),
                    f"{_fmt_signed(m['cliffs_delta'])} ({m['effect']})",
                ]
            )
    if rows:
        lines += _table(
            ["condition", "factor", "metric", "baseline [CI]", "condition [CI]",
             "improvement", "p-value", "delta"],
            rows,
        )
    else:
        lines.append("(no factor has both the baseline and another condition)")
    lines.append("")
    return "\n".join(lines)


def _json_default(obj: Any) -> Any:
    if isinstance(obj, np.integer):
        return int(obj)
    if isinstance(obj, np.floating):
        return float(obj)
    if isinstance(obj, np.ndarray):
        return obj.tolist()
    if isinstance(obj, Path):
        return str(obj)
    raise TypeError(f"not JSON serialisable: {type(obj).__name__}")


def sanitize_json(obj: Any) -> Any:
    """Recursively replace ``nan``/``inf`` floats with ``None`` and numpy scalars/arrays
    with plain Python values, so the output is strict RFC 8259 JSON.

    Python's ``json`` would otherwise emit bare ``NaN`` tokens (e.g. the
    per-run t-interval with fewer than three runs), which ``jq``, browsers and
    most other parsers reject.
    """
    if isinstance(obj, dict):
        return {str(k): sanitize_json(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [sanitize_json(v) for v in obj]
    if isinstance(obj, np.ndarray):
        return sanitize_json(obj.tolist())
    if isinstance(obj, (bool, np.bool_)):
        return bool(obj)
    if isinstance(obj, (int, np.integer)):
        return int(obj)
    if isinstance(obj, (float, np.floating)):
        f = float(obj)
        return None if (math.isnan(f) or math.isinf(f)) else f
    if isinstance(obj, Path):
        return str(obj)
    return obj


def to_json(summary: dict[str, Any], indent: int = 2) -> str:
    """Serialise a summary as strict JSON (``nan``/``inf`` become ``null``)."""
    return json.dumps(
        sanitize_json(summary), indent=indent, default=_json_default, sort_keys=False,
        allow_nan=False,
    )


def write_json(summary: dict[str, Any], path: str | Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(to_json(summary), encoding="utf-8")
    return path

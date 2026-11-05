"""Summary dict, Markdown tables and JSON for a results directory."""

from __future__ import annotations

import json
import math
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import numpy as np

from tsn_analysis.dataset import Cell, build_dataset
from tsn_analysis.metrics import (
    distribution_summary,
    dscp_distribution,
    jitter_values,
    latency_summary,
    loss_summary,
)
from tsn_analysis.stats import compare, per_run_aggregate

# (label, Cell attribute, statistic) for every comparison row
COMPARISON_METRICS: tuple[tuple[str, str, str], ...] = (
    ("latency_p50_ms", "latency_ms", "p50"),
    ("latency_p99_ms", "latency_ms", "p99"),
    ("jitter_p99_us", "jitter_us", "p99"),
)


def choose_baseline(conditions: Sequence[str], requested: str | None = None) -> str:
    """``requested`` if given (it must exist), otherwise the first condition."""
    if requested is not None:
        if requested not in conditions:
            raise ValueError(f"baseline {requested!r} not among conditions {list(conditions)}")
        return requested
    if not conditions:
        raise ValueError("no conditions found")
    return conditions[0]


def _aggregate_loss(cell: Cell) -> dict[str, float]:
    per_run = [loss_summary(r.seq) for r in cell.runs]
    keys = ("expected", "received", "unique", "lost", "duplicates", "reorders")
    total = {k: float(sum(d[k] for d in per_run)) for k in keys}
    total["loss_pct"] = (
        100.0 * total["lost"] / total["expected"] if total["expected"] else float("nan")
    )
    return total


def _aggregate_dscp(cell: Cell) -> dict[str, Any] | None:
    per_run = [d for d in (dscp_distribution(r.tos) for r in cell.runs) if d is not None]
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
    """Descriptive metrics of one condition, pooled over its runs."""
    out: dict[str, Any] = {
        "condition": cell.condition,
        "runs": [r.name for r in cell.runs],
        "n_runs": cell.n_runs,
        "n_packets": int(cell.latency_ms.size),
        "latency_ms": latency_summary(cell.latency_ms, method),
        "jitter_us": distribution_summary(cell.jitter_us, method=method),
        "loss": _aggregate_loss(cell),
        "dscp": _aggregate_dscp(cell),
    }
    if cell.n_runs > 1:
        out["per_run"] = {
            "latency_p99_ms": per_run_aggregate(
                [r.latency_ms for r in cell.runs], "p99", ci, method
            ),
            "jitter_p99_us": per_run_aggregate(
                [jitter_values(r.jitter_us) for r in cell.runs], "p99", ci, method
            ),
        }
    return out


def compare_cells(
    base: Cell,
    other: Cell,
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    method: str = "linear",
) -> dict[str, dict[str, Any]]:
    """:func:`tsn_analysis.stats.compare` for every entry of ``COMPARISON_METRICS``."""
    return {
        label: compare(getattr(base, attr), getattr(other, attr), stat, n_boot, ci, seed, method)
        for label, attr, stat in COMPARISON_METRICS
    }


def build_summary(
    results_dir: str | Path,
    baseline: str | None = None,
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    method: str = "linear",
) -> dict[str, Any]:
    """Every table for ``results_dir``; ``method`` is used for all percentiles."""
    cells = build_dataset(results_dir)
    names = list(cells)
    base = choose_baseline(names, baseline)
    return {
        "results_dir": str(Path(results_dir)),
        "percentile_method": method,
        "baseline": base,
        "conditions": names,
        "bootstrap": {"n_boot": n_boot, "ci": ci, "seed": seed},
        "cells": [cell_summary(cells[c], method, ci) for c in names],
        "comparisons": [
            {
                "condition": c,
                "baseline": base,
                "metrics": compare_cells(cells[base], cells[c], n_boot, ci, seed, method),
            }
            for c in names
            if c != base
        ],
    }


def _fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "-"
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return "nan"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def _fmt_signed(value: float) -> str:
    return "nan" if math.isnan(value) else f"{value:+.2f}"


def _fmt_p(p: float) -> str:
    if math.isnan(p):
        return "nan"
    if p < 1e-300:
        return "<1e-300"
    return f"{p:.2e}" if p < 0.01 else f"{p:.2f}"


def _table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> list[str]:
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines.extend("| " + " | ".join(r) + " |" for r in rows)
    return lines + [""]


def render_markdown(summary: dict[str, Any]) -> str:
    """ASCII Markdown tables for :func:`build_summary` output."""
    bs = summary["bootstrap"]
    lines = [
        "# TSN measurement summary",
        "",
        f"- results dir: `{summary['results_dir']}`",
        f"- baseline: `{summary['baseline']}`",
        f"- conditions: {', '.join(summary['conditions'])}",
        f"- percentiles: numpy `{summary['percentile_method']}`; CIs: {bs['ci'] * 100:.0f}% "
        f"percentile bootstrap, n_boot={bs['n_boot']}, seed={bs['seed']}",
        "",
    ]

    cols = ("p50", "p90", "p99", "p99.9", "max", "mean", "std")
    lines += ["## Latency (ms)", ""]
    rows = [
        [c["condition"], str(c["n_runs"]), str(c["n_packets"])]
        + [_fmt(c["latency_ms"][k]) for k in cols]
        for c in summary["cells"]
    ]
    lines += _table(["condition", "runs", "n", *cols], rows)

    lines += ["## Jitter |dt| (us)", ""]
    rows = [[c["condition"]] + [_fmt(c["jitter_us"][k]) for k in cols] for c in summary["cells"]]
    lines += _table(["condition", *cols], rows)

    lines += ["## Loss and DSCP", ""]
    rows = []
    for c in summary["cells"]:
        loss, dscp = c["loss"], c["dscp"]
        rows.append(
            [
                c["condition"],
                _fmt(loss["expected"], 0),
                _fmt(loss["received"], 0),
                _fmt(loss["lost"], 0),
                _fmt(loss["loss_pct"]),
                _fmt(loss["duplicates"], 0),
                _fmt(loss["reorders"], 0),
                "-" if dscp is None else _fmt(dscp["dominant_dscp"]),
            ]
        )
    lines += _table(
        ["condition", "expected", "received", "lost", "loss %", "dup", "reorder", "DSCP"], rows
    )

    rows = [
        [
            c["condition"],
            label,
            str(agg["n_runs"]),
            _fmt(agg["mean"]),
            _fmt(agg["std"]),
            f"[{_fmt(agg['ci_low'])}, {_fmt(agg['ci_high'])}]",
        ]
        for c in summary["cells"]
        for label, agg in c.get("per_run", {}).items()
    ]
    if rows:
        lines += ["## Per-run p99 (mean over runs, t-interval)", ""]
        lines += _table(["condition", "metric", "runs", "mean", "std", "CI"], rows)

    lines += [
        f"## Comparisons vs `{summary['baseline']}`",
        "",
        "improvement = (baseline - condition) / baseline. p: two-sided Mann-Whitney U; "
        "delta: Cliff's delta, + when the baseline is slower. Both compare whole "
        "distributions, so they repeat across the latency rows.",
        "",
    ]
    rows = []
    for cmp in summary["comparisons"]:
        for label, m in cmp["metrics"].items():
            b, p = m["baseline"], m["proposed"]
            rows.append(
                [
                    cmp["condition"],
                    label,
                    f"{_fmt(b['point'])} [{_fmt(b['low'])}, {_fmt(b['high'])}]",
                    f"{_fmt(p['point'])} [{_fmt(p['low'])}, {_fmt(p['high'])}]",
                    _fmt_signed(m["improvement_pct"]) + "%",
                    _fmt_p(m["p_value"]),
                    f"{_fmt_signed(m['cliffs_delta'])} ({m['effect']})",
                ]
            )
    headers = ["condition", "metric", "baseline [CI]", "condition [CI]", "improvement"]
    lines += _table([*headers, "p-value", "delta"], rows)
    return "\n".join(lines)


def sanitize_json(obj: Any) -> Any:
    """Plain Python values only, with ``nan``/``inf`` as ``None``.

    ``json`` would otherwise write bare ``NaN`` (e.g. the t-interval of a two-run
    condition), which ``jq`` and most other parsers reject.
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
    return json.dumps(sanitize_json(summary), indent=indent, allow_nan=False)


def write_json(summary: dict[str, Any], path: str | Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(to_json(summary), encoding="utf-8")
    return path

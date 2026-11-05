from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.dataset import build_dataset
from tsn_analysis.report import build_summary, choose_baseline, render_markdown, to_json, write_json

from .conftest import write_run_csv


def test_choose_baseline():
    assert choose_baseline(["fifo", "prio_clsf"]) == "fifo"
    assert choose_baseline(["fifo", "prio_clsf"], "prio_clsf") == "prio_clsf"
    with pytest.raises(ValueError):
        choose_baseline(["fifo"], "missing")
    with pytest.raises(ValueError):
        choose_baseline([])


def test_build_dataset_orders_conditions(run_dir: Path):
    write_run_csv(run_dir / "zzz_run1.csv", np.ones(10))
    write_run_csv(run_dir / "aaa_run1.csv", np.ones(10))
    cells = build_dataset(run_dir)
    assert list(cells) == ["fifo", "pfifo_fast_noclsf", "prio_clsf", "aaa", "zzz"]
    cell = cells["prio_clsf"]
    assert cell.n_runs == 3
    assert cell.latency_ms.size == 1500
    assert cell.jitter_us.size == 1500 - 3  # first row of each run dropped


def test_build_summary(run_dir: Path):
    s = build_summary(run_dir, n_boot=50)
    assert s["baseline"] == "fifo"
    assert s["conditions"] == ["fifo", "pfifo_fast_noclsf", "prio_clsf"]
    by = {c["condition"]: c for c in s["cells"]}
    assert by["prio_clsf"]["n_runs"] == 3 and by["prio_clsf"]["n_packets"] == 1500
    assert by["prio_clsf"]["dscp"]["dominant_dscp"] == 46
    assert by["fifo"]["dscp"]["dominant_dscp"] == 0
    assert by["fifo"]["loss"]["lost"] == 0 and by["fifo"]["loss"]["expected"] == 1500
    agg = by["prio_clsf"]["per_run"]["latency_p99_ms"]
    assert agg["n_runs"] == 3 and agg["ci_low"] < agg["mean"] < agg["ci_high"]

    assert [c["condition"] for c in s["comparisons"]] == ["pfifo_fast_noclsf", "prio_clsf"]
    m = s["comparisons"][1]["metrics"]
    assert set(m) == {"latency_p50_ms", "latency_p99_ms", "jitter_p99_us"}
    assert m["latency_p99_ms"]["improvement_pct"] > 0  # prio_clsf is the fast synthetic set
    assert m["latency_p99_ms"]["p_value"] < 0.01

    s2 = build_summary(run_dir, baseline="prio_clsf", n_boot=20)
    assert s2["baseline"] == "prio_clsf"
    assert s2["comparisons"][0]["metrics"]["latency_p99_ms"]["improvement_pct"] < 0


def test_render_markdown(run_dir: Path):
    md = render_markdown(build_summary(run_dir, n_boot=20))
    for header in (
        "# TSN measurement summary",
        "## Latency (ms)",
        "## Jitter |dt| (us)",
        "## Loss and DSCP",
        "## Per-run p99",
        "## Comparisons vs `fifo`",
        "| condition | runs | n | p50 | p90 | p99 | p99.9 | max | mean | std |",
    ):
        assert header in md
    assert md.isascii()
    assert "+" in md.split("## Comparisons")[1]  # improvement carries a sign


def test_json_roundtrip(run_dir: Path, tmp_path: Path):
    s = build_summary(run_dir, n_boot=20)
    loaded = json.loads(to_json(s))
    assert loaded["baseline"] == "fifo" and len(loaded["cells"]) == 3
    out = write_json(s, tmp_path / "sub" / "summary.json")
    assert out.exists() and out.stat().st_size > 100
    assert to_json({"x": np.float64(1.5), "y": np.int64(2), "z": np.arange(2), "p": Path("a")})


def test_json_is_strict_for_two_run_dataset(tmp_path: Path):
    """Two runs give a nan t-interval; the JSON must still be strict (null, not NaN)."""
    d = tmp_path / "two"
    rng = np.random.default_rng(3)
    for k in (1, 2):
        write_run_csv(d / f"fifo_run{k}.csv", rng.lognormal(size=200) + 1)
        write_run_csv(d / f"prio_clsf_run{k}.csv", rng.lognormal(size=200) * 0.5 + 1)
    text = to_json(build_summary(d, n_boot=10))
    assert "NaN" not in text and "Infinity" not in text

    def reject(name: str):
        raise ValueError(f"non-standard token {name}")

    data = json.loads(text, parse_constant=reject)
    agg = data["cells"][0]["per_run"]["latency_p99_ms"]
    assert agg["n_runs"] == 2 and agg["ci_low"] is None


def test_percentile_method_consistent_between_tables_and_comparisons(run_dir: Path):
    s = build_summary(run_dir, n_boot=10, method="nearest")
    assert s["percentile_method"] == "nearest"
    base = s["cells"][0]
    m = s["comparisons"][0]["metrics"]
    assert m["latency_p99_ms"]["percentile_method"] == "nearest"
    assert m["latency_p99_ms"]["baseline"]["point"] == base["latency_ms"]["p99"]
    assert m["latency_p50_ms"]["baseline"]["point"] == base["latency_ms"]["p50"]
    assert m["jitter_p99_us"]["baseline"]["point"] == base["jitter_us"]["p99"]

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.dataset import build_dataset
from tsn_analysis.report import (
    build_summary,
    choose_baseline,
    render_markdown,
    to_json,
    write_json,
)


def test_choose_baseline():
    assert choose_baseline(["proposed", "baseline"]) == "baseline"
    assert choose_baseline(["prio_class", "pfifo"]) == "pfifo"
    assert choose_baseline(["b", "a"]) == "a"
    assert choose_baseline(["b", "a"], "b") == "b"
    with pytest.raises(ValueError):
        choose_baseline(["a"], "missing")
    with pytest.raises(ValueError):
        choose_baseline([])


def test_build_dataset_legacy(legacy_dir: Path):
    ds = build_dataset(legacy_dir, normalize_skew=True)
    assert ds.conditions == ["baseline", "proposed"]
    assert ds.factor_keys == ["cpu10", "cpu50", "cpu99"]
    assert ds.get("baseline", "cpu99") is None
    assert ds.factor_label("cpu10") == "CPU 10%"
    cell = ds.get("proposed", "cpu10")
    assert cell is not None and cell.n_runs == 1
    assert cell.runs[0].clock_skew_ms is not None
    assert cell.jitter_us.size == cell.latency_ms.size - 1


def test_build_summary_legacy(legacy_dir: Path):
    s = build_summary(legacy_dir, normalize_skew=True, n_boot=100)
    assert s["baseline"] == "baseline"
    assert [c["condition"] + "/" + c["factor"] for c in s["cells"]] == [
        "baseline/cpu10", "proposed/cpu10", "baseline/cpu50", "proposed/cpu50", "proposed/cpu99",
    ]
    assert [c["factor"] for c in s["comparisons"]] == ["cpu10", "cpu50"]
    m = s["comparisons"][0]["metrics"]
    assert set(m) == {"latency_p50_ms", "latency_p99_ms", "jitter_p99_us"}
    assert m["latency_p99_ms"]["improvement_pct"] > 0  # proposed synthetic is faster
    assert m["latency_p99_ms"]["p_value"] < 0.01
    cell = s["cells"][0]
    assert cell["loss"]["lost"] == 0 and cell["loss"]["expected"] == 600
    assert cell["throughput_kbps"]["mean"] > 0
    assert cell["dscp"] is None
    assert "per_run" not in cell


def test_build_summary_newstyle_per_run_and_dscp(newstyle_dir: Path):
    s = build_summary(newstyle_dir, n_boot=50)
    assert s["baseline"] == "pfifo"
    assert s["factors"] == [{"key": "all", "label": "all runs", "factors": {}}]
    by = {c["condition"]: c for c in s["cells"]}
    assert by["prio_class"]["n_runs"] == 3
    assert by["prio_class"]["n_packets"] == 1500
    assert by["prio_class"]["dscp"]["dominant_dscp"] == 46
    assert by["pfifo"]["dscp"]["dominant_dscp"] == 0
    agg = by["prio_class"]["per_run"]["latency_p99_ms"]
    assert agg["n_runs"] == 3 and agg["ci_low"] < agg["mean"] < agg["ci_high"]
    assert sorted(c["condition"] for c in s["comparisons"]) == ["pfifo_fast_noclass", "prio_class"]
    s2 = build_summary(newstyle_dir, baseline="prio_class", n_boot=20)
    assert s2["baseline"] == "prio_class"
    assert s2["comparisons"][0]["metrics"]["latency_p99_ms"]["improvement_pct"] < 0


def test_render_markdown_headers(legacy_dir: Path, newstyle_dir: Path):
    md = render_markdown(build_summary(legacy_dir, normalize_skew=True, n_boot=50))
    for header in (
        "# TSN measurement summary",
        "## Latency (ms)",
        "## Jitter |dt| (us)",
        "## Loss, throughput, DSCP",
        "## Comparisons vs `baseline`",
        "| condition | factor | runs | n | p50 | p90 | p99 | p99.9 | max | mean | std |",
    ):
        assert header in md
    assert "1st percentile subtracted" in md
    assert "CPU 99%" in md
    assert md.isascii()
    # improvement column carries a sign
    assert "+" in md.split("## Comparisons")[1]
    md2 = render_markdown(build_summary(newstyle_dir, n_boot=20))
    assert "## Per-run aggregate" in md2
    assert "no clock-skew normalisation" in md2


def test_json_roundtrip(legacy_dir: Path, tmp_path: Path):
    s = build_summary(legacy_dir, n_boot=20)
    text = to_json(s)
    loaded = json.loads(text)
    assert loaded["baseline"] == "baseline"
    assert len(loaded["cells"]) == 5
    out = write_json(s, tmp_path / "sub" / "summary.json")
    assert out.exists() and out.stat().st_size > 100
    # numpy scalars serialise
    assert to_json({"x": np.float64(1.5), "y": np.int64(2), "z": np.arange(2)})


def test_json_is_strict_for_two_run_dataset(tmp_path: Path):
    """Fewer than 3 runs yields nan t-intervals; JSON must still be RFC-strict (null)."""
    from .conftest import write_run_csv

    d = tmp_path / "two"
    rng = np.random.default_rng(3)
    for k in (1, 2):
        write_run_csv(d / f"baseline_cpu10_run{k}.csv", rng.lognormal(size=200) + 1)
        write_run_csv(d / f"proposed_cpu10_run{k}.csv", rng.lognormal(size=200) * 0.5 + 1)
    s = build_summary(d, n_boot=10, normalize_skew=True)
    text = to_json(s)
    assert "NaN" not in text and "Infinity" not in text

    def reject(name: str):
        raise ValueError(f"non-standard token {name}")

    data = json.loads(text, parse_constant=reject)
    agg = next(c for c in data["cells"] if c["condition"] == "baseline")["per_run"]
    assert agg["latency_p99_ms"]["n_runs"] == 2
    assert agg["latency_p99_ms"]["ci_low"] is None
    # skew-normalised comparisons carry the joint-bootstrap marker
    assert data["comparisons"][0]["metrics"]["latency_p99_ms"]["skew_percentile"] == 1.0
    assert data["comparisons"][0]["metrics"]["jitter_p99_us"]["skew_percentile"] is None


def test_percentile_method_consistent_between_tables_and_comparisons(legacy_dir: Path):
    s = build_summary(legacy_dir, n_boot=10, method="nearest", normalize_skew=True)
    assert s["percentile_method"] == "nearest"
    cell = next(c for c in s["cells"] if c["condition"] == "baseline" and c["factor"] == "cpu10")
    cmp = next(c for c in s["comparisons"] if c["factor"] == "cpu10")
    m = cmp["metrics"]
    assert m["latency_p99_ms"]["percentile_method"] == "nearest"
    assert m["latency_p99_ms"]["baseline"]["point"] == cell["latency_ms"]["p99"]
    assert m["latency_p50_ms"]["baseline"]["point"] == cell["latency_ms"]["p50"]
    assert m["jitter_p99_us"]["baseline"]["point"] == cell["jitter_us"]["p99"]


def test_markdown_skew_caveats(legacy_dir: Path):
    md = render_markdown(build_summary(legacy_dir, n_boot=10, normalize_skew=True))
    assert "above each run's floor" in md
    assert "joint bootstrap" in md
    assert "NOT (n-1) * send interval" in md
    md2 = render_markdown(build_summary(legacy_dir, n_boot=10))
    assert "joint bootstrap" not in md2

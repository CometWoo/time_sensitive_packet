from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.dataset import build_dataset
from tsn_analysis.plots import FIGURE_NAMES, condition_colors, plot_all, plot_latency_cdf

from .conftest import write_run_csv


def _assert_pngs(paths: list[Path], out_dir: Path) -> None:
    assert [p.name for p in paths] == list(FIGURE_NAMES)
    for p in paths:
        assert p.parent == out_dir
        assert p.exists()
        assert p.stat().st_size > 1000
        assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"


def test_plot_all_legacy_with_missing_condition(legacy_dir: Path, tmp_path: Path):
    out = tmp_path / "figs"
    paths = plot_all(legacy_dir, out, normalize_skew=True)
    _assert_pngs(paths, out)


def test_plot_all_newstyle_single_factor(newstyle_dir: Path, tmp_path: Path):
    out = tmp_path / "figs2"
    paths = plot_all(newstyle_dir, out)
    _assert_pngs(paths, out)


def test_plot_all_empty_dir_raises(tmp_path: Path):
    with pytest.raises(ValueError, match="no CSV runs"):
        plot_all(tmp_path, tmp_path / "x")


def test_plot_handles_nonpositive_latency(tmp_path: Path):
    d = tmp_path / "neg"
    write_run_csv(d / "baseline_cpu10.csv", np.linspace(-5.0, 5.0, 200))
    write_run_csv(d / "proposed_cpu10.csv", np.linspace(-3.0, 3.0, 200))
    out = tmp_path / "figs3"
    paths = plot_all(d, out, normalize_skew=False)
    _assert_pngs(paths, out)


def test_plot_deterministic(legacy_dir: Path, tmp_path: Path):
    ds = build_dataset(legacy_dir)
    (tmp_path / "a").mkdir()
    a = plot_latency_cdf(ds, tmp_path / "a")
    (tmp_path / "b").mkdir()
    b = plot_latency_cdf(ds, tmp_path / "b")
    assert a.read_bytes() == b.read_bytes()


def test_condition_colors_stable():
    c = condition_colors(["proposed", "baseline", "zzz", "aaa"])
    assert c["baseline"] == "#4EABD1"
    assert c["proposed"] == "#E8734A"
    assert c["aaa"] != c["zzz"]
    assert condition_colors(["aaa", "zzz"]) == {"aaa": c["aaa"], "zzz": c["zzz"]}

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.dataset import build_dataset
from tsn_analysis.plots import (
    FIGURE_NAMES,
    KNOWN_STYLES,
    condition_styles,
    plot_all,
    plot_latency_cdf,
)

from .conftest import write_run_csv


def _assert_pngs(paths: list[Path], out_dir: Path) -> None:
    assert [p.name for p in paths] == list(FIGURE_NAMES)
    for p in paths:
        assert p.parent == out_dir
        assert p.stat().st_size > 1000
        assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"


def test_plot_all(run_dir: Path, tmp_path: Path):
    out = tmp_path / "figs"
    _assert_pngs(plot_all(run_dir, out), out)


def test_plot_all_empty_dir_raises(tmp_path: Path):
    with pytest.raises(ValueError, match="no CSV runs"):
        plot_all(tmp_path, tmp_path / "x")


def test_plot_handles_nonpositive_latency(tmp_path: Path):
    # log axes cannot show <= 0; such points are dropped instead of crashing
    d = tmp_path / "neg"
    write_run_csv(d / "fifo_run1.csv", np.linspace(-5.0, 5.0, 200))
    write_run_csv(d / "prio_clsf_run1.csv", np.linspace(-3.0, 3.0, 200))
    out = tmp_path / "figs"
    _assert_pngs(plot_all(d, out), out)


def test_plot_deterministic(run_dir: Path, tmp_path: Path):
    cells = build_dataset(run_dir)
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    a = plot_latency_cdf(cells, tmp_path / "a")
    b = plot_latency_cdf(cells, tmp_path / "b")
    assert a.read_bytes() == b.read_bytes()


def test_condition_styles():
    s = condition_styles(["fifo", "zzz", "prio_clsf", "aaa"])
    assert s["fifo"] == KNOWN_STYLES["fifo"] and s["prio_clsf"] == KNOWN_STYLES["prio_clsf"]
    assert s["zzz"] != s["aaa"]

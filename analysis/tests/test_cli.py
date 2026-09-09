from __future__ import annotations

import json
from pathlib import Path

import pytest

from tsn_analysis.cli import main
from tsn_analysis.plots import FIGURE_NAMES


def test_summary_stdout_markdown(legacy_dir: Path, capsys):
    rc = main(["summary", str(legacy_dir), "--normalize-skew", "--n-boot", "30"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "# TSN measurement summary" in out
    assert "## Comparisons vs `baseline`" in out
    assert out.isascii()


def test_summary_json_and_markdown_files(legacy_dir: Path, tmp_path: Path, capsys):
    js = tmp_path / "out" / "summary.json"
    md = tmp_path / "out" / "summary.md"
    rc = main(
        ["summary", str(legacy_dir), "--json", str(js), "--markdown", str(md), "--n-boot", "20"]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert "wrote" in out
    assert "# TSN measurement summary" not in out  # redirected to file
    data = json.loads(js.read_text(encoding="utf-8"))
    assert data["baseline"] == "baseline"
    assert data["normalize_skew"] is False
    assert data["bootstrap"]["n_boot"] == 20
    assert "## Latency (ms)" in md.read_text(encoding="utf-8")


def test_summary_json_stdout(newstyle_dir: Path, capsys):
    rc = main(["summary", str(newstyle_dir), "--json", "-", "--n-boot", "10"])
    assert rc == 0
    out = capsys.readouterr().out
    data = json.loads(out)
    assert data["baseline"] == "pfifo"
    assert "# TSN" not in out


def test_summary_explicit_baseline(newstyle_dir: Path, capsys):
    rc = main(["summary", str(newstyle_dir), "--baseline", "prio_class", "--n-boot", "10"])
    assert rc == 0
    assert "## Comparisons vs `prio_class`" in capsys.readouterr().out


def test_summary_bad_baseline(newstyle_dir: Path, capsys):
    rc = main(["summary", str(newstyle_dir), "--baseline", "nope", "--n-boot", "10"])
    assert rc == 2
    err = capsys.readouterr().err
    assert err.startswith("error:") and "nope" in err


def test_missing_results_dir(tmp_path: Path, capsys):
    ghost = tmp_path / "ghost"
    for argv in (
        ["summary", str(ghost)],
        ["plot", str(ghost), "--out", str(tmp_path / "figs")],
        ["compare", str(ghost), "--baseline", "a", "--against", "b"],
    ):
        assert main(argv) == 2
        assert "results directory not found" in capsys.readouterr().err


def test_empty_results_dir(tmp_path: Path, capsys):
    empty = tmp_path / "empty"
    empty.mkdir()
    assert main(["summary", str(empty)]) == 2
    assert "no conditions found" in capsys.readouterr().err
    assert main(["plot", str(empty), "--out", str(tmp_path / "figs")]) == 2
    assert "no CSV runs" in capsys.readouterr().err


def test_plot_command(legacy_dir: Path, tmp_path: Path, capsys):
    out_dir = tmp_path / "figures"
    rc = main(["plot", str(legacy_dir), "--out", str(out_dir), "--normalize-skew"])
    assert rc == 0
    for name in FIGURE_NAMES:
        assert (out_dir / name).stat().st_size > 1000
    assert capsys.readouterr().out.count("wrote") == len(FIGURE_NAMES)


def test_compare_command(legacy_dir: Path, capsys):
    rc = main(
        ["compare", str(legacy_dir), "--baseline", "baseline", "--against", "proposed",
         "--stat", "p99", "--normalize-skew", "--n-boot", "30"]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert "CPU 10%" in out and "CPU 50%" in out and "CPU 99%" not in out
    assert "p-value" in out
    assert out.isascii()
    rc = main(["compare", str(legacy_dir), "--baseline", "baseline", "--against", "proposed",
               "--metric", "jitter", "--stat", "p50", "--n-boot", "10"])
    assert rc == 0
    assert "(us)" in capsys.readouterr().out


def test_compare_unknown_condition(legacy_dir: Path, capsys):
    rc = main(["compare", str(legacy_dir), "--baseline", "baseline", "--against", "ghost"])
    assert rc == 2
    assert "not found" in capsys.readouterr().err


def test_compare_no_common_factor(tmp_path: Path, capsys):
    import numpy as np

    from .conftest import write_run_csv

    d = tmp_path / "disjoint"
    write_run_csv(d / "a_cpu10.csv", np.ones(50))
    write_run_csv(d / "b_cpu50.csv", np.ones(50))
    rc = main(["compare", str(d), "--baseline", "a", "--against", "b", "--n-boot", "5"])
    assert rc == 1
    assert "no factor" in capsys.readouterr().out


def test_no_command_errors():
    with pytest.raises(SystemExit):
        main([])

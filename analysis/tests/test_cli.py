from __future__ import annotations

import json
from pathlib import Path

import pytest

from tsn_analysis.cli import main
from tsn_analysis.plots import FIGURE_NAMES


def test_summary_stdout_markdown(run_dir: Path, capsys):
    assert main(["summary", str(run_dir), "--n-boot", "30"]) == 0
    out = capsys.readouterr().out
    assert "# TSN measurement summary" in out
    assert "## Comparisons vs `fifo`" in out
    assert out.isascii()


def test_summary_json_and_markdown_files(run_dir: Path, tmp_path: Path, capsys):
    js = tmp_path / "out" / "summary.json"
    md = tmp_path / "out" / "summary.md"
    argv = ["summary", str(run_dir), "--json", str(js), "--markdown", str(md), "--n-boot", "20"]
    assert main(argv) == 0
    out = capsys.readouterr().out
    assert "wrote" in out
    assert "# TSN measurement summary" not in out  # redirected to the file
    data = json.loads(js.read_text(encoding="utf-8"))
    assert data["baseline"] == "fifo"
    assert data["bootstrap"]["n_boot"] == 20
    assert "## Latency (ms)" in md.read_text(encoding="utf-8")


def test_summary_json_stdout(run_dir: Path, capsys):
    assert main(["summary", str(run_dir), "--json", "-", "--n-boot", "10"]) == 0
    out = capsys.readouterr().out
    assert json.loads(out)["baseline"] == "fifo"
    assert "# TSN" not in out


def test_summary_explicit_baseline(run_dir: Path, capsys):
    assert main(["summary", str(run_dir), "--baseline", "prio_clsf", "--n-boot", "10"]) == 0
    assert "## Comparisons vs `prio_clsf`" in capsys.readouterr().out


def test_summary_bad_baseline(run_dir: Path, capsys):
    assert main(["summary", str(run_dir), "--baseline", "nope", "--n-boot", "10"]) == 2
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


def test_plot_command(run_dir: Path, tmp_path: Path, capsys):
    out_dir = tmp_path / "figures"
    assert main(["plot", str(run_dir), "--out", str(out_dir)]) == 0
    for name in FIGURE_NAMES:
        assert (out_dir / name).stat().st_size > 1000
    assert capsys.readouterr().out.count("wrote") == len(FIGURE_NAMES)


def test_compare_command(run_dir: Path, capsys):
    argv = ["compare", str(run_dir), "--baseline", "fifo", "--against", "prio_clsf"]
    assert main([*argv, "--stat", "p99", "--n-boot", "30"]) == 0
    out = capsys.readouterr().out
    assert "latency p99 (ms)" in out and "p-value" in out
    assert "fifo" in out and "prio_clsf" in out
    assert out.isascii()
    assert main([*argv, "--metric", "jitter", "--stat", "p50", "--n-boot", "10"]) == 0
    assert "jitter p50 (us)" in capsys.readouterr().out


def test_compare_unknown_condition(run_dir: Path, capsys):
    assert main(["compare", str(run_dir), "--baseline", "fifo", "--against", "ghost"]) == 2
    assert "not found" in capsys.readouterr().err


def test_no_command_errors():
    with pytest.raises(SystemExit):
        main([])

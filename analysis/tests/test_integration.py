"""Integration test against the committed CI testbed run (results/testbed/ci-34294518788).

Pins the headline numbers quoted in README.md and docs/RESULTS.md, so a change in the
analysis code that moves them fails here.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tsn_analysis.cli import main

REAL_RESULTS = Path(__file__).resolve().parents[2] / "results" / "testbed" / "ci-34294518788" / "ci"

pytestmark = pytest.mark.skipif(
    not (REAL_RESULTS / "fifo_run1.csv").exists(),
    reason="committed testbed CSVs not present",
)


def _cell(summary: dict, condition: str) -> dict:
    return next(c for c in summary["cells"] if c["condition"] == condition)


def test_summary_on_committed_testbed_run(tmp_path: Path, capsys):
    js = tmp_path / "ci.json"
    rc = main(
        [
            "summary",
            str(REAL_RESULTS),
            "--baseline",
            "fifo",
            "--json",
            str(js),
            "--markdown",
            "-",
            "--n-boot",
            "200",
        ]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert "# TSN measurement summary" in out
    assert out.isascii()
    s = json.loads(js.read_text(encoding="utf-8"))

    fifo, noclsf, clsf = (_cell(s, c) for c in ("fifo", "pfifo_fast_noclsf", "pfifo_fast_clsf"))
    assert fifo["latency_ms"]["p50"] == pytest.approx(431.33, abs=0.01)
    assert fifo["latency_ms"]["p99"] == pytest.approx(543.73, abs=0.01)
    assert noclsf["latency_ms"]["p50"] == pytest.approx(433.15, abs=0.01)
    assert clsf["latency_ms"]["p50"] == pytest.approx(0.05, abs=0.005)
    assert clsf["latency_ms"]["p99"] == pytest.approx(0.17, abs=0.005)
    assert fifo["loss"]["loss_pct"] == pytest.approx(35.18, abs=0.01)
    assert noclsf["loss"]["loss_pct"] == pytest.approx(38.96, abs=0.01)
    assert clsf["loss"]["lost"] == 0
    # the classifier's DSCP mark arrives on every TS packet; without it nothing is marked
    assert clsf["dscp"]["dscp"] == {"46": 30000}
    assert noclsf["dscp"]["dominant_dscp"] == 0

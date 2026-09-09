"""Integration test against the real results/k8s-2026-05 CSVs.

Reference values come from README.md (computed with nearest-rank percentiles
after 1st-percentile normalisation); numpy ``linear`` must land within 0.3 ms.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tsn_analysis.cli import main

REAL_RESULTS = Path(__file__).resolve().parents[2] / "results" / "k8s-2026-05"

pytestmark = pytest.mark.skipif(
    not (REAL_RESULTS / "baseline_cpu10.csv").exists(),
    reason="real measurement CSVs not present",
)


def _cell(summary: dict, condition: str, factor: str) -> dict:
    for c in summary["cells"]:
        if c["condition"] == condition and c["factor"] == factor:
            return c
    raise KeyError((condition, factor))


def test_summary_on_real_results(tmp_path: Path, capsys):
    js = tmp_path / "real.json"
    rc = main(
        ["summary", str(REAL_RESULTS), "--normalize-skew", "--json", str(js), "--markdown", "-",
         "--n-boot", "200"]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert "# TSN measurement summary" in out
    assert out.isascii()
    s = json.loads(js.read_text(encoding="utf-8"))

    assert s["baseline"] == "baseline"
    assert [f["key"] for f in s["factors"]] == ["cpu10", "cpu30", "cpu50", "cpu70", "cpu99"]

    b10 = _cell(s, "baseline", "cpu10")
    p10 = _cell(s, "proposed", "cpu10")
    assert b10["latency_ms"]["p99"] == pytest.approx(13.02, abs=0.3)
    assert p10["latency_ms"]["p99"] == pytest.approx(3.42, abs=0.3)
    assert b10["latency_ms"]["p50"] == pytest.approx(1.19, abs=0.1)
    assert p10["latency_ms"]["p50"] == pytest.approx(0.80, abs=0.1)
    # 1st percentile normalisation: p1 of every cell is ~0 and the skew was negative
    assert b10["clock_skew_ms"][0] < 0
    assert b10["n_packets"] == 10000
    assert b10["loss"]["lost"] == 0

    # proposed-only cpu99 is present in the cells but not in comparisons
    assert _cell(s, "proposed", "cpu99")["n_runs"] == 1
    assert [c["factor"] for c in s["comparisons"]] == ["cpu10", "cpu30", "cpu50", "cpu70"]
    m10 = s["comparisons"][0]["metrics"]["latency_p99_ms"]
    assert m10["improvement_pct"] == pytest.approx(73.7, abs=2.0)
    assert m10["p_value"] < 1e-100
    assert m10["cliffs_delta"] > 0.3

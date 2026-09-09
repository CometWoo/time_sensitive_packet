#!/usr/bin/env python3
"""Thin wrapper: `tsn-analysis plot <dir> --normalize-skew --out figures`.

Figures: fig_latency_percentiles / fig_jitter_percentiles / fig_latency_cdf /
fig_throughput / fig_latency_box (.png). Code lives in ../analysis/tsn_analysis.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from tsn_analysis.cli import main  # noqa: E402

results = sys.argv[1] if len(sys.argv) > 1 else "results"
sys.exit(main(["plot", results, "--normalize-skew", "--out", "figures", *sys.argv[2:]]))

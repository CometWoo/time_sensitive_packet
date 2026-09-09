#!/usr/bin/env python3
"""Thin wrapper: `tsn-analysis summary <dir> --normalize-skew --markdown -`.

The analysis code lives in analysis/tsn_analysis; see analysis/README.md.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "analysis"))
from tsn_analysis.cli import main  # noqa: E402

results = sys.argv[1] if len(sys.argv) > 1 else "step8-measurement/results"
sys.exit(main(["summary", results, "--normalize-skew", "--markdown", "-", *sys.argv[2:]]))

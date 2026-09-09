#!/usr/bin/env python3
"""Thin wrapper: tsn-analysis summary <dir> --normalize-skew --markdown - (code: analysis/)."""
import sys
from pathlib import Path


def main() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent / "analysis"))
    from tsn_analysis.cli import main as cli_main

    results = sys.argv[1] if len(sys.argv) > 1 else "step8-measurement/results"
    return cli_main(["summary", results, "--normalize-skew", "--markdown", "-", *sys.argv[2:]])


sys.exit(main())

#!/usr/bin/env python3
"""Thin wrapper: tsn-analysis plot <dir> --normalize-skew --out figures (code: ../analysis/)."""
import sys
from pathlib import Path


def main() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
    from tsn_analysis.cli import main as cli_main

    results = sys.argv[1] if len(sys.argv) > 1 else "results"
    return cli_main(["plot", results, "--normalize-skew", "--out", "figures", *sys.argv[2:]])


sys.exit(main())

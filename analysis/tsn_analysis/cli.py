"""``tsn-analysis summary|plot|compare``.

Output is plain ASCII so it survives a cp949 Windows console as well.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from tsn_analysis.dataset import build_dataset
from tsn_analysis.plots import plot_all
from tsn_analysis.report import build_summary, render_markdown, to_json, write_json
from tsn_analysis.stats import compare


def _configure_stdout() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):  # pragma: no cover - closed/odd streams
                pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tsn-analysis",
        description="Latency / jitter / loss analysis for the testbed CSVs.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("summary", help="Markdown tables and/or JSON for a results directory")
    s.add_argument("results_dir", type=Path, help="directory with <condition>_run<k>.csv")
    s.add_argument("--baseline", default=None, help="reference condition (default: first)")
    s.add_argument("--json", type=Path, default=None, help="write JSON here ('-' = stdout)")
    s.add_argument(
        "--markdown",
        type=Path,
        default=None,
        help="write Markdown here ('-' = stdout, the default)",
    )
    s.add_argument("--n-boot", type=int, default=2000, help="bootstrap resamples (default 2000)")
    s.add_argument("--ci", type=float, default=0.95, help="confidence level (default 0.95)")
    s.add_argument("--seed", type=int, default=0, help="bootstrap RNG seed (default 0)")

    p = sub.add_parser("plot", help="write the latency percentile and CDF figures")
    p.add_argument("results_dir", type=Path, help="directory with <condition>_run<k>.csv")
    p.add_argument("--out", type=Path, required=True, help="figure output directory")

    c = sub.add_parser("compare", help="compare two conditions on one statistic")
    c.add_argument("results_dir", type=Path, help="directory with <condition>_run<k>.csv")
    c.add_argument("--baseline", required=True, help="reference condition")
    c.add_argument("--against", required=True, help="condition to compare with the baseline")
    c.add_argument("--stat", default="p99", help="p50, p99, p99.9, mean, max ...")
    c.add_argument("--metric", default="latency", choices=("latency", "jitter"))
    c.add_argument("--n-boot", type=int, default=2000)
    c.add_argument("--ci", type=float, default=0.95)
    c.add_argument("--seed", type=int, default=0)
    return parser


def _emit(text: str, target: Path | None, stdout_default: bool) -> None:
    if target is None:
        if stdout_default:
            print(text)
        return
    if str(target) == "-":
        print(text)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print(f"wrote {target}")


def cmd_summary(args: argparse.Namespace) -> int:
    summary = build_summary(
        args.results_dir, baseline=args.baseline, n_boot=args.n_boot, ci=args.ci, seed=args.seed
    )
    # Markdown goes to stdout unless redirected; JSON only when asked for
    _emit(render_markdown(summary), args.markdown, stdout_default=args.json is None)
    if args.json is not None:
        if str(args.json) == "-":
            print(to_json(summary))
        else:
            write_json(summary, args.json)
            print(f"wrote {args.json}")
    return 0


def cmd_plot(args: argparse.Namespace) -> int:
    for path in plot_all(args.results_dir, args.out):
        print(f"wrote {path}")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    cells = build_dataset(args.results_dir)
    for name in (args.baseline, args.against):
        if name not in cells:
            print(f"error: condition {name!r} not found; available: {list(cells)}", file=sys.stderr)
            return 2
    attr, unit = ("latency_ms", "ms") if args.metric == "latency" else ("jitter_us", "us")
    r = compare(
        getattr(cells[args.baseline], attr),
        getattr(cells[args.against], attr),
        args.stat,
        args.n_boot,
        args.ci,
        args.seed,
    )
    print(f"{args.metric} {args.stat} ({unit}), {args.ci * 100:.0f}% bootstrap CI")
    for name, side in ((args.baseline, r["baseline"]), (args.against, r["proposed"])):
        print(f"  {name:<20}{side['point']:>12.3f}  [{side['low']:.3f}, {side['high']:.3f}]")
    print(
        f"  improvement {r['improvement_pct']:+.1f}%  p-value {r['p_value']:.2e}  "
        f"delta {r['cliffs_delta']:+.3f} ({r['effect']})"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Return 0 on success, 2 on a user error (missing directory, unknown condition or
    statistic), which is printed as ``error: ...`` on stderr instead of a traceback."""
    _configure_stdout()
    args = build_parser().parse_args(argv)
    if not args.results_dir.is_dir():
        print(f"error: results directory not found: {args.results_dir}", file=sys.stderr)
        return 2
    handlers = {"summary": cmd_summary, "plot": cmd_plot, "compare": cmd_compare}
    try:
        return handlers[args.command](args)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())

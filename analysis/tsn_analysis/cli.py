"""Command-line interface: ``tsn-analysis summary|plot|compare``.

All printed output is plain ASCII so it renders on a Windows cp949 console;
stdout is additionally reconfigured to UTF-8 with replacement for safety.
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


def _add_common(p: argparse.ArgumentParser) -> None:
    p.add_argument("results_dir", type=Path, help="directory containing <name>.csv runs")
    p.add_argument(
        "--normalize-skew",
        action="store_true",
        help="subtract each run's 1st-percentile latency (two-clock testbed only)",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tsn-analysis",
        description="Latency / jitter / loss analysis for the TSN measurement CSVs.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("summary", help="tables (Markdown) and/or JSON for a results directory")
    _add_common(s)
    s.add_argument("--baseline", default=None, help="reference condition (default: baseline/pfifo)")
    s.add_argument("--json", type=Path, default=None, help="write JSON summary here ('-' = stdout)")
    s.add_argument("--markdown", type=Path, default=None,
                   help="write Markdown summary here ('-' = stdout, the default)")
    s.add_argument("--n-boot", type=int, default=2000, help="bootstrap resamples (default 2000)")
    s.add_argument("--ci", type=float, default=0.95, help="confidence level (default 0.95)")
    s.add_argument("--seed", type=int, default=0, help="bootstrap RNG seed (default 0)")

    p = sub.add_parser("plot", help="write the five figures")
    _add_common(p)
    p.add_argument("--out", type=Path, required=True, help="figure output directory")

    c = sub.add_parser("compare", help="compare two conditions on one statistic")
    _add_common(c)
    c.add_argument("--baseline", required=True, help="reference condition name")
    c.add_argument("--against", required=True, help="condition to compare with the baseline")
    c.add_argument("--stat", default="p99", help="statistic: p50, p99, p99.9, mean, max ...")
    c.add_argument("--metric", default="latency", choices=("latency", "jitter"),
                   help="which sample to compare (default latency)")
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
        args.results_dir,
        baseline=args.baseline,
        normalize_skew=args.normalize_skew,
        n_boot=args.n_boot,
        ci=args.ci,
        seed=args.seed,
    )
    # Markdown goes to stdout unless redirected; JSON only when asked for.
    _emit(render_markdown(summary), args.markdown, stdout_default=args.json is None)
    if args.json is not None:
        if str(args.json) == "-":
            print(to_json(summary))
        else:
            write_json(summary, args.json)
            print(f"wrote {args.json}")
    return 0


def cmd_plot(args: argparse.Namespace) -> int:
    paths = plot_all(args.results_dir, args.out, normalize_skew=args.normalize_skew)
    for p in paths:
        print(f"wrote {p}")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    ds = build_dataset(args.results_dir, normalize_skew=args.normalize_skew)
    for name in (args.baseline, args.against):
        if name not in ds.conditions:
            print(f"error: condition {name!r} not found; available: {ds.conditions}",
                  file=sys.stderr)
            return 2
    attr = "latency_ms" if args.metric == "latency" else "jitter_us"
    unit = "ms" if args.metric == "latency" else "us"
    print(f"{args.metric} {args.stat}: {args.against} vs {args.baseline} "
          f"(normalize_skew={args.normalize_skew})")
    print(f"{'factor':<14}{'baseline [CI]':>30}{'against [CI]':>30}"
          f"{'improv%':>10}{'p-value':>12}{'delta':>10}")
    found = False
    for fk in ds.factor_keys:
        a, b = ds.get(args.baseline, fk), ds.get(args.against, fk)
        if a is None or b is None:
            continue
        found = True
        if attr == "latency_ms":
            (va, sp), (vb, _) = a.latency_samples(), b.latency_samples()
        else:
            va, vb, sp = a.jitter_us, b.jitter_us, None
        r = compare(va, vb, args.stat, args.n_boot, args.ci, args.seed, skew_percentile=sp)
        ba, pr = r["baseline"], r["proposed"]
        print(
            f"{ds.factor_label(fk):<14}"
            f"{ba['point']:>10.2f} [{ba['low']:.2f}, {ba['high']:.2f}]".rjust(30)
            + f"{pr['point']:>10.2f} [{pr['low']:.2f}, {pr['high']:.2f}]".rjust(30)
            + f"{r['improvement_pct']:>+9.1f}%"
            + f"{r['p_value']:>12.2e}"
            + f"{r['cliffs_delta']:>+10.3f} {r['effect']} ({unit})"
        )
    if not found:
        print("no factor has data for both conditions")
        return 1
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point.  Returns 0 on success, 1 for "nothing to compare", 2 for user errors
    (missing directory, unknown condition, bad statistic), which are printed as
    ``error: ...`` on stderr instead of a traceback."""
    _configure_stdout()
    parser = build_parser()
    args = parser.parse_args(argv)
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

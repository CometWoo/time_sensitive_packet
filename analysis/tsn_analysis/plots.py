"""Figures for a results directory (matplotlib, Agg backend, deterministic).

Every figure is written with a fixed name so downstream docs can link to it:

* ``fig_latency_percentiles.png`` - grouped bars p50/p99/max per factor x condition (log y)
* ``fig_jitter_percentiles.png``  - same for |jitter| (us)
* ``fig_latency_cdf.png``         - one CDF panel per factor, log x
* ``fig_throughput.png``          - received throughput bars (kbit/s)
* ``fig_latency_box.png``         - latency box plots per condition, one panel per factor

A condition that has no data for some factor simply has no bar / line there.
Colours are assigned per condition and reused across all figures.
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from tsn_analysis.dataset import Dataset, build_dataset  # noqa: E402
from tsn_analysis.metrics import percentile, throughput_kbps  # noqa: E402

FIGURE_NAMES: tuple[str, ...] = (
    "fig_latency_percentiles.png",
    "fig_jitter_percentiles.png",
    "fig_latency_cdf.png",
    "fig_throughput.png",
    "fig_latency_box.png",
)

# Known conditions get fixed colours so figures stay comparable between reruns;
# anything else is assigned from the fallback cycle in sorted order.
KNOWN_COLORS: dict[str, str] = {
    "baseline": "#4EABD1",
    "proposed": "#E8734A",
    "pfifo": "#4EABD1",
    "fq_codel": "#7B68EE",
    "pfifo_fast_noclass": "#9E9E9E",
    "pfifo_fast_class": "#F2B134",
    "prio_class": "#E8734A",
}
FALLBACK_COLORS: tuple[str, ...] = (
    "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf",
)
PCT_HATCH: dict[str, str] = {"p50": "", "p99": "//", "max": "xx"}
PCT_ALPHA: dict[str, float] = {"p50": 0.9, "p99": 0.7, "max": 0.5}

RC = {
    "font.size": 10,
    "axes.titlesize": 12,
    "axes.labelsize": 11,
    "legend.fontsize": 9,
    "figure.titlesize": 13,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
    "savefig.dpi": 150,
}


def condition_colors(conditions: Sequence[str]) -> dict[str, str]:
    """Stable colour per condition (known names fixed, others from a cycle)."""
    colors: dict[str, str] = {}
    i = 0
    for c in sorted(conditions):
        if c in KNOWN_COLORS:
            colors[c] = KNOWN_COLORS[c]
        else:
            colors[c] = FALLBACK_COLORS[i % len(FALLBACK_COLORS)]
            i += 1
    return colors


def _stat(values: np.ndarray, name: str) -> float:
    if values.size == 0:
        return float("nan")
    if name == "max":
        return float(values.max())
    return float(percentile(values, float(name[1:])))


def _positive_or_nan(v: float) -> float:
    """Log axes cannot show <= 0; mask such bars instead of crashing."""
    return v if v > 0 else float("nan")


def _grouped_percentile_bars(
    ds: Dataset,
    attr: str,
    stats: Sequence[str],
    ylabel: str,
    title: str,
    out: Path,
    log_y: bool = True,
) -> Path:
    colors = condition_colors(ds.conditions)
    n_cond, n_stat, n_fac = len(ds.conditions), len(stats), len(ds.factor_keys)
    width = 0.8 / max(1, n_cond * n_stat)
    x_base = np.arange(n_fac)
    with plt.rc_context(RC):
        fig, ax = plt.subplots(figsize=(max(8, 2.2 * n_fac + 2), 5.5))
        ymax = 0.0
        for ci, cond in enumerate(ds.conditions):
            for si, st in enumerate(stats):
                offset = (ci * n_stat + si) * width - 0.4 + width / 2
                heights = []
                for fk in ds.factor_keys:
                    cell = ds.get(cond, fk)
                    v = _stat(getattr(cell, attr), st) if cell else float("nan")
                    heights.append(_positive_or_nan(v) if log_y else v)
                bars = ax.bar(
                    x_base + offset, heights, width=width, color=colors[cond],
                    alpha=PCT_ALPHA.get(st, 0.8), hatch=PCT_HATCH.get(st, ""),
                    edgecolor="black", linewidth=0.5, label=f"{cond} {st}",
                )
                for bar, val in zip(bars, heights, strict=True):
                    if not np.isnan(val):
                        ymax = max(ymax, val)
                        ax.text(
                            bar.get_x() + bar.get_width() / 2, val,
                            f"{val:.1f}" if val < 100 else f"{val:.0f}",
                            ha="center", va="bottom", fontsize=6.5,
                            rotation=90 if n_cond * n_stat > 4 else 0,
                        )
        ax.set_xticks(x_base)
        ax.set_xticklabels([ds.factor_label(k) for k in ds.factor_keys])
        ax.set_ylabel(ylabel + (" (log)" if log_y else ""))
        if log_y:
            ax.set_yscale("log")
            if ymax > 0:
                ax.set_ylim(top=ymax * 4)  # headroom for the rotated value labels
        elif ymax > 0:
            ax.set_ylim(top=ymax * 1.15)
        ax.set_title(title)
        # Legend below the axes so it never hides a bar.
        ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.12),
                  ncol=max(1, n_cond * n_stat), framealpha=0.9)
        ax.grid(True, axis="y", which="both", alpha=0.3)
        fig.tight_layout()
        fig.savefig(out, bbox_inches="tight")
        plt.close(fig)
    return out


def plot_latency_percentiles(ds: Dataset, out_dir: Path) -> Path:
    return _grouped_percentile_bars(
        ds, "latency_ms", ("p50", "p99", "max"), "Latency (ms)",
        "Latency p50 / p99 / max per condition (lower is better)",
        out_dir / "fig_latency_percentiles.png",
    )


def plot_jitter_percentiles(ds: Dataset, out_dir: Path) -> Path:
    return _grouped_percentile_bars(
        ds, "jitter_us", ("p50", "p99", "max"), "|Jitter| (us)",
        "Jitter p50 / p99 / max per condition (lower is better)",
        out_dir / "fig_jitter_percentiles.png",
    )


def _panels(n: int, width: float = 5.5, height: float = 4.5) -> tuple[plt.Figure, list[plt.Axes]]:
    ncols = min(3, max(1, n))
    nrows = int(np.ceil(n / ncols))
    fig, axes = plt.subplots(nrows, ncols, figsize=(width * ncols, height * nrows), squeeze=False)
    flat = list(axes.ravel())
    for ax in flat[n:]:
        ax.set_visible(False)
    return fig, flat[:n]


def plot_latency_cdf(ds: Dataset, out_dir: Path) -> Path:
    colors = condition_colors(ds.conditions)
    out = out_dir / "fig_latency_cdf.png"
    with plt.rc_context(RC):
        fig, axes = _panels(len(ds.factor_keys))
        for ax, fk in zip(axes, ds.factor_keys, strict=True):
            plotted = False
            for cond in ds.conditions:
                cell = ds.get(cond, fk)
                if cell is None:
                    continue
                lat = np.sort(cell.latency_ms)
                cdf = np.arange(1, lat.size + 1) / lat.size
                mask = lat > 0
                ax.plot(lat[mask], cdf[mask], color=colors[cond], lw=1.8, label=cond)
                plotted = True
            if not plotted:
                ax.text(0.5, 0.5, "no data", ha="center", va="center", transform=ax.transAxes)
            ax.set_xscale("log")
            ax.set_xlabel("Latency (ms, log)")
            ax.set_ylabel("Cumulative probability")
            ax.set_ylim(0, 1.02)
            ax.set_title(ds.factor_label(fk))
            if plotted:
                ax.legend(loc="lower right")
        fig.suptitle("Latency CDF (closer to top-left is better)")
        fig.tight_layout()
        fig.savefig(out, bbox_inches="tight")
        plt.close(fig)
    return out


def plot_throughput(ds: Dataset, out_dir: Path) -> Path:
    colors = condition_colors(ds.conditions)
    out = out_dir / "fig_throughput.png"
    n_cond, n_fac = len(ds.conditions), len(ds.factor_keys)
    width = 0.8 / max(1, n_cond)
    x_base = np.arange(n_fac)
    with plt.rc_context(RC):
        fig, ax = plt.subplots(figsize=(max(7, 2.0 * n_fac + 2), 5))
        ymax = 0.0
        for ci, cond in enumerate(ds.conditions):
            heights = []
            for fk in ds.factor_keys:
                cell = ds.get(cond, fk)
                if cell is None:
                    heights.append(float("nan"))
                    continue
                per_run = [throughput_kbps(r.pkt_size, r.recv_ns) for r in cell.runs]
                heights.append(float(np.nanmean(per_run)))
            offset = ci * width - 0.4 + width / 2
            bars = ax.bar(
                x_base + offset, heights, width=width, color=colors[cond],
                edgecolor="black", linewidth=0.6, label=cond,
            )
            for bar, val in zip(bars, heights, strict=True):
                if not np.isnan(val):
                    ymax = max(ymax, val)
                    ax.text(bar.get_x() + bar.get_width() / 2, val, f"{val:.1f}",
                            ha="center", va="bottom", fontsize=7)
        ax.set_xticks(x_base)
        ax.set_xticklabels([ds.factor_label(k) for k in ds.factor_keys])
        ax.set_ylabel("Received throughput (kbit/s)")
        ax.set_ylim(0, ymax * 1.18 if ymax > 0 else 1)
        ax.set_title("Throughput = 8 * bytes / receive span")
        ax.legend(loc="upper right", ncol=max(1, n_cond // 2), framealpha=0.9)
        fig.tight_layout()
        fig.savefig(out, bbox_inches="tight")
        plt.close(fig)
    return out


def plot_latency_box(ds: Dataset, out_dir: Path) -> Path:
    colors = condition_colors(ds.conditions)
    out = out_dir / "fig_latency_box.png"
    with plt.rc_context(RC):
        fig, axes = _panels(len(ds.factor_keys))
        for ax, fk in zip(axes, ds.factor_keys, strict=True):
            data, labels, cols = [], [], []
            for cond in ds.conditions:
                cell = ds.get(cond, fk)
                if cell is None:
                    continue
                lat = cell.latency_ms
                lat = lat[lat > 0]
                if lat.size == 0:
                    continue
                data.append(lat)
                labels.append(cond)
                cols.append(colors[cond])
            if not data:
                ax.text(0.5, 0.5, "no data", ha="center", va="center", transform=ax.transAxes)
                ax.set_title(ds.factor_label(fk))
                continue
            # ``tick_labels=`` only exists from matplotlib 3.9 (``labels=`` before);
            # setting the ticks explicitly works on every supported version.
            bp = ax.boxplot(
                data, patch_artist=True, whis=(1, 99), showfliers=True,
                flierprops={"marker": ".", "markersize": 2, "alpha": 0.4},
                medianprops={"color": "black"},
            )
            ax.set_xticks(range(1, len(labels) + 1), labels)
            for patch, col in zip(bp["boxes"], cols, strict=True):
                patch.set_facecolor(col)
                patch.set_alpha(0.7)
            ax.set_yscale("log")
            ax.set_ylabel("Latency (ms, log)")
            ax.set_title(ds.factor_label(fk))
            ax.tick_params(axis="x", rotation=20)
        fig.suptitle("Latency distribution (box = IQR, whiskers = p1..p99, dots beyond)")
        fig.tight_layout()
        fig.savefig(out, bbox_inches="tight")
        plt.close(fig)
    return out


def plot_all(
    results_dir: str | Path,
    out_dir: str | Path,
    normalize_skew: bool = False,
) -> list[Path]:
    """Generate all five figures into ``out_dir``; returns the written paths."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ds = build_dataset(results_dir, normalize_skew=normalize_skew)
    if not ds.cells:
        raise ValueError(f"no CSV runs found in {results_dir}")
    return [
        plot_latency_percentiles(ds, out_dir),
        plot_jitter_percentiles(ds, out_dir),
        plot_latency_cdf(ds, out_dir),
        plot_throughput(ds, out_dir),
        plot_latency_box(ds, out_dir),
    ]

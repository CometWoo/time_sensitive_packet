"""The two figures the README shows: latency percentiles and latency CDF per condition."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from tsn_analysis.dataset import Cell, build_dataset  # noqa: E402
from tsn_analysis.metrics import percentile  # noqa: E402

FIGURE_NAMES: tuple[str, ...] = ("fig_latency_percentiles.png", "fig_latency_cdf.png")

# (colour, linestyle); conditions whose curves overlap get different dashes
KNOWN_STYLES: dict[str, tuple[str, str]] = {
    "fifo": ("#9E9E9E", "--"),
    "fq_codel": ("#7B68EE", "-"),
    "pfifo_fast_noclsf": ("#424242", "-"),
    "pfifo_fast_clsf": ("#E8734A", "-"),
    "prio_clsf": ("#A93226", "--"),
}
FALLBACK_COLORS: tuple[str, ...] = ("#1F77B4", "#2CA02C", "#8C564B", "#E377C2", "#17BECF")
STAT_COLORS: dict[str, str] = {"p50": "#1F3A5F", "p99": "#4F81B0", "max": "#B5CBE3"}

RC = {
    "font.size": 10,
    "axes.titlesize": 11,
    "legend.fontsize": 9,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
    "savefig.dpi": 150,
}


def condition_styles(conditions: Sequence[str]) -> dict[str, tuple[str, str]]:
    """Fixed style for the testbed's conditions, a colour cycle for anything else."""
    styles: dict[str, tuple[str, str]] = {}
    extra = 0
    for c in conditions:
        if c in KNOWN_STYLES:
            styles[c] = KNOWN_STYLES[c]
        else:
            styles[c] = (FALLBACK_COLORS[extra % len(FALLBACK_COLORS)], "-")
            extra += 1
    return styles


def _stat(values: np.ndarray, name: str) -> float:
    if values.size == 0:
        return float("nan")
    v = float(values.max()) if name == "max" else float(percentile(values, float(name[1:])))
    return v if v > 0 else float("nan")  # log axis


def _label(v: float) -> str:
    if v >= 100:
        return f"{v:.0f}"
    if v >= 1:
        return f"{v:.1f}"
    return f"{v:.2g}"


def plot_latency_percentiles(cells: dict[str, Cell], out_dir: Path) -> Path:
    out = out_dir / "fig_latency_percentiles.png"
    names = list(cells)
    stats = ("p50", "p99", "max")
    x = np.arange(len(names))
    width = 0.27
    with plt.rc_context(RC):
        fig, ax = plt.subplots(figsize=(1.5 * len(names) + 2, 4.6))
        top = 0.0
        for i, st in enumerate(stats):
            values = [_stat(cells[c].latency_ms, st) for c in names]
            bars = ax.bar(
                x + (i - 1) * width,
                values,
                width,
                color=STAT_COLORS[st],
                edgecolor="#333333",
                linewidth=0.4,
                label=st,
            )
            for bar, v in zip(bars, values, strict=True):
                if np.isnan(v):
                    continue
                top = max(top, v)
                ax.text(
                    bar.get_x() + bar.get_width() / 2,
                    v * 1.1,
                    _label(v),
                    ha="center",
                    va="bottom",
                    fontsize=7,
                )
        ax.set_yscale("log")
        if top > 0:
            ax.set_ylim(top=top * 6)  # room for the labels and the legend
        ax.set_xticks(x, names)
        ax.set_ylabel("one-way latency (ms, log)")
        ax.set_title("TS flow latency per condition")
        ax.grid(False, axis="x")
        ax.legend(loc="upper right", ncol=3)
        fig.tight_layout()
        fig.savefig(out)
        plt.close(fig)
    return out


def plot_latency_cdf(cells: dict[str, Cell], out_dir: Path) -> Path:
    out = out_dir / "fig_latency_cdf.png"
    styles = condition_styles(list(cells))
    with plt.rc_context(RC):
        fig, ax = plt.subplots(figsize=(7.5, 4.6))
        for cond, cell in cells.items():
            lat = np.sort(cell.latency_ms)
            frac = np.arange(1, lat.size + 1) / lat.size
            keep = lat > 0  # log axis
            color, dash = styles[cond]
            z = 3 if dash != "-" else 2  # dashed on top so an overlapped pair stays visible
            ax.plot(lat[keep], frac[keep], color=color, ls=dash, lw=1.8, label=cond, zorder=z)
        ax.set_xscale("log")
        ax.set_ylim(0, 1.02)
        ax.set_xlabel("one-way latency (ms, log)")
        ax.set_ylabel("fraction of packets")
        ax.set_title("TS flow latency CDF")
        ax.legend(loc="center left", bbox_to_anchor=(1.01, 0.5), frameon=False)
        fig.tight_layout()
        fig.savefig(out, bbox_inches="tight")
        plt.close(fig)
    return out


def plot_all(results_dir: str | Path, out_dir: str | Path) -> list[Path]:
    """Write both figures into ``out_dir`` and return their paths."""
    out_dir = Path(out_dir)
    cells = build_dataset(results_dir)
    if not cells:
        raise ValueError(f"no CSV runs found in {results_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)
    return [plot_latency_percentiles(cells, out_dir), plot_latency_cdf(cells, out_dir)]

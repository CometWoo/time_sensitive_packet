"""Grouping of runs into (condition, factor) cells shared by reports and plots."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from tsn_analysis.loader import Run, discover, factor_key, normalize_runs
from tsn_analysis.metrics import jitter_values


@dataclass
class Cell:
    """All runs of one condition at one factor combination (e.g. proposed @ cpu70).

    ``latency_ms`` and ``jitter_us`` are the per-run samples concatenated, which
    is what the pooled percentiles and the plots use; ``runs`` keeps the
    per-run arrays for throughput/loss (which only make sense per run) and for
    :func:`tsn_analysis.stats.per_run_aggregate`.
    """

    condition: str
    factors: dict[str, int]
    runs: list[Run] = field(default_factory=list)

    @property
    def factor_key(self) -> str:
        return factor_key(self.factors)

    @property
    def latency_ms(self) -> np.ndarray:
        return np.concatenate([r.latency_ms for r in self.runs])

    @property
    def jitter_us(self) -> np.ndarray:
        return np.concatenate([jitter_values(r.jitter_us) for r in self.runs])

    @property
    def n_runs(self) -> int:
        return len(self.runs)

    @property
    def skew_percentile(self) -> float | None:
        """The clock-skew percentile shared by every run, or ``None`` if not normalised."""
        values = {r.skew_percentile for r in self.runs}
        if len(values) == 1 and None not in values:
            return values.pop()
        return None

    @property
    def raw_latency_runs(self) -> list[np.ndarray]:
        """Per-run latency as read from the files (before any skew normalisation).

        Together with :attr:`skew_percentile` this is the input for the joint
        clock-skew bootstrap in :func:`tsn_analysis.stats.bootstrap_ci`.
        """
        return [
            r.raw_latency_ms if r.raw_latency_ms is not None else r.latency_ms for r in self.runs
        ]

    def latency_samples(self) -> tuple[np.ndarray | list[np.ndarray], float | None]:
        """``(values, skew_percentile)`` to hand to :func:`tsn_analysis.stats.compare`.

        Normalised cells return the raw per-run arrays plus the percentile so
        the offset is re-estimated inside every bootstrap resample; other
        cells return the pooled latency and ``None``.
        """
        sp = self.skew_percentile
        if sp is None:
            return self.latency_ms, None
        return self.raw_latency_runs, sp


@dataclass
class Dataset:
    """Every cell of a results directory plus the axis orderings used everywhere."""

    results_dir: Path
    normalize_skew: bool
    cells: dict[tuple[str, str], Cell]
    conditions: list[str]
    factor_keys: list[str]
    factor_values: dict[str, dict[str, int]]

    def get(self, condition: str, factor: str) -> Cell | None:
        return self.cells.get((condition, factor))

    def factor_label(self, key: str) -> str:
        """Human label for a factor key: ``cpu10 -> "CPU 10%"``, ``all -> "all runs"``."""
        factors = self.factor_values.get(key, {})
        if not factors:
            return "all runs"
        parts = []
        for name, value in sorted(factors.items()):
            parts.append(f"CPU {value}%" if name == "cpu" else f"{name}={value}")
        return ", ".join(parts)


def _factor_sort_key(item: tuple[str, dict[str, int]]) -> tuple[tuple[str, int], ...]:
    return tuple(sorted(item[1].items()))


def build_dataset(
    results_dir: str | Path,
    normalize_skew: bool = False,
    skew_percentile: float = 1.0,
) -> Dataset:
    """Load, optionally normalise and group all CSVs under ``results_dir``.

    ``normalize_skew`` applies :func:`tsn_analysis.loader.normalize_clock_skew`
    per run; see that function for when this is (not) appropriate.
    """
    results_dir = Path(results_dir)
    groups = discover(results_dir)
    cells: dict[tuple[str, str], Cell] = {}
    factor_values: dict[str, dict[str, int]] = {}
    for condition, runs in groups.items():
        if normalize_skew:
            runs = normalize_runs(runs, skew_percentile)
        for run in runs:
            key = (condition, run.factor_key)
            cell = cells.setdefault(key, Cell(condition=condition, factors=dict(run.factors)))
            cell.runs.append(run)
            factor_values.setdefault(run.factor_key, dict(run.factors))
    conditions = sorted(groups)
    factor_keys = [k for k, _ in sorted(factor_values.items(), key=_factor_sort_key)]
    return Dataset(
        results_dir=results_dir,
        normalize_skew=normalize_skew,
        cells=cells,
        conditions=conditions,
        factor_keys=factor_keys,
        factor_values=factor_values,
    )

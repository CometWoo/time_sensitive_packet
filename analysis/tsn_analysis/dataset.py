"""Runs grouped per condition."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from tsn_analysis.loader import Run, discover
from tsn_analysis.metrics import jitter_values

# testbed/run.sh order: FIFO baseline, fair queueing, then one 3-band qdisc without and
# with the classifier, so tables and figures put the causal pair side by side
CONDITION_ORDER: tuple[str, ...] = (
    "fifo",
    "fq_codel",
    "pfifo_fast_noclsf",
    "pfifo_fast_clsf",
    "prio_clsf",
)


@dataclass
class Cell:
    """All runs of one condition.

    Percentiles and figures use the pooled samples; loss and the per-run aggregate
    need the individual ``runs``.
    """

    condition: str
    runs: list[Run] = field(default_factory=list)

    @property
    def latency_ms(self) -> np.ndarray:
        return np.concatenate([r.latency_ms for r in self.runs])

    @property
    def jitter_us(self) -> np.ndarray:
        return np.concatenate([jitter_values(r.jitter_us) for r in self.runs])

    @property
    def n_runs(self) -> int:
        return len(self.runs)


def _order(condition: str) -> tuple[int, str]:
    if condition in CONDITION_ORDER:
        return CONDITION_ORDER.index(condition), ""
    return len(CONDITION_ORDER), condition


def build_dataset(results_dir: str | Path) -> dict[str, Cell]:
    """Condition -> Cell; the testbed's conditions first, anything else alphabetically."""
    groups = discover(results_dir)
    return {c: Cell(c, groups[c]) for c in sorted(groups, key=_order)}

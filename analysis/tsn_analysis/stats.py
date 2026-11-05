"""Comparing two conditions.

* Bootstrap CIs: a tail percentile such as p99 has no simple standard error and the
  latency here is heavy-tailed, so intervals come from a percentile bootstrap over packets.
* Mann-Whitney U rather than a t-test: the question is whether a packet from one condition
  is typically slower than one from the other, and ranks keep a few outliers from deciding it.
* Cliff's delta as the effect size: with tens of thousands of packets every p-value is tiny,
  so the p-value alone says nothing about how large the difference is.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from typing import Any

import numpy as np
from scipy import stats as sps

Statistic = Callable[[np.ndarray, int], np.ndarray]


@dataclass(frozen=True)
class BootstrapCI:
    """Point estimate with a two-sided bootstrap confidence interval."""

    point: float
    low: float
    high: float
    ci: float
    n_boot: int

    def as_dict(self) -> dict[str, float]:
        return {k: float(v) for k, v in asdict(self).items()}


def _percentile_statistic(q: float, method: str = "linear") -> Statistic:
    def stat(x: np.ndarray, axis: int) -> np.ndarray:
        return np.percentile(x, q, axis=axis, method=method)

    return stat


def resolve_statistic(stat: str | Statistic, method: str = "linear") -> Statistic:
    """Map ``"p99"``, ``"p99.9"``, ``"mean"``, ``"median"``, ``"max"``, ``"min"``, ``"std"``
    or a callable ``f(x, axis)`` to a vectorised statistic.

    ``method`` is the ``numpy.percentile`` method for percentile names, so tables and
    comparisons share one definition.
    """
    if callable(stat):
        return stat
    name = stat.lower()
    if name.startswith("p"):
        return _percentile_statistic(float(name[1:]), method)
    table: dict[str, Statistic] = {
        "mean": lambda x, axis: np.mean(x, axis=axis),
        "median": _percentile_statistic(50.0, method),
        "max": lambda x, axis: np.max(x, axis=axis),
        "min": lambda x, axis: np.min(x, axis=axis),
        "std": lambda x, axis: np.std(x, axis=axis, ddof=1),
    }
    if name not in table:
        raise ValueError(f"unknown statistic {stat!r}")
    return table[name]


def bootstrap_ci(
    values: np.ndarray,
    statistic: str | Statistic = "p99",
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    chunk: int = 200,
    method: str = "linear",
) -> BootstrapCI:
    """Percentile-bootstrap interval of ``statistic(values)``, deterministic per ``seed``.

    Resamples are drawn ``chunk`` at a time so a 30 000-packet sample never allocates
    ``n_boot x n`` floats at once.
    """
    x = np.asarray(values, dtype=np.float64).ravel()
    if x.size == 0:
        nan = float("nan")
        return BootstrapCI(nan, nan, nan, ci, n_boot)
    stat = resolve_statistic(statistic, method)
    point = float(stat(x[None, :], 1)[0])
    if x.size == 1 or n_boot <= 0:
        return BootstrapCI(point, point, point, ci, n_boot)
    rng = np.random.default_rng(seed)
    boots = np.empty(n_boot, dtype=np.float64)
    done = 0
    while done < n_boot:
        k = min(chunk, n_boot - done)
        boots[done : done + k] = stat(x[rng.integers(0, x.size, size=(k, x.size))], 1)
        done += k
    alpha = (1.0 - ci) / 2.0
    low, high = np.percentile(boots, [100.0 * alpha, 100.0 * (1.0 - alpha)], method="linear")
    return BootstrapCI(point, float(low), float(high), ci, n_boot)


def mann_whitney(a: np.ndarray, b: np.ndarray) -> tuple[float, float]:
    """Two-sided Mann-Whitney U test; returns ``(U, p)`` with U for sample ``a``."""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    if a.size == 0 or b.size == 0:
        return float("nan"), float("nan")
    res = sps.mannwhitneyu(a, b, alternative="two-sided")
    return float(res.statistic), float(res.pvalue)


def cliffs_delta(a: np.ndarray, b: np.ndarray) -> float:
    """``P(a > b) - P(a < b)`` in O((n+m) log(n+m)); ties count zero.

    ``b`` is sorted once and ``searchsorted`` counts, for every element of ``a``, how many
    ``b`` are strictly smaller and strictly larger.
    """
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.sort(np.asarray(b, dtype=np.float64).ravel())
    if a.size == 0 or b.size == 0:
        return float("nan")
    less = np.searchsorted(b, a, side="left")  # b < a
    greater = b.size - np.searchsorted(b, a, side="right")  # b > a
    return float((less.sum() - greater.sum()) / (a.size * b.size))


def describe_delta(delta: float) -> str:
    """Verbal label for |delta| (Romano et al. 2006 thresholds)."""
    d = abs(delta)
    if np.isnan(d):
        return "n/a"
    if d < 0.147:
        return "negligible"
    if d < 0.33:
        return "small"
    if d < 0.474:
        return "medium"
    return "large"


def compare(
    baseline_values: np.ndarray,
    proposed_values: np.ndarray,
    stat: str | Statistic = "p99",
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    method: str = "linear",
) -> dict[str, Any]:
    """Compare two samples on one statistic.

    ``improvement_pct`` is ``(baseline - proposed) / baseline * 100``, positive when the
    proposed side is lower. ``cliffs_delta`` is baseline vs proposed, positive when
    baseline packets tend to be slower.
    """
    b = bootstrap_ci(baseline_values, stat, n_boot, ci, seed, method=method)
    p = bootstrap_ci(proposed_values, stat, n_boot, ci, seed + 1, method=method)
    if b.point != 0 and not np.isnan(b.point):
        improvement = (b.point - p.point) / abs(b.point) * 100.0
    else:
        improvement = float("nan")
    base = np.asarray(baseline_values, dtype=np.float64).ravel()
    prop = np.asarray(proposed_values, dtype=np.float64).ravel()
    u, pval = mann_whitney(base, prop)
    delta = cliffs_delta(base, prop)
    stat_name = stat if isinstance(stat, str) else getattr(stat, "__name__", "custom")
    return {
        "stat": stat_name,
        "percentile_method": method,
        "baseline": b.as_dict(),
        "proposed": p.as_dict(),
        "improvement_pct": float(improvement),
        "mann_whitney_u": u,
        "p_value": pval,
        "cliffs_delta": delta,
        "effect": describe_delta(delta),
        "n_baseline": int(base.size),
        "n_proposed": int(prop.size),
    }


def per_run_aggregate(
    runs_values: Sequence[np.ndarray],
    stat: str | Statistic = "p99",
    ci: float = 0.95,
    method: str = "linear",
) -> dict[str, Any]:
    """Mean of a per-run statistic over repeated runs.

    Runs are the unit of replication for run-to-run effects that a bootstrap over packets
    cannot see. The Student-t interval needs at least three runs; below that it is ``nan``.
    """
    f = resolve_statistic(stat, method)
    per_run = np.asarray(
        [float(f(np.asarray(v, dtype=np.float64)[None, :], 1)[0]) for v in runs_values],
        dtype=np.float64,
    )
    n = per_run.size
    out: dict[str, Any] = {
        "stat": stat if isinstance(stat, str) else "custom",
        "n_runs": int(n),
        "per_run": [float(v) for v in per_run],
        "mean": float(per_run.mean()) if n else float("nan"),
        "std": float(per_run.std(ddof=1)) if n > 1 else float("nan"),
        "ci_low": float("nan"),
        "ci_high": float("nan"),
        "ci": ci,
    }
    if n >= 3:
        half = sps.t.ppf(0.5 + ci / 2.0, df=n - 1) * per_run.std(ddof=1) / np.sqrt(n)
        out["ci_low"] = float(per_run.mean() - half)
        out["ci_high"] = float(per_run.mean() + half)
    return out

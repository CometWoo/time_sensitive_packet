"""Inferential statistics for comparing two conditions.

Design notes
------------
* **Bootstrap confidence intervals** (:func:`bootstrap_ci`).  A tail
  percentile such as p99 has no simple closed-form standard error, and the
  latency distributions here are heavy-tailed (a handful of packets at
  1000+ ms next to a median of ~1 ms), so normal-theory intervals would be
  wrong.  The non-parametric percentile bootstrap only assumes the packets
  are exchangeable, which is what a single run gives us.
* **Mann-Whitney U** (:func:`mann_whitney`) instead of Student's t.  The t-test
  compares means and assumes finite, similar variances; with heavy tails the
  mean is dominated by a few outliers (see the README: one 1.7 s packet moves
  the mean but not p99).  The rank-based U test asks "is a random packet from
  A typically slower than one from B?", which is the practical question and is
  robust to the tail.
* **Cliff's delta** (:func:`cliffs_delta`) as the effect size.  With 10 000
  packets per run every p-value is tiny, so a p-value alone says nothing about
  *how much* better a condition is; delta = P(a > b) - P(a < b) does, on a
  scale from -1 to +1, and is directly comparable across CPU loads.
* **Clock-skew offset is bootstrapped jointly** (``skew_percentile``).  When a
  run has been normalised by subtracting its own 1st percentile, the reported
  statistic is really ``pXX(run) - p1(run)`` and *both* terms are estimated
  from the same sample.  Resampling the already-shifted values would treat
  the offset as a known constant and understate the interval (about 2x too
  narrow for p50 on the real data; negligible for p99, whose variance
  dominates).  :func:`bootstrap_ci` therefore accepts the *raw* per-run
  samples plus ``skew_percentile`` and recomputes the offset inside every
  resample, run by run, before pooling.
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
    """Map a name (``"p99"``, ``"p99.9"``, ``"mean"``, ``"median"``, ``"max"``, ``"std"``)
    or a callable ``f(x, axis)`` to a vectorised statistic.

    ``method`` is the ``numpy.percentile`` method used for percentile names, so
    descriptive tables and comparisons can share one definition.
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


def _as_runs(values: np.ndarray | Sequence[np.ndarray]) -> list[np.ndarray]:
    """Normalise ``values`` to a list of 1-D float arrays (one per run).

    A single array (any shape) is one run; a list/tuple of array-likes is one
    run per element.  Empty runs are dropped.
    """
    if isinstance(values, (list, tuple)) and values and np.ndim(values[0]) >= 1:
        runs = [np.asarray(v, dtype=np.float64).ravel() for v in values]
    else:
        runs = [np.asarray(values, dtype=np.float64).ravel()]
    return [r for r in runs if r.size > 0]


def _shift(x: np.ndarray, skew_percentile: float | None) -> np.ndarray:
    """Subtract each row's own ``skew_percentile`` from ``x`` (2-D, rows = resamples).

    The offset always uses numpy's ``linear`` method, matching
    :func:`tsn_analysis.loader.normalize_clock_skew`, regardless of the method
    chosen for the reported statistic - the shift is part of the data
    definition, not of the summary statistic.
    """
    if skew_percentile is None:
        return x
    return x - np.percentile(x, skew_percentile, axis=1, method="linear", keepdims=True)


def pooled_values(
    values: np.ndarray | Sequence[np.ndarray],
    skew_percentile: float | None = None,
) -> np.ndarray:
    """Concatenate runs, first subtracting each run's own ``skew_percentile``
    when one is given (the same transform as
    :func:`tsn_analysis.loader.normalize_clock_skew`)."""
    runs = _as_runs(values)
    if not runs:
        return np.empty(0, dtype=np.float64)
    return np.concatenate([_shift(r[None, :], skew_percentile)[0] for r in runs])


def bootstrap_ci(
    values: np.ndarray | Sequence[np.ndarray],
    statistic: str | Statistic = "p99",
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    chunk: int = 200,
    method: str = "linear",
    skew_percentile: float | None = None,
) -> BootstrapCI:
    """Percentile-bootstrap confidence interval of ``statistic(values)``.

    ``values`` is either one sample or a sequence of per-run samples.
    Resamples ``n_boot`` times with replacement (vectorised in chunks of
    ``chunk`` resamples so a 10 000-sample run does not allocate
    ``n_boot x n`` floats at once) and returns the ``(1-ci)/2`` and
    ``(1+ci)/2`` quantiles of the bootstrap distribution.  Deterministic for a
    given ``seed``.

    ``skew_percentile`` enables the *joint* clock-skew bootstrap: ``values``
    must then be the **raw** per-run latencies, and every resample is drawn
    within each run, shifted by that resample's own ``skew_percentile``, and
    pooled before ``statistic`` is applied.  The point estimate is the
    statistic of the runs shifted by their observed offsets, i.e. identical to
    what :func:`tsn_analysis.loader.normalize_runs` followed by a plain
    bootstrap would report - only the interval changes, because the offset's
    sampling variance is now included.  Without ``skew_percentile`` the runs
    are simply pooled and resampled as one sample.
    """
    runs = _as_runs(values)
    if not runs:
        nan = float("nan")
        return BootstrapCI(nan, nan, nan, ci, n_boot)
    stat = resolve_statistic(statistic, method)
    if skew_percentile is None:
        runs = [np.concatenate(runs)]
    pooled = np.concatenate([_shift(r[None, :], skew_percentile)[0] for r in runs])
    point = float(stat(pooled[None, :], 1)[0])
    if pooled.size == 1 or n_boot <= 0:
        return BootstrapCI(point, point, point, ci, n_boot)
    rng = np.random.default_rng(seed)
    boots = np.empty(n_boot, dtype=np.float64)
    done = 0
    while done < n_boot:
        k = min(chunk, n_boot - done)
        parts = [
            _shift(r[rng.integers(0, r.size, size=(k, r.size))], skew_percentile)
            for r in runs
        ]
        sample = parts[0] if len(parts) == 1 else np.concatenate(parts, axis=1)
        boots[done : done + k] = stat(sample, 1)
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
    """Cliff's delta ``P(a > b) - P(a < b)`` in O((n+m) log(n+m)).

    Sorts ``b`` once and uses ``searchsorted`` to count, for every element of
    ``a``, how many ``b`` are strictly smaller / strictly larger.  Ties
    contribute zero.  +1 means every ``a`` exceeds every ``b``; -1 the reverse;
    0 for identical distributions.
    """
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.sort(np.asarray(b, dtype=np.float64).ravel())
    if a.size == 0 or b.size == 0:
        return float("nan")
    less = np.searchsorted(b, a, side="left")  # b < a
    greater = b.size - np.searchsorted(b, a, side="right")  # b > a
    return float((less.sum() - greater.sum()) / (a.size * b.size))


def cliffs_delta_bruteforce(a: np.ndarray, b: np.ndarray) -> float:
    """O(n*m) reference implementation, used only to test :func:`cliffs_delta`."""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    diff = np.sign(a[:, None] - b[None, :])
    return float(diff.sum() / (a.size * b.size))


def describe_delta(delta: float) -> str:
    """Conventional verbal label for |delta| (Romano et al. 2006 thresholds)."""
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
    baseline_values: np.ndarray | Sequence[np.ndarray],
    proposed_values: np.ndarray | Sequence[np.ndarray],
    stat: str | Statistic = "p99",
    n_boot: int = 2000,
    ci: float = 0.95,
    seed: int = 0,
    method: str = "linear",
    skew_percentile: float | None = None,
) -> dict[str, Any]:
    """Compare two samples on one statistic.

    Returns point estimates and bootstrap CIs for both sides, the improvement
    in percent (``(baseline - proposed) / baseline * 100``; positive means the
    proposed condition is *lower*, i.e. better for latency/jitter), the
    two-sided Mann-Whitney U and p-value, and Cliff's delta of baseline vs
    proposed (positive when baseline packets tend to be slower).

    ``method`` is the percentile definition shared with the descriptive tables.
    With ``skew_percentile`` the inputs are raw per-run latencies (see
    :func:`bootstrap_ci`); the rank tests then run on the per-run shifted,
    pooled values, exactly as the summary tables do.
    """
    b = bootstrap_ci(
        baseline_values, stat, n_boot, ci, seed, method=method, skew_percentile=skew_percentile
    )
    p = bootstrap_ci(
        proposed_values, stat, n_boot, ci, seed + 1, method=method, skew_percentile=skew_percentile
    )
    if b.point != 0 and not np.isnan(b.point):
        improvement = (b.point - p.point) / abs(b.point) * 100.0
    else:
        improvement = float("nan")
    base_pooled = pooled_values(baseline_values, skew_percentile)
    prop_pooled = pooled_values(proposed_values, skew_percentile)
    u, pval = mann_whitney(base_pooled, prop_pooled)
    delta = cliffs_delta(base_pooled, prop_pooled)
    stat_name = stat if isinstance(stat, str) else getattr(stat, "__name__", "custom")
    return {
        "stat": stat_name,
        "percentile_method": method,
        "skew_percentile": skew_percentile,
        "baseline": b.as_dict(),
        "proposed": p.as_dict(),
        "improvement_pct": float(improvement),
        "mann_whitney_u": u,
        "p_value": pval,
        "cliffs_delta": delta,
        "effect": describe_delta(delta),
        "n_baseline": int(base_pooled.size),
        "n_proposed": int(prop_pooled.size),
    }


def per_run_aggregate(
    runs_values: Sequence[np.ndarray],
    stat: str | Statistic = "p99",
    ci: float = 0.95,
    method: str = "linear",
) -> dict[str, Any]:
    """Aggregate a statistic over repeated runs (mean of per-run values).

    Repeated runs are the right unit of replication for run-to-run effects
    (scheduler state, background load) that a within-run bootstrap cannot see.
    With at least three runs a Student-t interval on the mean of the per-run
    statistics is returned; with fewer runs the interval is ``nan`` because
    the variance estimate would be meaningless.
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

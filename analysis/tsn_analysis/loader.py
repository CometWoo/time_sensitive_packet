"""CSV loading and file-name parsing for measurement runs.

Two naming schemes are understood (``<stem>.csv``):

* ``<mode>_cpu<N>``  - legacy two-VM testbed, e.g. ``baseline_cpu10``.
  ``condition = mode`` and a *factor* ``cpu = N`` (background CPU load in %).
* ``<cond>_run<k>``  - new local testbed, e.g. ``fq_codel_run3``.
  ``condition = cond`` and ``run_index = k``.
* ``<cond>``          - a plain condition name with neither suffix.

The suffixes may be combined (``<cond>_cpu<N>_run<k>``); they are stripped from
the right, so a condition name may itself contain underscores
(``pfifo_fast_noclass``).

CSV columns: ``seq,send_ns,recv_ns,latency_ms,jitter_us,pkt_size[,tos]``.
``tos`` (received IP TOS byte, for DSCP verification) is optional.
"""

from __future__ import annotations

import csv
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

REQUIRED_COLUMNS: tuple[str, ...] = (
    "seq",
    "send_ns",
    "recv_ns",
    "latency_ms",
    "jitter_us",
    "pkt_size",
)

_RUN_SUFFIX = re.compile(r"^(?P<stem>.+?)_run(?P<k>\d+)$")
_CPU_SUFFIX = re.compile(r"^(?P<stem>.+?)_cpu(?P<n>\d+)$")


@dataclass(frozen=True)
class RunName:
    """Parsed pieces of a result-file stem."""

    condition: str
    run_index: int | None
    factors: dict[str, int]

    @property
    def factor_key(self) -> str:
        """Stable string key for the factor combination (``cpu10`` or ``all``)."""
        return factor_key(self.factors)


def factor_key(factors: dict[str, int]) -> str:
    """Render a factor dict as a compact key, e.g. ``{"cpu": 10} -> "cpu10"``.

    Runs without any factor share the key ``"all"``.
    """
    if not factors:
        return "all"
    return "_".join(f"{k}{v}" for k, v in sorted(factors.items()))


def parse_name(stem: str) -> RunName:
    """Parse a file stem into condition / run index / factors.

    >>> parse_name("baseline_cpu10")
    RunName(condition='baseline', run_index=None, factors={'cpu': 10})
    >>> parse_name("pfifo_fast_noclass_run2")
    RunName(condition='pfifo_fast_noclass', run_index=2, factors={})
    >>> parse_name("pfifo")
    RunName(condition='pfifo', run_index=None, factors={})
    """
    run_index: int | None = None
    factors: dict[str, int] = {}
    m = _RUN_SUFFIX.match(stem)
    if m:
        run_index = int(m.group("k"))
        stem = m.group("stem")
    m = _CPU_SUFFIX.match(stem)
    if m:
        factors["cpu"] = int(m.group("n"))
        stem = m.group("stem")
    if not stem:
        raise ValueError(f"empty condition name in stem {stem!r}")
    return RunName(condition=stem, run_index=run_index, factors=factors)


@dataclass
class Run:
    """One measurement run (one CSV file) held as numpy arrays.

    ``latency_ms`` is stored exactly as found in the file; clock-skew
    normalisation is a separate, explicit step (:func:`normalize_clock_skew`).
    """

    name: str
    condition: str
    run_index: int | None
    factors: dict[str, int]
    seq: np.ndarray
    send_ns: np.ndarray
    recv_ns: np.ndarray
    latency_ms: np.ndarray
    jitter_us: np.ndarray
    pkt_size: np.ndarray
    tos: np.ndarray | None = None
    path: Path | None = None
    clock_skew_ms: float | None = field(default=None)
    skew_percentile: float | None = field(default=None)
    raw_latency_ms: np.ndarray | None = field(default=None)

    @property
    def factor_key(self) -> str:
        return factor_key(self.factors)

    def __len__(self) -> int:
        return int(self.seq.shape[0])

    @property
    def is_normalized(self) -> bool:
        """True once :func:`normalize_clock_skew` has been applied to this run."""
        return self.skew_percentile is not None

    def with_latency(
        self,
        latency_ms: np.ndarray,
        clock_skew_ms: float | None,
        skew_percentile: float | None = None,
    ) -> Run:
        """Return a copy with a replaced latency column (used by skew normalisation).

        The latency as read from the file is kept in ``raw_latency_ms`` so the
        joint clock-skew bootstrap (:func:`tsn_analysis.stats.bootstrap_ci`)
        can re-estimate the offset inside every resample.
        """
        raw = self.raw_latency_ms if self.raw_latency_ms is not None else self.latency_ms
        return Run(
            name=self.name,
            condition=self.condition,
            run_index=self.run_index,
            factors=dict(self.factors),
            seq=self.seq,
            send_ns=self.send_ns,
            recv_ns=self.recv_ns,
            latency_ms=latency_ms,
            jitter_us=self.jitter_us,
            pkt_size=self.pkt_size,
            tos=self.tos,
            path=self.path,
            clock_skew_ms=clock_skew_ms,
            skew_percentile=skew_percentile,
            raw_latency_ms=raw,
        )


def _to_int(value: str) -> int:
    """Parse an integer cell exactly.

    Epoch nanoseconds (~1.7e18) exceed 2^53, so going through ``float`` would
    round them to multiples of 256 ns and corrupt inter-arrival gaps; only a
    cell written with a decimal point or exponent falls back to ``float``.
    """
    v = value.strip()
    if v.lstrip("+-").isdigit():
        return int(v)
    return int(float(v))


def _to_int_array(values: list[str]) -> np.ndarray:
    return np.asarray([_to_int(v) for v in values], dtype=np.int64)


def _to_float_array(values: list[str]) -> np.ndarray:
    return np.asarray([float(v) for v in values], dtype=np.float64)


def load_csv(path: str | Path) -> Run:
    """Load one result CSV into a :class:`Run`.

    Raises ``ValueError`` when a required column is missing or the file has no rows.
    The optional ``tos`` column is parsed when present (empty cells become -1).
    """
    path = Path(path)
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        header = reader.fieldnames or []
        missing = [c for c in REQUIRED_COLUMNS if c not in header]
        if missing:
            raise ValueError(f"{path}: missing columns {missing}")
        columns: dict[str, list[str]] = {c: [] for c in header}
        for row in reader:
            for c in header:
                columns[c].append(row[c] if row[c] is not None else "")
    if not columns["seq"]:
        raise ValueError(f"{path}: no data rows")

    tos: np.ndarray | None = None
    if "tos" in columns:
        tos = np.asarray(
            [_to_int(v) if v.strip() else -1 for v in columns["tos"]], dtype=np.int64
        )

    parsed = parse_name(path.stem)
    return Run(
        name=path.stem,
        condition=parsed.condition,
        run_index=parsed.run_index,
        factors=parsed.factors,
        seq=_to_int_array(columns["seq"]),
        send_ns=_to_int_array(columns["send_ns"]),
        recv_ns=_to_int_array(columns["recv_ns"]),
        latency_ms=_to_float_array(columns["latency_ms"]),
        jitter_us=_to_float_array(columns["jitter_us"]),
        pkt_size=_to_int_array(columns["pkt_size"]),
        tos=tos,
        path=path,
    )


def _sort_key(run: Run) -> tuple[tuple[str, int], ...]:
    factors = tuple(sorted(run.factors.items()))
    return (*factors, ("run", run.run_index if run.run_index is not None else -1))


def discover(directory: str | Path, pattern: str = "*.csv") -> dict[str, list[Run]]:
    """Load every CSV in ``directory`` and group the runs by condition.

    Within a condition the runs are ordered by factor value then run index.
    Files that fail to parse raise immediately - a silently skipped run would
    bias every downstream statistic.
    """
    directory = Path(directory)
    groups: dict[str, list[Run]] = {}
    for path in sorted(directory.glob(pattern)):
        run = load_csv(path)
        groups.setdefault(run.condition, []).append(run)
    for runs in groups.values():
        runs.sort(key=_sort_key)
    return dict(sorted(groups.items()))


def normalize_clock_skew(
    latency_ms: np.ndarray, percentile: float = 1.0
) -> tuple[np.ndarray, float]:
    """Subtract a low percentile of the latency so the run starts near zero.

    Why this exists: the legacy testbed timestamped ``send_ns`` on one VM and
    ``recv_ns`` on another.  The two clocks were offset by tens of milliseconds,
    which made the raw one-way latency *negative*.  Subtracting the 1st
    percentile (rather than the minimum, which is a single sample and hence
    noisy) removes that constant offset so distributions from different runs
    become comparable in *shape* and *spread*.

    What it destroys: any absolute meaning of the latency.  After
    normalisation "p50 = 1.2 ms" means "1.2 ms above the fastest 1 % of
    packets", not "1.2 ms end-to-end".  Within a run, percentile *differences*
    (p99 - p50, tail width) are unaffected because every packet of that run is
    shifted by the same constant.  Across runs the caveat is stronger: each
    run is shifted by its *own* p1, so comparisons between conditions (p50,
    p99, Mann-Whitney, Cliff's delta) are comparisons of the distribution
    *above each run's floor*.  Any real location difference between
    conditions - a fixed per-packet overhead of one data path, or a different
    floor - is removed by construction and cannot be recovered.  Do **not**
    use it when both timestamps come from the same clock (the new local
    testbed), where the raw latency is meaningful as is.

    The offset is itself an estimate from the run; see
    :func:`tsn_analysis.stats.bootstrap_ci` (``skew_percentile``) for
    confidence intervals that account for its sampling variance.

    Returns ``(normalised_latency, offset_ms)``.
    """
    latency_ms = np.asarray(latency_ms, dtype=np.float64)
    if latency_ms.size == 0:
        return latency_ms.copy(), 0.0
    offset = float(np.percentile(latency_ms, percentile, method="linear"))
    return latency_ms - offset, offset


def normalize_runs(runs: Iterable[Run], percentile: float = 1.0) -> list[Run]:
    """Apply :func:`normalize_clock_skew` to each run independently."""
    out: list[Run] = []
    for run in runs:
        lat, offset = normalize_clock_skew(run.latency_ms, percentile)
        out.append(run.with_latency(lat, offset, skew_percentile=percentile))
    return out

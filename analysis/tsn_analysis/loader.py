"""Read listener CSVs (``<condition>_run<k>.csv``) into numpy arrays.

Columns: ``seq,send_ns,recv_ns,latency_ms,jitter_us,pkt_size`` and an optional
``tos`` (received IP TOS byte). Other columns, such as ``recv_kernel_ns``, are ignored.
"""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass
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

_RUN_SUFFIX = re.compile(r"^(?P<condition>.+?)_run(?P<k>\d+)$")


def parse_name(stem: str) -> tuple[str, int | None]:
    """Split a file stem into condition and run index.

    >>> parse_name("pfifo_fast_clsf_run2")
    ('pfifo_fast_clsf', 2)
    >>> parse_name("fifo")
    ('fifo', None)
    """
    m = _RUN_SUFFIX.match(stem)
    if m is None:
        return stem, None
    return m.group("condition"), int(m.group("k"))


@dataclass
class Run:
    """One listener CSV."""

    name: str
    condition: str
    run_index: int | None
    seq: np.ndarray
    send_ns: np.ndarray
    recv_ns: np.ndarray
    latency_ms: np.ndarray
    jitter_us: np.ndarray
    pkt_size: np.ndarray
    tos: np.ndarray | None = None
    path: Path | None = None

    def __len__(self) -> int:
        return int(self.seq.shape[0])


def _to_int(value: str) -> int:
    # epoch ns (~1.8e18) is past 2**53; a float round trip would snap it to 256 ns steps
    v = value.strip()
    if v.lstrip("+-").isdigit():
        return int(v)
    return int(float(v))


def _ints(values: list[str]) -> np.ndarray:
    return np.asarray([_to_int(v) for v in values], dtype=np.int64)


def _floats(values: list[str]) -> np.ndarray:
    return np.asarray([float(v) for v in values], dtype=np.float64)


def load_csv(path: str | Path) -> Run:
    """Load one CSV; empty ``tos`` cells become -1.

    Raises ``ValueError`` when a required column is missing or there are no rows.
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

    tos = None
    if "tos" in columns:
        tos = np.asarray([_to_int(v) if v.strip() else -1 for v in columns["tos"]], dtype=np.int64)

    condition, run_index = parse_name(path.stem)
    return Run(
        name=path.stem,
        condition=condition,
        run_index=run_index,
        seq=_ints(columns["seq"]),
        send_ns=_ints(columns["send_ns"]),
        recv_ns=_ints(columns["recv_ns"]),
        latency_ms=_floats(columns["latency_ms"]),
        jitter_us=_floats(columns["jitter_us"]),
        pkt_size=_ints(columns["pkt_size"]),
        tos=tos,
        path=path,
    )


def discover(directory: str | Path) -> dict[str, list[Run]]:
    """Load every ``*.csv`` in ``directory``, grouped by condition, runs in index order.

    A file that does not parse raises instead of being skipped; a silently missing
    run would bias every statistic computed from the rest.
    """
    groups: dict[str, list[Run]] = {}
    for path in sorted(Path(directory).glob("*.csv")):
        run = load_csv(path)
        groups.setdefault(run.condition, []).append(run)
    for runs in groups.values():
        runs.sort(key=lambda r: -1 if r.run_index is None else r.run_index)
    return groups

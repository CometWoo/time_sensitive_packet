from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.loader import _to_int, discover, load_csv, parse_name

from .conftest import write_run_csv


@pytest.mark.parametrize(
    ("stem", "condition", "run_index"),
    [
        ("fifo_run3", "fifo", 3),
        ("pfifo_fast_noclsf_run12", "pfifo_fast_noclsf", 12),
        ("fifo", "fifo", None),
        ("a_run1_run2", "a_run1", 2),
    ],
)
def test_parse_name(stem, condition, run_index):
    assert parse_name(stem) == (condition, run_index)


def test_load_csv_without_tos(tmp_path: Path):
    lat = np.array([1.0, 2.0, 3.0, 4.0])
    run = load_csv(write_run_csv(tmp_path / "fifo_run1.csv", lat, pkt_size=200))
    assert run.name == "fifo_run1"
    assert run.condition == "fifo" and run.run_index == 1
    assert run.tos is None
    assert len(run) == 4
    np.testing.assert_allclose(run.latency_ms, lat)
    assert run.pkt_size.dtype.kind == "i" and (run.pkt_size == 200).all()
    assert run.seq.tolist() == [0, 1, 2, 3]
    assert run.jitter_us[0] == 0.0


def test_load_csv_with_tos(tmp_path: Path):
    tos = np.array([184, 184, 0, 184, 184])
    run = load_csv(write_run_csv(tmp_path / "prio_clsf_run2.csv", np.ones(5), tos=tos))
    assert run.condition == "prio_clsf" and run.run_index == 2
    assert run.tos is not None and run.tos.tolist() == tos.tolist()


def test_load_csv_missing_column(tmp_path: Path):
    p = tmp_path / "bad_run1.csv"
    p.write_text("seq,send_ns\n0,1\n", encoding="utf-8")
    with pytest.raises(ValueError, match="missing columns"):
        load_csv(p)


def test_load_csv_empty(tmp_path: Path):
    p = tmp_path / "empty_run1.csv"
    p.write_text("seq,send_ns,recv_ns,latency_ms,jitter_us,pkt_size\n", encoding="utf-8")
    with pytest.raises(ValueError, match="no data rows"):
        load_csv(p)


def test_discover(run_dir: Path):
    groups = discover(run_dir)
    assert set(groups) == {"fifo", "pfifo_fast_noclsf", "prio_clsf"}
    assert [r.run_index for r in groups["fifo"]] == [1, 2, 3]
    assert all(r.tos is not None for r in groups["prio_clsf"])


def test_load_csv_timestamps_are_exact_integers(tmp_path: Path):
    """Epoch-ns values (> 2^53) must not pass through float64 (rounds to 256 ns)."""
    t0 = 1_700_000_000_000_000_000
    lat = np.array([1.000001, 1.000003, 1.000002])
    run = load_csv(write_run_csv(tmp_path / "fifo_run1.csv", lat, t0_ns=t0))
    expected_send = [t0, t0 + 1_000_000, t0 + 2_000_000]
    assert run.send_ns.tolist() == expected_send
    expected_recv = [s + int(v * 1e6) for s, v in zip(expected_send, lat, strict=True)]
    assert run.recv_ns.tolist() == expected_recv
    assert run.send_ns.dtype == np.int64


def test_to_int_accepts_float_cells():
    assert _to_int("1700000000000000001") == 1700000000000000001
    assert _to_int(" 12 ") == 12
    assert _to_int("-3") == -3
    assert _to_int("128.0") == 128
    assert _to_int("1e3") == 1000

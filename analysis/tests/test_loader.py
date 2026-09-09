from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.loader import (
    discover,
    factor_key,
    load_csv,
    normalize_clock_skew,
    normalize_runs,
    parse_name,
)

from .conftest import write_run_csv


@pytest.mark.parametrize(
    ("stem", "condition", "run_index", "factors"),
    [
        ("baseline_cpu10", "baseline", None, {"cpu": 10}),
        ("proposed_cpu99", "proposed", None, {"cpu": 99}),
        ("pfifo_run3", "pfifo", 3, {}),
        ("pfifo_fast_noclass_run12", "pfifo_fast_noclass", 12, {}),
        ("fq_codel_cpu50_run2", "fq_codel", 2, {"cpu": 50}),
        ("pfifo", "pfifo", None, {}),
        ("prio_class", "prio_class", None, {}),
    ],
)
def test_parse_name(stem, condition, run_index, factors):
    parsed = parse_name(stem)
    assert parsed.condition == condition
    assert parsed.run_index == run_index
    assert parsed.factors == factors


def test_factor_key():
    assert factor_key({}) == "all"
    assert factor_key({"cpu": 10}) == "cpu10"
    assert parse_name("x_cpu70").factor_key == "cpu70"


def test_load_csv_without_tos(tmp_path: Path):
    lat = np.array([1.0, 2.0, 3.0, 4.0])
    p = write_run_csv(tmp_path / "baseline_cpu30.csv", lat, pkt_size=200)
    run = load_csv(p)
    assert run.name == "baseline_cpu30"
    assert run.condition == "baseline"
    assert run.factors == {"cpu": 30}
    assert run.run_index is None
    assert run.tos is None
    assert len(run) == 4
    np.testing.assert_allclose(run.latency_ms, lat)
    assert run.pkt_size.dtype.kind == "i"
    assert (run.pkt_size == 200).all()
    assert run.seq.tolist() == [0, 1, 2, 3]
    assert run.jitter_us[0] == 0.0
    assert run.clock_skew_ms is None


def test_load_csv_with_tos(tmp_path: Path):
    lat = np.ones(5)
    tos = np.array([184, 184, 0, 184, 184])
    p = write_run_csv(tmp_path / "prio_class_run2.csv", lat, tos=tos)
    run = load_csv(p)
    assert run.condition == "prio_class"
    assert run.run_index == 2
    assert run.tos is not None
    assert run.tos.tolist() == tos.tolist()


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


def test_discover_legacy(legacy_dir: Path):
    groups = discover(legacy_dir)
    assert list(groups) == ["baseline", "proposed"]
    assert [r.factors["cpu"] for r in groups["baseline"]] == [10, 50]
    assert [r.factors["cpu"] for r in groups["proposed"]] == [10, 50, 99]


def test_discover_newstyle(newstyle_dir: Path):
    groups = discover(newstyle_dir)
    assert list(groups) == ["pfifo", "pfifo_fast_noclass", "prio_class"]
    assert [r.run_index for r in groups["pfifo"]] == [1, 2, 3]
    assert all(r.factor_key == "all" for r in groups["prio_class"])
    assert all(r.tos is not None for r in groups["prio_class"])


def test_normalize_clock_skew():
    lat = np.array([-12.0, -11.0, -10.0, -9.0, 5.0])
    norm, offset = normalize_clock_skew(lat, percentile=0.0)
    assert offset == -12.0
    np.testing.assert_allclose(norm, lat + 12.0)
    norm1, offset1 = normalize_clock_skew(lat, percentile=1.0)
    assert offset1 == pytest.approx(np.percentile(lat, 1.0))
    assert np.percentile(norm1, 1.0) == pytest.approx(0.0, abs=1e-12)
    # empty input is a no-op
    e, o = normalize_clock_skew(np.array([]))
    assert e.size == 0 and o == 0.0


def test_normalize_runs_records_offset(tmp_path: Path):
    lat = np.linspace(-20.0, -10.0, 100)
    run = load_csv(write_run_csv(tmp_path / "baseline_cpu10.csv", lat))
    (norm,) = normalize_runs([run])
    assert norm.clock_skew_ms == pytest.approx(np.percentile(lat, 1))
    assert norm.latency_ms.min() > -1.0
    # original untouched (pure function)
    assert run.clock_skew_ms is None
    np.testing.assert_allclose(run.latency_ms, lat)


def test_load_csv_timestamps_are_exact_integers(tmp_path: Path):
    """Epoch-ns values (> 2^53) must not pass through float64 (rounds to 256 ns)."""
    t0 = 1_700_000_000_000_000_000
    lat = np.array([1.000001, 1.000003, 1.000002])
    p = write_run_csv(tmp_path / "pfifo_run1.csv", lat, t0_ns=t0)
    run = load_csv(p)
    expected_send = [t0, t0 + 1_000_000, t0 + 2_000_000]
    assert run.send_ns.tolist() == expected_send
    expected_recv = [s + int(v * 1e6) for s, v in zip(expected_send, lat, strict=True)]
    assert run.recv_ns.tolist() == expected_recv
    assert run.send_ns.dtype == np.int64


def test_to_int_accepts_float_cells():
    from tsn_analysis.loader import _to_int

    assert _to_int("1700000000000000001") == 1700000000000000001
    assert _to_int(" 12 ") == 12
    assert _to_int("-3") == -3
    assert _to_int("128.0") == 128
    assert _to_int("1e3") == 1000


def test_normalize_runs_keeps_raw_latency(tmp_path: Path):
    lat = np.array([-30.0, -29.0, -28.0, -20.0, 5.0])
    run = load_csv(write_run_csv(tmp_path / "baseline_cpu10.csv", lat))
    assert run.raw_latency_ms is None and run.skew_percentile is None
    (norm,) = normalize_runs([run], percentile=1.0)
    assert norm.is_normalized and norm.skew_percentile == 1.0
    np.testing.assert_allclose(norm.raw_latency_ms, lat)
    np.testing.assert_allclose(norm.latency_ms, lat - np.percentile(lat, 1.0))
    # the original run is untouched
    np.testing.assert_allclose(run.latency_ms, lat)
    # normalising twice still refers to the file values
    (again,) = normalize_runs([norm], percentile=1.0)
    np.testing.assert_allclose(again.raw_latency_ms, lat)

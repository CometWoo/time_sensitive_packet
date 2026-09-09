from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from tsn_analysis.metrics import (
    distribution_summary,
    dscp_distribution,
    inter_arrival_summary,
    jitter_summary,
    jitter_values,
    latency_summary,
    loss_summary,
    percentile,
    throughput_kbps,
)


def test_percentile_linear_hand_computed():
    # values 1..10: linear (type 7) p50 = 5.5, p90 = 9.1, p99 = 9.91
    x = np.arange(1, 11, dtype=float)
    assert percentile(x, 50) == pytest.approx(5.5)
    assert percentile(x, 90) == pytest.approx(9.1)
    assert percentile(x, 99) == pytest.approx(9.91)
    assert percentile(x, 0) == 1.0
    assert percentile(x, 100) == 10.0
    # method parameter is honoured: nearest-rank style differs from linear
    assert percentile(x, 50, method="lower") == 5.0
    assert percentile(x, 50, method="higher") == 6.0
    out = percentile(x, [50, 90])
    np.testing.assert_allclose(out, [5.5, 9.1])
    assert np.isnan(percentile(np.array([]), 50))


def test_latency_summary_keys_and_values():
    x = np.arange(1, 101, dtype=float)  # 1..100
    s = latency_summary(x)
    assert set(s) >= {"n", "min", "p50", "p90", "p99", "p99.9", "max", "mean", "std"}
    assert s["n"] == 100
    assert s["min"] == 1.0
    assert s["max"] == 100.0
    assert s["p50"] == pytest.approx(50.5)
    assert s["p90"] == pytest.approx(90.1)
    assert s["p99"] == pytest.approx(99.01)
    assert s["p99.9"] == pytest.approx(99.901)
    assert s["mean"] == pytest.approx(50.5)
    assert s["std"] == pytest.approx(np.std(x, ddof=1))


def test_distribution_summary_empty_and_single():
    s = distribution_summary(np.array([]))
    assert s["n"] == 0 and np.isnan(s["p99"]) and np.isnan(s["mean"])
    s1 = distribution_summary(np.array([3.0]))
    assert s1["p50"] == 3.0 and np.isnan(s1["std"])


def test_jitter_uses_abs_and_drops_first():
    j = np.array([0.0, -5.0, 3.0, -1.0])
    np.testing.assert_allclose(jitter_values(j), [5.0, 3.0, 1.0])
    s = jitter_summary(j)
    assert s["n"] == 3
    assert s["max"] == 5.0
    assert s["p50"] == 3.0


def test_loss_summary_hand_computed():
    # expected 0..9 = 10; seq 3 missing; 5 duplicated; 7 arrives after 8 (reorder)
    seq = np.array([0, 1, 2, 4, 5, 5, 6, 8, 7, 9])
    loss = loss_summary(seq)
    assert loss["expected"] == 10
    assert loss["received"] == 10
    assert loss["unique"] == 9
    assert loss["lost"] == 1
    assert loss["loss_pct"] == pytest.approx(10.0)
    assert loss["duplicates"] == 1
    assert loss["reorders"] == 1


def test_loss_summary_clean_and_offset_start():
    seq = np.arange(100, 200)
    loss = loss_summary(seq)
    assert loss["expected"] == 100 and loss["lost"] == 0 and loss["loss_pct"] == 0.0
    assert loss["duplicates"] == 0 and loss["reorders"] == 0


def test_loss_summary_multiple_reorders():
    seq = np.array([2, 0, 1, 5, 3, 4])  # 0,1 after 2; 3,4 after 5 -> 4 reorders
    assert loss_summary(seq)["reorders"] == 4


def test_throughput_uses_recv_span():
    sizes = np.full(11, 100)  # 1100 bytes
    recv = np.arange(11) * 100_000_000  # 0.1 s apart -> span 1.0 s
    assert throughput_kbps(sizes, recv) == pytest.approx(8 * 1100 / 1000.0)
    # a stall doubles the span and halves the throughput
    recv2 = recv.copy()
    recv2[-1] += 1_000_000_000
    assert throughput_kbps(sizes, recv2) == pytest.approx(8 * 1100 / 2000.0)
    assert np.isnan(throughput_kbps(np.array([100]), np.array([0])))
    assert np.isnan(throughput_kbps(np.array([100, 100]), np.array([5, 5])))


def test_inter_arrival_summary():
    recv = np.array([0, 1_000_000, 2_000_000, 4_000_000])  # gaps 1000,1000,2000 us
    s = inter_arrival_summary(recv)
    assert s["n"] == 3
    assert s["min"] == 1000.0
    assert s["max"] == 2000.0
    assert s["p50"] == 1000.0


def test_dscp_distribution():
    assert dscp_distribution(None) is None
    tos = np.array([184, 184, 0, 185, -1])  # EF(46) x2 + ECN variant, BE(0), missing
    d = dscp_distribution(tos)
    assert d["dscp"] == {46: 3, 0: 1}
    assert d["ecn"] == {0: 3, 1: 1}
    assert d["tos"] == {184: 2, 0: 1, 185: 1}
    assert d["missing"] == 1
    assert d["dominant_dscp"] == 46


def test_inter_arrival_exact_at_epoch_magnitude(tmp_path: Path):
    """Gaps of a few hundred ns must survive loading of ~1.7e18 ns timestamps."""
    from tsn_analysis.loader import load_csv

    from .conftest import write_run_csv

    t0 = 1_780_000_000_000_000_000
    # dyadic latencies (exact in float64) -> recv gaps 1_500_000 / 750_000 / 875_000 ns,
    # none of which is a multiple of 256, so a float64 round trip would corrupt them
    lat = np.array([1.0, 1.5, 1.25, 1.125])
    run = load_csv(write_run_csv(tmp_path / "fq_codel_run1.csv", lat, t0_ns=t0))
    gaps_ns = np.diff(run.recv_ns)
    assert gaps_ns.tolist() == [1_500_000, 750_000, 875_000]
    assert (run.recv_ns % 256 != 0).any()
    s = inter_arrival_summary(run.recv_ns)
    assert s["p50"] == pytest.approx(875.0)
    assert s["max"] == pytest.approx(1500.0)

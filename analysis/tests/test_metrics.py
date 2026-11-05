from __future__ import annotations

import numpy as np
import pytest

from tsn_analysis.metrics import (
    distribution_summary,
    dscp_distribution,
    jitter_values,
    latency_summary,
    loss_summary,
    percentile,
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
    s = distribution_summary(jitter_values(j))
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


def test_loss_summary_counts_head_loss():
    # the talker numbers packets from 0, so 0..99 never arriving is 100 lost packets
    loss = loss_summary(np.arange(100, 200))
    assert loss["expected"] == 200 and loss["lost"] == 100 and loss["loss_pct"] == 50.0
    assert loss["duplicates"] == 0 and loss["reorders"] == 0


def test_loss_summary_multiple_reorders():
    seq = np.array([2, 0, 1, 5, 3, 4])  # 0,1 after 2; 3,4 after 5 -> 4 reorders
    assert loss_summary(seq)["reorders"] == 4


def test_dscp_distribution():
    assert dscp_distribution(None) is None
    tos = np.array([184, 184, 0, 185, -1])  # EF(46) x2 + ECN variant, BE(0), missing
    d = dscp_distribution(tos)
    assert d["dscp"] == {46: 3, 0: 1}
    assert d["ecn"] == {0: 3, 1: 1}
    assert d["tos"] == {184: 2, 0: 1, 185: 1}
    assert d["missing"] == 1
    assert d["dominant_dscp"] == 46

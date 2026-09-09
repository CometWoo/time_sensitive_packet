from __future__ import annotations

import numpy as np
import pytest

from tsn_analysis.stats import (
    bootstrap_ci,
    cliffs_delta,
    cliffs_delta_bruteforce,
    compare,
    describe_delta,
    mann_whitney,
    per_run_aggregate,
    resolve_statistic,
)


def test_bootstrap_ci_contains_true_value_normal_mean():
    rng = np.random.default_rng(123)
    x = rng.normal(loc=10.0, scale=2.0, size=2000)
    r = bootstrap_ci(x, "mean", n_boot=1000, ci=0.95, seed=0)
    assert r.low <= 10.0 <= r.high
    assert r.low < r.point < r.high
    assert r.point == pytest.approx(x.mean())
    assert r.n_boot == 1000 and r.ci == 0.95


def test_bootstrap_ci_p99_exponential_known_quantile():
    # Exponential(1): true p99 = -ln(0.01) = 4.605
    rng = np.random.default_rng(7)
    x = rng.exponential(1.0, size=20000)
    r = bootstrap_ci(x, "p99", n_boot=500, seed=1)
    assert r.low <= -np.log(0.01) <= r.high
    assert r.point == pytest.approx(np.percentile(x, 99))


def test_bootstrap_ci_deterministic_and_chunked():
    x = np.arange(100, dtype=float)
    a = bootstrap_ci(x, "p99", n_boot=250, seed=3, chunk=7)
    b = bootstrap_ci(x, "p99", n_boot=250, seed=3, chunk=250)
    assert a == b
    c = bootstrap_ci(x, "p99", n_boot=250, seed=4)
    assert (a.low, a.high) != (c.low, c.high)


def test_bootstrap_ci_edge_cases():
    r = bootstrap_ci(np.array([]), "p99")
    assert np.isnan(r.point) and np.isnan(r.low)
    r1 = bootstrap_ci(np.array([5.0]), "mean")
    assert r1.point == r1.low == r1.high == 5.0
    r2 = bootstrap_ci(np.array([1.0, 2.0]), "max", n_boot=0)
    assert r2.point == 2.0 and r2.low == r2.high == 2.0


def test_resolve_statistic():
    x = np.array([[1.0, 2.0, 3.0, 4.0]])
    assert resolve_statistic("p50")(x, 1)[0] == 2.5
    assert resolve_statistic("median")(x, 1)[0] == 2.5
    assert resolve_statistic("mean")(x, 1)[0] == 2.5
    assert resolve_statistic("max")(x, 1)[0] == 4.0
    assert resolve_statistic("p99.9")(x, 1)[0] == pytest.approx(3.997)
    with pytest.raises(ValueError):
        resolve_statistic("nope")


def test_mann_whitney_identical_vs_shifted():
    rng = np.random.default_rng(0)
    a = rng.lognormal(size=500)
    _, p_same = mann_whitney(a, a.copy())
    assert p_same > 0.99
    _, p_shift = mann_whitney(a, a * 1.5)
    assert p_shift < 1e-6
    u, _ = mann_whitney(np.array([1.0, 2.0]), np.array([3.0, 4.0]))
    assert u == 0.0
    assert np.isnan(mann_whitney(np.array([]), a)[1])


def test_cliffs_delta_separable_identical():
    lo = np.arange(0, 10, dtype=float)
    hi = np.arange(100, 110, dtype=float)
    assert cliffs_delta(hi, lo) == 1.0
    assert cliffs_delta(lo, hi) == -1.0
    assert cliffs_delta(lo, lo) == 0.0
    assert np.isnan(cliffs_delta(np.array([]), lo))


@pytest.mark.parametrize("seed", range(5))
def test_cliffs_delta_matches_bruteforce(seed):
    rng = np.random.default_rng(seed)
    a = rng.integers(0, 6, size=rng.integers(1, 40)).astype(float)  # many ties
    b = rng.integers(0, 6, size=rng.integers(1, 40)).astype(float)
    assert cliffs_delta(a, b) == pytest.approx(cliffs_delta_bruteforce(a, b))
    c = rng.normal(size=30)
    d = rng.normal(loc=0.5, size=45)
    assert cliffs_delta(c, d) == pytest.approx(cliffs_delta_bruteforce(c, d))


def test_describe_delta():
    assert describe_delta(0.0) == "negligible"
    assert describe_delta(-0.2) == "small"
    assert describe_delta(0.4) == "medium"
    assert describe_delta(0.9) == "large"
    assert describe_delta(float("nan")) == "n/a"


def test_compare_structure_and_direction():
    rng = np.random.default_rng(11)
    base = rng.lognormal(sigma=0.5, size=3000) * 2.0
    prop = rng.lognormal(sigma=0.5, size=3000)
    r = compare(base, prop, stat="p99", n_boot=200, seed=0)
    assert r["stat"] == "p99"
    assert r["baseline"]["point"] == pytest.approx(np.percentile(base, 99))
    assert r["proposed"]["point"] == pytest.approx(np.percentile(prop, 99))
    assert r["baseline"]["low"] <= r["baseline"]["point"] <= r["baseline"]["high"]
    assert 30.0 < r["improvement_pct"] < 70.0
    assert r["p_value"] < 1e-10
    assert r["cliffs_delta"] > 0.3
    assert r["effect"] in {"small", "medium", "large"}
    assert r["n_baseline"] == 3000 and r["n_proposed"] == 3000


def test_compare_zero_baseline_gives_nan_improvement():
    r = compare(np.zeros(10), np.ones(10), stat="mean", n_boot=10)
    assert np.isnan(r["improvement_pct"])


def test_per_run_aggregate():
    runs = [np.arange(100, dtype=float) + k for k in range(3)]
    agg = per_run_aggregate(runs, "p99")
    assert agg["n_runs"] == 3
    assert agg["per_run"] == pytest.approx([98.01, 99.01, 100.01])
    assert agg["mean"] == pytest.approx(99.01)
    assert agg["ci_low"] < agg["mean"] < agg["ci_high"]
    two = per_run_aggregate(runs[:2], "p99")
    assert np.isnan(two["ci_low"]) and two["n_runs"] == 2
    one = per_run_aggregate(runs[:1], "p99")
    assert np.isnan(one["std"])


def test_bootstrap_joint_skew_point_matches_normalised_and_is_wider():
    """Joint p1-offset bootstrap: same point estimate, interval includes offset variance."""
    rng = np.random.default_rng(5)
    raw = rng.lognormal(sigma=0.6, size=4000) - 40.0  # negative absolute latency (two clocks)
    shifted = raw - np.percentile(raw, 1.0)
    fixed = bootstrap_ci(shifted, "p50", n_boot=400, seed=0)
    joint = bootstrap_ci(raw, "p50", n_boot=400, seed=0, skew_percentile=1.0)
    joint_list = bootstrap_ci([raw], "p50", n_boot=400, seed=0, skew_percentile=1.0)
    assert joint.point == pytest.approx(fixed.point)
    assert joint == joint_list
    assert (joint.high - joint.low) > (fixed.high - fixed.low)
    assert joint.low <= joint.point <= joint.high


def test_bootstrap_multi_run_skew_shifts_each_run_separately():
    rng = np.random.default_rng(6)
    a = rng.lognormal(size=800) - 40.0
    b = rng.lognormal(size=800) + 25.0  # completely different clock offset
    r = bootstrap_ci([a, b], "p99", n_boot=100, skew_percentile=1.0)
    pooled = np.concatenate([a - np.percentile(a, 1.0), b - np.percentile(b, 1.0)])
    assert r.point == pytest.approx(np.percentile(pooled, 99))
    assert r.low <= r.point <= r.high
    # without a skew percentile the runs are pooled as-is
    plain = bootstrap_ci([a, b], "p99", n_boot=100)
    assert plain.point == pytest.approx(np.percentile(np.concatenate([a, b]), 99))


def test_pooled_values():
    from tsn_analysis.stats import pooled_values

    a = np.array([1.0, 2.0, 3.0])
    b = np.array([10.0, 20.0])
    np.testing.assert_allclose(pooled_values([a, b]), [1, 2, 3, 10, 20])
    np.testing.assert_allclose(pooled_values(a), a)
    p = pooled_values([a, b], skew_percentile=0.0)
    np.testing.assert_allclose(p, [0, 1, 2, 0, 10])
    assert pooled_values([]).size == 0


def test_percentile_method_threads_through():
    x = np.array([1.0, 2.0, 3.0, 4.0])
    lin = resolve_statistic("p50", "linear")(x[None, :], 1)[0]
    near = resolve_statistic("p50", "nearest")(x[None, :], 1)[0]
    assert lin == 2.5 and near in (2.0, 3.0)
    r = compare(x, x + 1, stat="p50", n_boot=20, method="nearest")
    assert r["percentile_method"] == "nearest"
    assert r["baseline"]["point"] == near
    agg = per_run_aggregate([x, x], "p50", method="nearest")
    assert agg["per_run"] == [near, near]


def test_compare_with_skew_uses_shifted_values_for_rank_tests():
    rng = np.random.default_rng(8)
    base = rng.lognormal(sigma=0.5, size=2000) * 2.0 - 50.0
    prop = rng.lognormal(sigma=0.5, size=2000) + 30.0
    r = compare([base], [prop], stat="p99", n_boot=100, skew_percentile=1.0)
    assert r["skew_percentile"] == 1.0
    # baseline tail is wider even though its raw values are 80 ms lower
    assert r["cliffs_delta"] > 0.3 and r["improvement_pct"] > 30.0
    assert r["n_baseline"] == 2000 and r["n_proposed"] == 2000

"""tsn_analysis - loading, metrics, statistics, reports and plots for the TSN testbed CSVs.

The package replaces the two ad-hoc scripts (``compare_results.py`` and
``step8-measurement/plot-results.py``) with one tested code path so that every
number in the README, the figures and the JSON summary is computed the same way.
"""

from tsn_analysis.loader import Run, discover, load_csv, normalize_clock_skew

__all__ = ["Run", "discover", "load_csv", "normalize_clock_skew", "__version__"]

__version__ = "0.1.0"

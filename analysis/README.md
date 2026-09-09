# tsn-analysis

Analysis package for the measurement CSVs of the eBPF time-sensitive networking
testbed. It replaces `compare_results.py` and `step8-measurement/plot-results.py`
(both are now thin wrappers around this package).

```
pip install -e analysis[dev]          # or just run with analysis/ on sys.path
tsn-analysis summary step8-measurement/results --normalize-skew --json out.json
tsn-analysis plot    step8-measurement/results --normalize-skew --out figures
tsn-analysis compare step8-measurement/results --baseline baseline --against proposed --stat p99
cd analysis && python -m pytest -q && ruff check .
```

## Input files

`<results_dir>/*.csv` with columns `seq,send_ns,recv_ns,latency_ms,jitter_us,pkt_size[,tos]`.
File stems are parsed as `<mode>_cpu<N>` (condition + factor `cpu=N`), `<cond>_run<k>`
(condition + run index) or a plain `<cond>`. `tos` is optional (received IP TOS byte;
`dscp = tos >> 2`).

## Statistical choices (see module docstrings)

* Percentiles: `numpy.percentile(method="linear")` (Hyndman-Fan type 7); the legacy
  `sorted(x)[int(n*0.99)]` nearest-rank variant is available via `method=`.
* `--normalize-skew` subtracts each run's 1st-percentile latency. Only for the old two-VM
  testbed whose clocks were offset (raw latency was negative); it destroys absolute latency
  and must not be used when both timestamps come from the same clock. Because every run is
  shifted by its *own* p1, cross-condition comparisons are of the distribution above each
  run's floor: a constant location difference between conditions is removed by construction.
* Confidence intervals: percentile bootstrap (default 2000 resamples, seed 0). Under
  `--normalize-skew` the latency bootstrap is *joint*: each resample is drawn from the raw
  run and its p1 offset re-estimated, so the CI includes the offset's sampling variance
  (about 2x wider for p50 than a fixed-offset bootstrap; negligible for p99).
* Significance: two-sided Mann-Whitney U (rank based; latency tails are heavy, so a t-test
  on means is not appropriate). Effect size: Cliff's delta.
* Throughput: `8 * total_bytes / (last_recv - first_recv)` in kbit/s - the rate actually
  delivered over the receive span, not `(n-1) * send_interval`. On the step8 data this
  exposes that the talker never reached 1 ms pacing (median receive gap 1.3-1.8 ms, receive
  spans 20-45 s for 10 000 packets), so throughput differs per run (264-561 kbit/s) and
  says nothing about the qdisc; read it together with `gap p50`.
* Loss from sequence gaps (`expected = max(seq) - min(seq) + 1`), duplicates and reorders
  reported separately.

## Figures

`fig_latency_percentiles.png`, `fig_jitter_percentiles.png`, `fig_latency_cdf.png`,
`fig_throughput.png`, `fig_latency_box.png`. Colours are fixed per condition.

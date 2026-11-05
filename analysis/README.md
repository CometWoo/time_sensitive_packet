# tsn-analysis

Statistics and figures for the listener CSVs written by `testbed/run.sh`.

```bash
pip install -e "analysis[dev]"
tsn-analysis summary results/testbed/ci-34294518788/ci --baseline fifo
tsn-analysis plot    results/testbed/ci-34294518788/ci --out figures
tsn-analysis compare results/testbed/ci-34294518788/ci --baseline fifo --against pfifo_fast_clsf --stat p99
cd analysis && python -m pytest
```

Input is `<condition>_run<k>.csv` with `seq,send_ns,recv_ns,latency_ms,jitter_us,pkt_size[,tos]`.

- Percentiles: `numpy.percentile(method="linear")` everywhere.
- CIs: percentile bootstrap over packets (2000 resamples, seed 0). The per-run p99 table
  adds a t-interval over runs.
- Significance: two-sided Mann-Whitney U with Cliff's delta as effect size. The latency
  tail is heavy, so no means or t-tests.
- Jitter: `|jitter_us|`, without each run's first row.
- Loss: `expected = max(seq) + 1` per run, so packets lost after the last arrival are not
  counted.

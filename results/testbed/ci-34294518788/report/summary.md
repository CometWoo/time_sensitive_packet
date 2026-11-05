# TSN measurement summary

- results dir: `results/testbed/ci-34294518788/ci`
- baseline: `fifo`
- conditions: fifo, fq_codel, pfifo_fast_noclsf, pfifo_fast_clsf, prio_clsf
- percentiles: numpy `linear`; CIs: 95% percentile bootstrap, n_boot=2000, seed=0

## Latency (ms)

| condition | runs | n | p50 | p90 | p99 | p99.9 | max | mean | std |
|---|---|---|---|---|---|---|---|---|---|
| fifo | 3 | 19444 | 431.33 | 440.38 | 543.73 | 573.39 | 577.31 | 434.29 | 18.58 |
| fq_codel | 3 | 30000 | 0.42 | 0.66 | 0.73 | 0.77 | 2.60 | 0.42 | 0.17 |
| pfifo_fast_noclsf | 3 | 18311 | 433.15 | 435.65 | 538.89 | 566.83 | 570.42 | 436.05 | 16.43 |
| pfifo_fast_clsf | 3 | 30000 | 0.05 | 0.07 | 0.17 | 0.21 | 2.48 | 0.06 | 0.04 |
| prio_clsf | 3 | 30000 | 0.05 | 0.07 | 0.18 | 0.33 | 2.97 | 0.06 | 0.05 |

## Jitter |dt| (us)

| condition | p50 | p90 | p99 | p99.9 | max | mean | std |
|---|---|---|---|---|---|---|---|
| fifo | 365.29 | 1947.89 | 3123.09 | 6569.11 | 9503.67 | 761.34 | 786.91 |
| fq_codel | 237.23 | 368.04 | 400.59 | 899.28 | 3093.79 | 273.77 | 79.76 |
| pfifo_fast_noclsf | 788.41 | 881.96 | 1958.54 | 2536.40 | 4265.06 | 676.66 | 384.83 |
| pfifo_fast_clsf | 5.94 | 110.80 | 133.90 | 624.88 | 2447.80 | 25.27 | 52.83 |
| prio_clsf | 5.69 | 113.17 | 144.69 | 987.72 | 5510.57 | 27.56 | 79.75 |

## Loss and DSCP

| condition | expected | received | lost | loss % | dup | reorder | DSCP |
|---|---|---|---|---|---|---|---|
| fifo | 29999 | 19444 | 10555 | 35.18 | 0 | 0 | 0 |
| fq_codel | 30000 | 30000 | 0 | 0.00 | 0 | 0 | 0 |
| pfifo_fast_noclsf | 29999 | 18311 | 11688 | 38.96 | 0 | 0 | 0 |
| pfifo_fast_clsf | 30000 | 30000 | 0 | 0.00 | 0 | 0 | 46 |
| prio_clsf | 30000 | 30000 | 0 | 0.00 | 0 | 0 | 46 |

## Per-run p99 (mean over runs, t-interval)

| condition | metric | runs | mean | std | CI |
|---|---|---|---|---|---|
| fifo | latency_p99_ms | 3 | 543.60 | 0.76 | [541.72, 545.48] |
| fifo | jitter_p99_us | 3 | 3131.69 | 15.31 | [3093.67, 3169.72] |
| fq_codel | latency_p99_ms | 3 | 0.73 | 0.01 | [0.71, 0.74] |
| fq_codel | jitter_p99_us | 3 | 400.50 | 0.97 | [398.08, 402.91] |
| pfifo_fast_noclsf | latency_p99_ms | 3 | 538.66 | 0.52 | [537.36, 539.96] |
| pfifo_fast_noclsf | jitter_p99_us | 3 | 1959.84 | 5.22 | [1946.87, 1972.81] |
| pfifo_fast_clsf | latency_p99_ms | 3 | 0.17 | 0.01 | [0.16, 0.18] |
| pfifo_fast_clsf | jitter_p99_us | 3 | 131.85 | 11.47 | [103.35, 160.35] |
| prio_clsf | latency_p99_ms | 3 | 0.18 | 0.01 | [0.15, 0.20] |
| prio_clsf | jitter_p99_us | 3 | 140.10 | 8.72 | [118.44, 161.77] |

## Comparisons vs `fifo`

improvement = (baseline - condition) / baseline. p: two-sided Mann-Whitney U; delta: Cliff's delta, + when the baseline is slower. Both compare whole distributions, so they repeat across the latency rows.

| condition | metric | baseline [CI] | condition [CI] | improvement | p-value | delta |
|---|---|---|---|---|---|---|
| fq_codel | latency_p50_ms | 431.33 [431.25, 431.49] | 0.42 [0.42, 0.43] | +99.90% | <1e-300 | +1.00 (large) |
| fq_codel | latency_p99_ms | 543.73 [538.79, 548.33] | 0.73 [0.72, 0.73] | +99.87% | <1e-300 | +1.00 (large) |
| fq_codel | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 400.59 [399.27, 401.64] | +87.17% | <1e-300 | +0.50 (large) |
| pfifo_fast_noclsf | latency_p50_ms | 431.33 [431.25, 431.49] | 433.15 [433.12, 433.19] | -0.42% | 9.68e-296 | -0.22 (small) |
| pfifo_fast_noclsf | latency_p99_ms | 543.73 [538.79, 548.33] | 538.89 [534.53, 543.45] | +0.89% | 9.68e-296 | -0.22 (small) |
| pfifo_fast_noclsf | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 1958.54 [1956.07, 1962.41] | +37.29% | 2.58e-19 | -0.05 (negligible) |
| pfifo_fast_clsf | latency_p50_ms | 431.33 [431.25, 431.49] | 0.05 [0.05, 0.05] | +99.99% | <1e-300 | +1.00 (large) |
| pfifo_fast_clsf | latency_p99_ms | 543.73 [538.79, 548.33] | 0.17 [0.17, 0.17] | +99.97% | <1e-300 | +1.00 (large) |
| pfifo_fast_clsf | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 133.90 [132.97, 135.16] | +95.71% | <1e-300 | +1.00 (large) |
| prio_clsf | latency_p50_ms | 431.33 [431.25, 431.49] | 0.05 [0.05, 0.05] | +99.99% | <1e-300 | +1.00 (large) |
| prio_clsf | latency_p99_ms | 543.73 [538.79, 548.33] | 0.18 [0.18, 0.18] | +99.97% | <1e-300 | +1.00 (large) |
| prio_clsf | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 144.69 [143.07, 146.60] | +95.37% | <1e-300 | +0.99 (large) |

# TSN measurement summary

- results dir: `results\testbed\ci-34294518788\ci`
- baseline condition: `fifo`
- conditions: fifo, fq_codel, pfifo_fast_clsf, pfifo_fast_noclsf, prio_clsf
- percentile method: numpy `linear`
- latency as recorded (no clock-skew normalisation)
- CIs: 95% percentile bootstrap, n_boot=2000, seed=0

## Latency (ms)

| condition | factor | runs | n | p50 | p90 | p99 | p99.9 | max | mean | std |
|---|---|---|---|---|---|---|---|---|---|---|
| fifo | all runs | 3 | 19444 | 431.33 | 440.38 | 543.73 | 573.39 | 577.31 | 434.29 | 18.58 |
| fq_codel | all runs | 3 | 30000 | 0.42 | 0.66 | 0.73 | 0.77 | 2.60 | 0.42 | 0.17 |
| pfifo_fast_clsf | all runs | 3 | 30000 | 0.05 | 0.07 | 0.17 | 0.21 | 2.48 | 0.06 | 0.04 |
| pfifo_fast_noclsf | all runs | 3 | 18311 | 433.15 | 435.65 | 538.89 | 566.83 | 570.42 | 436.05 | 16.43 |
| prio_clsf | all runs | 3 | 30000 | 0.05 | 0.07 | 0.18 | 0.33 | 2.97 | 0.06 | 0.05 |

## Jitter |dt| (us)

| condition | factor | p50 | p90 | p99 | p99.9 | max | mean | std |
|---|---|---|---|---|---|---|---|---|
| fifo | all runs | 365.29 | 1947.89 | 3123.09 | 6569.11 | 9503.67 | 761.34 | 786.91 |
| fq_codel | all runs | 237.23 | 368.04 | 400.59 | 899.28 | 3093.79 | 273.77 | 79.76 |
| pfifo_fast_clsf | all runs | 5.94 | 110.80 | 133.90 | 624.88 | 2447.80 | 25.27 | 52.83 |
| pfifo_fast_noclsf | all runs | 788.41 | 881.96 | 1958.54 | 2536.40 | 4265.06 | 676.66 | 384.83 |
| prio_clsf | all runs | 5.69 | 113.17 | 144.69 | 987.72 | 5510.57 | 27.56 | 79.75 |

## Loss, throughput, DSCP

throughput kbps = 8 * received bytes / (last recv - first recv) in kbit/s, i.e. the rate actually delivered over the run's receive span (NOT (n-1) * send interval). gap p50 is the median receive gap; compare it with the intended send interval to see whether the talker kept its pacing - a larger gap means lower throughput, not loss.

| condition | factor | expected | received | lost | loss % | dup | reorder | throughput kbps | gap p50 us | gap p99 us | DSCP |
|---|---|---|---|---|---|---|---|---|---|---|---|
| fifo | all runs | 29995 | 19444 | 10551 | 35.18 | 0 | 0 | 674.24 | 1228.57 | 4123.09 | 0 |
| fq_codel | all runs | 30000 | 30000 | 0 | 0.00 | 0 | 0 | 1024.07 | 1203.73 | 1269.42 | 0 |
| pfifo_fast_clsf | all runs | 30000 | 30000 | 0 | 0.00 | 0 | 0 | 1024.11 | 999.94 | 1126.54 | 46 |
| pfifo_fast_noclsf | all runs | 29991 | 18311 | 11680 | 38.95 | 0 | 0 | 633.80 | 1785.37 | 2958.54 | 0 |
| prio_clsf | all runs | 30000 | 30000 | 0 | 0.00 | 0 | 0 | 1024.11 | 999.87 | 1134.80 | 46 |

## Per-run aggregate (mean of per-run statistic, t-interval when >= 3 runs)

| condition | factor | metric | runs | mean | std | CI |
|---|---|---|---|---|---|---|
| fifo | all runs | latency_p99_ms | 3 | 543.60 | 0.76 | [541.72, 545.48] |
| fifo | all runs | jitter_p99_us | 3 | 3131.69 | 15.31 | [3093.67, 3169.72] |
| fq_codel | all runs | latency_p99_ms | 3 | 0.73 | 0.01 | [0.71, 0.74] |
| fq_codel | all runs | jitter_p99_us | 3 | 400.50 | 0.97 | [398.08, 402.91] |
| pfifo_fast_clsf | all runs | latency_p99_ms | 3 | 0.17 | 0.01 | [0.16, 0.18] |
| pfifo_fast_clsf | all runs | jitter_p99_us | 3 | 131.85 | 11.47 | [103.35, 160.35] |
| pfifo_fast_noclsf | all runs | latency_p99_ms | 3 | 538.66 | 0.52 | [537.36, 539.96] |
| pfifo_fast_noclsf | all runs | jitter_p99_us | 3 | 1959.84 | 5.22 | [1946.87, 1972.81] |
| prio_clsf | all runs | latency_p99_ms | 3 | 0.18 | 0.01 | [0.15, 0.20] |
| prio_clsf | all runs | jitter_p99_us | 3 | 140.10 | 8.72 | [118.44, 161.77] |

## Comparisons vs `fifo`

improvement % = (baseline - condition) / baseline * 100; positive = lower = better. p from two-sided Mann-Whitney U; delta = Cliff's delta (positive = baseline slower). p and delta compare whole distributions, so they repeat across latency statistics.

| condition | factor | metric | baseline [CI] | condition [CI] | improvement | p-value | delta |
|---|---|---|---|---|---|---|---|
| fq_codel | all runs | latency_p50_ms | 431.33 [431.25, 431.49] | 0.42 [0.42, 0.43] | +99.90% | <1e-300 | +1.00 (large) |
| fq_codel | all runs | latency_p99_ms | 543.73 [538.79, 548.33] | 0.73 [0.72, 0.73] | +99.87% | <1e-300 | +1.00 (large) |
| fq_codel | all runs | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 400.59 [399.27, 401.64] | +87.17% | <1e-300 | +0.50 (large) |
| pfifo_fast_clsf | all runs | latency_p50_ms | 431.33 [431.25, 431.49] | 0.05 [0.05, 0.05] | +99.99% | <1e-300 | +1.00 (large) |
| pfifo_fast_clsf | all runs | latency_p99_ms | 543.73 [538.79, 548.33] | 0.17 [0.17, 0.17] | +99.97% | <1e-300 | +1.00 (large) |
| pfifo_fast_clsf | all runs | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 133.90 [132.97, 135.16] | +95.71% | <1e-300 | +1.00 (large) |
| pfifo_fast_noclsf | all runs | latency_p50_ms | 431.33 [431.25, 431.49] | 433.15 [433.12, 433.19] | -0.42% | 9.68e-296 | -0.22 (small) |
| pfifo_fast_noclsf | all runs | latency_p99_ms | 543.73 [538.79, 548.33] | 538.89 [534.53, 543.45] | +0.89% | 9.68e-296 | -0.22 (small) |
| pfifo_fast_noclsf | all runs | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 1958.54 [1956.07, 1962.41] | +37.29% | 2.58e-19 | -0.05 (negligible) |
| prio_clsf | all runs | latency_p50_ms | 431.33 [431.25, 431.49] | 0.05 [0.05, 0.05] | +99.99% | <1e-300 | +1.00 (large) |
| prio_clsf | all runs | latency_p99_ms | 543.73 [538.79, 548.33] | 0.18 [0.18, 0.18] | +99.97% | <1e-300 | +1.00 (large) |
| prio_clsf | all runs | jitter_p99_us | 3123.09 [3112.73, 3654.67] | 144.69 [143.07, 146.60] | +95.37% | <1e-300 | +0.99 (large) |

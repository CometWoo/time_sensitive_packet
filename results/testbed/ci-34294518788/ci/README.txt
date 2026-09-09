testbed run: 2026-09-09T00:24:55+00:00
kernel: 6.17.0-1022-azure   shaper: tbf   link: 20 Mbit/s   flood: 30 Mbit/s
conditions: fifo fq_codel pfifo_fast_noclsf pfifo_fast_clsf prio_clsf   runs: 3   ts: 10000 pkts @ 1 ms
files: <condition>_run<k>.csv (listener), <condition>_run<k>.meta.json (probes/counters/qdisc)

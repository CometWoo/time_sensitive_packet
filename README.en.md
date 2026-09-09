# Time-Sensitive Cloud-Native Network on eBPF — reproduce, refute, redesign

English summary. The full documentation is in Korean: [README.md](README.md), [docs/](docs/), [ADRs](docs/adr/README.md).

## What this is

A reproduction of Wen et al., *"A Time-Sensitive Cloud-Native Network Based on eBPF"* (CSCWD 2024) on
Cilium/Kubernetes — and the story of finding out, from kernel source and measurement, why the first
reproduction could not have worked, then redesigning and verifying it.

## Findings

1. **`skb->priority` does not survive a veth crossing.** `____dev_forward_skb()` sets `skb->priority = 0`
   for every forwarded packet (`include/linux/netdevice.h`, v5.15 L4140 / v6.8 L4110; reached from
   `veth_xmit → veth_forward_skb → __dev_forward_skb`). Anything a Pod sets — `SO_PRIORITY` or a BPF
   program on the Pod's own `eth0` — reaches the host qdisc as 0. Measured with a priority histogram probe:
   52,858 / 52,858 packets arrive at the host side with priority 0 although the sender set 6.
2. **On kernel ≥ 6.6, Cilium's tcx programs hide legacy `clsact` filters.** `sch_handle_egress()` runs
   `tcx_run()` first and only falls through to `tc_run()` when the chain returns `TC_ACT_UNSPEC`. Cilium's
   `cil_to_netdev` returns `TC_ACT_OK`, so a `tc filter … bpf` classifier is never executed (CI integration
   test: 0/21 hits; attached with `BPF_F_BEFORE` and returning `TCX_NEXT`: 20/22).
3. The May 2026 cluster measurements (baseline vs proposed under CPU load) were taken with no competing
   network traffic, with the priority reset above in effect (custom priomap sent priority 0 to the *lowest*
   band), and with a talker that resolved DNS on every `sendto()` (effective 216–547 pkt/s instead of 1,000).
   They are kept and re-interpreted, not presented as evidence ([docs/RESULTS.md](docs/RESULTS.md)).

## Redesign (v2)

- `step6-ebpf/src/ts_classifier.c` — classifier at the **host physical NIC egress** (just before the qdisc):
  AVTP EtherType / 802.1Q·802.1ad outer PCP ≥ 5 / IPv4-UDP destination port (compile-time 6000 + runtime map)
  → `skb->priority = 6`; non-TS packets untouched; IP fragments ignored; optional **DSCP EF marking** with
  incremental IPv4 checksum update; per-CPU counters; returns `TC_ACT_UNSPEC` so Cilium still runs.
- `tools/tcx_attach.c` — libbpf link-based tcx attach with `BPF_F_BEFORE` / `BPF_F_AFTER`, pinning, chain query.
- `testbed/` — single-host netns testbed mimicking Pod ↔ veth ↔ host ↔ NIC: `tbf` bottleneck (20 Mbit/s),
  best-effort UDP flood (30 Mbit/s), five qdisc conditions, priority probes on both sides of the veth,
  classifier counters, receiver-side DSCP (`IP_RECVTOS`) and kernel RX timestamps.
- `analysis/` — `tsn-analysis`: linear percentiles, bootstrap CIs, Mann-Whitney U, Cliff's δ, loss/dup/reorder,
  throughput from timestamps, plots and Markdown/JSON reports (65 tests).
- K8s orchestration (`deploy-experiment.sh`, kustomize manifests): HTB bottleneck class keyed on the listener
  IP, BE flood Job, condition names shared with the testbed, per-run metadata. **Not yet executed on the
  cluster** (no VM access at the time of writing).

## Headline result (GitHub Actions runner, kernel 6.17, 3 runs × 10,000 packets per condition)

| condition | classifier | latency p50 / p99 (ms) | loss | received DSCP |
|---|---|---|---|---|
| `fifo` (pfifo) | no | 431.3 / 543.7 | 35.2 % | 0 |
| `fq_codel` (Linux default) | no | 0.42 / 0.73 | 0 | 0 |
| `pfifo_fast_noclsf` (priority 0) | no | 433.2 / 538.9 | 38.9 % | 0 |
| `pfifo_fast_clsf` | **yes** | **0.05 / 0.17** | **0** | **46 (EF)** |
| `prio_clsf` | **yes** | **0.05 / 0.18** | **0** | **46 (EF)** |

`pfifo_fast_noclsf` equals `fifo` (Cliff's δ = −0.22): a 3-band priority queue does nothing when the priority
never arrives — the real state of the May design. With the classifier, p50 drops ~8,600× and loss goes to zero
on the same qdisc; the DSCP mark arrives end-to-end with a valid checksum.

## Verification

26 `bpftool prog run` (BPF_PROG_TEST_RUN) unit tests (kernel 5.15 WSL2 and 6.17 CI), tcx chain integration test
(CI), testbed runs in CI with artifacts committed under `results/testbed/`, 65 analysis tests, shellcheck/ruff/
kubeconform. Matrix: [docs/VERIFICATION.md](docs/VERIFICATION.md). Limits: [docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## Why it matters for AI-datacenter networking

Priority is about *where you mark*. Host-internal `skb->priority` dies at the veth and again at the NIC; the
fabric only reads DSCP/PCP. QoS is invisible without contention. Tail latency (p99/p99.9) is the SLO in
collective communication. Composing BPF hooks with a CNI datapath requires tcx ordering.
Mapping table and hardware roadmap: [docs/AIDC_RELEVANCE.md](docs/AIDC_RELEVANCE.md).

## Quick start

```bash
make -C step6-ebpf && make -C step6-ebpf tools
sudo make -C step6-ebpf test && sudo make -C step6-ebpf test-tcx      # kernel >= 6.6 for test-tcx
sudo bash testbed/run_testbed.sh --runs 3 --rate-mbps 20 --flood-mbps 30 --out testbed/runs/local
python -m pip install -e ./analysis && tsn-analysis summary testbed/runs/local --baseline fifo --markdown -
```

## Reference

J. Wen, J. Ge, Z. Zhang, H. Li, Y. E, B. Wu, "A time-sensitive cloud-native network based on eBPF," Proc. 27th IEEE
CSCWD, 2024, pp. 2577–2582, DOI 10.1109/CSCWD61410.2024.10580477.

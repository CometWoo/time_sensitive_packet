# eBPF Time-Sensitive Cloud-Native Network — 재현, 반증, 재설계

[![ci](https://github.com/CometWoo/time_sensitive_packet/actions/workflows/ci.yml/badge.svg)](https://github.com/CometWoo/time_sensitive_packet/actions/workflows/ci.yml)
[![testbed](https://github.com/CometWoo/time_sensitive_packet/actions/workflows/testbed.yml/badge.svg)](https://github.com/CometWoo/time_sensitive_packet/actions/workflows/testbed.yml)
[English](README.en.md) · [결과](docs/RESULTS.md) · [설계 결정(ADR)](docs/adr/README.md) · [한계](docs/LIMITATIONS.md) · [AIDC 연결](docs/AIDC_RELEVANCE.md)

Wen et al., "A Time-Sensitive Cloud-Native Network Based on eBPF"(CSCWD 2024)를 Cilium/Kubernetes 에서 재현하다가,
첫 재현이 애초에 동작할 수 없었다는 것을 커널 소스와 실측으로 확인하고 다시 설계한 프로젝트입니다.

- **발견**: Pod 가 설정한 `skb->priority` 는 veth 를 건너는 순간 0 이 되고, kernel 6.6 이상에서는 Cilium 의 tcx 프로그램이
  legacy clsact 필터를 건너뛰게 만듭니다.
- **재설계**: 분류기를 호스트 물리 NIC egress, Cilium 보다 앞선 tcx 위치에 두고 DSCP EF 를 마킹합니다.
- **결과**: 같은 `pfifo_fast` 큐에서 TS 흐름 p50 433 ms, 손실 39 % → 0.05 ms, 손실 0 (CI 테스트베드, 조건당 30,000 패킷).

## 무엇을 발견했나

1. **veth 가 priority 를 지운다.** `____dev_forward_skb()`(`include/linux/netdevice.h`)는 veth 를 건너는 모든 패킷에
   `skb->priority = 0` 을 씁니다. Pod 안에서 `SO_PRIORITY` 나 BPF 로 무엇을 하든 호스트 qdisc 는 0 을 봅니다.
   프로브로 재면 talker 가 6 을 설정해도 veth 직후의 패킷(런마다 약 52,860개)이 전부 priority 0 입니다.
2. **tcx 가 legacy 필터를 가린다.** kernel 6.6 이상의 `sch_handle_egress()` 는 tcx 체인이 `TC_ACT_UNSPEC` 이 아닌 값을
   돌려주면 `tc_run()` 을 건너뜁니다. Cilium 은 `TC_ACT_OK` 를 돌려주므로 `tc filter … bpf` 분류기는 실행되지 않습니다.
   CI 통합 테스트로 확인했습니다: OK 를 돌려주는 tcx 프로그램 뒤의 legacy 분류기는 한 번도 실행되지 않고,
   `BPF_F_BEFORE` 로 붙이면 둘 다 실행됩니다.
3. **첫 측정은 무효였다.** 2026년 5월 K8s 측정은 경합 트래픽이 없었고, 위 두 문제로 우선순위가 한 번도 적용되지 않았으며,
   talker 가 패킷마다 DNS 를 조회했습니다. 그래서 결과를 철회하고 원본은 저장소에서 내렸습니다
   ([RESULTS.md 2절](docs/RESULTS.md), [ADR-0016](docs/adr/0016-results-provenance.md)).

## 결과

GitHub Actions 러너(kernel 6.17), 20 Mbit/s `tbf` 병목, 30 Mbit/s best-effort UDP flood, 1 ms 간격 128 B TS 흐름,
조건당 3 run × 10,000 패킷입니다. 원본 CSV 에서 다시 계산한 값이고, `analysis/tests/test_integration.py` 가 고정합니다.

| 조건 | 분류기 | p50 (ms) | p99 (ms) | 손실 | 수신 DSCP |
|---|---|---|---|---|---|
| `fifo` (pfifo) | 없음 | 431.33 | 543.73 | 35.18 % | 0 |
| `fq_codel` | 없음 | 0.42 | 0.73 | 0 | 0 |
| `pfifo_fast_noclsf` | 없음 | 433.15 | 538.89 | 38.96 % | 0 |
| `pfifo_fast_clsf` | 있음 | 0.05 | 0.17 | 0 | 46 (EF) |
| `prio_clsf` | 있음 | 0.05 | 0.18 | 0 | 46 (EF) |

- **인과 분리**: 분류기 없는 `pfifo_fast` 는 `fifo` 와 같은 430 ms 대에 머뭅니다. 3-band 큐가 있어도 priority 가
  도달하지 않으면 소용없다는 뜻입니다. 같은 큐에 분류기를 붙이면 p50 이 약 8,900배 줄고 손실이 0 이 됩니다
  (`fifo` 대비 Mann-Whitney U p < 1e-300, Cliff's δ = +1.00).
- **DSCP**: 30,000개 모두 DSCP 46 을 단 채 도착했습니다. IPv4 체크섬을 증분 갱신했기 때문에 수신 커널이 버린 패킷이 없습니다.
- **fq_codel** 도 손실 0 이지만 strict priority 보다 4배 느리고, 흐름 단위 우대는 호스트 안에서만 일어납니다.

| latency 백분위 | latency CDF |
|---|---|
| ![latency percentiles](results/testbed/ci-34294518788/report/fig_latency_percentiles.png) | ![latency CDF](results/testbed/ci-34294518788/report/fig_latency_cdf.png) |

통계 전체와 해석: [docs/RESULTS.md](docs/RESULTS.md) · 원본: [results/testbed/ci-34294518788](results/testbed/ci-34294518788)

## 구조

<img width="864" height="648" alt="20260918_020025_e7ac3f84284fced756c38028c715819b" src="https://github.com/user-attachments/assets/867eca2d-7bb1-41eb-a884-52801512f0b8" />

1. talker 가 1 ms 마다 UDP 6000 으로 128 B 패킷을 보냅니다. Pod 안의 `SO_PRIORITY` 는 다음 단계에서 지워집니다.
2. veth: `veth_forward_skb() → ____dev_forward_skb()` 가 `skb->priority = 0`.
3. Cilium `cil_from_container` 가 물리 NIC 로 redirect 합니다.
4. NIC egress tcx 체인 맨 앞의 `ts_classifier`: UDP 6000(또는 AVTP, VLAN PCP ≥ 5)이면 `skb->priority = 6`,
   DSCP 46 마킹, IPv4 체크섬 증분 갱신 후 `TC_ACT_UNSPEC` 을 돌려줍니다.
5. Cilium 이 이어서 실행되고, `prio`/`pfifo_fast` 가 priority 6 을 band 0 에 넣습니다.
6. listener 가 `IP_RECVTOS` 로 DSCP 도착을 확인합니다.

커널 함수와 줄 번호: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · 논문과의 대응: [docs/PAPER_MAPPING.md](docs/PAPER_MAPPING.md)

## 핵심 설계 결정

| 결정 | 이유 | ADR |
|---|---|---|
| 분류 지점 = 호스트 NIC egress | veth 뒤, qdisc 직전에 남은 유일한 지점 | [0003](docs/adr/0003-classify-at-host-nic-egress.md) |
| tcx `BPF_F_BEFORE` + `TC_ACT_UNSPEC` | Cilium 앞에서 실행하되 Cilium 정책은 그대로 통과 | [0005](docs/adr/0005-tcx-before-cilium.md) |
| 병목 + 경합 트래픽 | 큐가 비어 있으면 QoS 효과는 관측되지 않음 | [0006](docs/adr/0006-testbed-needs-contention.md) |
| DSCP EF 마킹 | 호스트 밖 스위치가 읽을 수 있는 유일한 신호 | [0007](docs/adr/0007-dscp-marking-for-fabric-qos.md) |
| 비교 조건 5개 | 2개로는 qdisc 차이와 priority 도달을 구분할 수 없음 | [0010](docs/adr/0010-qdisc-conditions.md) |

전체 16개: [docs/adr/README.md](docs/adr/README.md)

## 검증

| 항목 | 방법 | 상태 |
|---|---|---|
| 분류 규칙, DSCP, 체크섬, 설정 map | `BPF_PROG_TEST_RUN` 단위 테스트 26개 (kernel 5.15, 6.17) | 통과 |
| tcx 실행 순서 | `bpf/tests/test_tcx_chain.sh` (kernel 6.17) | 통과 |
| veth priority 리셋, DSCP 도착, 경합 하 latency | netns 테스트베드 5조건 × 3 run (CI) | 실측 |
| 통계 코드와 위 표의 숫자 | pytest 79개 | 통과 |
| 실제 Cilium 다중 노드 클러스터 | `scripts/experiment.sh` | 미검증 (VM 접근 불가) |

상세: [docs/VERIFICATION.md](docs/VERIFICATION.md) · 한계: [docs/LIMITATIONS.md](docs/LIMITATIONS.md)

## AI 데이터센터 네트워크와의 연결

우선순위는 "어디서 찍느냐"가 전부입니다. 호스트 안의 `skb->priority` 는 veth 와 NIC 에서 사라지고, 패브릭이 읽는 것은
DSCP/PCP 뿐입니다. 집단 통신에서는 꼬리 지연(p99)이 학습 스텝을 잡으므로, 혼잡 속에서 제어 트래픽을 지키는 이 구조가
그대로 연결됩니다. 매핑 표와 로드맵: [docs/AIDC_RELEVANCE.md](docs/AIDC_RELEVANCE.md)

## 빠른 시작

```bash
make -C bpf && make -C bpf tools
sudo make -C bpf test            # BPF_PROG_TEST_RUN 단위 테스트
sudo make -C bpf test-tcx        # tcx 체인 (kernel >= 6.6)
sudo bash testbed/run.sh --runs 3 --rate-mbps 20 --flood-mbps 30 --out testbed/runs/local
python -m pip install -e ./analysis
tsn-analysis summary testbed/runs/local --baseline fifo --markdown -
```

K8s 클러스터 실험: [docs/RUNBOOK.md](docs/RUNBOOK.md)

## 저장소 구조

```
bpf/              eBPF 분류기, 프로브, tcx 로더, 단위·통합 테스트
workload/         talker, listener, best-effort flood, sink
testbed/          단일 호스트 netns 테스트베드
analysis/         tsn-analysis 통계 패키지
k8s/, scripts/    클러스터 오케스트레이션 (미실행)
results/testbed/  CI 실측 원본과 리포트
docs/             ARCHITECTURE, RESULTS, LIMITATIONS, VERIFICATION, ADR 16개
```

## 참고 문헌

- J. Wen, J. Ge, Z. Zhang, H. Li, Y. E, B. Wu, "A time-sensitive cloud-native network based on eBPF," Proc. 27th IEEE CSCWD,
  2024, pp. 2577–2582. DOI: [10.1109/CSCWD61410.2024.10580477](https://doi.org/10.1109/CSCWD61410.2024.10580477)
- Linux: `include/linux/netdevice.h` (`____dev_forward_skb`), `net/core/dev.c` (`sch_handle_egress`), `kernel/bpf/mprog.c`
- Cilium datapath: [docs.cilium.io](https://docs.cilium.io)

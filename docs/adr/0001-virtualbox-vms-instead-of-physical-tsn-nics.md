# ADR-0001 — 물리 TSN NIC 대신 VirtualBox VM 2대 + WSL/CI netns 테스트베드로 재현한다

- 상태: 채택 (2026-05, 2026-09 보강)
- 관련: [ADR-0002](0002-prio-instead-of-mqprio-etf-taprio.md), [ADR-0012](0012-clock-skew-and-same-host-testbed.md), [docs/LIMITATIONS.md](../LIMITATIONS.md)

## 문제

논문(Wen et al., CSCWD 2024)의 환경: Ubuntu 22.04 / kernel 5.15, 72 코어(8 코어 isolcpus),
16 GB, **4 TX/RX 큐 NIC**, 하드웨어 PTP. 개인 학습·포트폴리오 예산으로는 확보할 수 없다.

## 결정

1. **K8s 재현**: Windows 노트북의 VirtualBox VM 2대(각 4 vCPU/4 GB, virtio-net 1 큐, NAT 네트워크)에
   kubeadm + Cilium(native routing, kube-proxy 대체)을 올린다. 논문의 아키텍처(Pod → veth → 호스트
   eBPF → NIC qdisc)를 **구조적으로** 재현하되, 하드웨어 큐 분리·하드웨어 타임스탬프는 포기한다.
2. **메커니즘 검증**: 커널 동작(veth priority 리셋, tcx 순서, qdisc 우선순위, DSCP)은 VM 없이도
   재현 가능한 **단일 호스트 netns 테스트베드**(`testbed/`)로 검증한다. WSL2 에서 기능 검증,
   GitHub Actions 러너(ubuntu-24.04, kernel 6.x)에서 경합 실험을 돌려 CI 아티팩트로 남긴다.

## 고려한 대안

| 대안 | 장점 | 단점 |
|---|---|---|
| Intel i210/i225 미니 PC 2대 (LaunchTime, 4 큐, HW timestamp) | 논문 충실, ETF/taprio 하드웨어 오프로드 가능 | 비용·시간. 나중에 `docs/AIDC_RELEVANCE.md` 의 "실 하드웨어 로드맵" 으로 남김 |
| KVM/QEMU virtio multiqueue (`mq=on`) 또는 SR-IOV 패스스루 | `mqprio hw 0` 로 per-tc 큐 분리 가능 | Windows 호스트에서 불가 |
| 클라우드 VM (ENA/gVNIC 멀티큐) | 멀티큐·좋은 클럭 | 비용, PTP 없음, 실험 반복 시 과금 |
| **VirtualBox VM (채택, 5월)** | 비용 0, 이미 보유 | TX 큐 1개, HW timestamp 없음, 하이퍼바이저 스톨(수백 ms~수 s), XDP generic 만 |
| **netns 테스트베드 (채택, 9월 추가)** | 재현성·자동화·CI 실행, 같은 시계(one-way latency 절대값 유효), 셰이퍼로 경합 제어 | 물리 NIC/드라이버 큐가 없어 mqprio·ETF 하드웨어 경로는 검증 불가 |

## 결과

- VM 환경의 한계는 [docs/LIMITATIONS.md](../LIMITATIONS.md) 에 항목별로 기록한다.
- 논문의 절대 수치(수십 μs)와 비교하지 않는다. 상대 비교(조건 간)와 메커니즘 검증에 집중한다.
- 환경 불일치(설치 스크립트 22.04/K8s 1.28/Cilium 1.15.6 vs 실제 측정 24.04/K8s 1.30/Cilium 1.19,
  kernel ≥ 6.6 tcx)는 스크립트를 변수화해 해소했다 (step2–step4).

# 논문 ↔ 이 저장소 대응표

J. Wen, J. Ge, Z. Zhang, H. Li, Y. E, B. Wu, "A time-sensitive cloud-native network based on eBPF,"
*Proc. 27th IEEE Int. Conf. Computer Supported Cooperative Work in Design (CSCWD)*, 2024, pp. 2577–2582,
DOI [10.1109/CSCWD61410.2024.10580477](https://doi.org/10.1109/CSCWD61410.2024.10580477).

논문의 주장: 컨테이너 네트워크(Cilium)에서 계산 자원 경쟁이 심할 때도 시간 민감 링크의 속성을
보존하기 위해, eBPF 프로그램(veth 필터 vef / NIC egress eg / NIC ingress ig)과 리눅스 TC 스케줄링
스택(mqprio + ETF + 802.1Qbv 게이트)을 결합한다.

## 1. 구성 요소 대응

| 논문 요소 (Fig. 1, §III–IV) | 이 저장소 | 비고 |
|---|---|---|
| Cilium 기반 K8s, underlay/overlay 혼합 | Cilium native routing, kube-proxy 대체 (`step4-cilium/`) | overlay 없음 → vef 의 우회 역할이 무의미 |
| **vef** (컨테이너 veth 필터: TS 는 underlay 직행, 나머지는 overlay) | **의도적 미구현** | Pod 측/호스트측 veth 어디서든 priority 는 veth 리셋·tcx 순서 때문에 무효 ([ADR-0003](adr/0003-classify-at-host-nic-egress.md)) |
| **eg** (NIC egress: skb->priority → TC 클래스) | `step6-ebpf/src/ts_classifier.c` — NIC egress, tcx BEFORE Cilium | 논문의 eg 위치와 같다. 분류 기준에 UDP 포트 추가 ([ADR-0014](adr/0014-udp-port-classification-and-trust-boundary.md)), DSCP 마킹 추가 ([ADR-0007](adr/0007-dscp-marking-for-fabric-qos.md)) |
| **ig** (NIC ingress: 수신 타임스탬프/통계) | 없음 — listener 가 사용자 공간에서 측정 | 로드맵: `SO_TIMESTAMPNS` |
| XDP VLAN 802.1Q/AVTP 파싱 | 삭제 | VM generic XDP, 트래픽에 VLAN/AVTP 없음 |
| Table I: VLAN PCP → TC 매핑 (pri 3 → tc0) | priority 6 → band 0 (기본 priomap) | [ADR-0011](adr/0011-priority-6-default-priomap.md) |
| mqprio (4 하드웨어 큐 → 3 TC) | `prio bands 3` / `pfifo_fast` (소프트웨어) | 1 TX 큐 ([ADR-0002](adr/0002-prio-instead-of-mqprio-etf-taprio.md)) |
| ETF (CLOCK_TAI, Δ 150 μs, tc0) | 참고 스크립트만 (`step5-tc-qdisc/02-setup-etf.sh`) | talker 에 SO_TXTIME 없음 → 전량 드롭 위험 |
| ETS 게이트 (125/125/750 μs, 1 ms 주기) = 802.1Qbv | 참고 스크립트 (`03-setup-taprio.sh`) | 리눅스 `taprio`. `sch_ets`(802.1Qaz) 와 이름 충돌 주의 |
| PTP 동기화 | 소프트웨어 NTP(VM) / 같은 시계(테스트베드) | [ADR-0012](adr/0012-clock-skew-and-same-host-testbed.md) |
| isolcpus (72 코어 중 8) | 스크립트 제공, 5월 VM 미적용 | [LIMITATIONS.md](LIMITATIONS.md) |
| 실험: talker/listener 1 ms UDP, CPU 부하 경쟁 | `step7-experiment/`, stress DaemonSet(옵션) | 이 저장소는 **네트워크 경합**(BE 홍수 + 병목)을 추가 ([ADR-0006](adr/0006-testbed-needs-contention.md)) |
| 지표: bandwidth, latency, jitter | 같음 + 손실·중복·재정렬·수신 DSCP·송신 페이싱 품질 | `analysis/` |
| Fig. 2–6 (throughput, latency, jitter, CDF) | `tsn-analysis plot` 의 5개 그림 | 백분위 그룹 막대 + CDF + 박스 |

## 2. 논문과 다른 결론

논문은 CPU 경쟁 하에서 제안 스택이 latency/jitter 를 개선한다고 보고한다. 이 저장소의 5월 재현은
같은 방향의 표를 얻었지만, 메커니즘이 작동하지 않은 상태였음을 나중에 확인했다
([RESULTS.md §2](RESULTS.md)). 9월 테스트베드는 **네트워크 경합** 하에서 strict priority 의 효과를
두 자릿수 배로 확인했으나, 이는 논문의 독립변수(CPU 부하)가 아니라 큐 경합에 대한 결과다. 논문의
"CPU 경쟁 → 네트워크 품질 저하" 축은 격리(isolcpus)와 데이터플레인 코어 분리가 있어야 재현할 수
있으며, 이 저장소에서는 검증하지 못했다.

## 3. 논문에 없는데 이 저장소가 추가한 것

- 커널 소스 기반의 priority 생존 경로 분석과 실측 프로브(veth 리셋, tcx 순서).
- DSCP 마킹(패브릭 QoS 연결), 체크섬 증분 갱신, 수신단 검증.
- BPF_PROG_TEST_RUN 단위 테스트, tcx 체인 통합 테스트, CI 에서 도는 재현 가능한 테스트베드.
- 5개 조건 설계로 인과 분리, 부트스트랩 CI·효과 크기.
- 실패한 시도의 기록(ADR)과 데이터 출처 표.

# 한계와 미검증 항목 (정직한 목록)

포트폴리오 독자가 "이 프로젝트가 증명한 것과 증명하지 못한 것" 을 한눈에 볼 수 있도록 적는다.
검증 수준 표는 [VERIFICATION.md](VERIFICATION.md), 데이터 출처는 [DATA_PROVENANCE.md](DATA_PROVENANCE.md).

## 1. 환경

| 항목 | 논문 | 이 저장소 | 영향 |
|---|---|---|---|
| NIC | 4 TX/RX 하드웨어 큐, LaunchTime | VirtualBox virtio-net 1 큐 / CI 러너 veth | `mqprio hw`, ETF 하드웨어 오프로드 검증 불가 ([ADR-0002](adr/0002-prio-instead-of-mqprio-etf-taprio.md)) |
| 시계 | 하드웨어 PTP (ns) | VM: 소프트웨어 NTP (14–37 ms 오프셋, 22 ms 스텝) / 테스트베드: 같은 시계 | 두 VM one-way latency 는 상대 비교만 ([ADR-0012](adr/0012-clock-skew-and-same-host-testbed.md)) |
| CPU 격리 | 72 코어 중 8 isolcpus | 5월 VM 에 isolcpus **미적용** (스크립트만 존재). `--cpu=2` 고정은 측정 이후 추가 | CPU 부하 축 결과는 격리 없는 상태 |
| 데이터패스 | 물리 서버 | 5월: 2 VM, 9월: 단일 호스트 netns (veth ↔ host ↔ veth) | 테스트베드는 물리 NIC 드라이버 큐/IRQ 경로를 재현하지 않음 |

## 2. 측정·통계

- **5월 K8s 데이터는 우선순위 메커니즘이 작동하지 않은 상태** 에서 측정됐다 ([ADR-0016](adr/0016-results-provenance.md)).
  표는 재해석 목적으로만 남겼다.
- talker 는 파이썬 sleep/spin 페이싱이다. 5월엔 DNS 질의와 CFS quota 로 실효 216–547 pkt/s 였고,
  9월 테스트베드에서도 1 ms 페이싱 정밀도는 수십 μs 수준이다. jitter 지표에 송신 오차가 포함된다.
- 테스트베드 latency 는 사용자 공간 `time.time_ns()` 기준이라 커널 RX 타임스탬프보다 스케줄링 지연을
  포함한다(로드맵: `SO_TIMESTAMPNS`).
- 부트스트랩은 i.i.d. 가정. 정규화된 run 의 p50 CI 는 오프셋 분산을 빼고 계산돼 약간 좁다.
- CI 러너는 공유 vCPU 라 run 간 잡음이 있다. 조건당 3 run 으로는 작은 차이를 판별할 수 없다 —
  이 프로젝트가 보고하는 차이는 두 자릿수 배 이상이라 판별에 문제가 없다.

## 3. eBPF 분류기

- **IPv6 미지원**: IPv6/UDP 6000 은 분류하지 않는다(테스트로 고정). Traffic Class 재기록도 없다.
- `skb->vlan_present`(하드웨어 VLAN 오프로드) 경로는 BPF_PROG_TEST_RUN 이 vlan 필드 설정을 허용하지
  않아 **단위 테스트 불가**. 인라인 802.1Q/802.1ad 태그만 테스트했다.
- VLAN/AVTP 분기는 논문 대응용이며, Cilium 위의 Pod 트래픽에서는 절대 발생하지 않는다.
- UDP 목적지 포트 기준은 신뢰 경계가 없다(테넌트가 임의로 EF 획득 가능) — [ADR-0014](adr/0014-udp-port-classification-and-trust-boundary.md).
- DSCP 마킹은 IPv4 헤더 체크섬만 갱신한다(UDP 체크섬은 IP 헤더를 포함하지 않으므로 불필요 — 맞음).
  하지만 GSO 된 대형 skb 의 경우 `bpf_skb_store_bytes` 가 헤더를 선형 영역으로 끌어와야 하며,
  실험 트래픽(128 B)에선 문제없지만 대형 TCP TS 흐름은 검증하지 않았다.

## 4. Cilium / Kubernetes 경로 — **클러스터에서 재측정되지 않음**

- 새 설계(호스트 NIC egress, tcx BEFORE, HTB 병목 + BE 홍수)는 `deploy-experiment.sh` 로 구현했지만
  현재 VM 클러스터에 접근할 수 없어 **실제 Cilium 환경에서 실행하지 못했다.** 검증된 것은:
  netns 테스트베드(kernel 5.15 WSL2, 6.17 CI 러너)에서의 동작과, CI 의 tcx 체인 테스트뿐이다.
- Cilium 의 `cil_to_netdev` 가 우리 프로그램 뒤에서 실행될 때의 상호작용(예: Cilium 이 skb 를
  재작성해 우리가 찍은 DSCP 가 encap 바깥으로 복사되는지 — native routing 에선 encap 없음)은 추론이다.
- Cilium agent 재시작 시 tcx 체인 순서가 바뀔 가능성: `verify-experiment.sh` 가 `tcx_attach query` 로
  순서를 확인하도록 했지만 실제로 재현하지 못했다.
- VirtualBox NAT 네트워크가 DSCP 를 보존하는지도 미검증(테스트베드는 호스트 내부).

## 5. 재현하지 않은 논문 요소

| 논문 요소 | 상태 |
|---|---|
| vef (veth 필터, overlay 우회) | 의도적으로 미구현 — Cilium native routing 에선 우회할 overlay 가 없고, priority 는 veth 뒤에서만 유효 |
| XDP VLAN/AVTP 파서 | 삭제 — VM 은 generic XDP 만, 트래픽에 VLAN/AVTP 없음 |
| mqprio 하드웨어 큐 매핑 | 하드웨어 없음 |
| ETF (txtime) | talker 에 SO_TXTIME 없음, VM 에 LaunchTime 없음 |
| ETS(802.1Qbv taprio) 게이트 | 소프트웨어 taprio 의 정밀도·동기 문제로 미사용 |
| 하드웨어 PTP | 없음 |

# AI 데이터센터(AIDC) 네트워크와의 연결

이 프로젝트는 "Kubernetes Pod 의 시간 민감 트래픽을 호스트 커널에서 우선 처리한다" 는 작은 문제를
다루지만, 그 과정에서 부딪힌 것들은 AI 데이터센터 네트워크 엔지니어가 매일 다루는 문제와 같은
뿌리다. 아래 표는 저장소의 각 메커니즘이 패브릭 규모에서 무엇에 해당하는지, 그리고 이 저장소가
**어디까지 검증했고 어디부터는 하드웨어가 필요한지** 를 적는다.

## 1. 메커니즘 대응표

| 이 저장소 | 패브릭(AIDC)에서의 대응 | 검증 수준 | 파일 |
|---|---|---|---|
| `skb->priority` (호스트 내부 메타데이터) | 없음 — NIC 를 떠나면 소실. 호스트 안의 큐 선택에만 유효 | 실측 (veth 통과 시 0 리셋 포함) | `bpf/src/ts_classifier.c`, `prio_probe.c` |
| **DSCP EF(46) 마킹** + IPv4 체크섬 증분 갱신 | ToR/스파인의 `trust dscp` → 스위치 egress 큐(strict priority / WRR) 매핑. RoCEv2 는 보통 DSCP 26/AF31 + PFC 클래스 3, 제어 트래픽은 EF/CS6 | 실측 end-to-end (수신 TOS 0xB8 30,000/30,000) | `ts_classifier.c` `mark_dscp()`, `listener.py --record-tos` |
| 802.1Q PCP 판별 | L2 QoS(PCP → 스위치 큐), PFC 우선순위 클래스의 기준 | 인라인 태그 단위 테스트 | `ts_classifier.c` `classify()` |
| `prio` / `pfifo_fast` strict-priority 밴드 | NIC 하드웨어 TX 큐 + 스위치 egress strict-priority 큐 (DCB ETS 의 "strict" 그룹) | 실측 (CI 러너, 경합 하 p50 433 ms → 0.05 ms) | `testbed/run.sh` |
| `fq_codel` 흐름 격리 | 스위치의 흐름 단위 공정성은 없다(큐 단위) — 호스트 AQM 과 패브릭 QoS 의 차이 | 실측 (p99 0.73 ms, 손실 0) | 같음 |
| tbf/HTB 병목 + BE 홍수 | 집단 통신(all-reduce)의 대량 흐름과 제어/스케줄러 트래픽의 경합. 짧은 패킷의 꼬리 지연이 곧 straggler | 실측 (테스트베드) | `workload/be_flood.py` |
| p99 / p99.9 꼬리 지연 | 분산 학습에서 한 랭크의 지연이 전체 스텝을 잡는다(straggler). 평균이 아니라 꼬리가 SLO | 통계 패키지 | `analysis/` |
| tcx 체인 순서 (`BPF_F_BEFORE`, `TCX_NEXT`) | CNI 데이터패스(Cilium)와 사용자 BPF 의 공존 — 관측/QoS 훅을 넣을 때 필수 지식 | CI 통합 테스트 (kernel 6.17) | `tools/tcx_attach.c`, `tests/test_tcx_chain.sh` |
| 1 TX 큐 VM, 격리 없음 | 실제 서버: 멀티큐 NIC + RSS/XPS + IRQ affinity + isolcpus/nohz_full 로 데이터플레인 코어 분리 | 미검증 (하드웨어 없음) | `scripts/setup/isolcpus.sh` (참고) |
| 소프트웨어 시계, p1 정규화 | 하드웨어 PTP(PHC) + `SO_TIMESTAMPING` 으로 ns 급 one-way 측정 | 미검증 | [ADR-0012](adr/0012-clock-skew-and-same-host-testbed.md) |
| ETF / taprio (미사용) | TSN 802.1Qbv 게이트, NIC LaunchTime — 산업/차량용. AIDC 에선 드묾 | 실패 기록 | [ADR-0002](adr/0002-prio-instead-of-mqprio-etf-taprio.md) |

## 2. 이 프로젝트가 AIDC 관점에서 보여주는 것

1. **우선순위는 "어디서 찍느냐" 가 전부다.** Pod 안에서 `SO_PRIORITY` 를 줘도 veth 를 건너면 0 이다
   (`____dev_forward_skb()`). 마찬가지로 호스트가 찍은 `skb->priority` 는 NIC 밖에서 0 이다.
   패브릭까지 가는 신호는 **패킷 헤더(DSCP/PCP)** 뿐이고, 그 신호를 스위치가 신뢰하도록 설정해야
   한다. 이 저장소는 그 첫 홉(호스트 → 와이어)을 eBPF 로 구현하고 수신단에서 확인했다.
2. **경합이 없으면 QoS 는 관측되지 않는다.** 5월 실험이 그랬다. 실제 패브릭에서도 "QoS 를 켰는데
   효과가 없다" 는 대개 병목이 다른 곳(호스트 CPU, DNS, 애플리케이션 페이싱)에 있다는 뜻이다.
   테스트베드는 병목을 명시적으로 만들고(tbf/HTB), 교란 변수(DNS, CFS quota)를 제거한 뒤에야
   두 자릿수 배의 차이를 얻었다.
3. **꼬리를 보고, 표본과 구간을 붙여라.** p99 와 손실을 부트스트랩 CI 로 보고하고, 조건을 다섯 개로
   나눠 인과를 분리했다(`pfifo_fast_noclsf` = `fifo` 이므로 효과는 qdisc 가 아니라 "priority 가
   도달했는가" 에서 온다).
4. **CNI 와 공존하는 관측/제어 훅.** kernel ≥ 6.6 + Cilium 에서 `tc filter add … bpf` 는 실행되지
   않을 수 있다. tcx 링크 + 순서 제어 + `TCX_NEXT` 반환이 정답이며, 이는 Tetragon/Hubble 같은
   관측 도구가 데이터패스에 끼어드는 방식과 같다.

## 3. 패브릭에서 하려면 (로드맵)

| 단계 | 내용 | 필요한 것 |
|---|---|---|
| R1 | 클러스터(VM) 재측정: `scripts/experiment.sh matrix` (HTB + BE 홍수, 5 조건 × CPU 부하 × ≥5 run) | VM 2대 접근 |
| R2 | 스위치 측 QoS: `trust dscp`, EF → strict-priority 큐, RoCE 클래스와 분리, ECN 마킹 임계 | 실 스위치 또는 SONiC VS |
| R3 | 멀티큐 NIC 에서 `mqprio hw 1` 로 TC ↔ 하드웨어 큐 매핑, XPS/IRQ affinity, `isolcpus` | 물리 서버 |
| R4 | 하드웨어 PTP + `SO_TIMESTAMPING`(TX/RX 하드웨어 스탬프) 로 ns 급 one-way latency | PHC 지원 NIC |
| R5 | 분류 신뢰 경계: 출발지 identity 기반 허용 목록, 애플리케이션 DSCP 검증/정규화 | Cilium identity 연동 |
| R6 | RDMA/RoCEv2 흐름과의 공존 실험: PFC 헤드라인 블로킹, DCQCN 과 EF 클래스 상호작용 | RoCE NIC |
| R7 | IPv6 Traffic Class, SO_TXTIME + ETF (TSN 계열 요구가 있을 때) | — |

## 4. 면접에서 자주 나올 만한 연결 질문 (요약)

- "DSCP 와 PCP 중 무엇을 쓰나?" — 컨테이너 트래픽은 untagged 라 PCP 가 없다. L3 DSCP 가 기본,
  L2 PCP 는 태그된 링크에서 보조. 둘 다 스위치가 trust 해야 의미가 있다.
- "PFC 와 이 우선순위는 어떻게 다른가?" — PFC 는 손실 방지용 flow control(클래스별 pause),
  strict priority 는 스케줄링. RoCE 는 PFC+ECN 으로 무손실을, 제어 트래픽은 strict priority 로
  낮은 지연을 노린다. 같은 클래스에 섞으면 HoL blocking 이 생긴다.
- "왜 fq_codel 도 꽤 좋았나?" — 흐름 단위 공정 큐가 저속 흐름을 우대하기 때문(sparse flow).
  그러나 손실 0 이면서 p99 0.73 ms 로, strict priority(0.17 ms)보다 4배 느리고, 패브릭 스위치엔
  흐름 단위 큐가 없다.

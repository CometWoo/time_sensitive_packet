# ADR-0002 — mqprio + ETF + taprio(802.1Qbv) 대신 소프트웨어 strict-priority qdisc(prio / pfifo_fast) 를 쓴다

- 상태: 채택 (2026-05 결정, 2026-06 ETF 제거, 2026-09 재확인)
- 관련: [ADR-0001](0001-virtualbox-vms-instead-of-physical-tsn-nics.md), [ADR-0010](0010-qdisc-conditions.md)

## 문제

논문 §IV 의 송신측 스케줄링 스택: `mqprio`(VLAN PCP → 3개 TC → 4개 하드웨어 큐) + `ETF`(tc0 에
CLOCK_TAI txtime, Δ=150 μs) + ETS 게이트 스케줄(125/125/750 μs, 1 ms 주기). 이 저장소의 VM 과
러너에는 하드웨어 큐도, LaunchTime 도, ns 급 PTP 도 없다.

## 시도와 실패의 기록

| 시도 (commit) | 결과 |
|---|---|
| `mqprio num_tc 3 … queues 1@0 1@0 1@0 hw 0` (430eccc) | 큐 범위가 겹치면 `mqprio_parse_opt` 가 EINVAL. virtio-net 은 TX 큐 1개라 `1@0 1@1 1@2` 도 불가 |
| `ethtool -L combined 4` 뒤 mqprio (3c4fb19) | VirtualBox 는 virtio multiqueue 를 노출하지 않음 |
| `mqprio hw 1 mode dcb` | virtio 드라이버에 `ndo_setup_tc` 없음 |
| `etf clockid CLOCK_TAI delta 150000 deadline_mode on` 을 band 0 에 child 로 (430eccc~) | `sch_etf` 의 `is_packet_valid()` 는 소켓에 `SOCK_TXTIME` 이 없으면 **드롭**한다(net/sched/sch_etf.c v6.8 L75-97). talker 는 `SO_TXTIME`/`SCM_TXTIME` 을 쓰지 않으므로 TS 패킷이 전량 드롭될 위험 → 3c4fb19 에서 메인 경로에서 제거 |
| taprio 소프트웨어 모드 게이트 리스트 (step5 참고 스크립트) | (a) `base-time=$(date +%s)…`(REALTIME) 과 `clockid CLOCK_TAI` 가 37 s 어긋남, (b) VM hrtimer 정밀도 수십 μs, (c) talker 가 게이트와 비동기라 tc0 게이트가 닫힌 250 μs 동안 대기 → latency/jitter 오히려 증가 |
| `sch_ets` | 이름이 같지만 논문의 ETS(Enhancements for Scheduled Traffic, 802.1Qbv = Linux `taprio`)가 아니라 802.1Qaz Enhanced Transmission Selection(가중 라운드로빈). 게이트 의미 없음 — step5 스크립트의 혼동을 문서에서 바로잡음 |

## 결정

- 우선순위 dequeue 라는 **의도**만 보존하는 소프트웨어 strict-priority qdisc 를 쓴다:
  `prio bands 3`(기본 priomap) 또는 커널 내장 `pfifo_fast`(같은 priomap, 모듈 불필요).
- ETF/taprio/mqprio 스크립트는 `scripts/qdisc-reference/` 에 **참고용(REFERENCE ONLY)** 으로 남기고 메인
  경로에서 호출하지 않는다. 각 스크립트 머리에 위 실패 사유를 적었다.
- ETF 를 실제로 쓰려면 talker 가 패킷마다 `SCM_TXTIME` 으로 미래 송신 시각을 지정해야 하고
  (`SO_TXTIME` + `CLOCK_TAI`), 그 시각이 의미 있으려면 PTP 동기 + LaunchTime 지원 NIC 가 필요하다.
  → [docs/AIDC_RELEVANCE.md](../AIDC_RELEVANCE.md) 의 실 하드웨어 로드맵.

## 결과

- 물리 fabric 에서 큐 분리는 mqprio 가 아니라 **DSCP → 스위치 큐 매핑**으로 넘긴다
  ([ADR-0007](0007-dscp-marking-for-fabric-qos.md)).
- 조건 비교 설계는 [ADR-0010](0010-qdisc-conditions.md).

# ADR-0016 — 2026-05 K8s 측정 결과는 "메커니즘 미작동 상태의 데이터" 로 재분류하고 보존한다

- 상태: 채택 (2026-09)
- 관련: [ADR-0003](0003-classify-at-host-nic-egress.md), [ADR-0006](0006-testbed-needs-contention.md), [ADR-0008](0008-talker-resolve-once.md), [docs/RESULTS.md](../RESULTS.md)

## 문제

`step8-measurement/results/*.csv` 9개는 2026-05-25 에 commit `8fc0be1` 구성(3-프로그램 eBPF,
UDP 5000, `SO_PRIORITY=3`, `prio priomap 2 2 1 0…` vs 기본 qdisc)으로 측정됐다. 이후 두 번의
재설계(6월 단일 프로그램, 9월 호스트 NIC egress)가 있었지만 데이터는 그대로였고, README 는 그
표를 최신 아키텍처 아래에 두었다. 감사(F01)와 커널 소스 검증으로 다음이 확정됐다.

1. 호스트측 BPF 는 tcx 순서 때문에 한 번도 실행되지 않았다(pkt_stats=0).
2. `SO_PRIORITY=3` 은 veth 에서 0 으로 리셋됐고, 커스텀 priomap 에서 0 은 **band 2(최하위)**.
3. 경쟁 트래픽이 없어 어떤 qdisc 든 큐가 비어 있었다.
4. talker 가 패킷마다 DNS 를 질의해 실효 216–547 pkt/s 였고 DNS 왕복이 latency 에 포함됐다.

따라서 "proposed 가 p99 latency 를 28–74 % 개선" 은 우선순위 큐 효과가 아니다.

## 결정

- 데이터는 **삭제하지 않는다.** `step8-measurement/results/` 에 그대로 두고, 표는
  [docs/RESULTS.md](../RESULTS.md) 의 "2026-05 K8s 측정 — 재해석" 절로 옮긴다. 각 파일에
  출처(commit, 구성, 실효 송신 속도, p1 오프셋)를 붙인다([docs/DATA_PROVENANCE.md](../DATA_PROVENANCE.md)).
- README 상단 상태 배너에 "5월 데이터는 메커니즘이 작동하지 않은 상태의 측정" 임을 명시한다.
- 유효한 결과의 자리는 9월 netns 테스트베드(CI 러너 kernel 6.17, 경합 있음, 같은 시계)가 맡고,
  K8s 클러스터 재측정은 로드맵(D4)으로 남긴다(현재 VM 접근 불가).
- 5월 데이터에서 **여전히 배울 수 있는 것**을 적는다: fq_codel vs prio(단일 밴드) 의 코드 경로 차이,
  VM 하이퍼바이저 스톨 분포, DNS/CFS 교란의 신호(송신 간격 분포).

## 왜 삭제하지 않나

포트폴리오의 가치는 "맞는 숫자" 보다 "틀린 숫자를 어떻게 찾아내고 무엇으로 대체했는가" 에 있다.
측정 → 의심 → 커널 소스 확인 → 실측 반증 → 재설계 → 재측정의 흐름이 남아야 한다.

# ADR-0016 — 2026-05 K8s 측정은 철회하고, 원본은 히스토리에만 남긴다

- 상태: 채택 (2026-09), 개정 (2026-11: 원본 CSV 를 트리에서 제거)
- 관련: [ADR-0003](0003-classify-at-host-nic-egress.md), [ADR-0006](0006-testbed-needs-contention.md), [ADR-0008](0008-talker-resolve-once.md), [docs/RESULTS.md](../RESULTS.md)

## 문제

2026-05-25 에 commit `8fc0be1` 구성(3-프로그램 eBPF, UDP 5000, `SO_PRIORITY=3`,
`prio priomap 2 2 1 0…` vs 기본 qdisc)으로 측정한 CSV 9개가 있었다. 감사와 커널 소스 검증으로 다음이 확정됐다.

1. 호스트측 BPF 는 tcx 순서 때문에 한 번도 실행되지 않았다(pkt_stats=0).
2. `SO_PRIORITY=3` 은 veth 에서 0 으로 리셋됐고, 커스텀 priomap 에서 0 은 band 2(최하위).
3. 경쟁 트래픽이 없어 어떤 qdisc 든 큐가 비어 있었다.
4. talker 가 패킷마다 DNS 를 질의해 실효 216–547 pkt/s 였고 DNS 왕복이 latency 에 포함됐다.

따라서 "proposed 가 p99 latency 를 28–74 % 개선" 은 우선순위 큐 효과가 아니다.

## 결정

- 5월 결과는 근거로 쓰지 않는다. 유효한 결과는 9월 netns 테스트베드(CI 러너 kernel 6.17, 경합 있음,
  같은 시계)이고, K8s cluster 재측정은 로드맵으로 남긴다(현재 VM 접근 불가).
- 왜 틀렸는지는 [docs/RESULTS.md](../RESULTS.md) 2절에 남긴다.
- 원본 CSV 9개와 그래프는 v0.4 에서 트리에서 내린다. 커밋 `67556cd` 이전 히스토리에 있다.

## 이유

틀린 숫자를 어떻게 찾아냈는지는 이 프로젝트의 핵심이라 기록으로 남긴다. 하지만 원본 CSV 는 다시 쓸 데가
없다. 두 VM 시계가 어긋나 raw latency 의 99 % 가 음수이고, 비교하려던 메커니즘은 실행되지 않았다. 트리에
두면 읽는 사람이 무효인 표를 다시 만들 위험만 남는다. 2026-09 의 결정은 "삭제하지 않고 보존" 이었고,
2026-11 에 위처럼 바꿨다.

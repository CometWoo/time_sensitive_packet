# ADR-0011 — skb->priority 값은 6 (커널 기본 priomap 으로 band 0) 을 쓴다

- 상태: 채택 (2026-06, 2026-09 재확인)
- 관련: [ADR-0004](0004-non-ts-priority-untouched.md), [ADR-0010](0010-qdisc-conditions.md)

## 배경

논문 Table I 은 VLAN PCP 3 → tc0(TS) 매핑이라 5월 구현은 `SO_PRIORITY=3` + 커스텀 priomap
`2 2 1 0 2 2 …`(priority 3 → band 0) 을 썼다. 커스텀 priomap 은 (a) 디바이스마다 다시 줘야 하고,
(b) 실수로 기본 priomap 이 적용되면 3 은 band 1(중간)이며, (c) priority 가 0 으로 리셋되면 이 맵에선
band **2(최하위)** 로 간다 — 5월 "proposed" 에 실제로 일어난 일.

커널 기본 priomap (`net/sched/sch_generic.c` `prio2band`, `sch_prio.c` 기본값):

```
priority : 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
band     : 1 2 2 2 1 2 0 0 1 1  1  1  1  1  1  1
```

## 결정

- TS 패킷의 `skb->priority = 6`. 기본 priomap 에서 6, 7 만 band 0 이다.
- 6 은 `SO_PRIORITY` 를 **CAP_NET_ADMIN 없이** 설정할 수 있는 최대값이다
  (net/core/sock.c v6.8 L1118-1125: `val >= 0 && val <= 6` 또는 CAP_NET_RAW/CAP_NET_ADMIN).
  애플리케이션이 직접 설정하는 경로와 분류기 경로가 같은 값을 쓴다.
- `prio` 도 `pfifo_fast` 도 커스텀 priomap 없이 그대로 동작한다.
- 값은 `ts_config.priority` 로 런타임 변경 가능(예: mqprio 하드웨어 매핑에 맞출 때).

## 고려한 대안

| 대안 | 비고 |
|---|---|
| 3 + 커스텀 priomap (논문 Table I) | 논문 충실. 위 (a)(b)(c) 취약성 |
| 7 + 기본 priomap | band 0 이지만 애플리케이션 경로는 CAP_NET_ADMIN 필요 |
| `TC_H_MAJ` 형식(0x10001 등)으로 클래스 직접 지정 | `prio_classify()` 는 `TC_H_MAJ(priority) == sch->handle` 이면 필터를 건너뛰고 minor 를 band 로 씀 — 특정 qdisc 핸들에 종속 |

# ADR-0004 — 분류기는 TS 패킷만 마킹하고, 비-TS 패킷의 skb->priority 는 건드리지 않는다

- 상태: 채택 (2026-09)
- 관련: [ADR-0003](0003-classify-at-host-nic-egress.md), [ADR-0011](0011-priority-6-default-priomap.md)

## 문제

구 `vnic_filter.c` 는 TS 가 아니면 `skb->priority = 0` 으로 **덮어썼다**. 호스트 NIC egress 에
붙는 새 위치에서는 그 hook 을 지나는 모든 트래픽(K8s 제어 평면, Cilium health, 다른 애플리케이션이
`SO_PRIORITY` 나 `net_prio` cgroup 으로 설정한 값)이 영향을 받는다.

## 결정

- TS 로 판별된 패킷만 `skb->priority = cfg.priority`(기본 6) 를 쓴다.
- 그 외 패킷은 **바이트 하나도 바꾸지 않고** `TC_ACT_UNSPEC` 으로 넘긴다.
- 테스트 `test_other_udp_port_untouched_keeps_existing_priority`(ctx priority 3 → 3 유지),
  `test_non_ts_never_modifies_packet_bytes` 가 이를 고정한다.

## 고려한 대안

| 대안 | 기각 사유 |
|---|---|
| 비-TS 를 0 으로 강제 (구 설계) | 다른 서비스의 QoS 설정을 조용히 파괴. "관찰자 원칙" 위반 |
| 비-TS 를 낮은 밴드로 강등 (priority 1 등) | 실험 대비군을 인위적으로 악화시켜 결과를 부풀림 |
| **TS 만 마킹 (채택)** | 최소 침습, 실험 변수는 오직 "TS 가 band 0 으로 가는가" |

## 결과

DSCP 재기록도 같은 원칙: `TS_CFG_MARK_DSCP` 플래그가 켜져 있고 TS 이며 IPv4 일 때만, ECN 2 bit 는
보존한 채 DSCP 6 bit 만 바꾼다.

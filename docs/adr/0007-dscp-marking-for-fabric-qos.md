# ADR-0007 — 호스트 밖 QoS 는 skb->priority 가 아니라 DSCP(IP 헤더)로 전달한다

- 상태: 채택 (2026-09)
- 관련: [ADR-0003](0003-classify-at-host-nic-egress.md), [docs/AIDC_RELEVANCE.md](../AIDC_RELEVANCE.md)

## 문제

`skb->priority` 는 **호스트 커널 내부 메타데이터**다. NIC 를 떠나는 순간 사라지고, ToR/스파인
스위치는 볼 수 없다. 논문의 스택(mqprio hw 큐)도 호스트 안에서 끝난다. AI 데이터센터처럼
여러 홉을 지나는 패브릭에서 우선순위를 유지하려면 와이어에 실리는 표식이 필요하다:

- L2: 802.1Q PCP (VLAN 태그가 있을 때만; 컨테이너 트래픽은 보통 untagged)
- L3: **IPv4 TOS 의 DSCP 6 bit** / IPv6 Traffic Class — 스위치가 trust-dscp 로 큐/PFC 클래스에 매핑

## 결정

`ts_classifier` 에 선택적 DSCP 재기록을 넣는다 (`ts_config.flags & TS_CFG_MARK_DSCP`, 기본 DSCP 46 EF).

- TOS 바이트는 IPv4 첫 16-bit 워드(version/IHL | TOS)의 하위 바이트이므로 `bpf_l3_csum_replace()` 로
  해당 워드만 **증분 갱신**(RFC 1624)하고 `bpf_skb_store_bytes()` 로 1 바이트를 쓴다.
- ECN 2 bit 는 보존한다(DCQCN/ECN 마킹과 충돌하지 않도록).
- 검증: BPF_PROG_TEST_RUN 테스트(체크섬 재계산 일치, IP 옵션·VLAN 태그 오프셋, no-op), 테스트베드
  listener 의 `IP_RECVTOS` 로 수신단에서 0xB8 확인 (3,000/3,000).

## 고려한 대안

| 대안 | 장단점 |
|---|---|
| 애플리케이션이 `IP_TOS` 로 직접 설정 (talker `--tos`) | 가장 단순, 권한 불필요. 그러나 애플리케이션 수정이 필요하고 정책을 중앙에서 바꿀 수 없음. 이 저장소는 **둘 다** 지원(talker 옵션 + 분류기) |
| `iptables -t mangle -j DSCP` | 표준 도구. netfilter 는 Cilium bpf_redirect 경로를 지나지 않을 수 있고(호스트 라우팅 우회), 분류 조건(AVTP/PCP)을 표현 못 함 |
| VLAN PCP 만 사용 | untagged 컨테이너 트래픽엔 적용 불가, L3 홉에서 소실 |
| **분류기가 DSCP 재기록 (채택)** | 한 곳에서 분류·우선순위·DSCP 를 일관되게, 카운터로 관측 가능 |

## 결과

- 실제 패브릭 적용 시 스위치 측 설정(trust DSCP, EF → strict-priority 큐, RoCE 클래스와의 분리)이
  필요하며 이는 이 저장소 범위 밖이다 — [docs/AIDC_RELEVANCE.md](../AIDC_RELEVANCE.md) 에 로드맵.
- IPv6 Traffic Class 재기록은 미구현 ([docs/LIMITATIONS.md](../LIMITATIONS.md)).

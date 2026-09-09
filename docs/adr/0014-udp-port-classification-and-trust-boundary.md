# ADR-0014 — TS 판별 기준에 UDP 목적지 포트를 포함한다 (논문의 AVTP/VLAN PCP 에 더해)

- 상태: 채택 (2026-05 포트 5000, 2026-06 포트 6000, 2026-09 map 으로 확장)
- 관련: [ADR-0007](0007-dscp-marking-for-fabric-qos.md), [docs/LIMITATIONS.md](../LIMITATIONS.md)

## 문제

논문의 TS 판별은 L2 표식(IEEE 1722 AVTP EtherType, 802.1Q PCP)이다. 그러나 Cilium native
routing 위의 Pod 가 보내는 트래픽은 **untagged plain UDP** 다 — VLAN 태그도 AVTP 도 Pod 소켓
API 로는 만들 수 없다(AF_PACKET + CAP_NET_RAW 가 필요). 재현 실험에서 L2 기준만 쓰면 분류기는
아무것도 잡지 못한다.

## 결정

- 분류 기준 = AVTP EtherType **또는** 802.1Q/802.1ad 외곽 PCP ≥ 5 **또는** IPv4/UDP 목적지 포트
  ∈ {컴파일 타임 기본 6000} ∪ `ts_udp_ports` map.
- 포트 map 은 bpftool 로 런타임에 추가/삭제하고, 기본 포트는 `TS_CFG_DISABLE_UDP_DEFAULT`
  플래그로 끌 수 있다.
- 포트 5000 → 6000 변경(2026-06)은 iperf3 기본 포트(5001) 등과의 혼동을 피하려는 정리였고,
  기능 차이는 없다. 이 저장소에서 5001 은 best-effort 홍수 포트로 쓴다.

## 신뢰 경계 (중요)

목적지 포트는 **송신 테넌트가 마음대로 정하는 값**이다. 프로덕션에서 dport 만으로 EF 를 주면
아무 Pod 나 6000 번으로 보내 우선순위를 가로챌 수 있다. 실험 목적(어떤 흐름이 TS 인지 실험자가
안다)에는 충분하지만, 실제 적용에서는:

- 출발지 Pod/네임스페이스 identity(Cilium identity, cgroup id, 출발지 IP/포트)로 제한하거나
- 애플리케이션이 `IP_TOS` 로 찍은 DSCP 를 **검증·정규화**(허용 목록에 없는 EF 는 강등)하는 정책 쪽이 맞다.

이 점은 [docs/LIMITATIONS.md](../LIMITATIONS.md) 와 [docs/AIDC_RELEVANCE.md](../AIDC_RELEVANCE.md) 에도 적었다.

## 고려한 대안

| 대안 | 비고 |
|---|---|
| L2 만 (논문 충실) | Pod 트래픽에 적용 불가 |
| DSCP 를 입력으로 (애플리케이션이 `IP_TOS` 설정) | 좋은 보완책. talker `--tos` 로 지원하며, 분류기 입력으로 삼는 것은 로드맵 |
| Cilium 네트워크 정책/identity 연동 | 프로덕션 방향. 실험 범위 밖 |

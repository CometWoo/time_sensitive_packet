# ADR-0012 — 두 VM 사이 one-way latency 는 1st-percentile 정규화로만 상대 비교하고, 절대값은 같은 시계(단일 호스트 테스트베드)에서만 말한다

- 상태: 채택 (2026-05 정규화, 2026-09 테스트베드 추가)
- 관련: [ADR-0001](0001-virtualbox-vms-instead-of-physical-tsn-nics.md), [ADR-0015](0015-statistics.md)

## 문제

one-way latency = `recv_ns − send_ns` 는 두 호스트의 시계 오프셋을 그대로 포함한다. virtio NIC 는
하드웨어 타임스탬프가 없고 ptp4l/chrony 는 ms 급이다. 5월 CSV 의 raw latency 는 **99 % 이상이
음수**(오프셋 −14 ~ −37 ms) 였고, cpu70 두 run 사이에 ~22 ms 시계 스텝이 있었다. run 안의 드리프트는
0.03~0.6 ms/10 s 로 작았다.

## 결정 (5월, 유지)

각 run 의 latency 에서 그 run 의 **1st percentile** 을 빼 "가장 빠른 1 % 대비 초과 지연" 으로
보고한다. 최소값(단일 outlier 에 민감)이나 중앙값(꼬리 구조 파괴)보다 강건하다.

- 단점: 조건 간 **상수 오프셋 차이는 보이지 않는다**(각 run 이 자기 바닥에 정렬되므로). p50 비교는
  의미가 약하고, p99/p99.9 같은 꼬리 폭 비교만 유효하다. `analysis` 의 bootstrap CI 는 p50 에 대해
  오프셋 추정 분산을 포함하지 않아 좁게 나올 수 있음을 문서에 명시한다.
- 대안으로 검토한 RTT/echo 방식(listener 가 되돌려 보내고 talker 가 RTT/2 를 한 시계로 측정)은
  경로가 대칭이라는 가정이 필요해 우선순위 실험(단방향 경합)엔 부적합.

## 결정 (9월, 추가)

메커니즘 검증과 경합 실험은 **단일 호스트 netns 테스트베드**에서 한다. 송수신이 같은
`CLOCK_REALTIME` 을 쓰므로 정규화 없이 절대 one-way latency 가 유효하다(WSL 무경합 실측
p50 0.113 ms, p99 0.21 ms). K8s 두 VM 결과는 상대 비교용으로만 남긴다.

## 결과

- `tsn-analysis summary --normalize-skew` 는 명시적 옵션이다. 테스트베드 결과엔 쓰지 않는다.
- jitter(`t_i − (t_{i−1} + T)`)와 손실은 수신측 단일 시계 지표라 두 환경 모두 유효하지만,
  송신 페이싱 오차를 포함한다([ADR-0008](0008-talker-resolve-once.md)).

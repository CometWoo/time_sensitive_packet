# ADR-0010 — 비교 조건은 baseline/proposed 두 개가 아니라 다섯 개다

- 상태: 채택 (2026-09)
- 관련: [ADR-0006](0006-testbed-needs-contention.md), [ADR-0002](0002-prio-instead-of-mqprio-etf-taprio.md)

## 문제

5월 실험은 `baseline`(root qdisc 삭제 → 배포판 기본 `fq_codel`) vs `proposed`(`prio` + 커스텀
priomap) 두 조건이었다. 두 가지가 섞여 있었다.

1. 대조군이 "우선순위 없음" 이 아니다. `fq_codel` 은 흐름별 DRR 공정 큐 + CoDel AQM 이라
   저속의 TS 흐름을 **이미 잘 보호**한다(sparse flow 우대). 그래서 "strict priority vs fair
   queueing" 비교였지 "priority vs none" 이 아니었다.
2. 6월 재설계는 baseline 을 명시적 `fq_codel` 로 고정했는데, 그 이유가 "`pfifo_fast` 기본
   priomap 은 priority 6 을 band 0 으로 보내 대조가 사라진다" 였다. 이는 곧 **priority 가 정말
   호스트에 도달하는지**를 조건 하나로 검증할 수 있다는 뜻이기도 하다.

## 결정 — 테스트베드·K8s 공통 조건 이름

| 조건 | 병목 아래 qdisc | 분류기 | 무엇을 보여주나 |
|---|---|---|---|
| `fifo` | `pfifo limit 1000` | 없음 | 우선순위도 AQM 도 없는 "멍청한 NIC 큐". 최악 기준선 |
| `fq_codel` | `fq_codel` | 없음 | 리눅스 기본. 공정 큐만으로 저속 TS 흐름이 얼마나 보호되는가 |
| `pfifo_fast_noclsf` | `pfifo_fast` | 없음 | 3-band 우선순위 큐가 있어도 priority 가 0 이면(veth 리셋) `fifo` 와 같다 = **5월 설계의 실제 상태** |
| `pfifo_fast_clsf` | `pfifo_fast` | 있음 | 호스트 NIC egress 분류기 → priority 6 → band 0. 커널 내장 qdisc 만으로 효과 |
| `prio_clsf` | `prio bands 3` | 있음 | K8s "proposed" 가 의도했던 상태 (sch_prio 모듈) |

`baseline` → `fq_codel`, `proposed` → `prio_clsf` 별칭을 유지해 옛 명령과 문서가 깨지지 않게 한다.

## 왜 이 다섯인가

- `fifo` 와 `pfifo_fast_noclsf` 가 같고, `pfifo_fast_clsf` 가 크게 다르면 → 효과는 qdisc 가
  아니라 **priority 가 도달했는가**에서 온다는 인과가 분리된다.
- `fq_codel` 이 `fifo` 보다 좋고 `*_clsf` 보다 나쁘면 → 공정 큐와 strict priority 의 차이를
  정량화한다(AIDC 에서 "왜 DSCP 기반 strict-priority 큐를 쓰는가" 의 근거).
- 각 조건 3회 반복, 조건 순서를 run 마다 고정하지 않고 순환해 시간 드리프트를 분산한다.

## 결과

`testbed/run_testbed.sh --conditions`, `deploy-experiment.sh run <condition>`,
`analysis` 패키지의 baseline 자동 선택(`baseline` > `pfifo`/`fifo` > 첫 조건) 이 이 이름을 공유한다.

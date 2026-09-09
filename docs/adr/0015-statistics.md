# ADR-0015 — 결과는 선형 보간 백분위 + 부트스트랩 CI + Mann-Whitney U + Cliff's δ 로 보고한다

- 상태: 채택 (2026-09)
- 관련: [ADR-0012](0012-clock-skew-and-same-host-testbed.md), `analysis/`

## 문제

5월 스크립트는 두 가지 백분위 정의를 섞어 썼고(`compare_results.py` 최근접 순위, `plot-results.py`
numpy 선형 보간), 단일 run 의 점추정만 보고했으며, "개선 −73.7 %" 가 잡음인지 신호인지 말할 수
없었다. max 는 10,000 개 중 1개 값이라 결론에 쓸 수 없다.

## 결정

| 항목 | 선택 | 이유 |
|---|---|---|
| 백분위 | `numpy.percentile(method="linear")` (Hyndman–Fan type 7) 하나로 통일 | 가장 널리 쓰이는 정의, 두 스크립트 불일치 제거 |
| 신뢰구간 | 비모수 부트스트랩 95 % (B=2000, 고정 seed) | latency 분포는 꼬리가 길어 정규 근사 부적합 |
| 조건 간 검정 | Mann-Whitney U (양측) | 분포 가정 없음, 꼬리 값에 강건. t-검정은 평균 기반이라 outlier 에 취약 |
| 효과 크기 | Cliff's δ (O(n log n) 구현, 소규모 입력에서 O(n²) 참조 구현과 대조 테스트) | p 값은 n=10,000 이면 무엇이든 유의해 보인다. 크기가 필요 |
| 반복 | 조건당 ≥ 3 run, run 순서 순환(ABAB) | 시간 드리프트·러너 잡음 분산 |
| 손실/무결성 | seq 기반 손실·중복·재정렬, 실효 송신 속도, 송신 간격 p50/p99 | 결과보다 먼저 데이터 품질을 보고 |
| 두 VM 결과 | 1st-percentile 정규화(옵션)로 상대 비교만 | [ADR-0012](0012-clock-skew-and-same-host-testbed.md) |

## 알려진 한계

- 정규화된 run 에서 p50 의 CI 는 오프셋 추정 분산을 포함하지 않아 약간 좁다(리뷰에서 지적,
  문서화). 꼬리(p99) 비교엔 영향이 미미하다.
- 부트스트랩은 표본이 i.i.d. 라고 가정한다. 시계열 상관이 있는 latency 에는 블록 부트스트랩이
  더 정확하다 — 로드맵.

## 결과

`analysis/tsn_analysis/` 패키지(65 테스트, ruff 클린)와 `tsn-analysis summary|plot|compare` CLI.
README 의 모든 숫자는 이 CLI 출력에서 가져온다.

# ADR-0013 — 실험 워크로드는 커스텀 이미지 대신 ConfigMap 으로 주입하고, ConfigMap 은 kustomize 가 .py 파일에서 생성한다

- 상태: 채택 (2026-05 ConfigMap, 2026-09 kustomize 생성)

## 이력

| 시점 | 결정 | 이유 |
|---|---|---|
| 2026-05 초기 | talker/listener 용 Docker 이미지 빌드 (`Dockerfile` + stress-ng 포함) | 논문의 컨테이너 워크로드를 그대로 |
| 2026-05 (eeec9ad) | `python:3.11-slim` + **ConfigMap 으로 스크립트 주입** | master VM 에 docker/nerdctl 이 없고, 레지스트리도 없어 이미지 배포가 병목. PVC 는 Pending → emptyDir |
| 2026-06 | YAML 안에 `.py` 사본을 인라인 (talker-job.yaml 150줄 중 100줄이 파이썬) | 단순함. 그러나 `workload/talker.py` 와 두 벌이 되어 **드리프트** 발생(감사에서 인라인본과 파일본 차이 확인) |
| 2026-09 (본 ADR) | `kustomization.yaml` 의 `configMapGenerator` 가 `.py` 파일에서 생성 | 단일 소스. `disableNameSuffixHash` 로 이름 고정, 내용 변경 시 rollout restart |

## 결정

- `k8s/kustomization.yaml`: `talker-script`, `listener-script`, `be-flood-script`,
  `udp-sink-script` 를 각각 `../workload/talker.py`, `../workload/listener.py`,
  `../workload/be_flood.py`, `../workload/udp_sink.py` 에서 생성.
- 파일이 kustomization 디렉터리 밖에 있으므로 `kubectl kustomize --load-restrictor
  LoadRestrictionsNone … | kubectl apply -f -` 로 적용한다(`kubectl apply -k` 는 이 플래그가 없다).
  테스트베드와 K8s 가 **같은 파이썬 파일**을 쓰기 위한 의도적 선택.
- 실행마다 값이 바뀌는 리소스(talker Job, be-flood Job, stress DaemonSet)는 `__PLACEHOLDER__`
  템플릿으로 두고 `scripts/experiment.sh run` 이 치환해 적용한다.

## 고려한 대안

| 대안 | 비고 |
|---|---|
| 커스텀 이미지 + 레지스트리 | 재현성은 좋지만 실험 VM 에 빌드/푸시 경로가 없음. 로드맵: CI 가 GHCR 로 이미지 발행 |
| 인라인 ConfigMap 유지 | 드리프트 재발 위험. CI 에서 diff 검사로 막을 수도 있으나 생성이 더 단순 |
| Helm 차트 | 값 치환에는 좋지만 실험 스크립트 규모에 과함 |

## 결과

- Dockerfile 2개, `build-and-deploy.sh`, `test-master.yaml`(옛 attach 용 더미 Pod) 삭제.
- CI lint 잡이 `kubectl kustomize … | kubeconform -strict` 로 매니페스트를 검증한다.

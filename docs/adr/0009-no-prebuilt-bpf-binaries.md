# ADR-0009 — 빌드된 BPF 오브젝트는 커밋하지 않고, CI 가 빌드·검증한다

- 상태: 채택 (2026-09). 2026-05 "pre-built .o 커밋" 결정을 뒤집음
- 관련: [ADR-0005](0005-tcx-before-cilium.md)

## 이력

| 시점 | 결정 | 이유 |
|---|---|---|
| 2026-05 (d18a6de) | `build/*.bpf.o` 커밋 | master VM 에 clang 이 없어 다른 노드에서 빌드한 결과를 git 으로 배포 |
| 2026-05 (48e1809) | `stub-headers/` 로 빌드 | `/usr/src` 내부 커널 헤더로 `-target bpf` 빌드가 깨져 최소 스텁 헤더 작성 |
| 2026-06 (3c4fb19) | 스텁 제거, 실제 UAPI(`linux-libc-dev`) + `libbpf-dev` 헤더 | 스텁이 실제 커널 구조체와 어긋날 위험. 정확한 원인은 "내부 헤더" 였지 UAPI 가 아니었음 |
| 2026-09 (본 ADR) | 바이너리 미커밋, CI 빌드 + 아티팩트 | 아래 |

## 결정

- `step6-ebpf/build/` 는 `.gitignore`. 소스와 `Makefile`(`-Wall -Werror`)만 커밋한다.
- GitHub Actions `ci.yml` 이 매 push 마다 clang 18 로 빌드하고, **커널 verifier 로드**
  (`bpftool prog load`), **BPF_PROG_TEST_RUN 단위 테스트 24개**, kernel ≥ 6.6 러너에서
  **tcx 체인 통합 테스트**까지 통과시킨 뒤 `.bpf.o` 와 `tcx_attach` 를 아티팩트로 올린다.
- 클러스터 노드에는 `clang llvm libbpf-dev linux-libc-dev` 를 설치한다(`step2-os-setup/02`).
  빌드 도구를 못 놓는 노드는 CI 아티팩트를 받아 쓴다.

## 왜 뒤집었나

- 바이너리 diff 는 리뷰 불가능하고, 소스와 어긋난 채 남기 쉽다(실제로 5월 결과는 트리에 없는
  구성으로 측정됐다 — [ADR-0016](0016-results-provenance.md)).
- 이 저장소의 핵심 주장은 "BPF 프로그램이 verifier 를 통과하고 의도대로 분류한다" 이며, 그것을
  증명하는 방법은 커밋된 바이너리가 아니라 **재현 가능한 빌드 + 테스트 로그** 다.
- BTF/`-g` 로 빌드된 오브젝트는 컴파일러 버전마다 달라져 커밋할 때마다 잡음이 생긴다.

## 고려한 대안

| 대안 | 비고 |
|---|---|
| CO-RE + vmlinux.h + 스켈레톤 | 이 프로그램은 `struct __sk_buff` 와 UAPI 만 쓰므로 CO-RE 가 필요 없다. 커널 내부 구조체를 읽게 되면 도입 |
| 컨테이너 이미지로 빌드 환경 고정 | CI 러너의 apt 툴체인으로 충분. 필요 시 `Dockerfile.build` 추가 |

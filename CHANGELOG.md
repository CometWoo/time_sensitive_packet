# Changelog

## v0.4 — 2026-11 정리 (수치 재검증, 무효 데이터 철회, 군살 제거)

수정
- 손실 계산: `expected = max(seq) - min(seq) + 1` 은 첫 수신 전에 잃은 패킷을 세지 못했다(BE 홍수가 talker 보다 1.5 s 먼저 큐를 채운다). talker 는 seq 0 부터 보내므로 `max(seq) + 1`. 커밋된 CI 리포트 재생성: `pfifo_fast_noclsf` 손실 38.95 → 38.96 %, 나머지 수치는 그대로 재현.
- 문서 수치: README 요약의 "433 ms / 35 % loss" 는 서로 다른 조건(noclsf p50, fifo 손실)을 섞은 것 → 같은 큐 기준 "433 ms / 39 % → 0.05 ms / 0". "noclsf 는 fifo 와 통계적으로 같다" 는 틀린 서술(p = 9.7e-296, δ = −0.22 small) → "같은 430 ms 대". p50 비율 약 8,600배 → 약 8,900배. README 끝에 남아 있던 깨진 디렉터리 목록 조각 삭제.

삭제
- `results/k8s-2026-05/` 원본 CSV 9개와 그래프 (철회, 커밋 `67556cd` 이전 히스토리에 있음). 이를 읽던 CI 단계 삭제, `verify.sh --offline` 의 v1 예외 삭제, ADR-0016 개정.
- 호출되지 않는 코드: talker `--vlan-priority` 별칭과 `--start-delay`, `metrics.run_metrics()`.

변경
- `test_integration.py` 는 이제 커밋된 CI 테스트베드 실측으로 README 표의 숫자를 고정한다.
- README 를 줄이고(ADR·검증 표 중복 제거) 수치를 원본 CSV 재계산 값으로 맞춤. Python 파일 `ruff format` 적용.

## v0.3 — 2026-09 "honest datapath" (branch `portfolio/v2-honest-datapath`, PR #3)

발견
- veth 통과 시 `____dev_forward_skb()` 가 `skb->priority` 를 0 으로 리셋 → Pod 안의 SO_PRIORITY/BPF 는 호스트 qdisc 에 도달 불가 (커널 소스 + 실측).
- kernel ≥ 6.6 Cilium tcx 프로그램이 TC_ACT_OK 를 반환하면 legacy clsact 는 실행되지 않음 → 5월 카운터 0 의 원인.
- 5월 실험: 경쟁 트래픽 없음, talker 가 패킷마다 DNS 질의(실효 216–547 pkt/s), priority 0 → band 2. 결과를 "메커니즘 미작동" 으로 재분류.

추가
- `ts_classifier.c`: 호스트 NIC egress 분류기 (AVTP/PCP/QinQ/UDP 포트 map, 비-TS 불변, IP 단편 제외, DSCP 마킹 + 증분 체크섬, PERCPU 카운터, TCX_NEXT 반환).
- `tools/tcx_attach.c`: libbpf tcx 링크 로더 (BPF_F_BEFORE/AFTER, pin, query).
- `tests/`: BPF_PROG_TEST_RUN 단위 테스트 26개, tcx 체인 통합 테스트, `prio_probe`/`tcx_dummy_ok`.
- `testbed/`: 단일 호스트 netns 테스트베드 (tbf 병목 + BE 홍수, 5 조건, 프로브/카운터/DSCP 메타데이터).
- `analysis/`: `tsn-analysis` 패키지 (선형 백분위, 부트스트랩 CI, Mann-Whitney, Cliff's δ, 손실/무결성, 그래프, 리포트; 65 테스트).
- CI: lint(shellcheck/ruff/kubeconform), BPF 빌드+테스트+tcx, analysis, testbed 실험 아티팩트.
- `results/testbed/ci-34294518788/`: kernel 6.17 러너 실측 (pfifo_fast_noclsf p50 433 ms / 손실 39 % → pfifo_fast_clsf p50 0.05 ms / 손실 0, DSCP 46 도착).
- 문서: README 재작성, ADR 16개, ARCHITECTURE / RESULTS / LIMITATIONS / VERIFICATION / DATA_PROVENANCE / PAPER_MAPPING / AIDC_RELEVANCE / RUNBOOK.
- K8s 오케스트레이션 재작성 (HTB 병목 + u32, BE 홍수 Job, kustomize ConfigMap 생성, 조건 이름 통일, meta.json) — cluster 미실행.

변경
- talker: 목적지 이름 1회 해석, `--so-priority`/`--tos`; listener: `IP_RECVTOS`, `--ready-file`.
- `.gitattributes` LF 강제, BPF 바이너리 미커밋, LICENSE(MIT + GPL-2.0 BPF).

삭제
- `vnic_filter.c`, `attach-vnic.sh`(Pod eth0 설계), Dockerfile 2개, `build-and-deploy.sh`, `test-master.yaml`, 인라인 ConfigMap 사본.

## v0.2 — 2026-06 정적 감사 + 단일 프로그램 재설계 (PR #1, #2)

- XDP 삭제, ETF 자동 attach 제거, stub 헤더 → 실제 UAPI/libbpf 헤더, `--cpu=2` 고정 추가.
- `vnic_filter.c` 를 Pod eth0 egress 에 nsenter 로 attach 하는 설계 (Windows 정적 분석, cluster 미검증 — 이후 v0.3 에서 무효로 판명).
- 3,500줄 CODE_REVIEW.md 작성 후 삭제 (git 이력 `11e49cd` 에 보존).

## v0.1 — 2026-05 최초 재현 + 측정

- 2-VM kubeadm + Cilium, 3-프로그램 eBPF(vef/eg/ig) + XDP, mqprio/ETF/taprio 시도 후 `prio` 폴백.
- ConfigMap 주입 워크로드, `SO_PRIORITY=3`, 9개 CSV 측정, 1st-percentile 정규화, README 결과 해석.

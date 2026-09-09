# 검증 매트릭스 — 무엇을 어떤 방법으로 확인했나

| 주장 | 근거 종류 | 어디서 | 상태 |
|---|---|---|---|
| veth 통과 시 `skb->priority` 가 0 이 된다 | 커널 소스 (netdevice.h `____dev_forward_skb`, v5.15 L4140 / v6.8 L4110; veth.c L316-322) | ADR-0003 | 확인 |
| 〃 | 실측: `prio_probe` 히스토그램 (WSL2 5.15: 27,110/27,110; CI 6.17: 52,858/52,858 이 priority 0) | testbed `.meta.json` | 확인 |
| kernel ≥ 6.6 에서 tcx 프로그램이 OK 를 반환하면 legacy clsact 는 실행되지 않는다 | 커널 소스 (dev.c `sch_handle_egress` L4054-4059) | ADR-0005 | 확인 |
| 〃 | 통합 테스트 `tests/test_tcx_chain.sh` Phase A/B | CI `bpf` 잡 (6.17) | 실행 중 — 첫 시도에서 로더 버그(EINVAL) 발견·수정 |
| `bpf_mprog` BEFORE(무상대) = 맨 앞, AFTER = 맨 뒤 | 커널 소스 (mprog.c L193-223, 260-283) | ADR-0005 | 확인 |
| ts_classifier 가 verifier 를 통과한다 | `bpftool prog load` (5.15 WSL2, 6.17 러너) | CI `bpf` 잡 | 확인 |
| 분류 규칙(AVTP/PCP/QinQ/UDP 포트/옵션/단편/절단/IPv6 무시), priority 설정, 비-TS 불변, DSCP+체크섬, 런타임 설정 | BPF_PROG_TEST_RUN 단위 테스트 26개 | `bpf/tests/` | 통과 (5.15, 6.17) |
| DSCP 46 이 와이어를 거쳐 수신단에 도착한다 (체크섬 유효) | listener `IP_RECVTOS` 30,000/30,000 | CI testbed | 확인 |
| 경합 하 strict priority 가 TS 흐름을 보호한다 (p50 433 ms → 0.05 ms, 손실 39 % → 0) | 테스트베드 3 run × 5 조건, 부트스트랩 CI, Mann-Whitney | `results/testbed/ci-…/report` | 확인 |
| priority 없이 3-밴드 qdisc 는 FIFO 와 같다 (`pfifo_fast_noclsf` ≈ `fifo`) | 같은 실험 | 같음 | 확인 |
| `SO_PRIORITY` 는 ≤ 6 이면 권한 불필요 | 커널 소스 (sock.c L1118-1125) | ADR-0011 | 확인 |
| ETF 는 SO_TXTIME 없는 소켓의 패킷을 버린다 | 커널 소스 (sch_etf.c `is_packet_valid` L75-97) | ADR-0002 | 확인 (실행 안 함) |
| python `sendto(hostname)` 은 호출마다 이름을 해석한다 | strace (20 sendto → 20 DNS 질의) | ADR-0008 | 확인 |
| 5월 talker 실효 216–547 pkt/s | CSV `send_ns` 재계산 | DATA_PROVENANCE §B | 확인 |
| 통계 함수(백분위·부트스트랩·Cliff's δ O(n log n) vs O(n²)) | pytest 65개 | CI `analysis` 잡 | 통과 |
| 셸 스크립트 / 파이썬 / 매니페스트 문법 | shellcheck, ruff, kubeconform | CI `lint` 잡 | 실행 중 |
| **K8s 클러스터(Cilium)에서 새 설계가 동작한다** | — | — | **미검증** (VM 접근 불가). `scripts/experiment.sh` 는 정적 검토·shellcheck 만 |
| Cilium 재시작 후 tcx 순서 유지 | — | `scripts/verify.sh` 가 순서를 검사하도록 설계 | 미검증 |
| VirtualBox NAT 가 DSCP 를 보존 | — | — | 미검증 |
| 물리 NIC 멀티큐/mqprio hw/PTP | — | — | 하드웨어 없음 |

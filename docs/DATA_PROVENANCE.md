# 데이터 출처 (Data provenance)

모든 결과 파일이 **어떤 코드·구성·환경에서** 나왔는지 기록한다. 결과 표를 볼 때 이 표를 먼저 본다.

## A. `results/testbed/ci-34294518788/` — 2026-09-09, GitHub Actions (유효)

| 항목 | 값 |
|---|---|
| 실행 | `.github/workflows/testbed.yml`, run 34294518788 (PR #3), 커밋 `e4f05b0` |
| 커널 / 러너 | `6.17.0-1022-azure`, ubuntu-24.04, 공유 vCPU |
| 토폴로지 | `testbed/topology.sh` (ns_send ↔ vs veth ↔ host ↔ vr veth ↔ ns_recv) |
| 병목 / 경쟁 | `tbf rate 20mbit burst 32kbit latency 200ms` → 조건별 leaf; `be_flood.py` 30 Mbit/s 1400 B UDP:5001 |
| TS 흐름 | `talker.py --interval 1 --count 10000 --so-priority 6` (128 B UDP:6000), `listener.py --record-tos` |
| 분류기 | `ts_classifier.bpf.o` (커밋 `e4f05b0` 소스, DSCP 마킹 on), pinned maps |
| 조건 × run | fifo, fq_codel, pfifo_fast_noclsf, pfifo_fast_clsf, prio_clsf × 3 (조건 순서 고정, run 순환) |
| 파일 | `ci/<cond>_run<k>.csv` (seq, send_ns, recv_ns, latency_ms, jitter_us, pkt_size, tos), `ci/<cond>_run<k>.meta.json` (prio_hist 두 지점, ts_counters, flood/sink 통계), `ci-log.txt`, `report/` (summary.md/json, 그래프) |
| 시계 | 송수신 같은 `CLOCK_REALTIME` → 절대 one-way latency 유효 |
| 알려진 결함 | 이 run 의 listener 는 사용자 공간 타임스탬프(커널 RX 스탬프 아님); run 순서 미순환 |

## B. `results/k8s-2026-05/*.csv` — 2026-05-25, VirtualBox 2-VM K8s (메커니즘 미작동, 재해석용)

| 파일 | 송신 구간 | 실효 pkt/s | 송신 간격 p50 / p99 (ms) | raw latency 음수 비율 | p1 오프셋 (ms) | run 내 드리프트 |
|---|---|---|---|---|---|---|
| baseline_cpu10 | 38.9 s | 257 | 1.81 / 14.0 | 99.4 % | −36.2 | +0.28 ms/10 s |
| baseline_cpu30 | 24.4 s | 410 | 1.74 / 9.4 | 99.6 % | — | +0.57 |
| baseline_cpu50 | 24.6 s | 406 | 1.71 / 12.8 | 99.3 % | — | +0.19 |
| baseline_cpu70 | 24.7 s | 404 | 1.71 / 12.9 | 99.3 % | −14.4 | +0.21 |
| proposed_cpu10 | 20.5 s | 488 | 1.60 / 4.3 | 99.9 % | −37.1 | +0.03 |
| proposed_cpu30 | 21.4 s | 466 | 1.69 / 6.9 | 99.7 % | — | −0.29 |
| proposed_cpu50 | 18.3 s | 547 | 1.29 / 7.8 | 99.7 % | — | +0.04 |
| proposed_cpu70 | 24.8 s | 403 | 1.59 / 10.5 | 99.5 % | −36.2 | −0.23 |
| proposed_cpu99 | 46.3 s | 216 | 1.84 / 12.6 | 99.5 % | — | −0.40 |

공통 사항:

| 항목 | 값 |
|---|---|
| 커밋 | 데이터 `8fc0be1`(cpu10, proposed 30/50/70/99), `55394ca`(baseline 30/50/70); 코드 구성은 `8fc0be1` |
| 환경 | Ubuntu 24.04, kernel 6.x(≥ 6.6, tcx), kubeadm 1.30, containerd 2.x, Cilium 1.19 native routing, VirtualBox 4 vCPU/4 GB × 2, virtio-net 1 TX 큐, NAT 네트워크 |
| 워크로드 | talker Job(master) → listener Deployment(worker01), UDP **5000**, 128 B, 목표 1 ms × 10,000; `sendto(service-name)` → 패킷마다 DNS; CPU limit 500m; `--cpu` 고정 없음 |
| 우선순위 | Pod 소켓 `SO_PRIORITY=3` (양쪽 모드 동일) → veth 에서 0 으로 리셋 |
| proposed qdisc | `prio bands 3 priomap 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2` (priority 0 → band 2) |
| baseline qdisc | root 삭제 → 배포판 기본(fq_codel) |
| eBPF | veth_filter/egress/ingress(clsact) + xdp generic — Cilium tcx 순서로 **미실행**, 카운터 0 |
| 경쟁 트래픽 | 없음. stress-ng DaemonSet 이 양 노드에 CPU 부하만 |
| 손실/중복/재정렬 | 0 / 0 / 0 (전 파일) |
| 미측정 | baseline_cpu99 (worker VM 응답 불능) |
| 이전 | 최초 커밋 `32c217b` 에는 `generate-sample-data.py` 로 만든 합성 CSV 가 있었고 `e311e57` 에서 실측으로 교체됨 |

## C. WSL2 로컬 스모크 (커밋되지 않음)

`/root/tsn-work/smoke`, kernel `5.15.167.4-microsoft-standard-WSL2`, 셰이퍼 없음. prio_hist {0: 27,110} →
{0: 24,110, 6: 3,000}, DSCP 0xB8 3,000/3,000, 무경합 p50 0.113 ms. `notes/PROGRESS.md` 에 기록.

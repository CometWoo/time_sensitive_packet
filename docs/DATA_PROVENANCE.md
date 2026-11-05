# 데이터 출처 (Data provenance)

모든 결과 파일이 어떤 코드·구성·환경에서 나왔는지 기록한다. 결과 표를 볼 때 이 표를 먼저 본다.

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

## B. 2026-05 VirtualBox 2-VM K8s 측정 (철회, 원본 제거)

9개 CSV(`baseline_cpu{10,30,50,70}`, `proposed_cpu{10,30,50,70,99}`)는 우선순위가 적용되지 않은 상태의 측정이라
철회했고([RESULTS.md 2절](RESULTS.md)), v0.4 에서 저장소 트리에서 내렸다. 원본은 커밋 `67556cd` 이전 히스토리의
`results/k8s-2026-05/` 에 있다. 환경: Ubuntu 24.04, kubeadm 1.30, Cilium 1.19 native routing, VirtualBox VM 2대,
talker 가 패킷마다 DNS 를 조회(실효 216–547 pkt/s), 두 VM 시계 오프셋 −14 ~ −37 ms(raw latency 99 % 음수).

## C. WSL2 로컬 스모크 (커밋되지 않음)

`/root/tsn-work/smoke`, kernel `5.15.167.4-microsoft-standard-WSL2`, 셰이퍼 없음. prio_hist {0: 27,110} →
{0: 24,110, 6: 3,000}, DSCP 0xB8 3,000/3,000, 무경합 p50 0.113 ms. `notes/PROGRESS.md` 에 기록.

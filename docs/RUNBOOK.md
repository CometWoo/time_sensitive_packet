# 실행 가이드 (Runbook)

세 가지 실행 경로가 있다. 위에서부터 요구 환경이 커진다.

| 경로 | 무엇을 검증하나 | 필요한 것 |
|---|---|---|
| A. eBPF 단위·통합 테스트 | 분류 규칙, DSCP/체크섬, tcx 체인 순서 | Linux(WSL2 가능), root, clang/libbpf/bpftool |
| B. netns 테스트베드 | veth priority 리셋, 경합 하 qdisc 비교, DSCP end-to-end | Linux root; 경합 실험엔 `sch_tbf`/`sch_prio` 모듈 (GitHub Actions 러너 OK, WSL2 는 기능 검증만) |
| C. Kubernetes/Cilium 클러스터 | 실제 CNI 데이터패스에서의 동작 | VM 2대(kubeadm + Cilium ≥ 1.16, kernel ≥ 6.6) — **미실행 상태** |

## A. eBPF 빌드와 테스트

```bash
sudo apt-get install -y clang llvm make gcc pkg-config libbpf-dev linux-libc-dev python3-pytest iproute2
bash scripts/ci/install-bpftool.sh          # apt 로 안 되면 소스 빌드
make bpf                                    # bpf/build/{ts_classifier,prio_probe,tcx_dummy_ok}.bpf.o + bpf/build/tcx_attach
sudo make test-bpf                          # 26 BPF_PROG_TEST_RUN 테스트 (bpftool prog run)
sudo make test-tcx                          # kernel >= 6.6: tcx 체인 통합 테스트 (Phase A/B/C)
make -C bpf check-env                       # 환경 진단
```

수동 attach (호스트 NIC egress):

```bash
IF=$(ip -o route show default | awk '{print $5; exit}')
# tcx (kernel >= 6.6, Cilium 앞에)
sudo bpf/build/tcx_attach attach $IF bpf/build/ts_classifier.bpf.o /sys/fs/bpf/ts_clsf egress before
sudo bpf/build/tcx_attach query $IF egress
# legacy clsact (kernel < 6.6)
sudo bpftool prog load bpf/build/ts_classifier.bpf.o /sys/fs/bpf/tsn/clsf pinmaps /sys/fs/bpf/tsn/clsf_maps
sudo tc qdisc add dev $IF clsact && sudo tc filter add dev $IF egress pref 10 bpf da pinned /sys/fs/bpf/tsn/clsf
# DSCP 마킹 켜기 (flags bit0), 카운터 읽기
sudo python3 testbed/bpfmaps.py set-ts-config /sys/fs/bpf/tsn/clsf_maps/ts_config 0 0 1
sudo python3 testbed/bpfmaps.py counters   /sys/fs/bpf/tsn/clsf_maps/ts_counters
```

## B. netns 테스트베드

```bash
sudo make testbed RUNS=3 RATE=20 FLOOD=30 OUT=testbed/runs/local
#   = sudo bash testbed/run.sh --runs 3 --rate-mbps 20 --flood-mbps 30 --out testbed/runs/local
make report OUT=testbed/runs/local          # testbed/runs/local/report/{summary.md,summary.json,fig_*.png}
```

- 조건: `--conditions "fifo fq_codel pfifo_fast_noclsf pfifo_fast_clsf prio_clsf"` (기본 전부), `--quick`(1 run × 3,000).
- 출력: `<cond>_run<k>.csv`(listener: seq, send_ns, recv_ns, latency_ms, jitter_us, pkt_size, tos, recv_kernel_ns),
  `<cond>_run<k>.meta.json`(veth 직후/NIC egress prio 히스토그램, ts_counters, flood/sink 통계), `<cond>/run<k>/`(로그, qdisc).
- 셰이퍼가 없는 커널(WSL2)에서는 `SHAPER=none` 경고와 함께 기능 검증만 한다 — latency 비교는 무의미.
- CI: `.github/workflows/testbed.yml` (PR 또는 수동 dispatch) → 아티팩트 `testbed-results-<n>` → `results/testbed/<run>/` 에 커밋.

토폴로지만 올리고 내리기: `sudo bash testbed/topology.sh up|status|down`.

## C. Kubernetes / Cilium 클러스터

전제: VM 2대(control-plane = sender, worker = receiver), kernel ≥ 6.6, kubeadm 1.30, Cilium ≥ 1.16(tcx), 두 노드 모두
`clang libbpf-dev linux-libc-dev bpftool`. 설치 참고 스크립트: `scripts/setup/` (실측 환경과 완전히 같지는 않음 — 각 파일 머리의 STATUS 참조).

```bash
cp experiment.env.example experiment.env        # PHYS_IF, SHAPE_MBPS=20, FLOOD_MBPS=30, TS_COUNT, MARK_DSCP=1 ...
bash scripts/experiment.sh build-ebpf            # sender 노드에서
bash scripts/experiment.sh deploy-k8s            # namespace / ConfigMap(kustomize) / listener / udp-sink
sudo bash scripts/experiment.sh matrix 3 0       # 5 조건 × 3 run, ABAB 인터리브, CPU 부하 없음
sudo bash scripts/experiment.sh run prio_clsf 50 # 단일 run + 수신 노드 stress-ng 50 %
sudo bash scripts/verify.sh --condition prio_clsf
tsn-analysis summary results/k8s --baseline fifo --markdown -
sudo bash scripts/experiment.sh cleanup
```

동작 요약 (sender 노드 NIC):

1. `ts_classifier` 를 tcx BEFORE(kernel ≥ 6.6) 또는 legacy clsact 로 NIC egress 에 attach, DSCP 마킹 on.
2. HTB root: 기본 클래스는 무제한, listener Pod IP 목적지만 u32 로 `1:10 rate SHAPE_MBPS` 클래스에 → 그 leaf 에 조건 qdisc
   (pfifo / fq_codel / pfifo_fast / prio). 제어 평면 트래픽은 제한하지 않는다.
3. be-flood Job(sender) → udp-sink(receiver) 로 경쟁 트래픽, talker Job → listener 로 TS 흐름.
4. 결과 `results/k8s/<condition>_cpu<N>_run<k>.csv` + `.meta.json`(kernel, cilium, tc -s class, ts_counters, git rev).

상태·카운터: `sudo bash scripts/experiment.sh status`, `show-counters`. 분류기만 붙였다 떼기: `attach-classifier` / `detach-classifier`.

## 문제 해결

| 증상 | 확인 |
|---|---|
| `make test` 가 전부 skip | root 가 아니거나 bpftool 없음: `sudo`, `bash scripts/ci/install-bpftool.sh` |
| `attach_tcx … Invalid argument` | kernel < 6.6 또는 libbpf < 1.3 → legacy clsact 경로 사용 |
| 테스트베드 `ping 실패` | Docker 호스트의 FORWARD DROP — topology.sh 가 iptables ACCEPT 를 넣지만 nftables 전용 환경이면 수동 허용 |
| `WARNING: tbf 없음` | 커널에 sch_tbf 없음(WSL2) — 경합 실험은 CI 또는 VM 에서 |
| 분류기 카운터 0 | `tcx_attach query $IF egress` 로 순서 확인(우리 프로그램이 [0] 이어야 함). Cilium 재시작 후 다시 attach |
| talker `WARNING: 페이싱 실패` | 송신측 CPU 경쟁/quota — 결과에 송신 교란 포함. `--strict-pacing` 이면 exit 3 |
| latency 가 음수 | 서로 다른 호스트의 시계 오프셋 — `tsn-analysis summary --normalize-skew` (상대 비교만) |

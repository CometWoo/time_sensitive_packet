# explain_06 — deploy-experiment.sh 전체 흐름

> 대상 파일: `deploy-experiment.sh` (실험 메인 자동화 스크립트)
> eBPF 컴파일/attach → TC qdisc → K8s 배포 → 실험 실행 → 결과 회수 → 정리/상태를
> 하나의 진입점으로 묶는다.

## 코드 (명령 디스패치 + 핵심 흐름 요약)

```bash
# 변수
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EBPF_DIR="$SCRIPT_DIR/step6-ebpf"
K8S_DIR="$SCRIPT_DIR/step7-experiment/k8s"
RESULTS_DIR="$SCRIPT_DIR/step8-measurement/results"
PHYS_IF=$(ip route | awk '/^default/{print $5}' | head -1)

# 1) eBPF attach (역할별)
setup_ebpf() {
    local ROLE="${1:-sender}"
    cd "$EBPF_DIR"
    ls build/*.bpf.o &>/dev/null || make all      # 사전 빌드 없으면 컴파일
    tc qdisc del dev "$PHYS_IF" clsact 2>/dev/null || true
    ip link set dev "$PHYS_IF" xdp off 2>/dev/null || true
    tc qdisc add dev "$PHYS_IF" clsact

    if [ "$ROLE" = "sender" ]; then
        tc filter add dev "$PHYS_IF" egress bpf da obj build/egress.bpf.o sec tc
        # veth_filter: tcx 우선(Cilium 공존), clsact 폴백 — 항상 TC_ACT_UNSPEC 카운터
        for veth in $(ip link show type veth | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1); do
            bpftool net attach tcx_ingress obj build/veth_filter.bpf.o sec tc dev "$veth" 2>/dev/null \
              || { tc qdisc add dev "$veth" clsact 2>/dev/null || true; \
                   tc filter add dev "$veth" ingress bpf da obj build/veth_filter.bpf.o sec tc 2>/dev/null; }
        done
    fi
    [ "$ROLE" = "receiver" ] && \
        tc filter add dev "$PHYS_IF" ingress bpf da obj build/ingress.bpf.o sec tc
    # XDP attach 제거됨(2026-06). ETF 자동 attach 제거됨.
}

# 2) TC qdisc (proposed 모드) — mqprio 시도 → prio 폴백 (explain_03 참고)
setup_tc_qdisc() { ...; }
remove_tc_qdisc() { tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true; }

# 3) K8s 배포
deploy_k8s() {
    kubectl apply -f "$K8S_DIR/namespace.yaml"
    kubectl apply -f "$K8S_DIR/listener-deployment.yaml"
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=180s
}

# 4) 실험 1회 (baseline/proposed × CPU 부하)
run_experiment() {
    local MODE="${1:-baseline}"; local CPU_LOAD="${2:-10}"
    [ "$MODE" = "proposed" ] && setup_tc_qdisc || remove_tc_qdisc
    kubectl -n tsn-experiment delete pod -l app=listener --grace-period=5
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=120s
    sed "s/\"99\"/\"$CPU_LOAD\"/" "$K8S_DIR/stress-daemonset.yaml" | kubectl apply -f -   # CPU 부하
    [ "${HUBBLE:-0}" = "1" ] && bash step8-measurement/hubble-monitor.sh start ...        # 선택적 Hubble
    kubectl apply -f "$K8S_DIR/talker-job.yaml"
    kubectl -n tsn-experiment wait --for=condition=complete job/talker-run --timeout=300s
    kubectl -n tsn-experiment cp "$LISTENER_POD:/data/results.csv" \
        "$RESULTS_DIR/${MODE}_cpu${CPU_LOAD}.csv"
    bpftool map dump name pkt_stats   # 카운터 출력 (debug_stats는 제거됨)
}

# 명령 디스패치
case "${1:-help}" in
    build-ebpf) make -C "$EBPF_DIR" all ;;
    setup-ebpf) setup_ebpf "${2:-sender}" ;;
    setup-tc)   setup_tc_qdisc ;;
    deploy-k8s) deploy_k8s ;;
    run)        run_experiment "${2:-baseline}" "${3:-10}" ;;
    cleanup)    cleanup ;;
    status)     status ;;
esac
```

> 실행 순서: `build-ebpf`(1회) → `setup-ebpf sender`(master)/`setup-ebpf receiver`(worker01)
> → `deploy-k8s` → `run baseline <cpu>` → `run proposed <cpu>` → 분석 → `cleanup`.
> 2026-06 감사 반영: XDP/ETF 자동 attach 제거, veth_filter tcx 우선 attach,
> mqprio 시도 후 prio 폴백, 선택적 Hubble 캡처(HUBBLE=1), debug_stats 출력 제거.

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **deploy-experiment.sh 전체 흐름** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `setup_ebpf(sender|receiver)`: 역할별로 어떤 BPF(egress/ingress/veth_filter)를 어디(PHYS_IF/veth)에 attach하는지. veth_filter를 tcx 우선·clsact 폴백으로 붙이는 이유(Cilium 공존, pkt_stats=0 대응).
   - `setup_tc_qdisc()`/`remove_tc_qdisc()`: proposed/baseline 모드 전환.
   - `deploy_k8s()`, `run_experiment(mode, cpu)`: listener 재시작 → CPU 부하 → talker Job → CSV 회수의 라이프사이클.
   - `case` 디스패치(build-ebpf/setup-ebpf/run/cleanup/status).
2. 코드, 문법 부분 설명
   - `PHYS_IF=$(ip route | awk '/^default/{print $5}')` 같은 자동 감지, `2>/dev/null || true` 패턴, `sed "s/\"99\"/.../"`로 stress 부하 치환.
   - `kubectl wait --for=condition=...`, `kubectl cp`의 의미.
   - `HUBBLE=1` 환경변수 가드로 선택적 모니터링을 켜는 방식.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `step6-ebpf/`(Makefile, *.bpf.o), `step7-experiment/k8s/*.yaml`, `step8-measurement/`(results, hubble-monitor.sh)와의 연결.
   - egress.c/ingress.c/veth_filter.c가 여기서 attach되고, 결과 CSV가 plot/compare 스크립트로 흐른다.
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - 이 스크립트가 baseline vs proposed 데이터를 어떻게 생성하는지, pkt_stats 출력과 listener.py의 jitter CSV가 각각 어떤 검증 역할을 하는지 설명해줘.

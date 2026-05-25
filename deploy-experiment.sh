#!/bin/bash
# =============================================================================
# deploy-experiment.sh
# Time-Sensitive Cloud Network 실험 배포 스크립트
#
# 환경:
#   Host-s (Sender):   k8s-master   (10.0.2.8)  - talker pod 실행
#   Host-r (Receiver): k8s-worker01 (10.0.2.4)  - listener pod 실행
#
# 사용법:
#   # 1단계: 양쪽 노드에서 eBPF 컴파일 + attach
#   ssh worker@k8s-master   "cd ~/time_sensitive_packet && sudo bash deploy-experiment.sh setup-ebpf sender"
#   ssh worker@k8s-worker01 "cd ~/time_sensitive_packet && sudo bash deploy-experiment.sh setup-ebpf receiver"
#
#   # 2단계: 마스터에서 K8s 실험 배포
#   ssh worker@k8s-master   "cd ~/time_sensitive_packet && bash deploy-experiment.sh deploy-k8s"
#
#   # 3단계: 실험 실행 (baseline 또는 proposed)
#   ssh worker@k8s-master   "cd ~/time_sensitive_packet && bash deploy-experiment.sh run baseline 10"
#   ssh worker@k8s-master   "cd ~/time_sensitive_packet && bash deploy-experiment.sh run proposed 10"
#
#   # 정리
#   ssh worker@k8s-master   "cd ~/time_sensitive_packet && sudo bash deploy-experiment.sh cleanup"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EBPF_DIR="$SCRIPT_DIR/step6-ebpf"
K8S_DIR="$SCRIPT_DIR/step7-experiment/k8s"
EXPERIMENT_DIR="$SCRIPT_DIR/step7-experiment"
RESULTS_DIR="$SCRIPT_DIR/step8-measurement/results"

# 네트워크 인터페이스 자동 감지
PHYS_IF=$(ip route | awk '/^default/{print $5}' | head -1)
MASTER_IP="10.0.2.8"
WORKER01_IP="10.0.2.4"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# =============================================================================
# 1단계: eBPF 컴파일 및 Attach
# =============================================================================
setup_ebpf() {
    local ROLE="${1:-sender}"  # sender 또는 receiver
    log_info "=== eBPF 설정 시작 (역할: $ROLE, NIC: $PHYS_IF) ==="

    # 빌드 환경 확인
    log_info "빌드 환경 확인..."
    for cmd in clang llvm-objdump bpftool; do
        if ! command -v $cmd &>/dev/null; then
            log_error "$cmd 이 설치되어 있지 않습니다"
            log_info "설치: sudo apt install clang llvm libbpf-dev linux-headers-\$(uname -r) linux-tools-common linux-tools-\$(uname -r)"
            exit 1
        fi
    done

    # 커널 헤더 확인
    if [ ! -d "/usr/src/linux-headers-$(uname -r)" ] && [ ! -d "/lib/modules/$(uname -r)/build" ]; then
        log_warn "커널 헤더가 없습니다. stub 헤더로 빌드합니다."
    fi

    # eBPF 컴파일
    log_info "eBPF 프로그램 컴파일..."
    cd "$EBPF_DIR"
    make clean 2>/dev/null || true
    make DEBUG=2
    log_info "컴파일 완료: $(ls build/*.bpf.o 2>/dev/null | tr '\n' ' ')"

    # 기존 필터 제거
    log_info "기존 TC 필터/qdisc 제거..."
    tc qdisc del dev "$PHYS_IF" clsact 2>/dev/null || true
    ip link set dev "$PHYS_IF" xdp off 2>/dev/null || true

    # clsact qdisc 추가
    log_info "clsact qdisc 추가..."
    tc qdisc add dev "$PHYS_IF" clsact

    if [ "$ROLE" = "sender" ]; then
        # Sender: egress + veth_filter
        log_info "[Sender] egress 프로그램 attach..."
        tc filter add dev "$PHYS_IF" egress bpf da obj build/egress.bpf.o sec tc
        log_info "[Sender] egress attach 완료"

        # veth 인터페이스에 veth_filter attach
        log_info "[Sender] veth_filter attach..."
        local veth_count=0
        for veth in $(ip link show type veth | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1 | grep -E '^lxc|^veth'); do
            tc qdisc add dev "$veth" clsact 2>/dev/null || true
            tc filter add dev "$veth" ingress bpf da obj build/veth_filter.bpf.o sec tc 2>/dev/null && {
                log_info "  veth_filter → $veth"
                veth_count=$((veth_count + 1))
            }
        done
        log_info "veth_filter: ${veth_count}개 인터페이스에 attach됨"
    fi

    if [ "$ROLE" = "receiver" ]; then
        # Receiver: ingress
        log_info "[Receiver] ingress 프로그램 attach..."
        tc filter add dev "$PHYS_IF" ingress bpf da obj build/ingress.bpf.o sec tc
        log_info "[Receiver] ingress attach 완료"
    fi

    # XDP attach (양쪽 모두, VM에서는 generic 모드)
    log_info "XDP 프로그램 attach (xdpgeneric)..."
    ip link set dev "$PHYS_IF" xdpgeneric obj build/xdp_vlan_avtp.bpf.o sec xdp 2>/dev/null && {
        log_info "XDP attach 완료"
    } || {
        log_warn "XDP attach 실패 (VM 환경에서 무시 가능)"
    }

    # 검증
    log_info "=== Attach 검증 ==="
    echo "--- TC egress filters ---"
    tc filter show dev "$PHYS_IF" egress 2>/dev/null || echo "(없음)"
    echo "--- TC ingress filters ---"
    tc filter show dev "$PHYS_IF" ingress 2>/dev/null || echo "(없음)"
    echo "--- XDP ---"
    ip link show dev "$PHYS_IF" | grep -i xdp || echo "(없음)"
    echo "--- BPF programs ---"
    bpftool prog list 2>/dev/null | head -20 || echo "(bpftool 없음)"

    log_info "=== eBPF 설정 완료 ($ROLE) ==="
}

# =============================================================================
# TC Qdisc 설정 (Proposed 실험용)
# =============================================================================
setup_tc_qdisc() {
    log_info "=== TC Qdisc 설정 (mqprio + etf) ==="

    # 기존 root qdisc 제거
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true

    # mqprio: 3개 TC class (hw 0 = 소프트웨어 모드, VM용)
    log_info "mqprio 설정..."
    tc qdisc add dev "$PHYS_IF" root handle 100: mqprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@0 1@0 \
        hw 0

    # ETF: tc0 (time-sensitive queue)에 txtime 스케줄링
    log_info "ETF 설정 (tc0)..."
    if tc qdisc add dev "$PHYS_IF" parent 100:1 handle 10: etf \
        clockid CLOCK_TAI \
        delta 150000 \
        deadline_mode on 2>/dev/null; then
        log_info "ETF 설정 완료"
    else
        log_warn "ETF 설정 실패 (CLOCK_TAI 미지원 가능성). CLOCK_REALTIME으로 재시도..."
        if ! tc qdisc add dev "$PHYS_IF" parent 100:1 handle 10: etf \
            clockid CLOCK_REALTIME \
            delta 150000 \
            deadline_mode on 2>/dev/null; then
            log_warn "ETF 설정 불가 — mqprio만 사용합니다"
        fi
    fi

    log_info "Qdisc 상태:"
    tc qdisc show dev "$PHYS_IF"
}

remove_tc_qdisc() {
    log_info "TC Qdisc 제거 (baseline 모드)..."
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
    log_info "Qdisc 제거 완료"
}

# =============================================================================
# 2단계: K8s 실험 배포
# =============================================================================
deploy_k8s() {
    log_info "=== K8s 실험 배포 ==="

    # 네임스페이스 생성
    kubectl apply -f "$K8S_DIR/namespace.yaml"

    # Docker 이미지 빌드 (containerd)
    log_info "Talker 이미지 빌드..."
    cd "$EXPERIMENT_DIR/talker"
    if command -v nerdctl &>/dev/null; then
        nerdctl build -t tsn-talker:latest .
    elif command -v docker &>/dev/null; then
        docker build -t tsn-talker:latest .
        docker save tsn-talker:latest | ctr -n k8s.io images import -
    else
        log_warn "nerdctl/docker 없음 — 이미지가 이미 있다고 가정합니다"
    fi

    log_info "Listener 이미지 빌드..."
    cd "$EXPERIMENT_DIR/listener"
    if command -v nerdctl &>/dev/null; then
        nerdctl build -t tsn-listener:latest .
    elif command -v docker &>/dev/null; then
        docker build -t tsn-listener:latest .
        docker save tsn-listener:latest | ctr -n k8s.io images import -
    else
        log_warn "nerdctl/docker 없음 — 이미지가 이미 있다고 가정합니다"
    fi

    # Listener 배포 (worker01에서 실행되도록)
    log_info "Listener 배포..."
    kubectl apply -f "$K8S_DIR/listener-deployment.yaml"

    # Listener pod 준비 대기
    log_info "Listener pod 준비 대기..."
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=120s || {
        log_error "Listener pod가 준비되지 않았습니다"
        kubectl -n tsn-experiment get pods
        exit 1
    }

    LISTENER_IP=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].status.podIP}')
    log_info "Listener pod IP: $LISTENER_IP"
    log_info "=== K8s 배포 완료 ==="
}

# =============================================================================
# 3단계: 실험 실행
# =============================================================================
run_experiment() {
    local MODE="${1:-baseline}"     # baseline 또는 proposed
    local CPU_LOAD="${2:-10}"       # CPU 부하 (%)

    log_info "=== 실험 실행: $MODE (CPU 부하: ${CPU_LOAD}%) ==="
    mkdir -p "$RESULTS_DIR"

    # Proposed 모드: TC qdisc 설정
    if [ "$MODE" = "proposed" ]; then
        setup_tc_qdisc
    else
        remove_tc_qdisc
    fi

    # 이전 Job 정리
    kubectl -n tsn-experiment delete job talker 2>/dev/null || true
    kubectl -n tsn-experiment delete daemonset stress-ng 2>/dev/null || true
    sleep 3

    # CPU 부하 생성
    log_info "CPU 부하 생성 (${CPU_LOAD}%)..."
    cat "$K8S_DIR/stress-daemonset.yaml" | \
        sed "s/--cpu-load [0-9]*/--cpu-load $CPU_LOAD/" | \
        kubectl apply -f -
    sleep 5

    # Talker Job 실행
    log_info "Talker Job 실행..."
    LISTENER_IP=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].status.podIP}')

    # VLAN priority 설정 (proposed 모드에서 skb->priority=3 → tc0)
    local VLAN_PRI_ARG=""
    if [ "$MODE" = "proposed" ]; then
        VLAN_PRI_ARG="--vlan-priority 3"
    fi

    cat "$K8S_DIR/talker-job.yaml" | \
        sed "s/--target .*/--target $LISTENER_IP $VLAN_PRI_ARG/" | \
        kubectl apply -f -

    # Talker 완료 대기
    log_info "Talker 완료 대기 (최대 5분)..."
    kubectl -n tsn-experiment wait --for=condition=complete job/talker --timeout=300s || {
        log_warn "Talker Job 타임아웃"
    }

    # 결과 수집
    local RESULT_FILE="$RESULTS_DIR/${MODE}_cpu${CPU_LOAD}.csv"
    log_info "결과 수집 → $RESULT_FILE"
    LISTENER_POD=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')
    kubectl -n tsn-experiment cp "$LISTENER_POD:/data/results.csv" "$RESULT_FILE" || {
        log_warn "결과 파일 복사 실패"
    }

    # 부하 제거
    kubectl -n tsn-experiment delete daemonset stress-ng 2>/dev/null || true

    # eBPF 통계 출력
    log_info "=== eBPF 통계 ==="
    bpftool map dump name pkt_stats 2>/dev/null || echo "(pkt_stats 없음)"

    log_info "=== 실험 완료: $RESULT_FILE ==="
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    log_info "=== 정리 ==="
    kubectl delete namespace tsn-experiment 2>/dev/null || true
    tc qdisc del dev "$PHYS_IF" clsact 2>/dev/null || true
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
    ip link set dev "$PHYS_IF" xdp off 2>/dev/null || true

    for veth in $(ip link show type veth | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1 | grep -E '^lxc|^veth'); do
        tc qdisc del dev "$veth" clsact 2>/dev/null || true
    done

    log_info "=== 정리 완료 ==="
}

# =============================================================================
# 상태 확인
# =============================================================================
status() {
    echo "=== 노드 상태 ==="
    kubectl get nodes -o wide 2>/dev/null || echo "(kubectl 사용 불가 — worker 노드인 경우 정상)"

    echo ""
    echo "=== TC Filters ($PHYS_IF) ==="
    echo "--- egress ---"
    tc filter show dev "$PHYS_IF" egress 2>/dev/null || echo "(없음)"
    echo "--- ingress ---"
    tc filter show dev "$PHYS_IF" ingress 2>/dev/null || echo "(없음)"

    echo ""
    echo "=== TC Qdisc ==="
    tc qdisc show dev "$PHYS_IF" 2>/dev/null

    echo ""
    echo "=== XDP ==="
    ip link show dev "$PHYS_IF" | grep -i xdp || echo "(없음)"

    echo ""
    echo "=== BPF Programs ==="
    bpftool prog list 2>/dev/null | head -20 || echo "(bpftool 없음)"

    echo ""
    echo "=== BPF Maps ==="
    bpftool map list 2>/dev/null | head -20 || echo "(bpftool 없음)"

    echo ""
    echo "=== Packet Stats ==="
    bpftool map dump name pkt_stats 2>/dev/null || echo "(pkt_stats 없음)"
}

# =============================================================================
# Main
# =============================================================================
case "${1:-help}" in
    setup-ebpf)
        setup_ebpf "${2:-sender}"
        ;;
    setup-tc)
        setup_tc_qdisc
        ;;
    remove-tc)
        remove_tc_qdisc
        ;;
    deploy-k8s)
        deploy_k8s
        ;;
    run)
        run_experiment "${2:-baseline}" "${3:-10}"
        ;;
    cleanup)
        cleanup
        ;;
    status)
        status
        ;;
    help|*)
        echo "사용법: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  setup-ebpf <sender|receiver>  - eBPF 컴파일 + attach"
        echo "  setup-tc                      - TC qdisc 설정 (mqprio+etf)"
        echo "  remove-tc                     - TC qdisc 제거"
        echo "  deploy-k8s                    - K8s 실험 환경 배포"
        echo "  run <baseline|proposed> <cpu%> - 실험 실행"
        echo "  cleanup                       - 전체 정리"
        echo "  status                        - 현재 상태 확인"
        echo ""
        echo "실행 순서:"
        echo "  1. [master]   sudo bash $0 setup-ebpf sender"
        echo "  2. [worker01] sudo bash $0 setup-ebpf receiver"
        echo "  3. [master]   bash $0 deploy-k8s"
        echo "  4. [master]   bash $0 run baseline 10"
        echo "  5. [master]   bash $0 run proposed 10"
        echo "  6. [master]   sudo bash $0 cleanup"
        ;;
esac

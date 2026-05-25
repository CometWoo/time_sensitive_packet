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

    # 사전 빌드된 .bpf.o 파일 확인
    cd "$EBPF_DIR"
    if ls build/*.bpf.o &>/dev/null; then
        log_info "사전 빌드된 eBPF 오브젝트 발견 — 컴파일 생략"
        ls build/*.bpf.o
    else
        # 빌드 환경 확인
        log_info "빌드된 오브젝트 없음 — 컴파일 시도..."
        for cmd in clang make; do
            if ! command -v $cmd &>/dev/null; then
                log_error "$cmd 이 설치되어 있지 않습니다"
                log_info "해결 방법 (택 1):"
                log_info "  A) 이 노드에 빌드 도구 설치: sudo apt install clang make"
                log_info "  B) 빌드 가능한 노드에서 컴파일 후 step6-ebpf/build/ 디렉토리를 이 노드로 복사"
                exit 1
            fi
        done

        log_info "eBPF 프로그램 컴파일..."
        make clean 2>/dev/null || true
        make all DEBUG=2
        log_info "컴파일 완료: $(ls build/*.bpf.o 2>/dev/null | tr '\n' ' ')"
    fi

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
        # Cilium은 lxc*, cilium_*, veth* 등 다양한 이름 사용
        log_info "[Sender] veth_filter attach..."
        log_info "  모든 veth 인터페이스 목록:"
        ip link show type veth | awk -F': ' '/^[0-9]/{print "    " $2}'
        local veth_count=0
        for veth in $(ip link show type veth | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1); do
            tc qdisc add dev "$veth" clsact 2>/dev/null || true
            if tc filter add dev "$veth" ingress bpf da obj build/veth_filter.bpf.o sec tc 2>/dev/null; then
                log_info "  veth_filter → $veth (성공)"
                veth_count=$((veth_count + 1))
            else
                log_warn "  veth_filter → $veth (실패)"
            fi
        done
        if [ "$veth_count" -eq 0 ]; then
            log_warn "veth_filter: attach된 인터페이스 없음!"
            log_warn "  Cilium pod veth 인터페이스가 없거나 이름 패턴이 다를 수 있습니다"
            log_warn "  수동 확인: ip link show type veth"
        else
            log_info "veth_filter: ${veth_count}개 인터페이스에 attach됨"
        fi
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
    log_info "=== TC Qdisc 설정 (우선순위 큐) ==="

    # 기존 root qdisc 제거
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true

    # TX queue 수 확인
    local txq_count
    txq_count=$(ls -d /sys/class/net/"$PHYS_IF"/queues/tx-* 2>/dev/null | wc -l)
    log_info "NIC TX queue 수: $txq_count"

    local qdisc_ok=0

    # 시도 1: mqprio (다중 TX queue가 있을 때만)
    if [ "$txq_count" -ge 3 ]; then
        log_info "mqprio 설정 시도 (TX queue $txq_count개)..."
        if tc qdisc add dev "$PHYS_IF" root handle 100: mqprio \
            num_tc 3 \
            map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
            queues 1@0 1@1 1@2 \
            hw 0 2>/dev/null; then
            log_info "mqprio 설정 완료"
            qdisc_ok=1
        else
            log_warn "mqprio 설정 실패"
        fi
    else
        log_info "TX queue 부족 ($txq_count < 3) — mqprio 건너뜀"
    fi

    # 시도 2: prio qdisc (VM 폴백 — 소프트웨어 우선순위 큐)
    if [ "$qdisc_ok" -eq 0 ]; then
        log_info "prio qdisc 설정 (VM 호환 모드)..."
        if tc qdisc add dev "$PHYS_IF" root handle 100: prio \
            bands 3 \
            priomap 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 2>/dev/null; then
            log_info "prio qdisc 설정 완료"
            qdisc_ok=1
        else
            log_error "prio qdisc 설정도 실패"
            log_info "디버그: tc qdisc show dev $PHYS_IF"
            tc qdisc show dev "$PHYS_IF"
            return 1
        fi
    fi

    # ETF 설정 시도 (mqprio/prio의 band 0 = time-sensitive)
    log_info "ETF 설정 시도 (band 0)..."
    if tc qdisc add dev "$PHYS_IF" parent 100:1 handle 10: etf \
        clockid CLOCK_TAI \
        delta 150000 \
        deadline_mode on 2>/dev/null; then
        log_info "ETF 설정 완료 (CLOCK_TAI)"
    elif tc qdisc add dev "$PHYS_IF" parent 100:1 handle 10: etf \
        clockid CLOCK_REALTIME \
        delta 150000 \
        deadline_mode on 2>/dev/null; then
        log_info "ETF 설정 완료 (CLOCK_REALTIME)"
    else
        log_warn "ETF 미지원 — 우선순위 큐만 사용 (txtime 스케줄링 없음)"
    fi

    log_info "최종 Qdisc 상태:"
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

    # 기존 리소스 정리 (개별 삭제 후 namespace 삭제 — Terminating 방지)
    log_info "기존 리소스 정리..."
    if kubectl get namespace tsn-experiment &>/dev/null; then
        kubectl -n tsn-experiment delete job --all --force --grace-period=0 2>/dev/null || true
        kubectl -n tsn-experiment delete daemonset --all --force --grace-period=0 2>/dev/null || true
        kubectl -n tsn-experiment delete deployment --all --force --grace-period=0 2>/dev/null || true
        kubectl -n tsn-experiment delete pod --all --force --grace-period=0 2>/dev/null || true
        kubectl -n tsn-experiment delete configmap --all 2>/dev/null || true
        kubectl -n tsn-experiment delete svc --all 2>/dev/null || true
        kubectl delete namespace tsn-experiment --timeout=30s 2>/dev/null || {
            log_warn "namespace 삭제 타임아웃 — 강제 진행합니다"
            # Finalizer 제거하여 강제 삭제
            kubectl get namespace tsn-experiment -o json | \
                sed 's/"finalizers": \[[^]]*\]/"finalizers": []/' | \
                kubectl replace --raw "/api/v1/namespaces/tsn-experiment/finalize" -f - 2>/dev/null || true
        }
        sleep 3
    fi

    # 네임스페이스 생성
    kubectl apply -f "$K8S_DIR/namespace.yaml"

    # python:3.11-slim 이미지가 노드에 있는지 확인
    log_info "python:3.11-slim 이미지 확인..."
    if sudo ctr -n k8s.io images ls | grep -q "python.*3.11-slim"; then
        log_info "python:3.11-slim 이미지 존재 확인"
    else
        log_warn "python:3.11-slim 이미지가 없습니다. Pod 생성 시 자동 pull 됩니다."
        log_warn "인터넷 연결이 필요합니다. 오프라인이면 수동으로 import 하세요:"
        log_warn "  sudo ctr -n k8s.io images pull docker.io/library/python:3.11-slim"
    fi

    # Listener 배포 (ConfigMap + python:3.11-slim)
    log_info "Listener 배포 (ConfigMap + base image)..."
    kubectl apply -f "$K8S_DIR/listener-deployment.yaml"

    # Listener pod 준비 대기
    log_info "Listener pod 준비 대기..."
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=180s || {
        log_error "Listener pod가 준비되지 않았습니다"
        kubectl -n tsn-experiment get pods -o wide
        kubectl -n tsn-experiment describe pod -l app=listener | tail -20
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

    # Proposed 모드: TC qdisc 설정 (root 권한 필요)
    if [ "$MODE" = "proposed" ]; then
        if [ "$(id -u)" -ne 0 ]; then
            log_error "proposed 모드는 TC qdisc 설정을 위해 sudo가 필요합니다"
            log_info "사용법: sudo bash $0 run proposed $CPU_LOAD"
            exit 1
        fi
        setup_tc_qdisc
    else
        remove_tc_qdisc
    fi

    # 이전 Job/DaemonSet 정리
    kubectl -n tsn-experiment delete job talker-run --ignore-not-found=true 2>/dev/null || true
    kubectl -n tsn-experiment delete daemonset cpu-stress --ignore-not-found=true 2>/dev/null || true
    sleep 3

    # Listener pod 재시작 (이전 실행 후 프로세스 종료 → CrashLoopBackOff 방지)
    log_info "Listener pod 재시작 (깨끗한 상태 보장)..."
    kubectl -n tsn-experiment delete pod -l app=listener --grace-period=5 2>/dev/null || true
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=120s || {
        log_error "Listener pod 재시작 실패"
        kubectl -n tsn-experiment get pods -l app=listener -o wide
        exit 1
    }
    LISTENER_POD=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')
    log_info "Listener pod 준비 완료: $LISTENER_POD"

    # CPU 부하 생성
    log_info "CPU 부하 생성 (${CPU_LOAD}%)..."
    sed "s/\"99\"/\"$CPU_LOAD\"/" "$K8S_DIR/stress-daemonset.yaml" | \
        kubectl apply -f -
    sleep 5

    # Talker ConfigMap + Job 배포
    log_info "Talker Job 실행..."
    kubectl apply -f "$K8S_DIR/talker-job.yaml"

    # Talker 완료 대기
    log_info "Talker 완료 대기 (최대 5분)..."
    kubectl -n tsn-experiment wait --for=condition=complete job/talker-run --timeout=300s || {
        log_warn "Talker Job 타임아웃"
    }

    # Listener가 결과 파일을 쓸 때까지 대기 (timeout 후 CSV 작성)
    log_info "Listener 결과 파일 대기 (최대 90초)..."
    local csv_found=0
    for i in $(seq 1 18); do
        if kubectl -n tsn-experiment exec "$LISTENER_POD" -- test -f /data/results.csv 2>/dev/null; then
            log_info "결과 파일 확인됨 (${i}회 폴링)"
            csv_found=1
            break
        fi
        sleep 5
    done
    if [ "$csv_found" -eq 0 ]; then
        log_warn "결과 파일 대기 타임아웃 — Listener 로그 확인:"
        kubectl -n tsn-experiment logs "$LISTENER_POD" --tail=20
    fi

    # 결과 수집
    local RESULT_FILE="$RESULTS_DIR/${MODE}_cpu${CPU_LOAD}.csv"
    log_info "결과 수집 → $RESULT_FILE"
    kubectl -n tsn-experiment cp "$LISTENER_POD:/data/results.csv" "$RESULT_FILE" || {
        log_warn "결과 파일 복사 실패"
    }

    # 부하 제거
    kubectl -n tsn-experiment delete daemonset cpu-stress --ignore-not-found=true 2>/dev/null || true

    # eBPF 통계 출력
    log_info "=== eBPF 통계 ==="
    if command -v bpftool &>/dev/null; then
        echo "--- pkt_stats ---"
        bpftool map dump name pkt_stats 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for m in data:
        mid = m.get('id', '?')
        elems = m.get('elements', [])
        vals = {e['key']: e['value'] for e in elems}
        print(f'  map_id={mid}: TOTAL={vals.get(0,0)} TSN={vals.get(1,0)} BEST_EFF={vals.get(2,0)} DROP={vals.get(3,0)}')
except: print('  (파싱 실패)')
" 2>/dev/null || echo "  (pkt_stats 없음 — sudo로 실행하세요)"
        echo "--- debug_stats (0이 아닌 값만) ---"
        bpftool map dump name debug_stats 2>/dev/null | python3 -c "
import sys, json
labels = {0:'ETH_SHORT',4:'NOT_IP',5:'NOT_UDP',8:'TSN_PORT',9:'TSN_PCP',13:'PROG_ENTER'}
try:
    data = json.load(sys.stdin)
    for m in data:
        mid = m.get('id', '?')
        nonzero = [(e['key'], e['value']) for e in m.get('elements', []) if e['value'] > 0]
        if nonzero:
            parts = [f'{labels.get(k,str(k))}={v}' for k, v in nonzero]
            print(f'  map_id={mid}: {\"  \".join(parts)}')
except: pass
" 2>/dev/null
    else
        echo "(bpftool 없음)"
    fi

    # 결과 CSV 미리보기
    if [ -f "$RESULT_FILE" ]; then
        local line_count
        line_count=$(wc -l < "$RESULT_FILE")
        log_info "결과 파일: $RESULT_FILE ($line_count 행)"
        head -3 "$RESULT_FILE"
        echo "..."
        tail -1 "$RESULT_FILE"
    fi

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
    echo "=== NIC 정보: $PHYS_IF ==="
    echo "--- TX queues ---"
    ls -d /sys/class/net/"$PHYS_IF"/queues/tx-* 2>/dev/null | wc -l | xargs -I{} echo "TX queue 수: {}"
    echo "--- driver ---"
    ethtool -i "$PHYS_IF" 2>/dev/null | head -3 || echo "(ethtool 없음)"

    echo ""
    echo "=== TC Filters ($PHYS_IF) ==="
    echo "--- egress ---"
    tc filter show dev "$PHYS_IF" egress 2>/dev/null || echo "(없음)"
    echo "--- ingress ---"
    tc filter show dev "$PHYS_IF" ingress 2>/dev/null || echo "(없음)"

    echo ""
    echo "=== veth 인터페이스 (veth_filter attach 대상) ==="
    local veth_list
    veth_list=$(ip link show type veth 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1)
    if [ -n "$veth_list" ]; then
        for v in $veth_list; do
            local has_bpf=""
            if tc filter show dev "$v" ingress 2>/dev/null | grep -q bpf; then
                has_bpf="[BPF attached]"
            else
                has_bpf="[NO BPF]"
            fi
            echo "  $v $has_bpf"
        done
    else
        echo "  (veth 인터페이스 없음 — Cilium 또는 CNI가 아직 veth를 생성하지 않음)"
    fi

    echo ""
    echo "=== TC Qdisc ==="
    tc qdisc show dev "$PHYS_IF" 2>/dev/null

    echo ""
    echo "=== XDP ==="
    ip link show dev "$PHYS_IF" | grep -i xdp || echo "(없음)"

    echo ""
    echo "=== BPF Programs (TC/XDP만) ==="
    bpftool prog list 2>/dev/null | grep -A2 -E 'sched_cls|xdp' || echo "(TC/XDP 프로그램 없음)"

    echo ""
    echo "=== Packet Stats (pkt_stats) ==="
    echo "  [0] TOTAL   [1] TSN   [2] BEST_EFF   [3] DROPPED"
    bpftool map dump name pkt_stats 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for m in data:
        mid = m.get('id', '?')
        elems = m.get('elements', [])
        vals = {e['key']: e['value'] for e in elems}
        total = vals.get(0, 0)
        tsn = vals.get(1, 0)
        best = vals.get(2, 0)
        drop = vals.get(3, 0)
        if total > 0 or tsn > 0:
            print(f'  map_id={mid}: TOTAL={total} TSN={tsn} BEST_EFF={best} DROPPED={drop}')
        else:
            print(f'  map_id={mid}: (모두 0 — 패킷이 이 프로그램을 통과하지 않음)')
except:
    print('  (파싱 실패 — raw dump:)')
    sys.stdin.seek(0)
    print(sys.stdin.read()[:500])
" 2>/dev/null || echo "  (pkt_stats 없음)"

    echo ""
    echo "=== Debug Stats (debug_stats) ==="
    echo "  [0]ETH_SHORT [4]NOT_IP [5]NOT_UDP [8]TSN_PORT [9]TSN_PCP [13]PROG_ENTER"
    bpftool map dump name debug_stats 2>/dev/null | python3 -c "
import sys, json
labels = {0:'ETH_SHORT',1:'VLAN_FAIL',2:'IP_SHORT',3:'UDP_SHORT',
          4:'NOT_IP',5:'NOT_UDP',6:'VLAN_TAG',7:'AVTP',
          8:'TSN_PORT',9:'TSN_PCP',10:'RINGBUF_FAIL',11:'MAP_FAIL',
          12:'UNK_PROTO',13:'PROG_ENTER',14:'IHL_BAD'}
try:
    data = json.load(sys.stdin)
    for m in data:
        mid = m.get('id', '?')
        elems = m.get('elements', [])
        nonzero = [(e['key'], e['value']) for e in elems if e['value'] > 0]
        if nonzero:
            parts = [f'{labels.get(k,str(k))}={v}' for k, v in nonzero]
            print(f'  map_id={mid}: {\"  \".join(parts)}')
        else:
            print(f'  map_id={mid}: (모두 0)')
except:
    print('  (파싱 실패)')
" 2>/dev/null || echo "  (debug_stats 없음)"

    echo ""
    echo "=== Cilium 네트워크 모드 ==="
    kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.tunnel}' 2>/dev/null && echo "" || \
    kubectl -n kube-system exec -l k8s-app=cilium -- cilium status 2>/dev/null | grep -i 'tunnel\|encap\|routing' || \
    echo "  (확인 불가)"

    echo ""
    echo "=== K8s 실험 Pod 상태 ==="
    kubectl -n tsn-experiment get pods -o wide 2>/dev/null || echo "(tsn-experiment namespace 없음)"

    echo ""
    echo "=== trace_pipe 최근 로그 (5줄) ==="
    timeout 1 cat /sys/kernel/debug/tracing/trace_pipe 2>/dev/null | head -5 || echo "(trace_pipe 접근 불가 — sudo 필요)"
}

# =============================================================================
# Main
# =============================================================================
case "${1:-help}" in
    build-ebpf)
        log_info "=== eBPF 프로그램 컴파일 ==="
        cd "$EBPF_DIR"
        for cmd in clang make; do
            if ! command -v $cmd &>/dev/null; then
                log_error "$cmd 이 설치되어 있지 않습니다"
                log_info "설치: sudo apt install clang make"
                exit 1
            fi
        done
        make clean 2>/dev/null || true
        make all DEBUG=2
        log_info "컴파일 완료. 다른 노드로 배포하려면:"
        log_info "  cd $SCRIPT_DIR && git add step6-ebpf/build/ && git commit -m 'add pre-built ebpf' && git push"
        log_info "  (다른 노드에서) git pull"
        ;;
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
        echo "  build-ebpf                    - eBPF 컴파일만 (빌드 가능한 노드에서)"
        echo "  setup-ebpf <sender|receiver>  - eBPF attach (사전 빌드된 .o 사용 가능)"
        echo "  setup-tc                      - TC qdisc 설정 (mqprio+etf)"
        echo "  remove-tc                     - TC qdisc 제거"
        echo "  deploy-k8s                    - K8s 실험 환경 배포"
        echo "  run <baseline|proposed> <cpu%> - 실험 실행"
        echo "  cleanup                       - 전체 정리"
        echo "  status                        - 현재 상태 확인"
        echo ""
        echo "실행 순서:"
        echo "  0. [master]   bash $0 build-ebpf    # 한 번만, make가 있는 노드에서"
        echo "     [master]   git add step6-ebpf/build/ && git commit -m 'add pre-built ebpf' && git push"
        echo "     [worker01] git pull               # 빌드 결과 배포"
        echo "  1. [master]   sudo bash $0 setup-ebpf sender"
        echo "  2. [worker01] sudo bash $0 setup-ebpf receiver"
        echo "  3. [master]   bash $0 deploy-k8s"
        echo "  4. [master]   bash $0 run baseline 10"
        echo "  5. [master]   bash $0 run proposed 10"
        echo "  6. [master]   sudo bash $0 cleanup"
        ;;
esac

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
    # 단일 프로그램 설계 (2026-06): vnic_filter 하나만 빌드한다.
    #   attach 는 호스트 NIC 이 아니라 Pod eth0 egress(netns 내부)에 한다.
    #   그 작업은 talker Pod 가 떠 있을 때 run_experiment() 가 attach-vnic.sh 로 수행한다.
    #   (Cilium tcx 우회를 피해 pkt_count 카운터가 확실히 찍히는 지점)
    log_info "=== eBPF 빌드 (단일 프로그램: vnic_filter) ==="
    cd "$EBPF_DIR"
    if ls build/*.bpf.o &>/dev/null; then
        log_info "사전 빌드된 오브젝트 발견 — 컴파일 생략"
        ls build/*.bpf.o
    else
        for cmd in clang make; do
            command -v $cmd &>/dev/null || { log_error "$cmd 미설치 — sudo apt install clang make libbpf-dev linux-libc-dev"; exit 1; }
        done
        log_info "vnic_filter 컴파일..."
        make clean 2>/dev/null || true
        make all
    fi
    log_info "빌드 완료: $(ls build/*.bpf.o 2>/dev/null | tr '\n' ' ')"
    log_info "attach 는 실험 실행 시 talker Pod eth0 egress 에 자동 수행됩니다 (attach-vnic.sh)."
}

# =============================================================================
# TC Qdisc 설정 (Proposed 실험용)
# =============================================================================
setup_tc_qdisc() {
    log_info "=== TC Qdisc 설정 (우선순위 큐) ==="

    # 기존 root qdisc 제거
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true

    # ── 단순 prio qdisc (3밴드, 기본 priomap) ──
    # vnic_filter / talker SO_PRIORITY 가 TS 패킷에 priority=6 을 설정한다.
    # 리눅스 prio 의 기본 priomap 은 priority 6,7 → band 0(최우선)이므로,
    # 커스텀 priomap 없이 plain prio 한 줄이면 TS 패킷이 band 0 으로 우선 dequeue 된다.
    #   (참고 기본 priomap: 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1)
    if tc qdisc add dev "$PHYS_IF" root handle 100: prio bands 3 2>/dev/null; then
        log_info "prio qdisc 설정 완료 (기본 priomap: priority 6 → band 0)"
    else
        log_error "prio qdisc 설정 실패"
        tc qdisc show dev "$PHYS_IF"
        return 1
    fi

    log_info "최종 Qdisc 상태:"
    tc qdisc show dev "$PHYS_IF"
}

remove_tc_qdisc() {
    # baseline 은 fq_codel(우선순위 밴드 없음)로 명시 설정한다.
    #   주의: priority 6 은 prio/pfifo_fast 의 기본 priomap 에서 band 0(최우선)으로 간다.
    #   baseline 에서 default qdisc 가 pfifo_fast 면 baseline 도 우선순위를 받아 contrast 가
    #   사라진다. fq_codel 은 priomap 을 쓰지 않으므로 baseline 이 깨끗한 best-effort 가 된다.
    log_info "baseline qdisc 설정 (fq_codel — 우선순위 밴드 없음)..."
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
    tc qdisc add dev "$PHYS_IF" root fq_codel 2>/dev/null || true
    log_info "baseline qdisc(fq_codel) 설정 완료"
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

    # (항목 8) 선택적 Hubble 캡처 — HUBBLE=1 일 때만. 정상 실험에는 영향 없음.
    if [ "${HUBBLE:-0}" = "1" ] && command -v hubble &>/dev/null; then
        log_info "Hubble 캡처 시작 (UDP 6000) → $RESULTS_DIR/hubble_${MODE}_cpu${CPU_LOAD}.json"
        bash "$SCRIPT_DIR/step8-measurement/hubble-monitor.sh" start \
            "$RESULTS_DIR/hubble_${MODE}_cpu${CPU_LOAD}.json" 2>/dev/null || \
            log_warn "Hubble 캡처 시작 실패 (enable 안 됨? — step8-measurement/hubble-monitor.sh enable)"
    fi

    # Talker ConfigMap + Job 배포 (talker 는 --start-delay 동안 송신 전 대기)
    log_info "Talker Job 실행..."
    kubectl apply -f "$K8S_DIR/talker-job.yaml"

    # ── vnic_filter 를 talker Pod eth0 egress(netns 내부)에 attach ──
    # talker Pod 가 Running 되면, --start-delay(8s) 안에 vnic_filter 를 붙인다.
    # 이 지점은 Cilium tcx 가 손대기 전이라 pkt_count 카운터가 확실히 찍힌다.
    log_info "talker Pod Running 대기..."
    if kubectl -n tsn-experiment wait --for=jsonpath='{.status.phase}'=Running \
            pod -l job-name=talker-run --timeout=120s 2>/dev/null; then
        TALKER_POD=$(kubectl -n tsn-experiment get pod -l job-name=talker-run -o jsonpath='{.items[0].metadata.name}')
        log_info "vnic_filter attach → $TALKER_POD eth0 egress ..."
        if sudo bash "$EBPF_DIR/attach-vnic.sh" attach tsn-experiment "$TALKER_POD" 2>&1 | sed 's/^/  /'; then
            log_info "vnic_filter attach 완료"
            VNIC_ATTACHED=1
        else
            log_warn "vnic_filter attach 실패 (crictl/nsenter 확인). 실험은 SO_PRIORITY 로 계속 진행됨."
        fi
    else
        log_warn "talker Pod Running 대기 실패 — attach 생략 (실험은 SO_PRIORITY 로 진행)"
    fi

    # Talker 완료 대기 + pkt_count 스냅샷
    #   주의: talker Job Pod 는 송신 후 Completed → netns 소멸 → 그 뒤엔 pkt_count 읽기 불가.
    #   그래서 송신 중(Pod Running)에 주기적으로 스냅샷을 떠서 마지막 값을 보관한다.
    log_info "Talker 완료 대기 (최대 5분, 송신 중 pkt_count 스냅샷)..."
    PKT_COUNT_SNAPSHOT=""
    for _i in $(seq 1 60); do
        if [ "$(kubectl -n tsn-experiment get job talker-run -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
            break
        fi
        if [ "${VNIC_ATTACHED:-0}" = "1" ] && [ -n "${TALKER_POD:-}" ]; then
            snap=$(sudo bash "$EBPF_DIR/attach-vnic.sh" show tsn-experiment "$TALKER_POD" 2>/dev/null || true)
            [ -n "$snap" ] && PKT_COUNT_SNAPSHOT="$snap"
        fi
        sleep 5
    done

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

    # (항목 8) Hubble 캡처 종료
    if [ "${HUBBLE:-0}" = "1" ] && command -v hubble &>/dev/null; then
        bash "$SCRIPT_DIR/step8-measurement/hubble-monitor.sh" stop 2>/dev/null || true
    fi

    # eBPF 카운터 출력 (vnic_filter pkt_count, key0=일반 key1=TS)
    log_info "=== eBPF 카운터 (vnic_filter pkt_count) ==="
    if [ -n "${PKT_COUNT_SNAPSHOT:-}" ]; then
        echo "$PKT_COUNT_SNAPSHOT" | sed 's/^/  /'
    else
        echo "  (스냅샷 없음 — attach 실패했거나 송신이 너무 빨랐음)"
        echo "  라이브 확인: 다른 터미널에서 talker 송신 중에 실행:"
        echo "    sudo bash $EBPF_DIR/attach-vnic.sh show tsn-experiment <talker-pod>"
        echo "  (실험 측정 자체는 listener.py 의 results.csv 가 담당하므로 카운터는 보조 지표)"
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
    # vnic_filter 는 talker Pod netns 안에 붙으므로 namespace 삭제 시 Pod 와 함께 사라진다.
    kubectl delete namespace tsn-experiment 2>/dev/null || true
    # 물리 NIC 의 prio qdisc(proposed 모드) 제거
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
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
    echo "=== TC Qdisc ($PHYS_IF) ==="
    echo "  proposed 모드면 'prio' 가 root qdisc 여야 함 (priority 6 → band 0)"
    tc qdisc show dev "$PHYS_IF" 2>/dev/null

    echo ""
    echo "=== vnic_filter (talker Pod eth0 egress, netns 내부) ==="
    echo "  vnic_filter 와 pkt_count 는 호스트가 아니라 talker Pod netns 안에 있다."
    echo "  카운터 확인 (talker 송신 중에):"
    echo "    TP=\$(kubectl -n tsn-experiment get pod -l job-name=talker-run -o jsonpath='{.items[0].metadata.name}')"
    echo "    sudo bash $EBPF_DIR/attach-vnic.sh show tsn-experiment \$TP"

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
        make all
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
        echo "  build-ebpf                    - vnic_filter 컴파일 (clang+libbpf-dev 필요)"
        echo "  setup-ebpf                    - vnic_filter 빌드 확인 (attach 는 run 시 Pod eth0 에 자동)"
        echo "  setup-tc                      - prio qdisc 설정 (priority 6 → band 0)"
        echo "  remove-tc                     - qdisc 제거 (baseline)"
        echo "  deploy-k8s                    - K8s 실험 환경 배포 (listener)"
        echo "  run <baseline|proposed> <cpu%> - 실험 실행 (proposed 시 talker Pod eth0 에 vnic_filter attach)"
        echo "  cleanup                       - 전체 정리"
        echo "  status                        - 현재 상태 확인"
        echo ""
        echo "실행 순서 (단일 프로그램 설계):"
        echo "  0. [master]   bash $0 build-ebpf      # vnic_filter 빌드 (make 있는 노드)"
        echo "  1. [master]   bash $0 deploy-k8s       # listener 배포"
        echo "  2. [master]   bash $0 run baseline 10"
        echo "  3. [master]   sudo bash $0 run proposed 10   # talker Pod eth0 egress 에 vnic_filter attach"
        echo "  4. [master]   sudo bash $0 cleanup"
        echo ""
        echo "  pkt_count 확인 (talker 송신 중): sudo bash step6-ebpf/attach-vnic.sh show tsn-experiment <talker-pod>"
        ;;
esac

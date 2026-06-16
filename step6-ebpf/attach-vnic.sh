#!/bin/bash
# =============================================================================
# attach-vnic.sh — vnic_filter.bpf.o 를 Pod eth0 egress(netns 내부)에 attach
#
# 왜 netns 내부인가:
#   Cilium tcx(cil_from_container)는 호스트측 veth(lxc)에서 먼저 실행되어
#   legacy clsact 를 스킵시킨다. 그래서 호스트측에 붙이면 카운터가 0이 된다.
#   Pod 의 eth0 egress 는 Cilium 이 손대기 전 지점이라, 여기 붙이면
#   vnic_filter 가 확실히 실행되고 pkt_count 카운터가 찍힌다.
#
# 사용법 (해당 Pod 가 떠 있는 노드에서 root 로):
#   sudo bash attach-vnic.sh attach <namespace> <pod-name> [obj]
#   sudo bash attach-vnic.sh detach <namespace> <pod-name>
#   sudo bash attach-vnic.sh show   <namespace> <pod-name>
#
# 의존: crictl (cri-tools) 또는 ctr, nsenter, tc, bpftool
# =============================================================================
set -euo pipefail

ACTION="${1:-}"
NS="${2:-tsn-experiment}"
POD="${3:-}"
OBJ="${4:-$(dirname "$0")/build/vnic_filter.bpf.o}"

err() { echo "[ERR] $*" >&2; }
log() { echo "[INFO] $*"; }

# Pod 컨테이너의 호스트 PID 조회 (containerd/crictl 우선, ctr 폴백)
get_pid() {
    local cid pid
    cid=$(kubectl -n "$NS" get pod "$POD" \
            -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null \
            | sed 's|.*://||')
    if [ -z "$cid" ]; then
        err "컨테이너 ID 조회 실패 (Pod 가 Running 상태인지 확인)"; return 1
    fi
    if command -v crictl &>/dev/null; then
        pid=$(crictl inspect "$cid" 2>/dev/null \
              | python3 -c 'import sys,json; print(json.load(sys.stdin)["info"]["pid"])' 2>/dev/null || true)
    fi
    if [ -z "${pid:-}" ] && command -v ctr &>/dev/null; then
        pid=$(ctr -n k8s.io task ls 2>/dev/null | awk -v c="$cid" '$1==c{print $2}' | head -1 || true)
    fi
    if [ -z "${pid:-}" ]; then
        err "컨테이너 PID 조회 실패 (crictl/ctr 필요: sudo apt install cri-tools)"; return 1
    fi
    echo "$pid"
}

case "$ACTION" in
    attach)
        [ -n "$POD" ] || { err "Pod 이름 필요"; exit 1; }
        [ -f "$OBJ" ] || { err "BPF 오브젝트 없음: $OBJ — make -C $(dirname "$0")"; exit 1; }
        PID=$(get_pid)
        log "Pod $NS/$POD → host PID $PID, obj=$OBJ"
        # netns 내부 eth0 egress 에 clsact + bpf filter
        nsenter -t "$PID" -n tc qdisc add dev eth0 clsact 2>/dev/null || true
        nsenter -t "$PID" -n tc filter del dev eth0 egress 2>/dev/null || true
        nsenter -t "$PID" -n tc filter add dev eth0 egress \
            bpf da obj "$OBJ" sec tc
        log "attach 완료. 확인:"
        nsenter -t "$PID" -n tc filter show dev eth0 egress
        ;;
    detach)
        [ -n "$POD" ] || { err "Pod 이름 필요"; exit 1; }
        PID=$(get_pid)
        nsenter -t "$PID" -n tc filter del dev eth0 egress 2>/dev/null || true
        nsenter -t "$PID" -n tc qdisc del dev eth0 clsact 2>/dev/null || true
        log "detach 완료"
        ;;
    show)
        [ -n "$POD" ] || { err "Pod 이름 필요"; exit 1; }
        PID=$(get_pid)
        echo "--- tc filter (eth0 egress) ---"
        nsenter -t "$PID" -n tc filter show dev eth0 egress 2>/dev/null || echo "(없음)"
        echo "--- pkt_count (key0=일반, key1=TS) ---"
        nsenter -t "$PID" -n bpftool map dump name pkt_count 2>/dev/null || echo "(맵 없음)"
        ;;
    *)
        echo "사용법: sudo bash $0 {attach|detach|show} <namespace> <pod> [obj]"
        ;;
esac

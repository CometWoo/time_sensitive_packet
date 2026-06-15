#!/bin/bash
# =============================================================================
# hubble-monitor.sh — Cilium Hubble 로 실험 트래픽(UDP 5000) 흐름 관찰
#
# ⚠️ 현재 상태 (2026-06 감사):
#   step4-cilium/01-install-cilium.sh 의 helm 설치에는 hubble 옵션이 없다.
#   → 기본적으로 Hubble 은 **비활성**이다. 먼저 enable 해야 한다(아래 'enable').
#
# ⚠️ 한계 (정직한 보고):
#   Hubble 은 L3/L4 흐름(누가→누구, 포트, verdict)만 본다. 본 실험의 핵심인
#   skb->priority(SO_PRIORITY=3) 나 TC band/qdisc 는 Hubble 로 볼 수 없다.
#   따라서 Hubble 은 "패킷이 흐르는지/드롭되는지/어느 pod 간인지" 확인용이며,
#   우선순위 큐 효과(latency/jitter)는 여전히 listener.py + pkt_stats 로 측정한다.
#
# 사용법:
#   bash hubble-monitor.sh enable      # Hubble + relay + UI 활성화 (1회)
#   bash hubble-monitor.sh status      # Hubble 상태
#   bash hubble-monitor.sh watch       # 실험 트래픽(UDP 5000) 실시간 관찰
#   bash hubble-monitor.sh start <out> # 백그라운드 캡처 시작 → <out> 파일
#   bash hubble-monitor.sh stop        # 백그라운드 캡처 종료
# =============================================================================
set -euo pipefail

NS="tsn-experiment"
PORT="${PORT:-5000}"
PIDFILE="/tmp/hubble-monitor.pid"

enable_hubble() {
    echo "[Hubble] 활성화 (helm upgrade)..."
    # 기존 cilium 릴리스에 hubble 옵션만 덧붙임 (--reuse-values 로 기존 설정 보존)
    helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --set hubble.metrics.enableOpenMetrics=true \
        --set 'hubble.metrics.enabled={dns,drop,tcp,flow,port-distribution,icmp,httpV2}'
    kubectl -n kube-system rollout status daemonset/cilium --timeout=180s || true
    echo "[Hubble] hubble CLI 설치 확인:"
    command -v hubble >/dev/null 2>&1 && hubble version || {
        echo "  hubble CLI 미설치 — 설치:"
        echo "    HUBBLE_VER=\$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)"
        echo "    curl -L --remote-name-all https://github.com/cilium/hubble/releases/download/\$HUBBLE_VER/hubble-linux-amd64.tar.gz"
        echo "    sudo tar xzvf hubble-linux-amd64.tar.gz -C /usr/local/bin"
    }
    echo "[Hubble] relay 포트포워딩(별도 터미널): cilium hubble port-forward &"
}

status_hubble() {
    kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide 2>/dev/null || echo "(hubble-relay 없음 — enable 필요)"
    cilium hubble enable --help >/dev/null 2>&1 || true
    hubble status 2>/dev/null || echo "(hubble CLI 미연결 — 'cilium hubble port-forward &' 후 재시도)"
}

# (a) 실험 트래픽 필터: 네임스페이스 + UDP 목적지 포트
watch_traffic() {
    echo "[Hubble] $NS 네임스페이스, UDP 포트 $PORT 흐름 관찰 (Ctrl+C 중단)..."
    # --protocol UDP, --port 으로 실험 트래픽만 필터. -f = follow.
    hubble observe -f \
        --namespace "$NS" \
        --protocol udp \
        --port "$PORT" \
        --output compact
}

start_capture() {
    local OUT="${1:-hubble-flows.json}"
    echo "[Hubble] 백그라운드 캡처 시작 → $OUT"
    hubble observe -f --namespace "$NS" --protocol udp --port "$PORT" --output json > "$OUT" 2>/dev/null &
    echo $! > "$PIDFILE"
    echo "  PID=$(cat "$PIDFILE")"
}

stop_capture() {
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "[Hubble] 캡처 종료"
    else
        echo "[Hubble] 실행 중인 캡처 없음"
    fi
}

case "${1:-help}" in
    enable) enable_hubble ;;
    status) status_hubble ;;
    watch)  watch_traffic ;;
    start)  start_capture "${2:-hubble-flows.json}" ;;
    stop)   stop_capture ;;
    *)
        echo "사용법: $0 {enable|status|watch|start <out>|stop}"
        echo "  enable  Hubble/relay/UI 활성화 (1회)"
        echo "  status  상태 확인"
        echo "  watch   UDP $PORT 실시간 관찰"
        echo "  start   백그라운드 JSON 캡처 시작"
        echo "  stop    백그라운드 캡처 종료"
        ;;
esac

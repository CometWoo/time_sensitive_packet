#!/bin/bash
# =============================================================================
# scripts/hubble-monitor.sh — Cilium Hubble 로 실험 트래픽(UDP TS_PORT) 흐름 관찰 (선택 도구)
#
# 상태:
#   scripts/setup/cilium-install.sh 의 helm 설치에는 hubble 옵션이 없다 → 기본 **비활성**.
#   먼저 'enable' 로 켠다 (helm upgrade --reuse-values --version <설치된 차트 버전>; Cilium 버전은 그대로,
#   agent 만 재시작된다 — 재시작 뒤에도 우리 tcx 링크(pin)는 남지만, scripts/experiment.sh run 이 체인
#   순서를 다시 확인한다). 재시작 전후로 meta.json 의 cilium_image 가 같아야 한다.
#   scripts/experiment.sh cleanup 이 'stop' 을 호출해 백그라운드 캡처를 끝낸다.
#
# 한계:
#   Hubble 은 L3/L4 흐름(누가→누구, 포트, verdict)만 본다. skb->priority, DSCP 재기록, HTB/prio band 는
#   Hubble 로 볼 수 없다. "패킷이 흐르는지 / 드롭되는지 / 어느 Pod 간인지" 확인용이고, 우선순위 효과는
#   listener CSV + ts_counters + tc -s class (scripts/experiment.sh / scripts/verify.sh) 로 본다.
#
# 사용법:
#   bash scripts/hubble-monitor.sh enable      # Hubble + relay + UI 활성화 (1회)
#   bash scripts/hubble-monitor.sh status      # Hubble 상태
#   bash scripts/hubble-monitor.sh watch       # 실험 트래픽 실시간 관찰
#   bash scripts/hubble-monitor.sh start <out> # 백그라운드 캡처 시작 → <out> 파일 (JSON)
#   bash scripts/hubble-monitor.sh stop        # 백그라운드 캡처 종료 (없어도 성공)
# 설정: ./experiment.env 의 NAMESPACE / TS_PORT / CILIUM_VERSION (없으면 tsn-experiment / 6000 / helm list 값)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${EXPERIMENT_ENV:-$SCRIPT_DIR/experiment.env}"
env_get() {   # env_get KEY default  — experiment.env 의 KEY=VALUE (환경변수 우선)
    local v="${!1:-}"
    [ -n "$v" ] || { [ -f "$ENV_FILE" ] && v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*/\1/p" "$ENV_FILE" | tail -1 | sed 's/[[:space:]]*$//'); }
    echo "${v:-$2}"
}
NS=$(env_get NAMESPACE tsn-experiment)
PORT=$(env_get TS_PORT 6000)
PIDFILE="/tmp/hubble-monitor.pid"

# 설치된 cilium 차트 버전. --version 없이 helm upgrade 하면 저장소의 최신 차트로 올라가 측정 중인
# Cilium 데이터패스가 바뀐다 (step4 의 CILIUM_VERSION 고정과 모순). experiment.env 의 CILIUM_VERSION 이
# 있으면 그것을, 없으면 'helm list' 의 chart 필드(cilium-1.19.1 → 1.19.1)를 쓴다.
cilium_chart_version() {
    local v; v=$(env_get CILIUM_VERSION "")
    if [ -n "$v" ]; then echo "$v"; return 0; fi
    helm -n kube-system list -o json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("name") == "cilium":
        print(r["chart"].rsplit("-", 1)[-1]); break' 2>/dev/null || true
}

enable_hubble() {
    local ver; ver=$(cilium_chart_version)
    [ -n "$ver" ] || { echo "[Hubble] 설치된 cilium 차트 버전을 알 수 없음 (helm -n kube-system list). experiment.env 에 CILIUM_VERSION=1.19.1 처럼 지정"; exit 1; }
    echo "[Hubble] 활성화 (helm upgrade --version $ver — 설치된 차트 버전 고정, Cilium 은 업그레이드하지 않는다)..."
    # 기존 cilium 릴리스에 hubble 옵션만 덧붙임 (--reuse-values 로 기존 설정 보존)
    helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values --version "$ver" \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --set hubble.metrics.enableOpenMetrics=true \
        --set 'hubble.metrics.enabled={dns,drop,tcp,flow,port-distribution,icmp,httpV2}'
    kubectl -n kube-system rollout status daemonset/cilium --timeout=180s || true
    echo "[Hubble] cilium 이미지(변하지 않아야 한다): $(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')"
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
    hubble status 2>/dev/null || echo "(hubble CLI 미연결 — 'cilium hubble port-forward &' 후 재시도)"
    [ -f "$PIDFILE" ] && echo "백그라운드 캡처 PID $(cat "$PIDFILE")" || echo "백그라운드 캡처 없음"
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
    command -v hubble >/dev/null 2>&1 || { echo "[Hubble] hubble CLI 없음 (enable 참고)"; exit 1; }
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && { echo "[Hubble] 이미 캡처 중 (PID $(cat "$PIDFILE")) — stop 먼저"; exit 1; }
    echo "[Hubble] 백그라운드 캡처 시작 → $OUT"
    hubble observe -f --namespace "$NS" --protocol udp --port "$PORT" --output json > "$OUT" 2>"${OUT}.err" &
    echo $! > "$PIDFILE"
    echo "  PID=$(cat "$PIDFILE") (오류는 ${OUT}.err)"
}

stop_capture() {   # 멱등: 캡처가 없어도 0 으로 끝난다 (scripts/experiment.sh cleanup 이 호출)
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

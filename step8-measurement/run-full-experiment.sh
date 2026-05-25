#!/bin/bash
# Step 8-1: 전체 실험 자동 실행 스크립트
# baseline(Cilium only) vs 제안 솔루션(Cilium + eBPF + TC) 비교
#
# 실험 매트릭스 (논문 Figure 2-6 재현):
#   CPU 사용률: 10%, 30%, 50%, 70%, 90%, 99%
#   솔루션: baseline (Cilium), proposed (Cilium + eBPF + TC qdisc)
#   측정: bandwidth, latency, jitter
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPERIMENT_DIR="$(dirname "$SCRIPT_DIR")/step7-experiment"
EBPF_DIR="$(dirname "$SCRIPT_DIR")/step6-ebpf"
TC_DIR="$(dirname "$SCRIPT_DIR")/step5-tc-qdisc"
RESULTS_DIR="$SCRIPT_DIR/results"
NAMESPACE="tsn-experiment"
PKT_COUNT=10000
PKT_INTERVAL=1  # ms

CPU_LOADS=(10 30 50 70 90 99)

mkdir -p "$RESULTS_DIR"

PHYS_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)

run_single_experiment() {
    local MODE="$1"    # baseline 또는 proposed
    local CPU_LOAD="$2"
    local RESULT_FILE="$RESULTS_DIR/${MODE}_cpu${CPU_LOAD}.csv"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " 실험: $MODE, CPU ${CPU_LOAD}%"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 1. 기존 실험 정리
    kubectl -n "$NAMESPACE" delete job talker-run 2>/dev/null || true
    kubectl -n "$NAMESPACE" delete ds cpu-stress 2>/dev/null || true
    sleep 3

    # 2. 솔루션별 설정
    if [ "$MODE" = "proposed" ]; then
        echo "  TC qdisc + eBPF 활성화..."
        bash "$TC_DIR/setup-all-qdisc.sh" "$PHYS_IF" simple 2>/dev/null
        bash "$EBPF_DIR/attach-ebpf.sh" "$PHYS_IF" 2>/dev/null
    else
        echo "  Baseline (Cilium only)..."
        sudo tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
        sudo tc filter del dev "$PHYS_IF" egress 2>/dev/null || true
        sudo tc filter del dev "$PHYS_IF" ingress 2>/dev/null || true
    fi

    # 3. Listener 재시작 (결과 초기화)
    kubectl -n "$NAMESPACE" rollout restart deployment/listener 2>/dev/null || true
    kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=listener --timeout=60s
    sleep 2

    # 4. CPU 부하 생성
    if [ "$CPU_LOAD" -gt 10 ]; then
        echo "  CPU 부하 생성: ${CPU_LOAD}%..."
        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cpu-stress
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: cpu-stress
  template:
    metadata:
      labels:
        app: cpu-stress
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: stress
          image: alexeiled/stress-ng:latest
          args: ["--cpu", "2", "--cpu-load", "$CPU_LOAD", "--timeout", "600s"]
          resources:
            limits:
              cpu: "2000m"
              memory: "64Mi"
EOF
        sleep 10
    fi

    # 5. Talker 실행
    echo "  Talker 시작 ($PKT_COUNT 패킷, ${PKT_INTERVAL}ms 간격)..."
    kubectl -n "$NAMESPACE" delete job talker-run 2>/dev/null || true
    kubectl apply -f "$EXPERIMENT_DIR/k8s/talker-job.yaml"

    kubectl -n "$NAMESPACE" wait --for=condition=complete job/talker-run --timeout=300s 2>/dev/null || true
    sleep 5

    # 6. 결과 수집
    LISTENER_POD=$(kubectl -n "$NAMESPACE" get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')
    kubectl -n "$NAMESPACE" cp "$LISTENER_POD:/data/results.csv" "$RESULT_FILE" 2>/dev/null || \
        echo "  결과 수집 실패"

    if [ -f "$RESULT_FILE" ]; then
        LINES=$(wc -l < "$RESULT_FILE")
        echo "  결과: $RESULT_FILE ($LINES 행)"
    fi

    # 부하 제거
    kubectl -n "$NAMESPACE" delete ds cpu-stress 2>/dev/null || true
    sleep 5
}

echo "=========================================="
echo " 전체 실험 실행"
echo " CPU 부하 레벨: ${CPU_LOADS[*]}"
echo " 패킷 수: $PKT_COUNT, 간격: ${PKT_INTERVAL}ms"
echo "=========================================="

# Baseline 실험
echo -e "\n▶▶▶ BASELINE (Cilium only) ◀◀◀"
for load in "${CPU_LOADS[@]}"; do
    run_single_experiment "baseline" "$load"
done

# Proposed 솔루션 실험
echo -e "\n▶▶▶ PROPOSED (Cilium + eBPF + TC) ◀◀◀"
for load in "${CPU_LOADS[@]}"; do
    run_single_experiment "proposed" "$load"
done

echo -e "\n=========================================="
echo " 전체 실험 완료"
echo " 결과 디렉토리: $RESULTS_DIR"
ls -la "$RESULTS_DIR/"
echo ""
echo " 그래프 생성: python3 plot-results.py"
echo "=========================================="

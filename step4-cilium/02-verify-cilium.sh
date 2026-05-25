#!/bin/bash
# Step 4-2: Cilium 설치 검증 및 underlay 네트워크 확인
set -euo pipefail

echo "=========================================="
echo " Cilium 상태 검증"
echo "=========================================="

# 1. Cilium 파드 상태
echo "[1/6] Cilium 파드 상태..."
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium -o wide
echo ""

# 2. Cilium status
echo "[2/6] Cilium status..."
cilium status 2>/dev/null || kubectl exec -n kube-system ds/cilium -- cilium status

# 3. kube-proxy 대체 확인
echo -e "\n[3/6] KubeProxy 대체 확인..."
KUBE_PROXY_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l)
if [ "$KUBE_PROXY_PODS" -eq 0 ]; then
    echo "  kube-proxy 파드 없음 — Cilium이 대체 중 (정상)"
else
    echo "  kube-proxy 파드 ${KUBE_PROXY_PODS}개 실행 중"
    echo "  → kube-proxy 제거 권장: kubectl -n kube-system delete ds kube-proxy"
fi

# 4. Native routing 확인
echo -e "\n[4/6] Native routing 모드 확인..."
ROUTING_MODE=$(kubectl exec -n kube-system ds/cilium -- cilium status 2>/dev/null | grep -i "routing" || echo "N/A")
echo "  $ROUTING_MODE"

# 5. BPF 맵 확인
echo -e "\n[5/6] BPF 맵 확인..."
kubectl exec -n kube-system ds/cilium -- cilium bpf endpoint list 2>/dev/null | head -10 || echo "  (cilium agent 시작 대기 중)"

# 6. 노드 상태
echo -e "\n[6/6] 노드 상태..."
kubectl get nodes -o wide

echo -e "\n=========================================="
echo " 검증 완료"
echo ""
echo " 모든 노드가 Ready이고 Cilium 파드가 Running이면 정상"
echo ""
echo " 문제 시:"
echo "   kubectl describe pod -n kube-system -l k8s-app=cilium"
echo "   kubectl logs -n kube-system -l k8s-app=cilium -c cilium-agent --tail=100"
echo "=========================================="

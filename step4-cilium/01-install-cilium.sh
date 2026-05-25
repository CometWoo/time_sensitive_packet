#!/bin/bash
# Step 4-1: Cilium CNI 설치 및 설정
# 논문 아키텍처: Cilium 기반 underlay + overlay 혼합 네트워크
# kube-proxy를 Cilium eBPF로 대체하여 성능 향상
set -euo pipefail

echo "=========================================="
echo " Cilium CNI 설치"
echo "=========================================="

# 1. Cilium CLI 설치
echo "[1/5] Cilium CLI 설치..."
if ! command -v cilium &>/dev/null; then
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH="amd64"
    curl -L --fail --remote-name-all \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}"
    sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm -f "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    echo "  Cilium CLI $(cilium version --client) 설치 완료"
else
    echo "  Cilium CLI $(cilium version --client) 이미 설치됨"
fi

# 2. Helm 설치 (Cilium 고급 설정에 필요)
echo -e "\n[2/5] Helm 설치..."
if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "  Helm $(helm version --short) 설치 완료"
else
    echo "  Helm $(helm version --short) 이미 설치됨"
fi

# 3. 노드의 기본 인터페이스 및 IP 감지
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
NODE_IP=$(ip -4 addr show "$DEFAULT_IF" | grep inet | awk '{print $2}' | cut -d/ -f1)
echo -e "\n  기본 인터페이스: $DEFAULT_IF"
echo "  노드 IP: $NODE_IP"

# 4. Cilium 설치 (Helm으로 고급 설정)
echo -e "\n[3/5] Cilium Helm 저장소 추가..."
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update

echo -e "\n[4/5] Cilium 설치..."
# 논문 요구사항:
#   - underlay 네트워크 (native routing)
#   - kube-proxy 대체
#   - eBPF 기반 패킷 포워딩
helm install cilium cilium/cilium --version 1.15.6 \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${NODE_IP}" \
    --set k8sServicePort=6443 \
    --set routingMode=native \
    --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
    --set autoDirectNodeRoutes=true \
    --set ipam.mode=kubernetes \
    --set bpf.masquerade=true \
    --set bpf.hostLegacyRouting=false \
    --set devices="${DEFAULT_IF}" \
    --set enableIPv6=false \
    --set operator.replicas=1 \
    --set resources.agent.requests.cpu="100m" \
    --set resources.agent.requests.memory="128Mi" \
    --set resources.operator.requests.cpu="50m" \
    --set resources.operator.requests.memory="64Mi"

# 5. 설치 확인
echo -e "\n[5/5] Cilium 상태 확인 (최대 5분 대기)..."
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s || true

echo -e "\n=========================================="
echo " Cilium 설치 완료"
echo ""
echo " 검증 명령어:"
echo "   cilium status"
echo "   cilium connectivity test  (선택, ~5분 소요)"
echo "   kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium"
echo ""
echo " 노드 상태 확인:"
echo "   kubectl get nodes  (이제 Ready 상태여야 함)"
echo ""
echo " 트러블슈팅:"
echo "   cilium status --verbose"
echo "   kubectl logs -n kube-system -l k8s-app=cilium --tail=50"
echo "=========================================="

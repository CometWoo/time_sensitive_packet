#!/bin/bash
# Step 4-1: Cilium CNI 설치 (native routing, kube-proxy 대체, tcx 데이터패스)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다 (run 은 cilium-config 의 routing-mode 와 이미지를
#     읽어 meta.json 에 기록하고, native 가 아니면 멈춘다).
#   - 커밋된 결과(2026-05)의 Cilium 1.19.1 은 손으로 설치됐다 (docs/DATA_PROVENANCE.md); 당시 이 파일은
#     1.15.6 템플릿이었고 helm 키 이름도 틀렸다 (enableIPv6, resources.agent.*, resources.operator.*).
#   - 지금은 CILIUM_VERSION=1.19.1 + 올바른 키로 고쳤지만 이 형태로 실행된 적은 없다.
#   - kernel >= 6.6 이면 Cilium 은 tcx 로 붙는다. 우리 분류기는 그 **앞** 에 tcx 링크로 붙어야 하므로
#     (ADR-0005) 설치 뒤 'bpftool net show dev $IF' 에 tcx 가 보이는지 확인한다.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.19.1}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-}"          # 비우면 stable.txt
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"                 # step3 의 podSubnet 과 같아야 한다
DEFAULT_IF="${DEFAULT_IF:-$(ip -o route show default | awk '{print $5; exit}')}"
NODE_IP="${NODE_IP:-$(ip -4 -o addr show "$DEFAULT_IF" | awk '{print $4; exit}' | cut -d/ -f1)}"

echo "=========================================="
echo " Cilium $CILIUM_VERSION  (devices=$DEFAULT_IF, k8sServiceHost=$NODE_IP, native routing $POD_CIDR)"
echo "=========================================="

echo "[1/5] cilium CLI..."
if ! command -v cilium >/dev/null 2>&1; then
    [ -n "$CILIUM_CLI_VERSION" ] || CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    curl -L --fail --remote-name-all \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}
    sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm -f "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
fi
echo "  $(cilium version --client 2>/dev/null | head -1)"

echo -e "\n[2/5] helm..."
if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null

echo -e "\n[3/5] helm upgrade --install cilium $CILIUM_VERSION..."
# routingMode=native + autoDirectNodeRoutes: 두 VM 이 같은 L2 (host-only 네트워크) 에 있어야 한다.
# 터널(vxlan) 모드면 NIC egress 에서 Pod IP/UDP 6000 이 캡슐화돼 u32/분류기가 보지 못한다 (deploy-experiment.sh 가 거부).
# bpf.masquerade=true: 이때 Cilium 이 물리 NIC egress 에 cil_to_netdev 를 붙인다 — 분류기가 그 앞에 붙는다.
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$NODE_IP" \
    --set k8sServicePort=6443 \
    --set routingMode=native \
    --set ipv4NativeRoutingCIDR="$POD_CIDR" \
    --set autoDirectNodeRoutes=true \
    --set ipam.mode=kubernetes \
    --set bpf.masquerade=true \
    --set bpf.hostLegacyRouting=false \
    --set devices="$DEFAULT_IF" \
    --set ipv6.enabled=false \
    --set operator.replicas=1 \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set operator.resources.requests.cpu=50m \
    --set operator.resources.requests.memory=64Mi

echo -e "\n[4/5] rollout 대기..."
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
cilium status --wait --wait-duration 5m

echo -e "\n[5/5] 데이터패스 확인..."
ROUTING=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.routing-mode}')
[ "$ROUTING" = native ] || { echo "  [FAIL] routing-mode=$ROUTING (native 필요)"; exit 1; }
echo "  routing-mode=native"
KMM=$(uname -r | cut -d. -f1-2)
if [ "$(printf '%s\n' 6.6 "$KMM" | sort -V | head -1)" = 6.6 ]; then
    if command -v bpftool >/dev/null 2>&1; then
        if sudo bpftool net show dev "$DEFAULT_IF" 2>/dev/null | grep -q tcx; then
            echo "  [PASS] $DEFAULT_IF 에 tcx 프로그램 (Cilium) — 분류기는 tcx BEFORE 로 그 앞에 붙는다"
        else
            echo "  [FAIL] kernel $KMM >= 6.6 인데 $DEFAULT_IF 에 tcx 프로그램이 없음:"
            sudo bpftool net show dev "$DEFAULT_IF" 2>&1 | sed 's/^/    /'
            echo "  bpf.masquerade / devices 설정 또는 Cilium 버전(>= 1.16 이 tcx) 확인"
            exit 1
        fi
    else
        echo "  [WARN] bpftool 없음 — tcx 확인 생략 (step2-os-setup/02-install-packages.sh)"
    fi
else
    echo "  kernel $KMM < 6.6: legacy tc. Cilium(TC_ACT_OK) 뒤의 clsact 분류기는 실행되지 않는다 (ADR-0005)"
fi

cat <<EOF

==========================================
 Cilium $CILIUM_VERSION 설치 완료
   검증: bash 02-verify-cilium.sh   /   cilium connectivity test (선택, ~5분)
   다음: bash deploy-experiment.sh build-ebpf && bash deploy-experiment.sh deploy-k8s
==========================================
EOF

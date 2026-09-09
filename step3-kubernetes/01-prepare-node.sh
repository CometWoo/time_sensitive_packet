#!/bin/bash
# Step 3-1: Kubernetes 노드 준비 (control-plane + worker 공통) — kubeadm/kubelet/kubectl 설치
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다.
#   - 커밋된 결과(2026-05)의 클러스터는 kubeadm v1.30.14 / containerd 2.2.1 로 수동 구성됐다
#     (docs/DATA_PROVENANCE.md). 당시 이 파일은 KUBE_VERSION=1.28 템플릿이었고 실행되지 않았다.
#   - 지금은 측정된 스택(KUBE_VERSION=1.30)으로 맞췄지만 이 형태로 실행된 적은 없다.
#   - 이전 버전의 /var/lib/kubelet/config-override.yaml 블록은 kubelet 이 읽지 않는 파일이라 삭제했다;
#     kubelet 설정은 02-init-control-plane.sh 의 kubeadm config(KubeletConfiguration) 로 들어간다.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

KUBE_VERSION="${KUBE_VERSION:-1.30}"     # pkgs.k8s.io minor 저장소. 측정 스택: v1.30.14

echo "=========================================="
echo " Kubernetes 노드 준비 (kubeadm $KUBE_VERSION)"
echo "=========================================="

echo "[1/5] swap 비활성화..."
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
free -h | grep -i swap

echo -e "\n[2/5] sysctl..."
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sudo modprobe br_netfilter overlay
sudo sysctl --system >/dev/null

echo -e "\n[3/5] containerd 확인..."
if ! systemctl is-active --quiet containerd; then
    echo "  containerd 미실행 — step2-os-setup/02-install-packages.sh 먼저"; exit 1
fi
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null \
    || { echo "  SystemdCgroup=true 가 아님 — 02-install-packages.sh 의 containerd 블록 참고"; exit 1; }
echo "  $(containerd --version) / SystemdCgroup=true"

echo -e "\n[4/5] kubeadm / kubelet / kubectl / cri-tools ($KUBE_VERSION)..."
if ! command -v kubeadm >/dev/null 2>&1; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq kubelet kubeadm kubectl cri-tools
    sudo apt-mark hold kubelet kubeadm kubectl
fi
echo "  kubeadm $(kubeadm version -o short), crictl $(crictl --version 2>/dev/null | awk '{print $3}')"
INSTALLED=$(kubeadm version -o short | sed 's/^v//' | cut -d. -f1-2)
[ "$INSTALLED" = "$KUBE_VERSION" ] || echo "  [WARN] 설치된 kubeadm $INSTALLED != KUBE_VERSION $KUBE_VERSION"

echo -e "\n[5/5] kubelet enable + crictl 런타임 설정..."
sudo systemctl enable kubelet >/dev/null 2>&1
cat <<EOF | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

echo -e "\n=========================================="
echo " 노드 준비 완료"
echo "   control-plane: bash 02-init-control-plane.sh"
echo "   worker:        sudo bash 03-join-worker.sh \"<kubeadm join ...>\""
echo "=========================================="

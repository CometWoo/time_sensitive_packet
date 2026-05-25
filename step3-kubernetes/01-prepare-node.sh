#!/bin/bash
# Step 3-1: Kubernetes 노드 사전 준비 (control-plane + worker 공통)
# 4GB RAM VM에 최적화된 경량 설정
set -euo pipefail

echo "=========================================="
echo " Kubernetes 노드 준비"
echo "=========================================="

# 1. Swap 비활성화 (Kubernetes 필수)
echo "[1/6] Swap 비활성화..."
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
echo "  Swap 비활성화 완료"
free -h | grep Swap

# 2. 커널 파라미터 설정
echo -e "\n[2/6] 커널 파라미터 설정..."
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sudo sysctl --system > /dev/null 2>&1
echo "  sysctl 설정 적용 완료"

# 3. 커널 모듈
echo -e "\n[3/6] 커널 모듈 로드..."
sudo modprobe br_netfilter
sudo modprobe overlay

# 4. containerd 설정 확인
echo -e "\n[4/6] containerd 상태 확인..."
if systemctl is-active --quiet containerd; then
    echo "  containerd 실행 중"
    # SystemdCgroup 확인
    if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
        echo "  SystemdCgroup = true 확인됨"
    else
        echo "  SystemdCgroup 설정 수정 중..."
        sudo mkdir -p /etc/containerd
        containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        sudo systemctl restart containerd
    fi
else
    echo "  containerd 미실행 — step2/02-install-packages.sh 먼저 실행"
    exit 1
fi

# 5. kubeadm, kubelet, kubectl 설치
echo -e "\n[5/6] Kubernetes 도구 설치..."
KUBE_VERSION="1.28"  # Cilium 호환성 검증된 안정 버전

if ! command -v kubeadm &>/dev/null; then
    # Kubernetes apt 저장소 추가
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" | \
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    echo "  kubeadm $(kubeadm version -o short) 설치 완료"
else
    echo "  kubeadm $(kubeadm version -o short) 이미 설치됨"
fi

# 6. kubelet 설정 (4GB RAM 최적화)
echo -e "\n[6/6] kubelet 경량 설정..."
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /var/lib/kubelet/config-override.yaml > /dev/null
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
systemReserved:
  cpu: "500m"
  memory: "512Mi"
kubeReserved:
  cpu: "500m"
  memory: "512Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
EOF

sudo systemctl enable kubelet

echo -e "\n=========================================="
echo " 노드 준비 완료"
echo ""
echo " 다음 단계:"
echo "   control-plane: bash 02-init-control-plane.sh"
echo "   worker:        bash 03-join-worker.sh <join-command>"
echo "=========================================="

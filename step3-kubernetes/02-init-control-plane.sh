#!/bin/bash
# Step 3-2: Kubernetes control-plane 초기화
# Cilium CNI를 사용하므로 --pod-network-cidr 설정하되 기본 CNI는 설치하지 않음
set -euo pipefail

echo "=========================================="
echo " Kubernetes Control Plane 초기화"
echo "=========================================="

# 노드 IP 자동 감지
NODE_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
echo "노드 IP: $NODE_IP"

# Pod 네트워크 CIDR (Cilium 기본값과 동일)
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

# kubeadm 설정 파일 생성 (4GB RAM 최적화)
cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
apiServer:
  extraArgs:
    # 4GB VM 메모리 절약
    default-not-ready-toleration-seconds: "30"
    default-unreachable-toleration-seconds: "30"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
# 4GB VM 최적화: 리소스 예약 축소
systemReserved:
  cpu: "500m"
  memory: "256Mi"
kubeReserved:
  cpu: "500m"
  memory: "256Mi"
evictionHard:
  memory.available: "100Mi"
EOF

# 초기화
echo -e "\n[1/3] kubeadm init 실행..."
sudo kubeadm init --config=/tmp/kubeadm-config.yaml --skip-phases=addon/kube-proxy 2>&1 | tee /tmp/kubeadm-init.log
# --skip-phases=addon/kube-proxy: Cilium이 kube-proxy를 대체

# kubeconfig 설정
echo -e "\n[2/3] kubeconfig 설정..."
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# join 커맨드 저장
echo -e "\n[3/3] Worker join 명령어 저장..."
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
echo "$JOIN_CMD" > "$HOME/worker-join-command.txt"

echo -e "\n=========================================="
echo " Control Plane 초기화 완료!"
echo ""
echo " 클러스터 상태 확인:"
echo "   kubectl get nodes"
echo "   kubectl get pods -A"
echo ""
echo " Worker 노드 join 명령어 (worker VM에서 실행):"
echo "   sudo $JOIN_CMD"
echo ""
echo " 명령어 파일: $HOME/worker-join-command.txt"
echo ""
echo " ⚠️  Cilium 설치 전까지 노드 상태는 NotReady"
echo " 다음 단계: step4-cilium/01-install-cilium.sh"
echo "=========================================="

#!/bin/bash
# Step 3-2: control-plane 초기화 (kubeadm init, kube-proxy 없이 — Cilium 이 대체)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다.
#   - 커밋된 결과(2026-05)의 클러스터는 kubeadm v1.30.14 로 수동 초기화됐다 (docs/DATA_PROVENANCE.md);
#     당시 이 파일은 kubernetesVersion: stable 템플릿이었고 실행되지 않았다.
#   - 지금은 KUBERNETES_VERSION=v1.30.14 로 고정했지만 이 형태로 실행된 적은 없다.
#   - control-plane 노드가 실험의 sender(talker) 노드다: deploy-experiment.sh 는 여기서 sudo 로 실행하고
#     이 노드의 물리 NIC egress 에 HTB/prio + ts_classifier 를 붙인다.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.30.14}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"        # step4 의 ipv4NativeRoutingCIDR 과 같아야 한다
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
# advertise 주소: 인터넷 방향 경로의 src 주소를 키워드('src')로 파싱 — 필드 위치($9)는 'proto dhcp src' 가 있을
# 때만 맞고 'proto static metric 100' 이면 metric 값이 잡힌다. VirtualBox NAT + host-only 처럼 클러스터 NIC 가
# default route 가 아니면 이 값은 NAT 주소다 → NODE_IP=<host-only IPv4> 로 명시할 것.
detect_node_ip() { ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }
NODE_IP="${NODE_IP:-$(detect_node_ip)}"
[[ "$NODE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "NODE_IP 를 판별하지 못함 ('$NODE_IP') — NODE_IP=<클러스터 NIC IPv4> 로 지정"; exit 1; }

echo "=========================================="
echo " kubeadm init $KUBERNETES_VERSION  (advertise $NODE_IP, pod $POD_CIDR)"
echo "=========================================="

cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  extraArgs:
    default-not-ready-toleration-seconds: "30"
    default-unreachable-toleration-seconds: "30"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
# 작은 VM: 예약을 줄여 allocatable 을 확보한다 (talker 1 CPU Guaranteed 가 control-plane 에 떠야 한다)
systemReserved:
  cpu: "200m"
  memory: "256Mi"
kubeReserved:
  cpu: "200m"
  memory: "256Mi"
evictionHard:
  memory.available: "100Mi"
EOF

echo -e "\n[1/3] kubeadm init (kube-proxy 건너뜀 — Cilium kubeProxyReplacement)..."
sudo kubeadm init --config=/tmp/kubeadm-config.yaml --skip-phases=addon/kube-proxy 2>&1 | tee /tmp/kubeadm-init.log
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "kubeadm init 실패 — /tmp/kubeadm-init.log"; exit 1; }

echo -e "\n[2/3] kubeconfig..."
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo -e "\n[3/3] worker join 명령어..."
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "$JOIN_CMD" > "$HOME/worker-join-command.txt"

cat <<EOF

==========================================
 control-plane 초기화 완료 ($KUBERNETES_VERSION)
   kubectl get nodes        (Cilium 설치 전까지 NotReady 가 정상)
 worker 에서:
   sudo $JOIN_CMD
 다음: step4-cilium/01-install-cilium.sh
 deploy-experiment.sh 를 sudo 로 돌릴 때 kubeconfig: KUBECONFIG=/etc/kubernetes/admin.conf (experiment.env)
==========================================
EOF

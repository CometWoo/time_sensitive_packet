#!/bin/bash
# Step 3-3: Worker 노드 Kubernetes 클러스터 합류
# 사용법: sudo bash 03-join-worker.sh
# 또는:  sudo bash 03-join-worker.sh "kubeadm join 192.168.x.x:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
set -euo pipefail

echo "=========================================="
echo " Worker 노드 Join"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then
    echo "root 권한 필요: sudo bash $0"
    exit 1
fi

if [ $# -ge 1 ]; then
    JOIN_CMD="$*"
    echo "전달된 join 명령어 사용"
else
    echo "join 명령어를 입력하세요 (control-plane의 ~/worker-join-command.txt 참조):"
    read -r JOIN_CMD
fi

if [ -z "$JOIN_CMD" ]; then
    echo "join 명령어가 비어 있음. 종료."
    exit 1
fi

echo -e "\n실행: $JOIN_CMD"
eval "$JOIN_CMD"

echo -e "\n=========================================="
echo " Worker 노드 Join 완료!"
echo ""
echo " Control-plane에서 확인:"
echo "   kubectl get nodes"
echo ""
echo " ⚠️  Cilium 설치 전까지 NotReady 상태 정상"
echo "=========================================="

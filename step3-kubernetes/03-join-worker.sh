#!/bin/bash
# Step 3-3: worker 노드 join
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다.
#   - 커밋된 결과(2026-05)의 worker 는 kubeadm join 을 손으로 실행해 붙였다; 이 래퍼는 실행되지 않았다.
#   - worker 노드가 실험의 receiver 노드다: listener / udp-sink Pod 가 여기에 뜬다 (nodeAffinity:
#     node-role.kubernetes.io/control-plane DoesNotExist). CPU 부하(stress DaemonSet, STRESS_NODES=receiver)
#     도 기본적으로 이 노드에만 건다.
#   - 사용법: sudo bash 03-join-worker.sh "kubeadm join 192.168.x.x:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [ "$EUID" -ne 0 ]; then echo "root 필요: sudo bash $0 \"<kubeadm join ...>\""; exit 1; fi

if [ $# -ge 1 ]; then
    JOIN_CMD="$*"
else
    echo "join 명령어 (control-plane 의 ~/worker-join-command.txt):"
    read -r JOIN_CMD
fi
case "$JOIN_CMD" in
    "kubeadm join "*) ;;
    *) echo "'kubeadm join ...' 형태여야 함: '$JOIN_CMD'"; exit 1 ;;
esac

echo "실행: $JOIN_CMD"
eval "$JOIN_CMD"

cat <<'EOF'

==========================================
 join 완료. control-plane 에서: kubectl get nodes  (Cilium 전까지 NotReady 정상)
 시간 동기화: sudo bash step2-os-setup/04-configure-ptp.sh worker <control-plane-ip>
==========================================
EOF

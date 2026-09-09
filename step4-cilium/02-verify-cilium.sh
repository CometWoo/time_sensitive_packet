#!/bin/bash
# Step 4-2: Cilium 상태 검증 (native routing / kube-proxy 대체 / tcx)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다 (같은 확인을 run/status 안에서 직접 한다).
#   - 커밋된 결과(2026-05) 당시에는 실행되지 않았다; routing 모드를 'cilium status | grep routing' 으로
#     찾던 방식은 출력 형식에 의존해 틀릴 수 있어 cilium-config ConfigMap 을 읽도록 바꿨다.
#   - 이 형태로 실행된 적은 없다.
#   - 실패 시 non-zero 로 끝난다 (routing-mode != native, kernel >= 6.6 인데 tcx 없음).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DEFAULT_IF="${DEFAULT_IF:-$(ip -o route show default | awk '{print $5; exit}')}"
FAILS=0

echo "=========================================="
echo " Cilium 검증 (dev $DEFAULT_IF)"
echo "=========================================="

echo "[1/6] Pod..."
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium -o wide

echo -e "\n[2/6] cilium status..."
cilium status 2>/dev/null || kubectl -n kube-system exec ds/cilium -- cilium status --brief

echo -e "\n[3/6] kube-proxy 대체..."
KP=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l)
if [ "$KP" -eq 0 ]; then echo "  kube-proxy 없음 (Cilium kubeProxyReplacement) — 정상"; else echo "  [WARN] kube-proxy Pod ${KP}개 — kubectl -n kube-system delete ds kube-proxy"; fi

echo -e "\n[4/6] routing-mode (cilium-config)..."
ROUTING=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.routing-mode}' 2>/dev/null || echo "?")
if [ "$ROUTING" = native ]; then echo "  native"; else echo "  [FAIL] routing-mode=$ROUTING — NIC egress 에서 Pod IP 가 캡슐화돼 u32/분류기가 보지 못한다"; FAILS=$((FAILS + 1)); fi
echo "  image: $(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"

echo -e "\n[5/6] $DEFAULT_IF 의 BPF 프로그램 (tcx 여야 분류기를 BEFORE 로 앞에 붙일 수 있다)..."
KMM=$(uname -r | cut -d. -f1-2)
if command -v bpftool >/dev/null 2>&1; then
    OUT=$(sudo -n bpftool net show dev "$DEFAULT_IF" 2>&1 || true)
    sed 's/^/  /' <<<"$OUT"
    if [ "$(printf '%s\n' 6.6 "$KMM" | sort -V | head -1)" = 6.6 ] && ! grep -q tcx <<<"$OUT"; then
        echo "  [FAIL] kernel $KMM >= 6.6 인데 tcx 프로그램 없음"; FAILS=$((FAILS + 1))
    fi
else
    echo "  bpftool 없음 — 생략"
fi

echo -e "\n[6/6] 노드..."
kubectl get nodes -o wide
NOTREADY=$(kubectl get nodes --no-headers | grep -vc ' Ready ' || true)
[ "${NOTREADY:-0}" -eq 0 ] || { echo "  [FAIL] Ready 아닌 노드 ${NOTREADY}개"; FAILS=$((FAILS + 1)); }

echo -e "\n=========================================="
if [ "$FAILS" -eq 0 ]; then echo " 검증 통과"; else echo " [FAIL] ${FAILS}건"; fi
echo "   문제 시: kubectl -n kube-system logs -l k8s-app=cilium -c cilium-agent --tail=100"
echo "=========================================="
[ "$FAILS" -eq 0 ]

#!/bin/bash
# =============================================================================
# verify-experiment.sh
# 사용자가 실험 결과를 한 번에 확인할 수 있는 검증 스크립트
#
# 사용법:
#   bash verify-experiment.sh           # 전체 검증
#   bash verify-experiment.sh quick     # 간단한 통계만
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/step8-measurement/results"
FIG_DIR="$SCRIPT_DIR/step8-measurement/figures"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }

MODE="${1:-full}"

echo "================================================================"
echo "  Time-Sensitive Cloud Network — 실험 결과 검증"
echo "================================================================"
echo ""

# ── 1. K8s/Cilium 상태 ──
echo "[1] K8s 클러스터 상태"
if kubectl get nodes 2>/dev/null | grep -q Ready; then
    ok "Kubernetes 노드 정상"
    kubectl get nodes -o wide | head -4
else
    err "kubectl 사용 불가 또는 노드 다운"
fi
echo ""

# ── 2. eBPF 빌드/부착 상태 (단일 프로그램 vnic_filter) ──
echo "[2] vnic_filter 빌드/부착 상태"
if [ -f "$SCRIPT_DIR/step6-ebpf/build/vnic_filter.bpf.o" ]; then
    ok "vnic_filter.bpf.o 빌드됨"
else
    warn "vnic_filter.bpf.o 없음 — make -C step6-ebpf"
fi
# vnic_filter 는 talker Pod eth0 egress(netns 내부)에 붙으므로 호스트에서는 안 보인다.
TP=$(kubectl -n tsn-experiment get pod -l job-name=talker-run -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$TP" ]; then
    echo "  talker Pod=$TP — 송신 중이면 카운터 확인:"
    echo "    sudo bash step6-ebpf/attach-vnic.sh show tsn-experiment $TP"
else
    echo "  (talker Pod 없음 — 실험 실행 중이 아님. vnic_filter 는 Pod eth0 에 붙음)"
fi
echo ""

# ── 3. TC Qdisc 상태 ──
echo "[3] TC Qdisc (priority queue) 상태"
QDISC=$(sudo tc qdisc show dev enp0s3 | head -1)
echo "  현재 qdisc: $QDISC"
if echo "$QDISC" | grep -q "prio"; then
    ok "prio qdisc 활성 (proposed 모드)"
elif echo "$QDISC" | grep -q "fq_codel\|pfifo"; then
    ok "기본 qdisc (baseline 모드)"
else
    warn "예상치 못한 qdisc"
fi
echo ""

# ── 4. 실험 결과 CSV ──
echo "[4] 실험 결과 파일"
if [ ! -d "$RESULTS_DIR" ]; then
    err "결과 디렉토리 없음: $RESULTS_DIR"
    exit 1
fi
CSV_COUNT=$(ls "$RESULTS_DIR"/*.csv 2>/dev/null | wc -l)
ok "CSV 파일 ${CSV_COUNT}개"
for f in "$RESULTS_DIR"/*.csv; do
    [ -f "$f" ] || continue
    LINES=$(wc -l < "$f")
    SIZE=$(du -h "$f" | cut -f1)
    echo "  $(basename "$f") — ${LINES}행 / ${SIZE}"
done
echo ""

# ── 5. 통계 비교 ──
echo "[5] Baseline vs Proposed 통계 비교"
python3 "$SCRIPT_DIR/compare_results.py" "$RESULTS_DIR" 2>&1 || warn "compare_results.py 실행 실패"
echo ""

# ── 6. 그래프 ──
if [ "$MODE" != "quick" ]; then
    echo "[6] 그래프 생성"
    if [ -d "$FIG_DIR" ] && [ -n "$(ls -A "$FIG_DIR" 2>/dev/null)" ]; then
        ok "생성된 그래프:"
        ls -la "$FIG_DIR"
    else
        warn "그래프 없음. 생성:"
        echo "  cd $SCRIPT_DIR/step8-measurement && python3 plot-results.py"
    fi
    echo ""
fi

# ── 7. eBPF 카운터 (vnic_filter pkt_count) ──
echo "[7] eBPF 카운터 (vnic_filter pkt_count, talker Pod netns 내부)"
echo "  pkt_count 는 호스트가 아니라 talker Pod eth0 의 netns 안에 있다."
echo "  talker 송신 중에만 읽을 수 있다:"
echo "    TP=\$(kubectl -n tsn-experiment get pod -l job-name=talker-run -o jsonpath='{.items[0].metadata.name}')"
echo "    sudo bash $SCRIPT_DIR/step6-ebpf/attach-vnic.sh show tsn-experiment \$TP"
echo "  (실험 검증의 본체는 latency/jitter CSV — [5] 통계 비교. 카운터는 보조 지표)"

echo ""
echo "================================================================"
echo "  검증 완료"
echo "================================================================"

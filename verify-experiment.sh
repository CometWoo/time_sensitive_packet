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

# ── 2. eBPF Attach 상태 ──
echo "[2] eBPF 프로그램 부착 상태 (enp0s3)"
TC_EGRESS=$(sudo tc filter show dev enp0s3 egress 2>/dev/null | grep -c egress.bpf.o || true)
if [ "$TC_EGRESS" -gt 0 ]; then ok "egress.bpf.o 부착됨"; else warn "egress.bpf.o 미부착"; fi
XDP=$(ip link show enp0s3 | grep -c xdpgeneric || true)
if [ "$XDP" -gt 0 ]; then ok "XDP 프로그램 부착됨"; else warn "XDP 미부착"; fi
VETH_COUNT=$(sudo bpftool net show 2>/dev/null | grep -c "veth_filter.bpf.o" || true)
ok "veth_filter 부착된 인터페이스: ${VETH_COUNT}개"
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

# ── 7. eBPF 통계 카운터 ──
echo "[7] eBPF 패킷 통계 (pkt_stats)"
if command -v bpftool >/dev/null; then
    sudo bpftool map dump name pkt_stats 2>/dev/null > /tmp/pkt_stats.json
    python3 - <<EOF
import json
try:
    with open("/tmp/pkt_stats.json") as f:
        data = json.load(f)
    any_nonzero = False
    for m in data:
        vals = {e["key"]: e["value"] for e in m["elements"]}
        if any(vals.values()):
            any_nonzero = True
            print(f"  map_id={m['id']}: TOTAL={vals.get(0,0)} TSN={vals.get(1,0)} BEST_EFF={vals.get(2,0)} DROP={vals.get(3,0)}")
    if not any_nonzero:
        print("  (모든 카운터 0 — Cilium native routing 모드에서는 정상)")
        print("  실험 검증은 latency/jitter CSV로 합니다 (Phase 4 결과)")
except FileNotFoundError:
    print("  (pkt_stats 맵 없음 — eBPF 미부착 상태)")
EOF
else
    warn "bpftool 없음"
fi

echo ""
echo "================================================================"
echo "  검증 완료"
echo "================================================================"

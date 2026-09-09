#!/bin/bash
# Step 5-2: ETF (Earliest TxTime First, sch_etf) — mqprio tc0 큐의 child (논문 §IV: delta 150 us, deadline mode)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다. 실험 경로에 ETF 는 없다 (ADR-0002).
#   - 커밋된 결과(2026-05)에는 쓰이지 않았고, 이 형태로 실행된 적도 없다.
#   - ★ sch_etf 의 is_packet_valid() 는 SOCK_TXTIME 이 없는 skb 를 qdisc_drop() 한다. talker.py 는
#     SO_TXTIME/SCM_TXTIME 을 쓰지 않으므로 이 qdisc 를 tc0 에 붙이면 **TS 패킷이 전량 드롭**된다.
#     skip_sock_check 옵션은 소켓 플래그 검사만 건너뛰고, txtime 이 과거인 패킷은 여전히 버린다.
#   - clockid 는 CLOCK_TAI 만 받는다 (sch_etf: 다른 clockid 는 EINVAL). CLOCK_REALTIME 폴백은 삭제했다.
#   - 이전 버전의 'offload off / deadline_mode on' 은 tc 문법 오류였다 — 플래그는 인자 없이 쓴다.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# shellcheck source=step5-tc-qdisc/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IFACE=$(step5_iface "${1:-}")
DELTA_NS="${DELTA_NS:-150000}"      # 150 us (논문)

echo "=========================================="
echo " ETF  dev=$IFACE  parent=100:1 (mqprio tc0 = TXQ0)  delta=${DELTA_NS}ns  clockid=CLOCK_TAI  deadline_mode"
echo "=========================================="

echo "[1/3] 전제 확인..."
tc qdisc show dev "$IFACE" | grep -q '^qdisc mqprio 100: root' \
    || { echo "mqprio 100: 이 없다 — 01-setup-mqprio.sh 먼저 (TX 큐 >= 3 필요)"; exit 1; }
python3 -c "import time; time.clock_gettime(time.CLOCK_TAI)" 2>/dev/null \
    || { echo "CLOCK_TAI 를 읽을 수 없다 (sch_etf 는 CLOCK_TAI 만 받는다)"; exit 1; }
echo "  mqprio 있음, CLOCK_TAI 사용 가능"

cat <<'EOF'

  ⚠ 경고: 이 ETF 는 SO_TXTIME 으로 송신 시각을 지정한 패킷만 통과시킨다. 이 저장소의 talker.py 는
    SO_TXTIME 을 쓰지 않으므로 실험 트래픽(UDP 6000, priority → tc0) 은 여기서 전부 드롭된다.
    학습/참고용으로만 붙이고, deploy-experiment.sh 를 돌리기 전에 반드시 제거하라:
      sudo tc qdisc del dev IFACE parent 100:1
EOF

echo -e "\n[2/3] ETF 추가 (100:1 = mqprio 의 첫 per-queue 클래스 = tc0 = TXQ0)..."
# 하드웨어 LaunchTime 오프로드('offload' 플래그) 는 i210/i225 등에서만 — VM/virtio 에는 없다 → 소프트웨어 ETF.
sudo tc qdisc replace dev "$IFACE" parent 100:1 handle 10: etf clockid CLOCK_TAI delta "$DELTA_NS" deadline_mode
tc qdisc show dev "$IFACE" | grep -q '^qdisc etf 10: parent 100:1' || { show_qdisc "$IFACE"; echo "ETF 확인 실패"; exit 1; }

echo -e "\n[3/3] 확인..."
show_qdisc "$IFACE"

cat <<EOF

==========================================
 ETF 완료: root mqprio 100: → 100:1(tc0) etf 10: / 100:2(tc1) / 100:3..(tc2)
 동작: 패킷의 SCM_TXTIME (CLOCK_TAI) 순으로 정렬해 그 시각에 송신, delta 만큼 앞서 깨어남.
       deadline_mode: txtime 을 '늦어도 이때까지' 로 해석. txtime 이 과거이거나 SO_TXTIME 이 없으면 드롭.
 제거: sudo tc qdisc del dev $IFACE parent 100:1
 다음: 03-setup-taprio.sh (802.1Qbv 게이트 스케줄; mqprio 를 통째로 대체한다)
==========================================
EOF

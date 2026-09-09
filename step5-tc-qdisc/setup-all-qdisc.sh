#!/bin/bash
# Step 5: 논문 §IV qdisc 스택 일괄 구성 — 참고용 (mqprio + ETF, 또는 taprio + ETF)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다. 실험의 qdisc 는 HTB 병목 + prio/… leaf 이며
#     deploy-experiment.sh 가 직접 만든다 (ADR-0002). 커밋된 결과에도 쓰이지 않았다.
#   - VirtualBox VM(TX 큐 1개) 에서는 mqprio/taprio 가 EINVAL 로 붙지 않는다 — "attach 자체는 된다" 던
#     이전 주석은 틀렸다. 이 형태로 실행된 적은 없다.
#   - 붙는 환경에서도 실험 결과가 깨지는 이유: (1) ETF 가 SO_TXTIME 없는 talker 패킷을 전량 드롭,
#     (2) 소프트웨어 taprio 게이트 정밀도가 VM hrtimer(수십 us) 에 종속, (3) talker 가 게이트와 비동기.
#   - 이전 버전의 오류(queues 1@0 1@0 1@0, flags 0x1, REALTIME base-time, 'offload off') 는 01/02/03 과 같이 고쳤다.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# shellcheck source=step5-tc-qdisc/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IFACE=$(step5_iface "${1:-}")
MODE="${2:-full}"        # full = taprio + ETF | simple = mqprio + ETF
TXQ=$(tx_queue_count "$IFACE")
MAP=$(prio_map)
DELTA_NS="${DELTA_NS:-150000}"

echo "=========================================="
echo " qdisc 스택 ($MODE)  dev=$IFACE  TX queues=$TXQ  TS_PRIORITY=$TS_PRIORITY"
echo "=========================================="
[ "$TXQ" -ge 3 ] || { echo "TX 큐 $TXQ 개 < 3: mqprio/taprio num_tc 3 불가. 실험은 HTB + prio (deploy-experiment.sh). 중단."; exit 1; }

reset_root_qdisc "$IFACE"

case "$MODE" in
    full)
        echo -e "\n--- taprio (802.1Qbv 게이트) + ETF(tc0) ---"
        BASE_TIME=$(tai_now_plus_ns 2)
        # shellcheck disable=SC2086
        sudo tc qdisc replace dev "$IFACE" root handle 100: taprio \
            num_tc 3 map $MAP queues 1@0 1@1 1@2 \
            base-time "$BASE_TIME" \
            sched-entry S 04 125000 sched-entry S 02 125000 sched-entry S 01 750000 \
            clockid CLOCK_TAI
        tc qdisc show dev "$IFACE" | grep -q '^qdisc taprio 100: root' || { show_qdisc "$IFACE"; echo "taprio 실패"; exit 1; }
        ;;
    simple)
        echo -e "\n--- mqprio + ETF(tc0) ---"
        QUEUES="1@0 1@1 $((TXQ - 2))@2"
        # shellcheck disable=SC2086
        sudo tc qdisc add dev "$IFACE" root handle 100: mqprio num_tc 3 map $MAP queues $QUEUES hw 1 mode dcb 2>/dev/null \
            || sudo tc qdisc add dev "$IFACE" root handle 100: mqprio num_tc 3 map $MAP queues $QUEUES hw 0
        tc qdisc show dev "$IFACE" | grep -q '^qdisc mqprio 100: root' || { show_qdisc "$IFACE"; echo "mqprio 실패"; exit 1; }
        ;;
    *) echo "MODE 는 full|simple: '$MODE'"; exit 2 ;;
esac

# ETF on tc0 (100:1 = TXQ0). ⚠ SO_TXTIME 없는 패킷(talker.py) 은 전량 드롭 — 02-setup-etf.sh 헤더 참고.
sudo tc qdisc replace dev "$IFACE" parent 100:1 handle 10: etf clockid CLOCK_TAI delta "$DELTA_NS" deadline_mode
tc qdisc show dev "$IFACE" | grep -q '^qdisc etf 10: parent 100:1' || { show_qdisc "$IFACE"; echo "ETF 실패"; exit 1; }

echo -e "\n--- 최종 ---"
show_qdisc "$IFACE"
cat <<EOF

==========================================
 완료 ($MODE). ⚠ 이 상태로 deploy-experiment.sh 를 돌리지 마라 — ETF 가 TS 패킷을 버린다.
 제거: sudo tc qdisc del dev $IFACE root
==========================================
EOF

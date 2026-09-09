#!/bin/bash
# Step 5-3: taprio — IEEE 802.1Qbv Time-Aware Shaper (게이트 제어 리스트) 소프트웨어 구현
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다 (ADR-0002). 커밋된 결과에도 쓰이지 않았다.
#   - 커밋된 결과(2026-05)의 VM 은 TX 큐 1개라 taprio 가 붙지 않는다 (num_tc 3 > TXQ → EINVAL).
#     이 형태로 실행된 적은 없다.
#   - 이름 충돌 주의 (이전 파일명 03-setup-ets.sh 를 바꾼 이유):
#       논문의 "ETS" = IEEE 802.1Qbv Enhancements for Scheduled Traffic = 게이트 스케줄(TAS) = 리눅스 **taprio**
#       리눅스 sch_ets   = IEEE 802.1Qaz Enhanced Transmission Selection = 대역폭 배분 (strict/DRR 밴드)
#     이전 스크립트의 sch_ets 분기는 다른 표준을 구현한 것이라 삭제했다.
#   - 이전 버전의 오류 3가지를 고쳤다: (1) queues 1@0 1@0 1@0 (겹침 → EINVAL) → 1@0 1@1 1@2,
#     (2) flags 0x1 은 "소프트웨어 모드" 가 아니라 txtime-assist 모드(ETF child 필요) → 플래그 없음 = 소프트웨어,
#     (3) base-time 을 date +%s(REALTIME) 로 계산 → clockid CLOCK_TAI 와 37 s 어긋남 → CLOCK_TAI 로 계산.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# shellcheck source=step5-tc-qdisc/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IFACE=$(step5_iface "${1:-}")
TXQ=$(tx_queue_count "$IFACE")
MAP=$(prio_map)

echo "=========================================="
echo " taprio (802.1Qbv)  dev=$IFACE  TX queues=$TXQ  TS_PRIORITY=$TS_PRIORITY"
echo "=========================================="

if [ "$TXQ" -lt 3 ]; then
    echo "TX 큐 $TXQ 개 < 3: taprio num_tc 3 는 tc 마다 다른 큐가 필요하다 (queues 1@0 1@1 1@2). 붙일 수 없다. 중단."
    exit 1
fi
modprobe -n sch_taprio 2>/dev/null || { echo "sch_taprio 모듈 없음"; exit 1; }
sudo modprobe sch_taprio 2>/dev/null || true

echo -e "\n[1/3] root qdisc 초기화 (mqprio/ETF 가 있으면 통째로 대체)..."
reset_root_qdisc "$IFACE"

echo -e "\n[2/3] taprio 추가..."
# 논문 스케줄 (주기 1 ms): tc2 125 us → tc1 125 us → tc0 750 us.  게이트 마스크 비트 i = tc i.
# base-time: 지금(CLOCK_TAI) + 2 s. 과거 base-time 도 커널이 주기 단위로 앞으로 맞추지만(taprio 의
# base-time 재정렬) 시작 시점을 명확히 하려고 미래로 둔다.
BASE_TIME=$(tai_now_plus_ns 2)
# shellcheck disable=SC2086  # MAP 은 의도적 단어 분리
sudo tc qdisc replace dev "$IFACE" root handle 100: taprio \
    num_tc 3 map $MAP queues 1@0 1@1 1@2 \
    base-time "$BASE_TIME" \
    sched-entry S 04 125000 \
    sched-entry S 02 125000 \
    sched-entry S 01 750000 \
    clockid CLOCK_TAI
tc qdisc show dev "$IFACE" | grep -q '^qdisc taprio 100: root' || { show_qdisc "$IFACE"; echo "taprio 확인 실패"; exit 1; }
echo "  base-time=$BASE_TIME (CLOCK_TAI ns), 소프트웨어 모드 (flags 없음)"

echo -e "\n[3/3] 확인..."
show_qdisc "$IFACE"

cat <<EOF

==========================================
 taprio 완료 — 1 ms 주기 게이트: 0–125 us tc2 | 125–250 us tc1 | 250–1000 us tc0 (TS_PRIORITY=$TS_PRIORITY → tc0)
 한계 (VM): 소프트웨어 게이트는 hrtimer 정밀도(수십 us) 에 묶이고, talker 는 게이트와 동기화돼 있지 않아
   게이트 대기가 latency/jitter 로 나타난다. 하드웨어 오프로드(flags 0x2) 는 i225/Intel TSN NIC 만.
 제거: sudo tc qdisc del dev $IFACE root
==========================================
EOF

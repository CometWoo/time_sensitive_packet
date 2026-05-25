#!/bin/bash
# Step 5-3: ETS (Enhancements for Scheduled Traffic) qdisc 설정
# 구 TAS (Time Aware Shaper) — IEEE 802.1Qbv
#
# 논문 구성:
#   - 3개 전송 큐, 3개 트래픽 레벨
#   - tc0 → 큐 1, tc1 → 큐 2, tc2 → 큐 3
#   - 주기적 게이트 제어: tc2 먼저 → 125μs 후 tc1 → 250μs 후 tc0
#
# VM 환경 대안:
#   - 커널 5.15의 sch_ets 모듈은 "소프트웨어 ETS" 제공
#   - 하드웨어 게이트 제어 불가 → strict priority + quanta 기반 스케줄링
#   - taprio를 대안으로 사용 (소프트웨어 게이트 제어 리스트 지원)
set -euo pipefail

IFACE="${1:-$(ip route show default | awk '/default/ {print $5}' | head -1)}"

echo "=========================================="
echo " ETS / taprio qdisc 설정"
echo " 인터페이스: $IFACE"
echo "=========================================="

# sch_ets 또는 sch_taprio 모듈 확인
echo "[1/3] 커널 모듈 확인..."
ETS_AVAIL=false
TAPRIO_AVAIL=false
if modprobe -n sch_ets 2>/dev/null; then
    sudo modprobe sch_ets
    ETS_AVAIL=true
    echo "  sch_ets 모듈 사용 가능"
fi
if modprobe -n sch_taprio 2>/dev/null; then
    sudo modprobe sch_taprio
    TAPRIO_AVAIL=true
    echo "  sch_taprio 모듈 사용 가능"
fi

# 방법 선택
echo -e "\n[2/3] 스케줄링 설정..."

if $TAPRIO_AVAIL; then
    echo "  taprio 사용 (논문의 ETS 게이트 제어 리스트에 가장 가까운 대안)"

    # 기존 qdisc 초기화 (mqprio + etf 전체 교체)
    sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true

    # taprio: 소프트웨어 모드 게이트 제어 리스트
    # 논문 스케줄: tc2 먼저 → 125μs 후 tc1 → 250μs 후 tc0
    BASE_TIME=$(date +%s)000000000  # 현재 시각 기준 (나노초)

    sudo tc qdisc replace dev "$IFACE" root handle 100: taprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@0 1@0 \
        base-time "$BASE_TIME" \
        sched-entry S 04 125000 \
        sched-entry S 02 125000 \
        sched-entry S 01 750000 \
        clockid CLOCK_TAI \
        flags 0x1
    # sched-entry S <gate-mask> <interval-ns>
    #   S 04 (0b100) = tc2 게이트 열림, 125μs 동안
    #   S 02 (0b010) = tc1 게이트 열림, 125μs 동안
    #   S 01 (0b001) = tc0 게이트 열림, 750μs 동안 (나머지 시간)
    # 총 주기: 1ms (1000μs)
    # flags 0x1: 소프트웨어 모드

    echo "  taprio 설정 완료 (주기: 1ms, 소프트웨어 게이트 제어)"

elif $ETS_AVAIL; then
    echo "  sch_ets 사용 (strict priority 기반)"

    # mqprio 유지하고 ETS를 child로 추가
    # 먼저 mqprio가 있는지 확인
    MQPRIO_CHECK=$(tc qdisc show dev "$IFACE" | grep mqprio || true)
    if [ -z "$MQPRIO_CHECK" ]; then
        echo "  mqprio 재설정..."
        sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true
        sudo tc qdisc add dev "$IFACE" root handle 100: mqprio \
            num_tc 3 \
            map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
            queues 1@0 1@0 1@0 \
            hw 0
    fi

    # ETS를 tc2 큐에 추가 (best-effort 트래픽 스케줄링)
    sudo tc qdisc add dev "$IFACE" parent 100:3 handle 30: ets \
        strict 1 \
        quanta 2500 1500
    echo "  sch_ets 설정 완료"

else
    echo "  sch_ets, sch_taprio 모두 불가 → prio qdisc 대안 사용"
    sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true
    sudo tc qdisc add dev "$IFACE" root handle 100: prio bands 3
    echo "  prio qdisc 설정 완료 (3 band strict priority)"
fi

# 검증
echo -e "\n[3/3] 전체 qdisc 구조 확인..."
echo "--- tc qdisc show ---"
tc qdisc show dev "$IFACE"
echo ""
echo "--- tc class show ---"
tc class show dev "$IFACE" 2>/dev/null || true

echo -e "\n=========================================="
echo " ETS/taprio 설정 완료"
echo ""
echo " 논문의 게이트 스케줄 (1ms 주기):"
echo "   0~125μs:     tc2 (best-effort) 전송"
echo "   125~250μs:   tc1 (중간 우선순위) 전송"
echo "   250~1000μs:  tc0 (time-sensitive) 전송"
echo ""
echo " VM 환경 한계:"
echo "   - 소프트웨어 타이머 정밀도 ~수십μs"
echo "   - 하드웨어 게이트 제어 불가"
echo "   - 실제 스케줄링 정밀도는 논문보다 낮을 수 있음"
echo "=========================================="

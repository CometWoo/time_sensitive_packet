#!/bin/bash
# Step 5: 전체 TC qdisc 일괄 설정 스크립트
# mqprio + ETF + taprio(ETS 대안) 통합 구성
#
# 두 가지 모드 제공:
#   MODE=full   : taprio(게이트 제어) 사용 — 논문의 ETS에 가장 가까움
#   MODE=simple : mqprio + ETF — taprio 없이 우선순위 스케줄링만
#
# ⚠️ 이 스크립트는 "논문(§IV mqprio+ETF+ETS) 충실 재현 참고용"이며 메인 실험에서는
#    사용하지 않는다. VM에서 attach 자체는 되지만 다음 이유로 결과가 깨진다
#    (2026-06 코드 감사, 자세한 내용은 README "코드 감사" 절):
#      1) ETF child 가 SO_TXTIME 없는 talker 패킷을 전량 드롭 (sch_etf is_packet_valid)
#      2) software taprio 게이트 정밀도가 VM hrtimer(~수십 μs)에 종속
#      3) base-time=$(date +%s)(REALTIME) vs clockid CLOCK_TAI → TAI-UTC 오프셋만큼 어긋남
#      4) talker가 게이트와 비동기(sleep 페이싱+PTP 부정확) → 게이트 대기로 latency/jitter 증가
#    메인 실험은 deploy-experiment.sh 의 prio(우선순위 dequeue)만 사용한다.
set -euo pipefail

IFACE="${1:-$(ip route show default | awk '/default/ {print $5}' | head -1)}"
MODE="${2:-full}"  # full 또는 simple

echo "=========================================="
echo " TC qdisc 통합 설정"
echo " 인터페이스: $IFACE"
echo " 모드: $MODE"
echo "=========================================="

# 초기화
sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true
echo "기존 qdisc 제거 완료"

if [ "$MODE" = "full" ]; then
    # taprio 모드: 게이트 제어 리스트 + ETF
    echo -e "\n--- taprio + ETF 설정 ---"

    BASE_TIME=$(date +%s)000000000

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

    # tc0에 ETF child qdisc 추가
    sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf \
        clockid CLOCK_TAI \
        delta 150000 \
        offload off \
        deadline_mode on 2>/dev/null || echo "  ETF 추가 실패 (taprio child로는 제한될 수 있음)"

    echo "taprio + ETF 설정 완료"

elif [ "$MODE" = "simple" ]; then
    # mqprio + ETF 모드
    echo -e "\n--- mqprio + ETF 설정 ---"

    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@0 1@0 \
        hw 0

    sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf \
        clockid CLOCK_TAI \
        delta 150000 \
        offload off \
        deadline_mode on

    echo "mqprio + ETF 설정 완료"
fi

echo -e "\n--- 최종 qdisc 구조 ---"
tc qdisc show dev "$IFACE"

echo -e "\n=========================================="
echo " 설정 완료. 다음: step6-ebpf (eBPF 프로그램 빌드)"
echo "=========================================="

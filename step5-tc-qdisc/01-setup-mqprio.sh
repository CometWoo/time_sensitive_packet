#!/bin/bash
# Step 5-1: Multiqueue Priority (mqprio) qdisc 설정
#
# 논문 구성:
#   - NIC에 4개 하드웨어 tx 큐 → 3개 트래픽 클래스(tc0, tc1, tc2)로 매핑
#   - tc0 → 큐 1 (최고 우선순위, time-sensitive)
#   - tc1 → 큐 2
#   - tc2 → 큐 3,4 (best-effort)
#
# VM 환경 대안:
#   - virtio NIC는 하드웨어 큐가 1~2개 → mqprio "hw 0" (소프트웨어 모드) 사용
#   - 하드웨어 오프로드 없이 커널에서 우선순위 스케줄링 수행
#   - 성능 차이는 있으나 논리적 동작은 동일
set -euo pipefail

# 설정 가능 파라미터
IFACE="${1:-$(ip route show default | awk '/default/ {print $5}' | head -1)}"

echo "=========================================="
echo " mqprio qdisc 설정"
echo " 인터페이스: $IFACE"
echo "=========================================="

# 현재 NIC 큐 수 확인
TX_QUEUES=$(ls -d /sys/class/net/$IFACE/queues/tx-* 2>/dev/null | wc -l)
echo "TX 큐 수: $TX_QUEUES"

# 기존 qdisc 초기화
echo -e "\n[1/3] 기존 qdisc 제거..."
sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true

if [ "$TX_QUEUES" -ge 4 ]; then
    # 하드웨어 큐 4개 이상 → 논문 원본 설정
    echo -e "\n[2/3] 하드웨어 mqprio 설정 (논문 원본)..."
    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@1 2@2 \
        hw 1 \
        mode dcb
    # map: VLAN priority → TC 매핑
    #   pri 0,1,4-15 → tc2 (best-effort)
    #   pri 2 → tc1
    #   pri 3 → tc0 (time-sensitive)
    # queues: tc0=큐0(1개), tc1=큐1(1개), tc2=큐2~3(2개)
    echo "  하드웨어 mqprio 설정 완료"
else
    # VM 환경: 소프트웨어 mqprio
    echo -e "\n[2/3] 소프트웨어 mqprio 설정 (VM 대안)..."
    echo "  하드웨어 큐 ${TX_QUEUES}개 < 4 → 소프트웨어 모드(hw 0) 사용"

    # 먼저 TX 큐를 최대한 늘려봄
    if command -v ethtool &>/dev/null; then
        MAX_TX=$(ethtool -l "$IFACE" 2>/dev/null | grep -A5 "Pre-set" | grep TX | awk '{print $2}' | head -1)
        if [ -n "$MAX_TX" ] && [ "$MAX_TX" -gt "$TX_QUEUES" ]; then
            echo "  TX 큐를 $TX_QUEUES → $MAX_TX 로 확장 시도..."
            sudo ethtool -L "$IFACE" tx "$MAX_TX" 2>/dev/null || echo "  큐 확장 실패 (VM 제한)"
        fi
    fi

    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@0 1@0 \
        hw 0
    # hw 0: 소프트웨어 모드 — 모든 TC가 같은 물리 큐 공유하지만
    #        커널 내 우선순위 스케줄링은 동작함
    echo "  소프트웨어 mqprio 설정 완료"
fi

# 검증
echo -e "\n[3/3] 설정 확인..."
echo "--- tc qdisc show ---"
tc qdisc show dev "$IFACE"
echo ""
echo "--- tc class show ---"
tc class show dev "$IFACE"

echo -e "\n=========================================="
echo " mqprio 설정 완료"
echo ""
echo " VLAN Priority → TC 매핑:"
echo "   pri 3    → tc0 (time-sensitive, 최고 우선순위)"
echo "   pri 2    → tc1 (중간)"
echo "   pri 0,1  → tc2 (best-effort)"
echo ""
echo " 다음: 02-setup-etf.sh (ETF qdisc 추가)"
echo "=========================================="

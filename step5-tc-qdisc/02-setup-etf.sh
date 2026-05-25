#!/bin/bash
# Step 5-2: ETF (Earliest TxTime First) qdisc 설정
#
# 논문 구성:
#   - mqprio의 tc0(큐1)에 ETF를 child qdisc로 추가
#   - clockid: CLOCK_TAI
#   - delta (스케줄링 간격): 150μs
#   - deadline_mode: 활성화
#
# VM 환경 한계:
#   - ETF는 NIC의 하드웨어 LaunchTime을 사용하는 것이 이상적
#   - VM virtio NIC에서는 하드웨어 오프로드 불가 → 소프트웨어 ETF만 동작
#   - 소프트웨어 ETF도 커널에서 txtime 기반 스케줄링은 수행함
#   - 정밀도: 하드웨어 ~1μs vs 소프트웨어 ~수십μs
set -euo pipefail

IFACE="${1:-$(ip route show default | awk '/default/ {print $5}' | head -1)}"

echo "=========================================="
echo " ETF qdisc 설정"
echo " 인터페이스: $IFACE"
echo "=========================================="

# mqprio가 먼저 설정되어 있는지 확인
MQPRIO_CHECK=$(tc qdisc show dev "$IFACE" | grep mqprio || true)
if [ -z "$MQPRIO_CHECK" ]; then
    echo "mqprio가 설정되지 않음. 01-setup-mqprio.sh를 먼저 실행하세요."
    exit 1
fi

# CLOCK_TAI 사용 가능 확인
echo "[1/3] CLOCK_TAI 확인..."
if python3 -c "import time; time.clock_gettime(time.CLOCK_TAI)" 2>/dev/null; then
    echo "  CLOCK_TAI 사용 가능"
    CLOCKID="CLOCK_TAI"
else
    echo "  CLOCK_TAI 사용 불가 → CLOCK_REALTIME 대체"
    CLOCKID="CLOCK_REALTIME"
fi

# ETF 설정
echo -e "\n[2/3] ETF qdisc 추가 (tc0 큐에)..."
# mqprio의 첫 번째 child는 100:1 (tc0에 해당)
# ETF를 tc0의 child qdisc로 추가

# 기존 child qdisc 제거
sudo tc qdisc del dev "$IFACE" parent 100:1 2>/dev/null || true

sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf \
    clockid "$CLOCKID" \
    delta 150000 \
    offload off \
    deadline_mode on
# delta 150000: 150μs (논문 설정)
# offload off: VM에서 하드웨어 오프로드 불가
# deadline_mode on: 데드라인 초과 패킷 드롭

echo "  ETF 설정 완료 (clockid=$CLOCKID, delta=150μs)"

# 검증
echo -e "\n[3/3] 전체 qdisc 구조 확인..."
echo "--- tc qdisc show ---"
tc qdisc show dev "$IFACE"

echo -e "\n=========================================="
echo " ETF 설정 완료"
echo ""
echo " 구조: root(mqprio) → tc0(ETF) / tc1(pfifo) / tc2(pfifo)"
echo ""
echo " ETF 동작 원리:"
echo "   - 패킷에 SO_TXTIME으로 전송 시각을 설정"
echo "   - ETF가 해당 시각까지 패킷을 보관 후 정확한 시점에 전송"
echo "   - deadline_mode: 전송 시각이 지나면 패킷 드롭"
echo ""
echo " 다음: 03-setup-ets.sh (ETS qdisc 추가)"
echo "=========================================="

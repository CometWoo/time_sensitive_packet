#!/bin/bash
# Step 2-4: PTP (Precision Time Protocol) 시간 동기화 설정
# 논문: PTP daemon으로 NIC 클럭 동기화
# VM 환경: 하드웨어 타임스탬프 미지원 → 소프트웨어 PTP + phc2sys 대안
#
# ┌─────────────────────────────────────────────────────────────┐
# │ VM 환경 한계:                                               │
# │ - virtio NIC는 하드웨어 타임스탬프를 지원하지 않음           │
# │ - PTP grandmaster/slave 구조 대신 chrony NTP 동기화 사용     │
# │ - 두 VM 간 시간 오차 ~수백μs 수준 (물리 PTP는 ~수ns)       │
# │ - 이로 인해 latency 측정에 수백μs 오차 포함될 수 있음       │
# └─────────────────────────────────────────────────────────────┘
set -euo pipefail

echo "=========================================="
echo " PTP / 시간 동기화 설정"
echo "=========================================="

DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)

# 하드웨어 타임스탬프 지원 확인
echo "[1/4] 하드웨어 타임스탬프 지원 확인..."
HW_TS=$(ethtool -T "$DEFAULT_IF" 2>/dev/null | grep "hardware-transmit" || true)
if [ -n "$HW_TS" ]; then
    echo "  하드웨어 타임스탬프 지원됨 → 물리 PTP 모드 사용"
    PTP_MODE="hardware"
else
    echo "  하드웨어 타임스탬프 미지원 → 소프트웨어 PTP 모드 사용"
    PTP_MODE="software"
fi

# 방법 A: 소프트웨어 PTP (VM 기본)
echo -e "\n[2/4] PTP 설정 (모드: $PTP_MODE)..."

if [ "$PTP_MODE" = "software" ]; then
    # VM 환경: chrony로 호스트 시계 동기화 + ptp4l 소프트웨어 모드
    cat <<'CONF' | sudo tee /etc/linuxptp/ptp4l-sw.conf > /dev/null
[global]
twoStepFlag             1
socket_priority         0
priority1               128
priority2               128
domainNumber            0
clockClass              248
clockAccuracy           0xFE
offsetScaledLogVariance 0xFFFF
free_running            0
freq_est_interval       1
dscp_event              0
dscp_general            0
dataset_comparison      ieee1588
maxStepsRemoved         255
logAnnounceInterval     1
logSyncInterval         -3
logMinDelayReqInterval  0
logMinPdelayReqInterval 0
announceReceiptTimeout  3
syncReceiptTimeout      0
transportSpecific       0x0
ptp_dst_mac             01:1B:19:00:00:00
p2p_dst_mac             01:80:C2:00:00:0E
network_transport       L2
delay_mechanism         E2E
time_stamping           software
CONF

    echo "  ptp4l 소프트웨어 모드 설정 파일 생성 완료"
    echo ""
    echo "  ── 실행 방법 (control-plane VM = master) ──"
    echo "  sudo ptp4l -i $DEFAULT_IF -f /etc/linuxptp/ptp4l-sw.conf -S -m"
    echo ""
    echo "  ── 실행 방법 (worker VM = slave) ──"
    echo "  sudo ptp4l -i $DEFAULT_IF -f /etc/linuxptp/ptp4l-sw.conf -S -s -m"

else
    # 하드웨어 지원 시 (물리 서버)
    echo "  기본 ptp4l.conf 사용"
    echo "  sudo ptp4l -i $DEFAULT_IF -m"
    echo "  sudo phc2sys -a -r -m"
fi

# chrony 설정 (VM 간 NTP 동기화 백업)
echo -e "\n[3/4] chrony NTP 동기화 설정..."
if command -v chronyc &>/dev/null; then
    sudo systemctl enable chrony
    sudo systemctl start chrony
    echo "  chrony 활성화됨"
    echo "  동기화 상태: $(chronyc tracking 2>/dev/null | grep 'System time' || echo 'N/A')"
else
    echo "  chrony 미설치 — 02-install-packages.sh 먼저 실행"
fi

# 검증 스크립트
echo -e "\n[4/4] 검증..."
echo "  현재 시스템 클럭 소스: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
echo "  사용 가능 클럭: $(cat /sys/devices/system/clocksource/clocksource0/available_clocksource)"

cat <<'EOF'

==========================================
 PTP 설정 완료

 VM 환경 검증 방법:
   1. 두 VM에서 chronyc tracking 실행
   2. System time 오차가 1ms 이내인지 확인
   3. 오차가 크면: sudo chronyc makestep

 논문과의 차이:
   - 논문: 하드웨어 PTP (NIC 클럭 동기화, ~ns 정밀도)
   - VM: 소프트웨어 PTP + NTP (~100μs~1ms 정밀도)
   - 영향: latency 절대값 측정에 오차 있으나,
           jitter 측정에는 영향 적음 (단일 노드 클럭 사용)
==========================================
EOF

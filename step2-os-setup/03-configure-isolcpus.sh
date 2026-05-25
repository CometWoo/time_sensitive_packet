#!/bin/bash
# Step 2-3: CPU isolation (isolcpus) 설정
# 논문: 72코어 중 8코어 격리
# VM 환경: 4 vCPU 중 2코어(CPU 2,3) 격리 → 네트워크 전용
#
# isolcpus로 격리된 CPU는 일반 스케줄러에서 제외되어
# eBPF 패킷 포워딩 및 TC qdisc 처리 전용으로 사용됨
set -euo pipefail

ISOLATED_CPUS="2,3"  # VM 4코어 기준: CPU 0,1은 시스템, CPU 2,3은 네트워크 전용

echo "=========================================="
echo " CPU Isolation 설정"
echo " 격리 대상: CPU $ISOLATED_CPUS"
echo "=========================================="

# 현재 GRUB 설정 백업
sudo cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d%H%M%S)

# GRUB_CMDLINE_LINUX_DEFAULT 수정
CURRENT_GRUB=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)
echo "현재 GRUB 설정: $CURRENT_GRUB"

# 기존 isolcpus 제거 후 새로 추가
NEW_PARAMS=$(echo "$CURRENT_GRUB" | sed 's/isolcpus=[^ "]*//g' | sed 's/nohz_full=[^ "]*//g' | sed 's/rcu_nocbs=[^ "]*//g')
# 닫는 따옴표 앞에 새 파라미터 삽입
NEW_PARAMS=$(echo "$NEW_PARAMS" | sed "s/\"$/ isolcpus=$ISOLATED_CPUS nohz_full=$ISOLATED_CPUS rcu_nocbs=$ISOLATED_CPUS\"/")
# 중복 공백 제거
NEW_PARAMS=$(echo "$NEW_PARAMS" | sed 's/  */ /g')

echo "새 GRUB 설정: $NEW_PARAMS"

sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$NEW_PARAMS|" /etc/default/grub

# GRUB 업데이트
sudo update-grub

echo ""
echo "=========================================="
echo " 설정 완료. 재부팅 필요!"
echo ""
echo " 재부팅: sudo reboot"
echo ""
echo " 검증 (재부팅 후):"
echo "   cat /sys/devices/system/cpu/isolated"
echo "   → 출력: $ISOLATED_CPUS"
echo ""
echo "   taskset -cp 1"
echo "   → CPU 0,1만 표시되어야 함"
echo ""
echo " 롤백:"
echo "   sudo cp /etc/default/grub.bak.* /etc/default/grub"
echo "   sudo update-grub && sudo reboot"
echo "=========================================="

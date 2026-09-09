#!/bin/bash
# Step 2-3: CPU isolation (isolcpus) — 선택 사항
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다.
#   - 커밋된 결과(2026-05)를 만든 VM 에는 isolcpus 가 **적용되지 않았다** (2 vCPU). talker/listener 의
#     --cpu 옵션(2026-06 추가)이 bind 에 성공했다고 해서 격리가 있었던 것은 아니다 (docs/LIMITATIONS.md).
#   - 실행된 적 없는 참고 구현. 4 vCPU 이상에서만 의미가 있다.
#   - 격리가 하는 일: 스케줄러가 다른 태스크를 격리 코어에 올리지 않는다. 그뿐이다. NIC RX softirq 는
#     여전히 IRQ 가 걸린 CPU 에서 돈다 — 그건 /proc/irq/*/smp_affinity 와 rps_cpus 로 따로 옮겨야 한다.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ISOLATED_CPUS="${ISOLATED_CPUS:-2,3}"    # 4 vCPU 기준: 0,1 시스템 / 2,3 실험 프로세스 (LISTENER_CPU/TALKER_CPU)
GRUB_D=/etc/default/grub.d/99-isolcpus.cfg

usage() { echo "사용법: sudo bash $0 apply | check | remove   (ISOLATED_CPUS=$ISOLATED_CPUS)"; }

apply() {
    local ncpu; ncpu=$(nproc)
    [ "$ncpu" -ge 4 ] || { echo "논리 코어 $ncpu < 4: 격리하면 시스템 코어가 부족하다. 중단."; exit 1; }
    [ -d /etc/default/grub.d ] || sudo mkdir -p /etc/default/grub.d
    # /etc/default/grub 을 sed 로 고치지 않고 grub.d 조각으로 덧붙인다 (grub-mkconfig 가 /etc/default/grub 다음에
    # /etc/default/grub.d/*.cfg 를 source 하므로 기존 값에 append 된다; 제거는 파일 삭제로 끝난다).
    cat <<EOF | sudo tee "$GRUB_D" >/dev/null
# time_sensitive_packet: CPU $ISOLATED_CPUS 격리 (step2-os-setup/03-configure-isolcpus.sh)
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT isolcpus=$ISOLATED_CPUS nohz_full=$ISOLATED_CPUS rcu_nocbs=$ISOLATED_CPUS"
EOF
    sudo update-grub
    cat <<EOF

==========================================
 $GRUB_D 작성 + update-grub 완료. 재부팅 필요: sudo reboot
 재부팅 후 검증: bash $0 check
   /sys/devices/system/cpu/isolated → $ISOLATED_CPUS
 experiment.env: LISTENER_CPU / TALKER_CPU 를 격리 코어 중 하나로 (예: 2)
 NIC IRQ/RPS 는 격리되지 않는다: cat /proc/interrupts | grep -i <IF>, /sys/class/net/<IF>/queues/rx-*/rps_cpus
 롤백: sudo bash $0 remove && sudo reboot
==========================================
EOF
}

check() {
    local iso; iso=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "")
    echo "isolated : '${iso:-<없음>}'   (기대 $ISOLATED_CPUS)"
    echo "nohz_full: '$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null || echo "")'"
    echo "cmdline  : $(cat /proc/cmdline)"
    [ "$iso" = "$ISOLATED_CPUS" ] && echo "[PASS] 격리 적용됨" || { echo "[FAIL] 격리 미적용 (apply + reboot 했는가?)"; exit 1; }
}

remove() {
    sudo rm -f "$GRUB_D"
    sudo update-grub
    echo "제거됨 — 재부팅 후 반영"
}

case "${1:-}" in
    apply) apply ;;
    check) check ;;
    remove) remove ;;
    *) usage; exit 2 ;;
esac

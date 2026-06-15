#!/bin/bash
# Step 6: eBPF 프로그램을 TC에 attach하는 스크립트
#
# 사용법: sudo bash attach-ebpf.sh [물리NIC] [veth인터페이스]
#   예: sudo bash attach-ebpf.sh eth0 lxc12345
#
# attach 위치 (논문 Figure 1):
#   veth_filter → 컨테이너 veth peer (호스트 측) ingress
#   egress      → 호스트 물리 NIC egress
#   ingress     → 호스트 물리 NIC ingress
set -euo pipefail

PHYS_IF="${1:-$(ip route show default | awk '/default/ {print $5}' | head -1)}"
VETH_IF="${2:-}"
BUILDDIR="$(dirname "$0")/build"

echo "=========================================="
echo " eBPF 프로그램 Attach"
echo " 물리 NIC: $PHYS_IF"
echo " veth: ${VETH_IF:-자동 감지}"
echo "=========================================="

# 빌드 확인
for prog in veth_filter egress ingress; do
    if [ ! -f "$BUILDDIR/${prog}.bpf.o" ]; then
        echo "빌드 필요: make -C $(dirname "$0")"
        exit 1
    fi
done

# (구) XDP VLAN/AVTP 프로그램 attach 단계 제거됨 (2026-06).
# 실험 트래픽이 plain UDP라 XDP의 VLAN/AVTP 분류가 한 번도 호출되지 않아 dead code였음.
# 혹시 남아 있던 XDP 프로그램이 있으면 정리만 수행:
sudo ip link set dev "$PHYS_IF" xdpgeneric off 2>/dev/null || true

# 1. 물리 NIC에 clsact qdisc 추가 (이미 있으면 무시)
echo "[1/4] clsact qdisc 추가..."
sudo tc qdisc add dev "$PHYS_IF" clsact 2>/dev/null || true

# 2. egress eBPF → 물리 NIC egress
echo "[2/4] egress 프로그램 attach → $PHYS_IF egress..."
sudo tc filter del dev "$PHYS_IF" egress 2>/dev/null || true
sudo tc filter add dev "$PHYS_IF" egress bpf \
    da obj "$BUILDDIR/egress.bpf.o" sec tc
echo "  완료"

# 3. ingress eBPF → 물리 NIC ingress
echo "[3/4] ingress 프로그램 attach → $PHYS_IF ingress..."
sudo tc filter del dev "$PHYS_IF" ingress 2>/dev/null || true
sudo tc filter add dev "$PHYS_IF" ingress bpf \
    da obj "$BUILDDIR/ingress.bpf.o" sec tc
echo "  완료"

# 4. veth_filter → 컨테이너의 veth peer
echo "[4/4] veth_filter 프로그램 attach..."
if [ -n "$VETH_IF" ]; then
    VETH_LIST="$VETH_IF"
else
    # Cilium이 생성한 lxc* 인터페이스 자동 감지
    VETH_LIST=$(ip link show | grep -oP 'lxc\w+' | sort -u || true)
    if [ -z "$VETH_LIST" ]; then
        # 일반 veth 감지
        VETH_LIST=$(ip link show type veth | grep -oP '^\d+: \K\w+' || true)
    fi
fi

if [ -z "$VETH_LIST" ]; then
    echo "  veth 인터페이스 없음 (컨테이너 배포 후 재실행 필요)"
else
    for veth in $VETH_LIST; do
        echo "  attach: $veth"
        sudo tc qdisc add dev "$veth" clsact 2>/dev/null || true
        sudo tc filter del dev "$veth" ingress 2>/dev/null || true
        sudo tc filter add dev "$veth" ingress bpf \
            da obj "$BUILDDIR/veth_filter.bpf.o" sec tc
    done
fi

# 검증
echo -e "\n--- 현재 TC filter 목록 ---"
echo "물리 NIC ($PHYS_IF):"
tc filter show dev "$PHYS_IF" egress 2>/dev/null || echo "  (없음)"
tc filter show dev "$PHYS_IF" ingress 2>/dev/null || echo "  (없음)"

if [ -n "$VETH_LIST" ]; then
    for veth in $VETH_LIST; do
        echo "veth ($veth):"
        tc filter show dev "$veth" ingress 2>/dev/null || echo "  (없음)"
    done
fi

echo -e "\n--- eBPF 통계 맵 확인 ---"
echo "(패킷 전송 후 아래 명령으로 확인)"
echo "  sudo bpftool map dump name pkt_stats"

echo -e "\n=========================================="
echo " Attach 완료"
echo ""
echo " Detach:"
echo "   sudo tc filter del dev $PHYS_IF egress"
echo "   sudo tc filter del dev $PHYS_IF ingress"
echo "=========================================="

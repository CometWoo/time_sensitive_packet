#!/bin/bash
# Step 2-1: 사전 요구사항 검증 스크립트
# 논문 환경: Ubuntu 22.04, kernel 5.15, 72 cores, 16GB RAM, 4-queue NIC
# VM 환경: Ubuntu 22.04, kernel 5.15, 4 vCPU, 4GB RAM, virtio NIC
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass()  { echo -e "${GREEN}[PASS]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }

echo "=========================================="
echo " 논문 재현 환경 사전 검증"
echo "=========================================="

# 1. OS 버전 확인
echo -e "\n--- OS 확인 ---"
if grep -q "22.04" /etc/lsb-release 2>/dev/null; then
    pass "Ubuntu 22.04 확인됨"
else
    CURRENT_OS=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)
    warn "Ubuntu 22.04가 아님: $CURRENT_OS (논문 요구: Ubuntu 22.04)"
fi

# 2. 커널 버전 확인
echo -e "\n--- 커널 확인 ---"
KVER=$(uname -r)
if [[ "$KVER" == 5.15.* ]]; then
    pass "Kernel 5.15.x 확인됨: $KVER"
elif [[ "$KVER" > "5.15" ]]; then
    warn "Kernel $KVER (논문 요구: 5.15.0, 상위 버전이라 대부분 호환)"
else
    fail "Kernel $KVER (논문 요구: 5.15.0 이상, 업그레이드 필요)"
fi

# 3. CPU 확인
echo -e "\n--- CPU 확인 ---"
NCPU=$(nproc)
echo "  논리 코어 수: $NCPU (논문: 72코어, VM 권장: 4코어)"
if [ "$NCPU" -ge 4 ]; then
    pass "최소 4코어 충족"
else
    fail "CPU 코어 $NCPU개 — 최소 4개 필요 (2개 isolcpus + 2개 시스템용)"
fi

# 4. 메모리 확인
echo -e "\n--- 메모리 확인 ---"
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$((MEM_KB / 1024 / 1024))
echo "  총 메모리: ${MEM_GB}GB (논문: 16GB, VM 권장: 4GB)"
if [ "$MEM_GB" -ge 3 ]; then
    pass "최소 메모리 요구 충족"
else
    fail "메모리 ${MEM_GB}GB — 최소 4GB 권장"
fi

# 5. NIC 큐 확인
echo -e "\n--- NIC 큐 확인 ---"
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [ -n "$DEFAULT_IF" ]; then
    TX_QUEUES=$(ls -d /sys/class/net/$DEFAULT_IF/queues/tx-* 2>/dev/null | wc -l)
    RX_QUEUES=$(ls -d /sys/class/net/$DEFAULT_IF/queues/rx-* 2>/dev/null | wc -l)
    echo "  인터페이스: $DEFAULT_IF, TX큐: $TX_QUEUES, RX큐: $RX_QUEUES"
    echo "  논문 요구: 4 tx/rx 큐 (하드웨어)"
    if [ "$TX_QUEUES" -lt 4 ]; then
        warn "TX 큐 ${TX_QUEUES}개 < 논문 요구 4개. VM virtio NIC는 보통 1~2개."
        warn "→ Step 5에서 소프트웨어 mqprio 대안 사용 예정"
    else
        pass "TX 큐 $TX_QUEUES개 — 논문 요구 충족"
    fi
else
    fail "기본 네트워크 인터페이스를 찾을 수 없음"
fi

# 6. 가상화 환경 확인
echo -e "\n--- 가상화 확인 ---"
VIRT=$(systemd-detect-virt 2>/dev/null || echo "unknown")
echo "  가상화 유형: $VIRT"
if [ "$VIRT" != "none" ]; then
    warn "VM 환경 감지. 하드웨어 타임스탬프 및 NIC 큐 제한 있음"
    warn "→ PTP는 소프트웨어 타임스탬프 모드 사용, ETF는 소프트웨어 모드 사용"
fi

# 7. 필수 커널 모듈 확인
echo -e "\n--- 커널 모듈 확인 ---"
MODULES=("br_netfilter" "overlay" "sch_mqprio" "sch_etf" "sch_ets" "cls_bpf" "act_bpf")
for mod in "${MODULES[@]}"; do
    if modprobe -n "$mod" 2>/dev/null; then
        pass "모듈 $mod 사용 가능"
    else
        fail "모듈 $mod 없음 — 커널 재빌드 또는 모듈 설치 필요"
    fi
done

# 8. eBPF 지원 확인
echo -e "\n--- eBPF 지원 확인 ---"
if [ -d /sys/fs/bpf ]; then
    pass "BPF 파일시스템 마운트됨"
else
    warn "BPF 파일시스템 미마운트 — 'mount -t bpf bpf /sys/fs/bpf' 필요"
fi

if [ -f /proc/config.gz ]; then
    for cfg in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF; do
        if zcat /proc/config.gz | grep -q "${cfg}=y"; then
            pass "$cfg=y"
        else
            warn "$cfg 미설정 또는 모듈"
        fi
    done
elif [ -f "/boot/config-$(uname -r)" ]; then
    for cfg in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF; do
        if grep -q "${cfg}=y" "/boot/config-$(uname -r)"; then
            pass "$cfg=y"
        else
            warn "$cfg 미설정 또는 모듈"
        fi
    done
fi

# 9. 필수 명령어 확인
echo -e "\n--- 필수 도구 확인 ---"
TOOLS=("ip" "tc" "ethtool" "curl" "git" "make" "gcc")
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool 설치됨"
    else
        fail "$tool 미설치 — 02-install-packages.sh로 설치 필요"
    fi
done

echo -e "\n=========================================="
echo " 검증 완료. [FAIL] 항목은 반드시 해결 필요."
echo " [WARN] 항목은 VM 환경 한계로 대안 사용."
echo "=========================================="

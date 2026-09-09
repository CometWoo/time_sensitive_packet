#!/bin/bash
# Step 2-1: 사전 요구사항 검증 (control-plane / worker 공통)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다.
#   - 커밋된 결과(step8-measurement/results, 2026-05)를 만든 VM 은 이 스크립트가 아니라 수동으로
#     준비됐다 (Ubuntu 24.04.4 / kernel 6.17 / kubeadm 1.30.14 / containerd 2.2.1 / Cilium 1.19.1,
#     2 vCPU / 3.8 GiB, TX queue 1개 — docs/DATA_PROVENANCE.md). 당시 이 파일은 22.04/5.15 템플릿이었다.
#   - 지금은 측정된 스택에 맞춰 기준을 고쳤지만 이 형태로 실행된 적은 없다. 실행 전 읽고 맞춰라.
#   - 실험 경로: step2(OS) → step3(kubeadm) → step4(Cilium) → deploy-experiment.sh. step5 는 참고용.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── 기준 (측정된 스택) ───────────────────────────────────────────────────────
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
MIN_KERNEL="${MIN_KERNEL:-6.6}"          # tcx (BPF_TCX_EGRESS) — Cilium 앞에 분류기를 붙이려면 필수 (ADR-0005)
MIN_CPUS="${MIN_CPUS:-2}"                # 측정 VM 은 2 vCPU. 4 이상 권장 (talker 1 CPU Guaranteed + be-flood)
MIN_MEM_GB="${MIN_MEM_GB:-3}"
# 실험이 실제로 쓰는 모듈 (HTB 병목 + prio/fq_codel/pfifo leaf + cls_bpf legacy 폴백)
MODULES=(br_netfilter overlay sch_prio sch_fq_codel sch_htb cls_bpf act_bpf)
# step5 참고 스크립트(mqprio/ETF/taprio)용 — 실험에는 불필요, 없어도 WARN
REF_MODULES=(sch_mqprio sch_etf sch_taprio)
TOOLS=(ip tc ethtool curl git make gcc clang bpftool nsenter crictl kubectl python3)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
N_FAIL=0
pass()  { echo -e "${GREEN}[PASS]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { N_FAIL=$((N_FAIL + 1)); echo -e "${RED}[FAIL]${NC} $1"; }

echo "=========================================="
echo " 실험 환경 사전 검증 (기준: Ubuntu $UBUNTU_VERSION, kernel >= $MIN_KERNEL)"
echo "=========================================="

# 1. OS
echo -e "\n--- OS ---"
OS_DESC=$( (lsb_release -ds 2>/dev/null) || (grep PRETTY_NAME /etc/os-release | cut -d= -f2) || echo unknown)
if grep -q "VERSION_ID=\"$UBUNTU_VERSION\"" /etc/os-release 2>/dev/null; then
    pass "Ubuntu $UBUNTU_VERSION: $OS_DESC"
else
    warn "Ubuntu $UBUNTU_VERSION 이 아님: $OS_DESC (다른 배포판도 kernel/모듈 조건만 맞으면 동작)"
fi

# 2. 커널 — 숫자 비교 (문자열 비교 '>' 는 5.15 > 6.6 같은 오판을 낸다)
echo -e "\n--- 커널 ---"
KVER=$(uname -r); KMM=$(echo "$KVER" | cut -d. -f1-2)
if [ "$(printf '%s\n' "$MIN_KERNEL" "$KMM" | sort -V | head -1)" = "$MIN_KERNEL" ]; then
    pass "kernel $KVER >= $MIN_KERNEL (tcx 사용 가능)"
else
    fail "kernel $KVER < $MIN_KERNEL — tcx 없음. Cilium(legacy tc) 이 TC_ACT_OK 를 반환하면 분류기가 실행되지 않는다 (ADR-0005). HWE 커널로 올릴 것"
fi

# 3. CPU
echo -e "\n--- CPU ---"
NCPU=$(nproc)
if [ "$NCPU" -ge 4 ]; then
    pass "논리 코어 $NCPU (talker Guaranteed 1 CPU + be-flood + 시스템)"
elif [ "$NCPU" -ge "$MIN_CPUS" ]; then
    warn "논리 코어 $NCPU — 측정 VM 과 같은 2 vCPU. control-plane 에서 talker(1 CPU) 가 Pending 이면 experiment.env TALKER_CPU_REQUEST=500m"
else
    fail "논리 코어 $NCPU < $MIN_CPUS"
fi

# 4. 메모리
echo -e "\n--- 메모리 ---"
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_GB=$((MEM_KB / 1024 / 1024))
if [ "$MEM_GB" -ge "$MIN_MEM_GB" ]; then pass "메모리 ${MEM_GB} GiB"; else fail "메모리 ${MEM_GB} GiB < ${MIN_MEM_GB} GiB"; fi

# 5. NIC
echo -e "\n--- NIC ---"
DEFAULT_IF=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "$DEFAULT_IF" ]; then
    TXQ=$(find "/sys/class/net/$DEFAULT_IF/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)
    RXQ=$(find "/sys/class/net/$DEFAULT_IF/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
    pass "default route 인터페이스 $DEFAULT_IF (TX 큐 $TXQ, RX 큐 $RXQ, driver $(ethtool -i "$DEFAULT_IF" 2>/dev/null | awk '/^driver/ {print $2}'))"
    if [ "$TXQ" -lt 3 ]; then
        echo "       TX 큐 $TXQ 개: mqprio/taprio(step5 참고 스크립트) 는 붙지 않는다 (num_tc 3 > TXQ). 실험은 HTB + prio 를 쓴다 (ADR-0002)"
    fi
else
    fail "default route 인터페이스를 찾을 수 없음"
fi

# 6. 가상화
echo -e "\n--- 가상화 ---"
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
echo "  $VIRT"
[ "$VIRT" = none ] || echo "  VM: 하드웨어 타임스탬프/PTP 없음. 두 VM 간 시계 오프셋(5월 측정 14–37 ms) 이 one-way latency 에 섞인다 (ADR-0012)"

# 7. 커널 모듈
echo -e "\n--- 커널 모듈 (modprobe -n) ---"
for mod in "${MODULES[@]}"; do
    if modprobe -n "$mod" 2>/dev/null; then pass "$mod"; else fail "$mod 없음 (built-in 이면 /boot/config 의 CONFIG_*=y 확인)"; fi
done
for mod in "${REF_MODULES[@]}"; do
    if modprobe -n "$mod" 2>/dev/null; then echo "  (참고) $mod 사용 가능"; else warn "$mod 없음 — step5 참고 스크립트에만 필요"; fi
done

# 8. eBPF / bpffs / 커널 config (=y 또는 =m 모두 허용)
echo -e "\n--- eBPF ---"
if mountpoint -q /sys/fs/bpf 2>/dev/null; then pass "bpffs 마운트됨"; else warn "bpffs 미마운트 — deploy-experiment.sh 가 mount -t bpf 한다"; fi
CFG=""
if [ -f /proc/config.gz ]; then CFG=$(zcat /proc/config.gz); elif [ -f "/boot/config-$KVER" ]; then CFG=$(cat "/boot/config-$KVER"); fi
if [ -n "$CFG" ]; then
    for c in CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF CONFIG_NET_SCH_HTB CONFIG_NET_SCH_PRIO CONFIG_NET_CLS_U32; do
        if grep -Eq "^${c}=(y|m)$" <<<"$CFG"; then pass "$c"; else fail "$c 미설정"; fi
    done
else
    warn "커널 config 를 읽을 수 없음 (/proc/config.gz, /boot/config-$KVER)"
fi

# 9. 도구
echo -e "\n--- 도구 ---"
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then pass "$tool"; else fail "$tool 없음 — 02-install-packages.sh / step3 (kubectl, crictl)"; fi
done
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libbpf; then
    LIBBPF=$(pkg-config --modversion libbpf)
    if [ "$(printf '%s\n' 1.3 "$LIBBPF" | sort -V | head -1)" = 1.3 ]; then pass "libbpf $LIBBPF >= 1.3 (tcx_attach 빌드 가능)"; else fail "libbpf $LIBBPF < 1.3 — tcx_attach 빌드 불가"; fi
else
    fail "libbpf-dev 없음 (pkg-config libbpf)"
fi

echo -e "\n=========================================="
if [ "$N_FAIL" -eq 0 ]; then
    echo " 검증 통과. 다음: 02-install-packages.sh (미설치 도구가 있으면) → step3-kubernetes/"
else
    echo " [FAIL] ${N_FAIL}건 — 해결 후 재실행"
fi
echo "=========================================="
[ "$N_FAIL" -eq 0 ]

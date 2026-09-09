#!/bin/bash
# Step 2-2: 필수 패키지 설치 (control-plane / worker 공통, Ubuntu 24.04)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - scripts/experiment.sh 는 이 파일을 호출하지 않는다.
#   - 커밋된 결과(2026-05)를 만든 VM 은 수동 설치됐다 (Ubuntu 24.04.4 / kernel 6.17 / containerd 2.2.1 /
#     kubeadm 1.30.14 / Cilium 1.19.1 — docs/DATA_PROVENANCE.md). 당시 이 파일은 22.04 템플릿이었고
#     pip 로 numpy/matplotlib 를 깔고 Docker 까지 설치했다 (24.04 는 PEP 668 로 pip 전역 설치가 막힌다).
#   - 지금은 측정된 스택에 맞췄지만 이 형태로 실행된 적은 없다. 실행 전 읽고 맞춰라.
#   - Docker 는 필요 없다: 이미지는 python:3.11-slim 을 그대로 쓰고 스크립트는 ConfigMap 으로 들어간다 (ADR-0013).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# containerd: Ubuntu 24.04 의 'containerd' 패키지는 1.7.x. 측정 VM 은 2.2.1 (Docker apt 저장소의
# containerd.io) 이었다. CONTAINERD_SOURCE=ubuntu 로 바꾸면 배포판 패키지를 쓴다 (1.7 도 K8s 1.30 과 호환).
CONTAINERD_SOURCE="${CONTAINERD_SOURCE:-docker-repo}"

echo "=========================================="
echo " 패키지 설치 (containerd: $CONTAINERD_SOURCE)"
echo "=========================================="

echo "[1/7] apt update..."
sudo apt-get update -qq

echo "[2/7] 기본 도구..."
sudo apt-get install -y -qq \
    apt-transport-https ca-certificates curl gnupg lsb-release wget jq \
    iproute2 ethtool iputils-ping net-tools iperf3 stress-ng htop sysstat \
    make gcc pkg-config build-essential git

echo "[3/7] eBPF 빌드/도구 (clang + libbpf + 커널 UAPI 헤더 + bpftool)..."
# libbpf >= 1.3 (24.04: 1.3.0) 이 tools/tcx_attach 빌드에 필요. linux-libc-dev 가 /usr/include/linux/bpf.h.
sudo apt-get install -y -qq \
    clang llvm libbpf-dev linux-libc-dev libelf-dev zlib1g-dev \
    linux-tools-common python3 python3-pytest
# 커널별 linux-tools 는 따로, 실패 허용: mainline/HWE 커널(측정 VM 의 6.17 등)은 24.04 저장소에 없어
# 'Unable to locate package' 로 끝난다 — 같은 apt 트랜잭션에 넣으면 clang/libbpf 까지 안 깔리고 set -e 로 죽는다.
KTOOLS="linux-tools-$(uname -r)"
if ! sudo apt-get install -y -qq "$KTOOLS"; then
    echo "  $KTOOLS 패키지 없음 (이 커널은 저장소 밖) → bpftool 은 소스 빌드로"
fi
if ! bpftool version >/dev/null 2>&1; then
    echo "  bpftool 이 linux-tools 에 없음 → 소스 빌드 (scripts/ci/install-bpftool.sh)"
    bash "$(dirname "$0")/../scripts/ci/install-bpftool.sh"
fi
bpftool version | head -1

echo "[4/7] 분석 도구 (apt — PEP 668 때문에 pip 전역 설치는 쓰지 않는다)..."
sudo apt-get install -y -qq python3-numpy python3-scipy python3-matplotlib

echo "[5/7] containerd..."
if command -v containerd >/dev/null 2>&1; then
    echo "  이미 설치됨: $(containerd --version)"
else
    if [ "$CONTAINERD_SOURCE" = docker-repo ]; then
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq containerd.io      # containerd 2.x 만. docker-ce 는 설치하지 않는다
    else
        sudo apt-get install -y -qq containerd
    fi
fi
sudo mkdir -p /etc/containerd
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    # 1.7 과 2.x 모두 runc options 에 SystemdCgroup 키가 있다 (섹션 이름만 다름) — kubelet cgroupDriver=systemd 와 맞춘다
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd
fi
sudo systemctl enable containerd >/dev/null 2>&1
echo "  containerd $(containerd --version | awk '{print $3}') / SystemdCgroup=true"

echo "[6/7] 시간 동기화 (chrony; ptp.sh 가 peer 모드로 설정)..."
sudo apt-get install -y -qq chrony

echo "[7/7] 커널 모듈..."
MODULES=(br_netfilter overlay sch_prio sch_fq_codel sch_htb cls_bpf act_bpf veth)
for mod in "${MODULES[@]}"; do
    if sudo modprobe "$mod" 2>/dev/null; then echo "  로드됨: $mod"; else echo "  [WARN] $mod 로드 실패 (built-in 이면 정상)"; fi
done
# step5 참고 스크립트용 (없어도 실험에는 영향 없음)
for mod in sch_mqprio sch_etf sch_taprio; do sudo modprobe "$mod" 2>/dev/null || true; done
printf '%s\n' "${MODULES[@]}" | sudo tee /etc/modules-load.d/tsn-reproduction.conf >/dev/null

echo -e "\n=========================================="
echo " 설치 완료. 검증: bash prerequisites.sh"
echo " 다음: scripts/setup/k8s-node-prepare.sh (kubeadm/kubelet/kubectl/crictl)"
echo "=========================================="

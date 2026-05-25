#!/bin/bash
# Step 2-2: 필수 패키지 설치 스크립트
# 대상: Ubuntu 22.04 VM (control-plane 및 worker 공통)
set -euo pipefail

echo "=========================================="
echo " 필수 패키지 설치"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive

# 시스템 업데이트
echo "[1/8] 시스템 패키지 업데이트..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# 기본 도구
echo "[2/8] 기본 도구 설치..."
sudo apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    wget \
    jq \
    net-tools \
    iputils-ping \
    iproute2 \
    ethtool \
    iperf3 \
    stress-ng \
    htop \
    sysstat

# 커널 헤더 및 BPF 도구
echo "[3/8] 커널 헤더 및 BPF 도구 설치..."
sudo apt-get install -y -qq \
    linux-headers-$(uname -r) \
    linux-tools-$(uname -r) \
    linux-tools-common \
    bpfcc-tools \
    libbpf-dev \
    bpftool

# eBPF 개발 도구
echo "[4/8] eBPF 개발 환경 설치..."
sudo apt-get install -y -qq \
    clang \
    llvm \
    gcc-multilib \
    build-essential \
    libelf-dev \
    pkg-config

# 컨테이너 런타임 (containerd)
echo "[5/8] containerd 설치..."
if ! command -v containerd &>/dev/null; then
    sudo apt-get install -y -qq containerd
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
    # SystemdCgroup 활성화 (Kubernetes 필수)
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd
    sudo systemctl enable containerd
    echo "  containerd 설치 및 설정 완료"
else
    echo "  containerd 이미 설치됨"
fi

# PTP (Precision Time Protocol)
echo "[6/8] PTP 도구 설치..."
sudo apt-get install -y -qq \
    linuxptp \
    chrony

# Python (측정 및 그래프용)
echo "[7/8] Python 및 분석 도구 설치..."
sudo apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv
pip3 install --quiet matplotlib numpy pandas

# Docker (talker/listener 이미지 빌드용)
echo "[8/8] Docker 설치..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    echo "  Docker 설치 완료. 로그아웃 후 재로그인 필요."
else
    echo "  Docker 이미 설치됨"
fi

# 커널 모듈 로드
echo -e "\n--- 필수 커널 모듈 로드 ---"
MODULES=(br_netfilter overlay sch_mqprio sch_etf sch_ets cls_bpf act_bpf veth)
for mod in "${MODULES[@]}"; do
    sudo modprobe "$mod" 2>/dev/null && echo "  로드됨: $mod" || echo "  실패: $mod"
done

# 부팅 시 자동 로드
cat <<EOF | sudo tee /etc/modules-load.d/tsn-reproduction.conf > /dev/null
br_netfilter
overlay
sch_mqprio
sch_etf
sch_ets
cls_bpf
act_bpf
veth
EOF

echo -e "\n=========================================="
echo " 패키지 설치 완료"
echo " 검증: bash 01-check-prerequisites.sh"
echo "=========================================="

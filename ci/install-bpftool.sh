#!/bin/bash
# ci/install-bpftool.sh — bpftool 설치 (apt 시도 → 실패 시 소스 빌드)
#
# GitHub Actions 의 azure 커널은 linux-tools-$(uname -r) 패키지가 없을 수 있어
# libbpf/bpftool 을 소스에서 빌드하는 폴백을 둔다 (약 1분).
set -euo pipefail

if command -v bpftool >/dev/null 2>&1 && bpftool version >/dev/null 2>&1; then
    echo "bpftool 이미 존재: $(bpftool version | head -1)"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
if sudo apt-get install -y -qq linux-tools-common "linux-tools-$(uname -r)" >/dev/null 2>&1 \
   && bpftool version >/dev/null 2>&1; then
    echo "apt bpftool: $(bpftool version | head -1)"
    exit 0
fi

echo "apt 로 bpftool 을 못 구함 → 소스 빌드"
sudo apt-get install -y -qq git build-essential libelf-dev zlib1g-dev libcap-dev pkg-config clang llvm >/dev/null
BPFTOOL_VER="${BPFTOOL_VER:-v7.5.0}"
rm -rf /tmp/bpftool-src
git clone -q --depth 1 --branch "$BPFTOOL_VER" --recurse-submodules https://github.com/libbpf/bpftool.git /tmp/bpftool-src
make -s -C /tmp/bpftool-src/src -j"$(nproc)"
sudo install -m 0755 /tmp/bpftool-src/src/bpftool /usr/local/sbin/bpftool
echo "source-built bpftool: $(/usr/local/sbin/bpftool version | head -1)"

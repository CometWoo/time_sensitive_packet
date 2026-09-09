# Makefile — eBPF 프로그램 빌드 / 단위 테스트 / tcx 로더
#
# 의존성 (Ubuntu): clang llvm make libbpf-dev linux-libc-dev bpftool python3-pytest gcc pkg-config
#
# 사용법:
#   make                 BPF 오브젝트 3개 빌드 → build/*.bpf.o
#   make tools           tcx 로더(build/tcx_attach) 빌드 (libbpf >= 1.3)
#   make test            BPF_PROG_TEST_RUN 기반 단위 테스트 (root + bpftool 필요)
#   make test-tcx        tcx 체인 순서 통합 테스트 (root, kernel >= 6.6)
#   make check-env       빌드 환경 진단
#   make clean
#
# 프로그램:
#   ts_classifier   호스트 NIC egress 분류기 (TS → skb->priority, 옵션 DSCP)   ★ 메인
#   prio_probe      skb->priority 히스토그램 (veth 통과 시 priority 리셋 증명용)
#   tcx_dummy_ok    TC_ACT_OK 를 반환하는 tcx 프로그램 (Cilium 흉내, 테스트 전용)

CLANG    ?= clang
BPFTOOL  ?= bpftool
CC       ?= gcc
PYTHON   ?= python3

ARCH      := $(shell uname -m 2>/dev/null | sed -e 's/x86_64/x86/' -e 's/aarch64/arm64/')
MULTIARCH ?= $(shell uname -m)-linux-gnu
EXTRA_CFLAGS ?=

# 실제 커널 UAPI(linux-libc-dev) + libbpf(libbpf-dev) 헤더 사용. stub 헤더 없음.
BPF_CFLAGS := -g -O2 -target bpf \
    -D__TARGET_ARCH_$(ARCH) \
    -D__LITTLE_ENDIAN_BITFIELD \
    -I/usr/include -I/usr/include/$(MULTIARCH) -Isrc \
    -Wall -Werror -Wno-unused-value \
    $(EXTRA_CFLAGS)

SRCDIR   := src
BUILDDIR := build
PROGS    := ts_classifier prio_probe tcx_dummy_ok
OBJS     := $(addprefix $(BUILDDIR)/, $(addsuffix .bpf.o, $(PROGS)))
TOOLS    := $(BUILDDIR)/tcx_attach

LIBBPF_FLAGS := $(shell pkg-config --cflags --libs libbpf 2>/dev/null || echo -lbpf)

.DEFAULT_GOAL := all
.PHONY: all tools test test-tcx verify check-env check-env-quiet clean help

all: check-env-quiet $(OBJS)
	@echo "빌드 완료:" && ls -la $(OBJS)

tools: $(TOOLS)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(BUILDDIR)/%.bpf.o: $(SRCDIR)/%.c $(SRCDIR)/ts_common.h | $(BUILDDIR)
	@echo "[BPF] $< -> $@"
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

$(BUILDDIR)/tcx_attach: tools/tcx_attach.c | $(BUILDDIR)
	@echo "[CC ] $< -> $@"
	$(CC) -O2 -Wall -o $@ $< $(LIBBPF_FLAGS)

# ── 테스트 ────────────────────────────────────────────────────────────────
test: all
	@[ "$$(id -u)" = 0 ] || { echo "make test 는 root 로 실행하세요 (bpf() syscall): sudo make test"; exit 1; }
	$(PYTHON) -m pytest -q tests

test-tcx: all tools
	@bash tests/test_tcx_chain.sh

# ── 진단 ──────────────────────────────────────────────────────────────────
verify: $(OBJS)
	@for obj in $(OBJS); do \
	    echo "== $$obj"; \
	    llvm-objdump -h $$obj 2>/dev/null | grep -E '^\s+[0-9]+ (tc|\.maps|license)' || true; \
	done

check-env:
	@echo "== clang";   ($(CLANG) --version | head -1) || echo "  [FAIL] clang 없음: apt install clang llvm"
	@echo "== headers"; for h in /usr/include/bpf/bpf_helpers.h /usr/include/linux/bpf.h /usr/include/$(MULTIARCH)/asm/types.h; do \
	    [ -f $$h ] && echo "  [OK] $$h" || echo "  [FAIL] $$h 없음 (libbpf-dev / linux-libc-dev)"; done
	@echo "== bpftool"; ($(BPFTOOL) version | head -1) || echo "  [WARN] bpftool 없음 (테스트/디버그에 필요)"
	@echo "== libbpf";  (pkg-config --modversion libbpf) || echo "  [WARN] libbpf pkg-config 없음 (tools 빌드에 필요)"
	@echo "== kernel";  uname -r
	@echo "== tcx";     [ "$$(printf '%s\n' 6.6 $$(uname -r | cut -d. -f1-2) | sort -V | head -1)" = 6.6 ] && echo "  [OK] kernel >= 6.6 (tcx 사용 가능)" || echo "  [INFO] kernel < 6.6 — legacy clsact 만 사용 가능"

check-env-quiet:
	@command -v $(CLANG) >/dev/null 2>&1 || { echo "[ERROR] clang 없음: apt install clang llvm"; exit 1; }
	@[ -f /usr/include/bpf/bpf_helpers.h ] || { echo "[ERROR] libbpf 헤더 없음: apt install libbpf-dev"; exit 1; }
	@[ -f /usr/include/linux/bpf.h ] || { echo "[ERROR] 커널 UAPI 헤더 없음: apt install linux-libc-dev"; exit 1; }

clean:
	rm -rf $(BUILDDIR) tests/__pycache__ tests/.pytest_cache .pytest_cache

help:
	@sed -n '2,20p' Makefile

# Makefile — eBPF 프로그램 빌드 (kernel 5.15, clang + libbpf)
#
# 사용법:
#   make                    — 릴리스 빌드 (DEBUG_LEVEL=2)
#   make DEBUG=4            — 전체 디버그 빌드 (모든 패킷 로그)
#   make DEBUG=0            — 디버그 off (프로덕션)
#   make check-env          — 빌드 환경 검증
#   make clean              — 정리
#
# 디버그 로그 확인:
#   sudo cat /sys/kernel/debug/tracing/trace_pipe
# 통계 확인:
#   sudo bpftool map dump name pkt_stats
#   sudo bpftool map dump name debug_stats

CLANG    ?= clang
LLC      ?= llc
BPFTOOL  ?= bpftool
ARCH     := $(shell uname -m 2>/dev/null | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/' || echo "x86")

# 디버그 레벨 (기본 2 = 오류+경고)
DEBUG    ?= 2

# 커널 헤더 경로
KERNEL_HEADERS ?= /usr/src/linux-headers-$(shell uname -r 2>/dev/null || echo "5.15.0-generic")
LIBBPF_HEADERS ?= /usr/include/bpf

# 추가 컴파일 플래그 (사용자 지정)
EXTRA_CFLAGS ?=

# 컴파일 플래그
BPF_CFLAGS := -g -O2 \
    -target bpf \
    -D__TARGET_ARCH_$(ARCH) \
    -DDEBUG_LEVEL=$(DEBUG) \
    -I$(KERNEL_HEADERS)/include \
    -I$(KERNEL_HEADERS)/include/uapi \
    -I$(KERNEL_HEADERS)/arch/$(ARCH)/include \
    -I$(KERNEL_HEADERS)/arch/$(ARCH)/include/uapi \
    -I$(KERNEL_HEADERS)/arch/$(ARCH)/include/generated \
    -I$(KERNEL_HEADERS)/arch/$(ARCH)/include/generated/uapi \
    -I$(LIBBPF_HEADERS) \
    -I/usr/include \
    -I/usr/include/$(shell uname -m 2>/dev/null || echo "x86_64")-linux-gnu \
    -Isrc \
    -Wall -Wno-unused-value \
    $(EXTRA_CFLAGS)

SRCDIR   := src
BUILDDIR := build
PROGS    := veth_filter egress ingress xdp_vlan_avtp

OBJS     := $(addprefix $(BUILDDIR)/, $(addsuffix .bpf.o, $(PROGS)))

.PHONY: all clean install verify check-env debug-build help

help:
	@echo "eBPF 빌드 시스템"
	@echo ""
	@echo "  make                  릴리스 빌드 (DEBUG_LEVEL=2)"
	@echo "  make DEBUG=4          전체 디버그 빌드"
	@echo "  make DEBUG=0          디버그 off 빌드"
	@echo "  make check-env        빌드 환경 검증"
	@echo "  make verify           빌드된 오브젝트 검증"
	@echo "  make clean            정리"
	@echo ""
	@echo "디버그 레벨:"
	@echo "  0 = off, 1 = ERR, 2 = +WARN, 3 = +INFO, 4 = +TRACE"

all: check-env-quiet $(BUILDDIR) $(OBJS)
	@echo ""
	@echo "빌드 완료 (DEBUG_LEVEL=$(DEBUG)):"
	@ls -la $(BUILDDIR)/*.bpf.o

# 전체 디버그 빌드 편의 타겟
debug-build:
	$(MAKE) all DEBUG=4

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(BUILDDIR)/%.bpf.o: $(SRCDIR)/%.c $(SRCDIR)/common.h
	@echo "[BPF] $< → $@ (DEBUG=$(DEBUG))"
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# 개별 빌드 타겟
veth_filter:    $(BUILDDIR) $(BUILDDIR)/veth_filter.bpf.o
egress:         $(BUILDDIR) $(BUILDDIR)/egress.bpf.o
ingress:        $(BUILDDIR) $(BUILDDIR)/ingress.bpf.o
xdp_vlan_avtp:  $(BUILDDIR) $(BUILDDIR)/xdp_vlan_avtp.bpf.o

# ──────────────────────────────────────────────
# 빌드 환경 검증 (상세)
# ──────────────────────────────────────────────
check-env:
	@echo "═══════════════════════════════════════"
	@echo " eBPF 빌드 환경 검증"
	@echo "═══════════════════════════════════════"
	@echo ""
	@# OS 확인
	@echo "── OS ──"
	@uname -a || echo "  [FAIL] uname 실행 불가 — Linux 환경이 아닌 것 같습니다"
	@echo ""
	@# clang 확인
	@echo "── clang ──"
	@if command -v $(CLANG) >/dev/null 2>&1; then \
	    echo "  [OK] $(CLANG) 발견: $$($(CLANG) --version | head -1)"; \
	    echo "  BPF 타겟 지원 확인:"; \
	    if $(CLANG) -target bpf -c /dev/null -o /dev/null 2>/dev/null; then \
	        echo "    [OK] -target bpf 지원"; \
	    else \
	        echo "    [FAIL] -target bpf 미지원 — clang 10+ 필요"; \
	    fi; \
	else \
	    echo "  [FAIL] clang 미설치"; \
	    echo "  설치: sudo apt-get install clang llvm"; \
	fi
	@echo ""
	@# 커널 헤더
	@echo "── 커널 헤더 ──"
	@if [ -d "$(KERNEL_HEADERS)" ]; then \
	    echo "  [OK] $(KERNEL_HEADERS) 존재"; \
	else \
	    echo "  [FAIL] $(KERNEL_HEADERS) 없음"; \
	    echo "  설치: sudo apt-get install linux-headers-$$(uname -r)"; \
	fi
	@if [ -f "$(KERNEL_HEADERS)/include/linux/bpf.h" ]; then \
	    echo "  [OK] linux/bpf.h 발견"; \
	else \
	    echo "  [WARN] linux/bpf.h 없음 — uapi 경로 확인:"; \
	    if [ -f "$(KERNEL_HEADERS)/include/uapi/linux/bpf.h" ]; then \
	        echo "    [OK] uapi/linux/bpf.h 발견"; \
	    else \
	        echo "    [FAIL] bpf.h 없음"; \
	    fi; \
	fi
	@echo ""
	@# libbpf 헤더
	@echo "── libbpf ──"
	@if [ -f "$(LIBBPF_HEADERS)/bpf_helpers.h" ]; then \
	    echo "  [OK] bpf/bpf_helpers.h 발견"; \
	elif [ -f "/usr/include/bpf/bpf_helpers.h" ]; then \
	    echo "  [OK] /usr/include/bpf/bpf_helpers.h 발견"; \
	else \
	    echo "  [FAIL] bpf_helpers.h 없음"; \
	    echo "  설치: sudo apt-get install libbpf-dev"; \
	fi
	@echo ""
	@# bpftool
	@echo "── bpftool ──"
	@if command -v $(BPFTOOL) >/dev/null 2>&1; then \
	    echo "  [OK] bpftool: $$($(BPFTOOL) version)"; \
	else \
	    echo "  [WARN] bpftool 미설치 (검증/디버그에 필요)"; \
	    echo "  설치: sudo apt-get install linux-tools-$$(uname -r) bpftool"; \
	fi
	@echo ""
	@# 커널 모듈
	@echo "── TC 관련 커널 모듈 ──"
	@for mod in cls_bpf act_bpf sch_mqprio sch_etf sch_ets; do \
	    if modprobe -n $$mod 2>/dev/null; then \
	        echo "  [OK] $$mod"; \
	    else \
	        echo "  [WARN] $$mod 미지원 (관련 기능 제한)"; \
	    fi; \
	done
	@echo ""
	@echo "═══════════════════════════════════════"

# 빌드 시 간략 검증 (에러만)
check-env-quiet:
	@if ! command -v $(CLANG) >/dev/null 2>&1; then \
	    echo "[ERROR] clang 미설치. 'make check-env'로 상세 확인"; \
	    exit 1; \
	fi

# 빌드된 오브젝트 검증
verify: $(OBJS)
	@echo "── eBPF 오브젝트 검증 ──"
	@for obj in $(OBJS); do \
	    echo ""; \
	    echo "파일: $$obj"; \
	    echo "  섹션:"; \
	    llvm-objdump -h $$obj 2>/dev/null | grep -E '^\s+[0-9]' || echo "    (llvm-objdump 실패)"; \
	    echo "  프로그램 크기:"; \
	    ls -la $$obj | awk '{print "    " $$5 " bytes"}'; \
	    echo "  맵:"; \
	    if command -v $(BPFTOOL) >/dev/null 2>&1; then \
	        $(BPFTOOL) map list 2>/dev/null | head -5 || echo "    (bpftool 확인 불가)"; \
	    fi; \
	done

clean:
	rm -rf $(BUILDDIR)
	@echo "정리 완료"

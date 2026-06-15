# Makefile — eBPF 프로그램 빌드 (clang + 실제 커널/libbpf 헤더)
#
# 의존성: clang make libbpf-dev linux-libc-dev
#
# 사용법:
#   make                    — 빌드
#   make check-env          — 빌드 환경 검증
#   make clean              — 정리
#
# 디버그(런타임 토글, debug_level map):
#   sudo bpftool map update name debug_level key 0 0 0 0 value 3 0 0 0
#   sudo cat /sys/kernel/debug/tracing/trace_pipe
# 통계 확인:
#   sudo bpftool map dump name pkt_stats

CLANG    ?= clang
LLC      ?= llc
BPFTOOL  ?= bpftool
ARCH     := $(shell uname -m 2>/dev/null | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/' || echo "x86")

# 멀티아치 UAPI 헤더 경로 (asm/ 심볼릭 링크용)
#   linux-libc-dev 가 /usr/include/<arch>-linux-gnu/asm 에 설치함
MULTIARCH ?= $(shell uname -m)-linux-gnu

# 추가 컴파일 플래그 (사용자 지정)
EXTRA_CFLAGS ?=

# 컴파일 플래그 (2026-06 감사: stub-headers 제거 → 실제 커널/libbpf 헤더 사용)
#   linux/* : linux-libc-dev (/usr/include/linux, /usr/include/<arch>-linux-gnu)
#   bpf/*   : libbpf-dev      (/usr/include/bpf)
#   DEBUG_LEVEL 매크로 제거 — 디버그는 런타임 debug_level BPF map 으로 일원화.
BPF_CFLAGS := -g -O2 \
    -target bpf \
    -D__TARGET_ARCH_$(ARCH) \
    -D__LITTLE_ENDIAN_BITFIELD \
    -I/usr/include \
    -I/usr/include/$(MULTIARCH) \
    -Isrc \
    -Wall -Wno-unused-value \
    $(EXTRA_CFLAGS)

SRCDIR   := src
BUILDDIR := build
# xdp_vlan_avtp 제거됨 (2026-06): 실험 트래픽이 plain UDP라 XDP의 VLAN/AVTP 분류가
# 한 번도 호출되지 않음 → dead code. 자세한 근거는 README "코드 감사" 절 참조.
PROGS    := veth_filter egress ingress

OBJS     := $(addprefix $(BUILDDIR)/, $(addsuffix .bpf.o, $(PROGS)))

.DEFAULT_GOAL := all

.PHONY: all clean install verify check-env help

help:
	@echo "eBPF 빌드 시스템 (실제 커널/libbpf 헤더 사용)"
	@echo ""
	@echo "  make                  빌드"
	@echo "  make check-env        빌드 환경 검증"
	@echo "  make verify           빌드된 오브젝트 검증"
	@echo "  make clean            정리"
	@echo ""
	@echo "디버그는 런타임 debug_level BPF map 으로 제어:"
	@echo "  sudo bpftool map update name debug_level key 0 0 0 0 value 3 0 0 0"
	@echo "  레벨: 0=off 1=ERR 2=+WARN 3=+INFO 4=+TRACE"
	@echo "  로그: sudo cat /sys/kernel/debug/tracing/trace_pipe"

all: check-env-quiet $(BUILDDIR) $(OBJS)
	@echo ""
	@echo "빌드 완료:"
	@ls -la $(BUILDDIR)/*.bpf.o

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(BUILDDIR)/%.bpf.o: $(SRCDIR)/%.c $(SRCDIR)/common.h
	@echo "[BPF] $< → $@"
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# 개별 빌드 타겟
veth_filter:    $(BUILDDIR) $(BUILDDIR)/veth_filter.bpf.o
egress:         $(BUILDDIR) $(BUILDDIR)/egress.bpf.o
ingress:        $(BUILDDIR) $(BUILDDIR)/ingress.bpf.o

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
	@# 실제 커널/libbpf 헤더 확인
	@echo "── 커널/libbpf 헤더 ──"
	@if [ -f "/usr/include/bpf/bpf_helpers.h" ]; then \
	    echo "  [OK] /usr/include/bpf/bpf_helpers.h 발견 (libbpf-dev)"; \
	else \
	    echo "  [FAIL] /usr/include/bpf/bpf_helpers.h 없음 — sudo apt install libbpf-dev"; \
	fi
	@if [ -f "/usr/include/linux/bpf.h" ]; then \
	    echo "  [OK] /usr/include/linux/bpf.h 발견 (linux-libc-dev)"; \
	else \
	    echo "  [FAIL] /usr/include/linux/bpf.h 없음 — sudo apt install linux-libc-dev"; \
	fi
	@if [ -d "/usr/include/$(MULTIARCH)/asm" ]; then \
	    echo "  [OK] /usr/include/$(MULTIARCH)/asm 발견"; \
	else \
	    echo "  [WARN] /usr/include/$(MULTIARCH)/asm 없음 — gcc-multilib 또는 linux-libc-dev 확인"; \
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
	@if [ ! -f "/usr/include/bpf/bpf_helpers.h" ]; then \
	    echo "[ERROR] libbpf 헤더 없음. sudo apt install libbpf-dev"; \
	    exit 1; \
	fi
	@if [ ! -f "/usr/include/linux/bpf.h" ]; then \
	    echo "[ERROR] 커널 UAPI 헤더 없음. sudo apt install linux-libc-dev"; \
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

#!/bin/bash
# eBPF 통계/디버그 조회 스크립트 (2026-06 감사 반영)
#
# 변경: debug_stats(ARRAY[16]) 제거 → pkt_stats 만 사용.
#       디버그는 런타임 debug_level map 으로 토글.
#
# 사용법:
#   sudo bash debug-stats.sh              — pkt_stats + debug_level 출력
#   sudo bash debug-stats.sh --watch      — 1초마다 갱신
#   sudo bash debug-stats.sh --reset      — pkt_stats 0으로 초기화
#   sudo bash debug-stats.sh --debug N    — debug_level 을 N(0~4)으로 설정
#   sudo bash debug-stats.sh --trace      — trace_pipe 실시간 로그

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

# pkt_stats 인덱스 이름
PKTSTAT_NAMES=(
    "TOTAL       (전체 패킷)"
    "TSN         (time-sensitive 패킷)"
    "BEST_EFFORT (일반 패킷)"
    "DROPPED     (드롭 패킷)"
)

dump_pkt_stats() {
    local VALUES
    VALUES=$(bpftool map dump name pkt_stats 2>/dev/null || echo "")
    if [ -z "$VALUES" ]; then
        echo -e "  ${RED}맵 'pkt_stats' 없음 — eBPF 미로드 또는 sudo 필요.${NC}"
        echo "  확인: sudo bpftool map list"
        return
    fi
    local IDX=0
    while IFS= read -r line; do
        if echo "$line" | grep -q '"value"'; then
            local VAL
            VAL=$(echo "$line" | grep -oP '\d+' | tail -1)
            if [ "$IDX" -lt "${#PKTSTAT_NAMES[@]}" ]; then
                if [ "${VAL:-0}" -gt 0 ]; then
                    echo -e "  ${GREEN}[$IDX] ${PKTSTAT_NAMES[$IDX]}: $VAL${NC}"
                else
                    echo "  [$IDX] ${PKTSTAT_NAMES[$IDX]}: 0"
                fi
            fi
            IDX=$((IDX + 1))
        fi
    done <<< "$VALUES"
}

dump_debug_level() {
    local VAL
    VAL=$(bpftool map dump name debug_level 2>/dev/null | grep -oP '"value":\s*\K\d+' | head -1 || true)
    if [ -n "${VAL:-}" ]; then
        echo "  debug_level = $VAL  (0=off 1=ERR 2=WARN 3=INFO 4=TRACE)"
    else
        echo "  debug_level 맵 없음"
    fi
}

set_debug_level() {
    local LVL="$1"
    local MAP_ID
    MAP_ID=$(bpftool map list 2>/dev/null | grep -w debug_level | awk '{print $1}' | tr -d ':' | head -1)
    if [ -z "${MAP_ID:-}" ]; then
        echo "debug_level 맵 없음 (eBPF 미로드?)"
        exit 1
    fi
    # key 0 (u32 LE) → value LVL (u32 LE)
    bpftool map update id "$MAP_ID" key 0 0 0 0 value "$LVL" 0 0 0
    echo "debug_level = $LVL 로 설정됨"
    echo "로그 확인: sudo cat /sys/kernel/debug/tracing/trace_pipe"
}

reset_pkt_stats() {
    local MAP_ID
    MAP_ID=$(bpftool map list 2>/dev/null | grep -w pkt_stats | awk '{print $1}' | tr -d ':' | head -1)
    if [ -n "${MAP_ID:-}" ]; then
        for i in 0 1 2 3; do
            bpftool map update id "$MAP_ID" \
                key "$i" 0 0 0 \
                value 0 0 0 0 0 0 0 0 2>/dev/null || true
        done
        echo "pkt_stats 초기화 완료"
    else
        echo "pkt_stats 맵 없음"
    fi
}

print_stats() {
    echo "═══════════════════════════════════════════════════"
    echo " eBPF 통계  $(date '+%H:%M:%S')"
    echo "═══════════════════════════════════════════════════"
    echo -e "\n${CYAN}── 패킷 통계 (pkt_stats) ──${NC}"
    dump_pkt_stats
    echo -e "\n${CYAN}── 런타임 디버그 레벨 (debug_level) ──${NC}"
    dump_debug_level
    echo -e "\n${CYAN}── 로드된 eBPF 프로그램 ──${NC}"
    bpftool prog list 2>/dev/null | grep -E "tc|sched_cls" || echo "  (없음)"
    echo ""
}

case "${1:-}" in
    --watch)
        echo "1초마다 갱신 (Ctrl+C로 중단)"
        while true; do clear; print_stats; sleep 1; done
        ;;
    --reset)
        reset_pkt_stats
        ;;
    --debug)
        set_debug_level "${2:?사용법: --debug N (0~4)}"
        ;;
    --trace)
        echo "eBPF trace 로그 (Ctrl+C로 중단). debug_level >= 1 이어야 출력됨"
        echo "  레벨 설정: sudo bash $0 --debug 3"
        echo "──────────────────────────────────────"
        cat /sys/kernel/debug/tracing/trace_pipe
        ;;
    --help)
        echo "사용법: sudo bash $0 [옵션]"
        echo "  (없음)      pkt_stats + debug_level 출력"
        echo "  --watch     1초마다 갱신"
        echo "  --reset     pkt_stats 0 초기화"
        echo "  --debug N   debug_level 을 N(0~4)으로 설정"
        echo "  --trace     trace_pipe 실시간 로그"
        ;;
    *)
        print_stats
        ;;
esac

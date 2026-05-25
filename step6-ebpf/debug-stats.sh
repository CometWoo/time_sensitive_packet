#!/bin/bash
# eBPF 디버그 통계 조회 스크립트
#
# 사용법:
#   sudo bash debug-stats.sh           — 전체 통계 출력
#   sudo bash debug-stats.sh --watch   — 1초마다 갱신
#   sudo bash debug-stats.sh --reset   — 통계 초기화
#   sudo bash debug-stats.sh --trace   — trace_pipe 실시간 로그

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# debug_stats 맵 인덱스 이름
DBGSTAT_NAMES=(
    "ETH_TOO_SHORT    (이더넷 헤더 파싱 실패)"
    "VLAN_PARSE_FAIL  (VLAN 헤더 파싱 실패)"
    "IP_TOO_SHORT     (IP 헤더 파싱 실패)"
    "UDP_TOO_SHORT    (UDP 헤더 파싱 실패)"
    "NOT_IP           (비-IP 패킷)"
    "NOT_UDP          (비-UDP IP 패킷)"
    "VLAN_TAGGED      (VLAN 태그 패킷)"
    "AVTP_PKT         (AVTP 프로토콜 패킷)"
    "TSN_BY_PORT      (UDP 포트 기반 TSN 분류)"
    "TSN_BY_PCP       (VLAN PCP 기반 TSN 분류)"
    "RINGBUF_FAIL     (ring buffer 예약 실패)"
    "MAP_UPDATE_FAIL  (맵 업데이트 실패)"
    "UNKNOWN_PROTO    (알 수 없는 EtherType)"
    "PROG_ENTER       (프로그램 진입 횟수)"
    "IHL_INVALID      (IP IHL 값 비정상)"
)

# pkt_stats 맵 인덱스 이름
PKTSTAT_NAMES=(
    "TOTAL       (전체 패킷)"
    "TSN         (time-sensitive 패킷)"
    "BEST_EFFORT (일반 패킷)"
    "DROPPED     (드롭 패킷)"
)

dump_map() {
    local MAP_NAME="$1"
    local -n NAMES=$2
    local VALUES

    VALUES=$(bpftool map dump name "$MAP_NAME" 2>/dev/null || echo "")
    if [ -z "$VALUES" ]; then
        echo -e "  ${RED}맵 '$MAP_NAME' 을 찾을 수 없습니다.${NC}"
        echo "  → eBPF 프로그램이 로드되지 않았거나 이름이 다릅니다."
        echo "  → 확인: sudo bpftool map list"
        return
    fi

    # bpftool 출력 파싱
    local IDX=0
    while IFS= read -r line; do
        if echo "$line" | grep -q '"value"'; then
            local VAL=$(echo "$line" | grep -oP '\d+' | tail -1)
            if [ "$IDX" -lt "${#NAMES[@]}" ]; then
                local NAME="${NAMES[$IDX]}"
                if [ "$VAL" -gt 0 ]; then
                    # 오류 관련 통계는 빨간색
                    if [[ "$NAME" == *"FAIL"* ]] || [[ "$NAME" == *"SHORT"* ]] || \
                       [[ "$NAME" == *"INVALID"* ]] || [[ "$NAME" == *"DROP"* ]]; then
                        echo -e "  ${RED}[$IDX] $NAME: $VAL${NC}"
                    else
                        echo -e "  ${GREEN}[$IDX] $NAME: $VAL${NC}"
                    fi
                else
                    echo "  [$IDX] $NAME: 0"
                fi
            fi
            IDX=$((IDX + 1))
        fi
    done <<< "$VALUES"
}

print_stats() {
    echo "═══════════════════════════════════════════════════"
    echo " eBPF 디버그 통계 $(date '+%H:%M:%S')"
    echo "═══════════════════════════════════════════════════"

    echo -e "\n${CYAN}── 패킷 통계 (pkt_stats) ──${NC}"
    dump_map "pkt_stats" PKTSTAT_NAMES

    echo -e "\n${CYAN}── 디버그 통계 (debug_stats) ──${NC}"
    dump_map "debug_stats" DBGSTAT_NAMES

    echo -e "\n${CYAN}── 로드된 eBPF 프로그램 ──${NC}"
    bpftool prog list 2>/dev/null | grep -E "tc|xdp" || echo "  (없음)"

    echo -e "\n${CYAN}── 활성 BPF 맵 ──${NC}"
    bpftool map list 2>/dev/null || echo "  (bpftool 실행 실패)"

    echo ""
}

reset_stats() {
    echo "통계 맵 초기화..."
    for MAP in pkt_stats debug_stats; do
        local MAP_ID=$(bpftool map list 2>/dev/null | grep "$MAP" | awk '{print $1}' | tr -d ':')
        if [ -n "$MAP_ID" ]; then
            # 모든 키를 0으로 초기화
            for i in $(seq 0 15); do
                bpftool map update id "$MAP_ID" \
                    key hex $(printf '%02x 00 00 00' $i) \
                    value hex 00 00 00 00 00 00 00 00 2>/dev/null || true
            done
            echo "  $MAP 초기화 완료"
        else
            echo "  $MAP 맵 없음"
        fi
    done
}

case "${1:-}" in
    --watch)
        echo "1초마다 갱신 (Ctrl+C로 중단)"
        while true; do
            clear
            print_stats
            sleep 1
        done
        ;;
    --reset)
        reset_stats
        ;;
    --trace)
        echo "eBPF trace 로그 (Ctrl+C로 중단):"
        echo "  DEBUG_LEVEL >= 1 로 빌드해야 출력됨"
        echo "  make DEBUG=3 으로 재빌드 후 재attach 필요"
        echo "──────────────────────────────────────"
        cat /sys/kernel/debug/tracing/trace_pipe
        ;;
    --help)
        echo "사용법: sudo bash $0 [옵션]"
        echo ""
        echo "  (없음)     전체 통계 출력"
        echo "  --watch    1초마다 갱신"
        echo "  --reset    통계 초기화"
        echo "  --trace    trace_pipe 실시간 로그"
        echo ""
        echo "빌드 시 디버그 레벨 설정:"
        echo "  make DEBUG=0   디버그 off"
        echo "  make DEBUG=1   ERR만"
        echo "  make DEBUG=2   ERR+WARN (기본)"
        echo "  make DEBUG=3   +INFO (패킷 분류 결과)"
        echo "  make DEBUG=4   +TRACE (모든 패킷 — 성능 저하 주의)"
        ;;
    *)
        print_stats
        ;;
esac

#!/bin/bash
# scripts/qdisc-reference/common.sh — 참고 스크립트(mqprio / ETF / taprio) 공통 정의. 직접 실행하지 않는다.
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - scripts/experiment.sh 는 step5 를 호출하지 않는다. 실험의 qdisc 는 HTB 병목 + {pfifo|fq_codel|
#     pfifo_fast|prio} leaf 이고 scripts/experiment.sh apply_condition() 이 직접 만든다 (ADR-0002).
#   - step5 는 논문 §IV (mqprio + ETF + 802.1Qbv 게이트 스케줄) 를 리눅스 qdisc 로 옮겨 본 참고 구현이다.
#     TX 큐가 1개인 VirtualBox VM 에서는 mqprio/taprio 가 붙지 않아 (num_tc 3 > TXQ) 커밋된 결과에
#     쓰이지 않았고, 이 형태로 실행된 적도 없다.
#   - TS_PRIORITY 는 experiment.env 와 같은 값(기본 6)을 쓴다: 분류기가 세팅하는 skb->priority 가 tc0 이 된다.
# ──────────────────────────────────────────────────────────────────────────────

STEP5_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# experiment.env 의 TS_PRIORITY (있으면). 환경변수가 우선.
if [ -z "${TS_PRIORITY:-}" ] && [ -f "$STEP5_ROOT/experiment.env" ]; then
    TS_PRIORITY=$(sed -n 's/^[[:space:]]*TS_PRIORITY[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$STEP5_ROOT/experiment.env" | tail -1)
fi
TS_PRIORITY="${TS_PRIORITY:-6}"
[[ "$TS_PRIORITY" =~ ^[0-9]+$ ]] && [ "$TS_PRIORITY" -le 15 ] || { echo "TS_PRIORITY 는 0..15: '$TS_PRIORITY'"; exit 2; }

step5_iface() {   # $1 = 인자로 받은 IFACE (비었으면 default route)
    local ifc=${1:-}
    [ -n "$ifc" ] || ifc=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$ifc" ] && [ -d "/sys/class/net/$ifc" ] || { echo "인터페이스를 찾지 못함: '$ifc'"; exit 1; }
    echo "$ifc"
}

tx_queue_count() { find "/sys/class/net/$1/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l; }

# map: skb->priority(0..15) → traffic class. 논문의 3단계 (pri 3→tc0, 2→tc1, 나머지→tc2) 를
# TS_PRIORITY 기준으로 일반화: TS_PRIORITY→tc0(최우선), TS_PRIORITY-1→tc1(중간), 나머지→tc2(best-effort).
# 주의: 이 map 은 mqprio/taprio 의 'priority → tc' 이지 prio qdisc 의 priomap(priority → band) 이 아니다
# — 둘 다 skb->priority 를 인덱스로 쓰지만 방향(값)이 다르다.
prio_map() {
    local i out=""
    for i in $(seq 0 15); do
        if [ "$i" -eq "$TS_PRIORITY" ]; then out+="0 "
        elif [ "$i" -eq $((TS_PRIORITY - 1)) ]; then out+="1 "
        else out+="2 "; fi
    done
    echo "${out% }"
}

# root qdisc 제거 — 배포판 기본(handle 0:) 은 지울 수 없고 지울 필요도 없다 (add 가 대체한다)
reset_root_qdisc() {
    local h
    h=$(tc qdisc show dev "$1" | awk '$1=="qdisc" && $4=="root" {print $3; exit}')
    case "$h" in ""|0:) ;; *) sudo tc qdisc del dev "$1" root ;; esac
}

# CLOCK_TAI 기준 현재 시각(ns) + $1 초 — taprio base-time 용. date +%s 는 REALTIME 이라
# TAI-UTC 오프셋(현재 37 s) 만큼 어긋난다.
tai_now_plus_ns() { python3 -c "import time; print(time.clock_gettime_ns(time.CLOCK_TAI) + int(${1:-1}) * 10**9)"; }

show_qdisc() {
    echo "--- tc qdisc show dev $1 ---"; tc qdisc show dev "$1"
    echo "--- tc class show dev $1 ---"; tc class show dev "$1" 2>/dev/null || true
}

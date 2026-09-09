#!/bin/bash
# =============================================================================
# run_testbed.sh — netns 테스트베드 실험 러너
#
# 조건(condition)별로 병목 링크(vr_host) 의 qdisc 를 바꿔 가며 TS 흐름(1 ms 간격 UDP:6000)
# 과 best-effort 홍수(UDP:5001) 를 동시에 흘리고, listener 의 CSV 와 메타데이터를 남긴다.
#
#   fifo               tbf → pfifo             (단일 FIFO, 분류기 없음)      "멍청한 NIC 큐"
#   fq_codel           tbf → fq_codel          (리눅스 기본, 흐름 격리)
#   pfifo_fast_noclsf  tbf → pfifo_fast        (3-band, 분류기 없음)         = 구 K8s 설계의 실제 상태
#   pfifo_fast_clsf    tbf → pfifo_fast + ts_classifier(egress, DSCP 마킹)
#   prio_clsf          tbf → prio bands 3 + ts_classifier                     = K8s proposed 모드가 의도한 상태
#
# 셰이퍼(tbf)가 없는 커널(WSL2 등)에서는 SHAPER=none 으로 "기능 검증 모드" 만 돈다:
# priority 리셋 증명·DSCP 도착 확인은 유효하지만, 경합이 없으므로 latency 비교는 무의미하다.
#
# 사용: sudo bash run_testbed.sh [--runs N] [--conditions "a b c"] [--rate-mbps 20] [--flood-mbps 30]
#                                [--count 10000] [--interval-ms 1] [--out DIR] [--quick]
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BPF_BUILD="$ROOT/step6-ebpf/build"
LISTENER="$ROOT/step7-experiment/listener/listener.py"
TALKER="$ROOT/step7-experiment/talker/talker.py"

RUNS=3
CONDITIONS="fifo fq_codel pfifo_fast_noclsf pfifo_fast_clsf prio_clsf"
RATE_MBPS=20
FLOOD_MBPS=30
COUNT=10000
INTERVAL_MS=1
OUT="$HERE/runs/$(date +%Y%m%d-%H%M%S)"
TS_PORT=6000; BE_PORT=5001
SEND_NS=ns_send; RECV_NS=ns_recv; VS_HOST=vs_host; VR_HOST=vr_host; RECV_IP=10.10.2.2
PIN=/sys/fs/bpf/tsn_testbed
TS_CFG_MARK_DSCP=1

while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS=$2; shift 2 ;;
        --conditions) CONDITIONS=$2; shift 2 ;;
        --rate-mbps) RATE_MBPS=$2; shift 2 ;;
        --flood-mbps) FLOOD_MBPS=$2; shift 2 ;;
        --count) COUNT=$2; shift 2 ;;
        --interval-ms) INTERVAL_MS=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --quick) COUNT=3000; RUNS=1; shift ;;
        *) echo "unknown arg $1"; exit 2 ;;
    esac
done
[ "$(id -u)" = 0 ] || { echo "root 필요"; exit 1; }
for f in "$BPF_BUILD/ts_classifier.bpf.o" "$BPF_BUILD/prio_probe.bpf.o"; do
    [ -f "$f" ] || { echo "$f 없음 — make -C step6-ebpf"; exit 1; }
done
mkdir -p "$OUT"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── 커널 기능 감지 ───────────────────────────────────────────────────────
detect_qdisc() { tc qdisc replace dev $VR_HOST root $1 >/dev/null 2>&1 && { tc qdisc del dev $VR_HOST root >/dev/null 2>&1 || true; return 0; } || return 1; }
bash "$HERE/topology.sh" up
SHAPER=none
if detect_qdisc "tbf rate ${RATE_MBPS}mbit burst 32kbit latency 100ms"; then SHAPER=tbf; fi
HAVE_PRIO=0; detect_qdisc "prio bands 3" && HAVE_PRIO=1
log "kernel=$(uname -r) shaper=$SHAPER prio=$HAVE_PRIO"
if [ "$SHAPER" = none ]; then
    log "WARNING: tbf 없음 → 경합 없는 기능 검증 모드. latency 비교는 무의미함 (WSL2 커널 등)."
fi

# ── BPF 로드 (pinned; map 도 pin 해서 이름 충돌 없이 읽는다) ────────────────
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
rm -rf $PIN; mkdir -p $PIN
bpftool prog load "$BPF_BUILD/prio_probe.bpf.o"    $PIN/probe_in   pinmaps $PIN/probe_in_maps
bpftool prog load "$BPF_BUILD/prio_probe.bpf.o"    $PIN/probe_out  pinmaps $PIN/probe_out_maps
bpftool prog load "$BPF_BUILD/ts_classifier.bpf.o" $PIN/clsf       pinmaps $PIN/clsf_maps
# vs_host ingress: veth 를 건넌 직후의 skb->priority 관찰
tc filter add dev $VS_HOST ingress pref 10 bpf da pinned $PIN/probe_in
# vr_host egress: (분류기, 조건별로 pref 10 에 추가) → pref 20 프로브
tc filter add dev $VR_HOST egress pref 20 bpf da pinned $PIN/probe_out
python3 "$HERE/bpfmaps.py" set-ts-config $PIN/clsf_maps/ts_config 0 0 $TS_CFG_MARK_DSCP

read_hist() { python3 "$HERE/bpfmaps.py" dump-percpu "$1"; }

apply_condition() {   # $1 = condition
    local cond=$1
    tc filter del dev $VR_HOST egress pref 10 2>/dev/null || true
    tc qdisc del dev $VR_HOST root 2>/dev/null || true
    local inner
    case "$cond" in
        fifo)              inner="pfifo limit 1000" ;;
        fq_codel)          inner="fq_codel" ;;
        pfifo_fast_noclsf|pfifo_fast_clsf) inner="pfifo_fast" ;;
        prio_clsf|prio_noclsf) inner="prio bands 3" ;;
        *) echo "unknown condition $cond"; return 1 ;;
    esac
    if [ "$SHAPER" = tbf ]; then
        tc qdisc add dev $VR_HOST root handle 1: tbf rate ${RATE_MBPS}mbit burst 32kbit latency 200ms
        tc qdisc add dev $VR_HOST parent 1:1 handle 10: $inner
    else
        tc qdisc add dev $VR_HOST root handle 10: $inner
    fi
    case "$cond" in
        *_clsf) tc filter add dev $VR_HOST egress pref 10 bpf da pinned $PIN/clsf ;;
    esac
}

wait_file() { local f=$1 n=${2:-50}; while [ ! -f "$f" ] && [ $n -gt 0 ]; do sleep 0.1; n=$((n-1)); done; [ -f "$f" ]; }

run_one() {   # $1 = condition, $2 = run index
    local cond=$1 run=$2
    local dir="$OUT/$cond/run$run"; mkdir -p "$dir"
    apply_condition "$cond"
    local before_in before_out before_cnt
    before_in=$(read_hist $PIN/probe_in_maps/prio_hist)
    before_out=$(read_hist $PIN/probe_out_maps/prio_hist)
    before_cnt=$(python3 "$HERE/bpfmaps.py" counters $PIN/clsf_maps/ts_counters)

    ip netns exec $RECV_NS python3 "$HERE/udp_sink.py" --port $BE_PORT --stats-file "$dir/sink.json" &
    local sink_pid=$!
    ip netns exec $RECV_NS python3 "$LISTENER" --port $TS_PORT --interval $INTERVAL_MS --timeout 3 \
        --record-tos --ready-file "$dir/listener.ready" --output "$dir/results.csv" --quiet > "$dir/listener.log" 2>&1 &
    local listener_pid=$!
    wait_file "$dir/listener.ready" || { echo "listener 시작 실패"; cat "$dir/listener.log"; exit 1; }

    local dur; dur=$(python3 -c "print(int($COUNT*$INTERVAL_MS/1000)+6)")
    ip netns exec $SEND_NS python3 "$HERE/be_flood.py" --target $RECV_IP --port $BE_PORT \
        --rate-mbps $FLOOD_MBPS --size 1400 --duration $dur --stats-file "$dir/flood.json" > "$dir/flood.log" 2>&1 &
    local flood_pid=$!
    sleep 1.5      # 큐가 찰 시간
    ip netns exec $SEND_NS python3 "$TALKER" --target $RECV_IP --port $TS_PORT --interval $INTERVAL_MS \
        --count $COUNT --so-priority 6 --quiet --log "$dir/talker.csv" > "$dir/talker.log" 2>&1
    wait $flood_pid || true
    wait $listener_pid || true
    kill $sink_pid 2>/dev/null || true; wait $sink_pid 2>/dev/null || true

    tc -s qdisc show dev $VR_HOST > "$dir/qdisc.txt"
    python3 - "$dir" "$cond" "$run" "$before_in" "$before_out" "$before_cnt" \
        "$(read_hist $PIN/probe_in_maps/prio_hist)" "$(read_hist $PIN/probe_out_maps/prio_hist)" \
        "$(python3 "$HERE/bpfmaps.py" counters $PIN/clsf_maps/ts_counters)" \
        "$SHAPER" "$RATE_MBPS" "$FLOOD_MBPS" "$COUNT" "$INTERVAL_MS" <<'PY'
import json, sys, platform, os
d, cond, run = sys.argv[1], sys.argv[2], int(sys.argv[3])
b_in, b_out, b_cnt, a_in, a_out, a_cnt = (json.loads(x) for x in sys.argv[4:10])
shaper, rate, flood, count, interval = sys.argv[10:15]
delta = lambda a, b: {k: a.get(k, 0) - b.get(k, 0) for k in a}
meta = {
    "condition": cond, "run": run, "kernel": platform.release(), "shaper": shaper,
    "link_rate_mbps": float(rate), "flood_offered_mbps": float(flood),
    "ts_count": int(count), "ts_interval_ms": float(interval),
    "prio_hist_after_veth_ingress": delta(a_in, b_in),
    "prio_hist_at_nic_egress": delta(a_out, b_out),
    "ts_counters": delta(a_cnt, b_cnt),
}
for name in ("flood.json", "sink.json"):
    p = os.path.join(d, name)
    if os.path.exists(p):
        meta[name.split(".")[0]] = json.load(open(p))
json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=1)
print(f"  prio hist after veth: {meta['prio_hist_after_veth_ingress']}")
print(f"  prio hist at NIC egress: {meta['prio_hist_at_nic_egress']}")
print(f"  ts_counters: {meta['ts_counters']}")
PY
    cp "$dir/results.csv" "$OUT/${cond}_run${run}.csv" 2>/dev/null || log "결과 CSV 없음 ($cond run$run)"
    cp "$dir/meta.json" "$OUT/${cond}_run${run}.meta.json"
    grep -E "Latency|Jitter|TOS|손실" "$dir/listener.log" | sed 's/^/  /'
}

cleanup() {
    tc filter del dev $VR_HOST egress 2>/dev/null || true
    tc filter del dev $VS_HOST ingress 2>/dev/null || true
    bash "$HERE/topology.sh" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

for run in $(seq 1 $RUNS); do
    for cond in $CONDITIONS; do
        if [ "$HAVE_PRIO" = 0 ] && [[ "$cond" == prio_* ]]; then log "skip $cond (sch_prio 없음)"; continue; fi
        log "=== run $run / $cond ==="
        run_one "$cond" "$run"
    done
done
cat > "$OUT/README.txt" <<EOF
testbed run: $(date -Iseconds)
kernel: $(uname -r)   shaper: $SHAPER   link: ${RATE_MBPS} Mbit/s   flood: ${FLOOD_MBPS} Mbit/s
conditions: $CONDITIONS   runs: $RUNS   ts: ${COUNT} pkts @ ${INTERVAL_MS} ms
files: <condition>_run<k>.csv (listener), <condition>_run<k>.meta.json (probes/counters/qdisc)
EOF
log "done → $OUT"

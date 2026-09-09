#!/bin/bash
# =============================================================================
# test_tcx_chain.sh — tcx 체인 실행 순서 통합 테스트 (root, kernel >= 6.6)
#
# 증명하려는 것 (net/core/dev.c sch_handle_egress, v6.6+):
#   A) tcx 프로그램이 TC_ACT_OK 를 반환하면 legacy clsact 필터는 실행되지 않는다.
#      → Cilium(tcx, cil_to_netdev 가 OK 반환) 뒤에 `tc filter add ... bpf` 로 붙인
#        분류기는 한 번도 실행되지 않는다. (구 설계의 pkt_stats=0 의 진짜 원인)
#   B) 분류기를 BPF_F_BEFORE 로 tcx 체인 맨 앞에 붙이고 TC_ACT_UNSPEC(TCX_NEXT) 을
#      반환하면 분류기와 뒤의 프로그램 모두 실행된다.
#
# 사용: sudo make -C step6-ebpf test-tcx
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=build
TOOL=$BUILD/tcx_attach
NS=tsn_tcx_ns
V0=tcxv0
V1=tcxv1
PIN_DUMMY=/sys/fs/bpf/tsn_tcx_test_dummy
PIN_CLSF=/sys/fs/bpf/tsn_tcx_test_clsf

kver=$(uname -r | cut -d. -f1-2)
if [ "$(printf '%s\n' 6.6 "$kver" | sort -V | head -1)" != "6.6" ]; then
    echo "SKIP: kernel $kver < 6.6 — tcx 없음 (legacy clsact 만 존재)"
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo "root 필요: sudo make test-tcx"; exit 1; }
[ -x "$TOOL" ] || { echo "$TOOL 없음: make tools"; exit 1; }

cleanup() {
    ip netns del $NS 2>/dev/null || true
    ip link del $V0 2>/dev/null || true
    rm -f $PIN_DUMMY $PIN_CLSF
}
trap cleanup EXIT
cleanup

ip netns add $NS
ip link add $V0 type veth peer name $V1
ip link set $V1 netns $NS
ip addr add 10.99.0.1/24 dev $V0
ip link set $V0 up
ip netns exec $NS ip addr add 10.99.0.2/24 dev $V1
ip netns exec $NS ip link set $V1 up
ip netns exec $NS ip link set lo up

send_ts() {   # 호스트 → netns 로 UDP:6000 20개 (V0 egress 를 통과)
    python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for _ in range(20):
    s.sendto(b"x" * 64, ("10.99.0.2", 6000))
PY
    sleep 0.2
}

# map 이름 + key 로 per-cpu 합산 (같은 이름의 map 이 여럿이면 가장 최근 id)
map_key_sum() {
    local name=$1 key=$2 id
    id=$(bpftool -j map show | python3 -c "import sys,json; m=[x for x in json.load(sys.stdin) if x.get('name')=='$name']; print(m[-1]['id'] if m else '')")
    [ -n "$id" ] || { echo 0; return; }
    bpftool -j map dump id "$id" | python3 -c "
import sys, json

def to_int(v):
    # bpftool -j: BTF 가 있으면 'formatted' 에 정수, 없으면 ['0x00','0x01',...] (LE 바이트 배열)
    if isinstance(v, int):
        return v
    if isinstance(v, list):
        return int.from_bytes(bytes(int(b, 16) for b in v), 'little')
    return int(v)

tot = 0
for e in json.load(sys.stdin):
    fmt = e.get('formatted')
    src = fmt if fmt is not None else e
    if to_int(src['key']) != $key:
        continue
    for v in src.get('values') or [{'value': src.get('value', 0)}]:
        tot += to_int(v['value'])
print(tot)"
}

echo "── Phase A: tcx(dummy, TC_ACT_OK) + legacy clsact(ts_classifier)"
$TOOL attach $V0 $BUILD/tcx_dummy_ok.bpf.o $PIN_DUMMY egress after
tc qdisc add dev $V0 clsact
tc filter add dev $V0 egress bpf da obj $BUILD/ts_classifier.bpf.o sec tc
send_ts
a_dummy=$(map_key_sum dummy_hits 0)
a_ts=$(map_key_sum ts_counters 3)          # CNT_TS_UDP
echo "   dummy_hits=$a_dummy  ts_counters[TS_UDP]=$a_ts"
if [ "$a_dummy" -ge 20 ] && [ "$a_ts" -eq 0 ]; then
    echo "   PASS: tcx 프로그램이 OK 를 반환하면 legacy clsact 분류기는 실행되지 않는다"
else
    echo "   FAIL (기대: dummy>=20, ts=0)"; exit 1
fi
tc filter del dev $V0 egress
tc qdisc del dev $V0 clsact

echo "── Phase B: ts_classifier 를 BPF_F_BEFORE 로 tcx 맨 앞에 → 둘 다 실행"
$TOOL attach $V0 $BUILD/ts_classifier.bpf.o $PIN_CLSF egress before
$TOOL query $V0 egress
send_ts
b_dummy=$(map_key_sum dummy_hits 0)
b_ts=$(map_key_sum ts_counters 3)
echo "   dummy_hits=$b_dummy (delta $((b_dummy - a_dummy)))  ts_counters[TS_UDP]=$b_ts"
if [ $((b_dummy - a_dummy)) -ge 20 ] && [ "$b_ts" -ge 20 ]; then
    echo "   PASS: BEFORE + TCX_NEXT 로 분류기와 뒤 프로그램이 모두 실행된다"
else
    echo "   FAIL (기대: dummy delta>=20, ts>=20)"; exit 1
fi

echo "── Phase C: detach 후 체인이 비는지"
$TOOL detach $PIN_CLSF
$TOOL detach $PIN_DUMMY
$TOOL query $V0 egress
echo "ALL PASS"

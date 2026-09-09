#!/bin/bash
# =============================================================================
# topology.sh — 단일 호스트 netns 테스트베드 토폴로지 (K8s Pod ↔ veth ↔ host ↔ NIC 를 흉내)
#
#   ┌─ ns_send ─────┐            host netns                    ┌─ ns_recv ─────┐
#   │ talker        │ vs_ns ── vs_host ─(routing)─ vr_host ── vr_ns │ listener      │
#   │ be_flood      │ 10.10.1.2  10.10.1.1        10.10.2.1  10.10.2.2 │ udp_sink    │
#   └───────────────┘   ▲                            ▲          └───────────────┘
#          "Pod"        │ prio_probe(ingress):       │ ★ 물리 NIC 역할:
#                       │ veth 를 건넌 직후          │   clsact egress: ts_classifier + prio_probe
#                       │ skb->priority 관찰         │   root qdisc: tbf(병목) → {pfifo|fq_codel|pfifo_fast|prio}
#
#   vs_host ingress 의 prio_probe 는 "Pod 안에서 SO_PRIORITY=6 을 줘도 veth 를 건너면 0"
#   을 측정으로 보여 주고, vr_host egress 의 prio_probe 는 분류기 뒤에서 6 이 됨을 보여 준다.
#
# 사용: sudo bash topology.sh up | down | status
# =============================================================================
set -euo pipefail

NS_SEND=ns_send
NS_RECV=ns_recv
VS_NS=vs_ns;   VS_HOST=vs_host    # sender 측 veth 쌍
VR_NS=vr_ns;   VR_HOST=vr_host    # receiver 측 veth 쌍 (vr_host = "물리 NIC")
SEND_IP=10.10.1.2; SEND_GW=10.10.1.1
RECV_IP=10.10.2.2; RECV_GW=10.10.2.1
BPF_PIN_DIR=/sys/fs/bpf/tsn_testbed

up() {
    [ "$(id -u)" = 0 ] || { echo "root 필요"; exit 1; }
    down >/dev/null 2>&1 || true
    ip netns add $NS_SEND
    ip netns add $NS_RECV
    ip link add $VS_NS type veth peer name $VS_HOST
    ip link add $VR_NS type veth peer name $VR_HOST
    ip link set $VS_NS netns $NS_SEND
    ip link set $VR_NS netns $NS_RECV

    ip addr add $SEND_GW/24 dev $VS_HOST; ip link set $VS_HOST up
    ip addr add $RECV_GW/24 dev $VR_HOST; ip link set $VR_HOST up

    ip netns exec $NS_SEND ip addr add $SEND_IP/24 dev $VS_NS
    ip netns exec $NS_SEND ip link set $VS_NS up
    ip netns exec $NS_SEND ip link set lo up
    ip netns exec $NS_SEND ip route add default via $SEND_GW

    ip netns exec $NS_RECV ip addr add $RECV_IP/24 dev $VR_NS
    ip netns exec $NS_RECV ip link set $VR_NS up
    ip netns exec $NS_RECV ip link set lo up
    ip netns exec $NS_RECV ip route add default via $RECV_GW

    sysctl -qw net.ipv4.ip_forward=1
    sysctl -qw net.ipv4.conf.$VS_HOST.rp_filter=0 net.ipv4.conf.$VR_HOST.rp_filter=0 2>/dev/null || true
    # 1500B 미만 패킷만 쓰지만, GSO/GRO 가 타이밍을 흐리지 않도록 오프로드 해제
    for dev in $VS_HOST $VR_HOST; do ethtool -K $dev tso off gso off gro off >/dev/null 2>&1 || true; done
    ip netns exec $NS_SEND ethtool -K $VS_NS tso off gso off gro off >/dev/null 2>&1 || true
    ip netns exec $NS_RECV ethtool -K $VR_NS tso off gso off gro off >/dev/null 2>&1 || true

    tc qdisc add dev $VS_HOST clsact
    tc qdisc add dev $VR_HOST clsact
    mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
    mkdir -p $BPF_PIN_DIR
    echo "topology up: $NS_SEND($SEND_IP) -> host -> $NS_RECV($RECV_IP); bottleneck dev = $VR_HOST"
    ip netns exec $NS_SEND ping -c1 -W1 $RECV_IP >/dev/null && echo "connectivity OK" || { echo "ping 실패"; exit 1; }
}

down() {
    tc qdisc del dev $VR_HOST root 2>/dev/null || true
    tc qdisc del dev $VR_HOST clsact 2>/dev/null || true
    tc qdisc del dev $VS_HOST clsact 2>/dev/null || true
    ip link del $VS_HOST 2>/dev/null || true
    ip link del $VR_HOST 2>/dev/null || true
    ip netns del $NS_SEND 2>/dev/null || true
    ip netns del $NS_RECV 2>/dev/null || true
    rm -rf $BPF_PIN_DIR 2>/dev/null || true
    echo "topology down"
}

status() {
    ip netns list
    echo "--- $VR_HOST qdisc ---"; tc -s qdisc show dev $VR_HOST 2>/dev/null || true
    echo "--- $VR_HOST egress filters ---"; tc filter show dev $VR_HOST egress 2>/dev/null || true
    echo "--- $VS_HOST ingress filters ---"; tc filter show dev $VS_HOST ingress 2>/dev/null || true
    echo "--- pins ---"; ls -R $BPF_PIN_DIR 2>/dev/null || true
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo "usage: $0 up|down|status"; exit 2 ;;
esac

/* ingress.c (ig) — 호스트 물리 NIC ingress eBPF 프로그램
 *
 * 논문 Figure 1의 "ig" (ingress) eBPF 프로그램.
 *
 * 2026-06 감사: 수신측 프로그램은 두 가지 역할만 수행하도록 단순화.
 *   (1) 수신 패킷 카운트            → pkt_stats
 *   (2) jitter 측정용 타임스탬프 기록 → last_arrival
 * 제거된 것: VLAN/AVTP 파싱, 분류 분기, ring buffer 로깅, debug_stats,
 *           컴파일타임 디버그 매크로(→ 런타임 debug_level map).
 *
 * 최소 파싱: 이더넷→IP→UDP 경계 검사만 수행해 dport(=flow 식별)와
 *           수신 시각을 얻는다. 그 외 분류/필터링은 하지 않는다.
 *
 * TC attach 위치: 호스트 물리 NIC의 ingress (clsact qdisc)
 *
 * 디버그:
 *   통계:        sudo bpftool map dump name pkt_stats
 *   jitter 맵:   sudo bpftool map dump name last_arrival
 *   런타임 로그: sudo bpftool map update name debug_level key 0 0 0 0 value 4 0 0 0
 */
#include "common.h"

/* 마지막 수신 시각 기록 (jitter 계산용)
 *   key   = dst_port (실험 flow 식별)
 *   value = 직전 수신 timestamp (ns, CLOCK_MONOTONIC)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u16);
    __type(value, __u64);
} last_arrival SEC(".maps");

SEC("tc")
int ingress_prog(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    /* ── 최소 파싱 1: 이더넷 ── */
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_OK;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    /* ── 최소 파싱 2: IP ── */
    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return TC_ACT_OK;
    if (iph->ihl < 5)
        return TC_ACT_OK;
    if (iph->protocol != IPPROTO_UDP)
        return TC_ACT_OK;

    /* ── 최소 파싱 3: UDP ── */
    struct udphdr *udph = (void *)iph + (iph->ihl * 4);
    if ((void *)(udph + 1) > data_end)
        return TC_ACT_OK;

    __u16 dport = bpf_ntohs(udph->dest);
    __u64 now = bpf_ktime_get_ns();

    /* ── (1) 카운트 ── */
    stats_inc(STATS_TOTAL);
    if (dport == 5000)
        stats_inc(STATS_TSN);
    else
        stats_inc(STATS_BEST_EFF);

    /* ── (2) jitter 타임스탬프 기록 ── */
    __u64 *prev_ts = bpf_map_lookup_elem(&last_arrival, &dport);
    if (prev_ts) {
        __s64 jitter = (__s64)(now - *prev_ts) - 1000000LL; /* 예상 간격 1ms */
        if (jitter < 0)
            jitter = -jitter;
        DBG_TRACE("ig: port=%d jitter=%lld ns", dport, jitter);
    } else {
        DBG_INFO("ig: first pkt on port %d", dport);
    }
    bpf_map_update_elem(&last_arrival, &dport, &now, BPF_ANY);

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";

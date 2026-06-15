/* egress.c (eg) — 호스트 물리 NIC egress eBPF 프로그램
 *
 * 논문 Figure 1의 "eg" (egress) eBPF 프로그램.
 * underlay 네트워크로 나가는 패킷을 분류하여:
 *   1. skb->priority → TC class 매핑 확인 (prio/mqprio priomap과 일치)
 *   2. time-sensitive vs best-effort 패킷 카운트 (pkt_stats)
 *
 * 2026-06 감사 변경:
 *   - ring buffer 로깅(egress_log) 제거 — 유저스페이스 소비자가 없어 미사용.
 *   - debug_stats map 제거.
 *   - 컴파일타임 디버그 매크로 → 런타임 debug_level map (common.h).
 *
 * TC attach 위치: 호스트 물리 NIC의 egress (clsact qdisc)
 *
 * 디버그:
 *   런타임 레벨: sudo bpftool map update name debug_level key 0 0 0 0 value 4 0 0 0
 *   로그:        sudo cat /sys/kernel/debug/tracing/trace_pipe
 *   통계:        sudo bpftool map dump name pkt_stats
 */
#include "common.h"

/* skb->priority → TC class 매핑 (prio/mqprio priomap과 일치해야 함) */
static __always_inline __u8 priority_to_tc(__u8 prio)
{
    switch (prio) {
    case 3:  return TC_CLASS_HIGH;  /* tc0 */
    case 2:  return TC_CLASS_MED;   /* tc1 */
    default: return TC_CLASS_LOW;   /* tc2 */
    }
}

SEC("tc")
int egress_prog(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    /* ── 경계 검사 1: 이더넷 헤더 ── */
    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("eg: pkt too short for eth (len=%d)", skb->len);
        return TC_ACT_OK;  /* egress에서는 드롭하지 않고 통과 */
    }

    stats_inc(STATS_TOTAL);

    __u16 eth_proto = eth->h_proto;
    __u16 inner_proto = eth_proto;
    void *l3_hdr = (void *)(eth + 1);

    DBG_TRACE("eg: proto=0x%04x len=%d pri=%d",
              bpf_ntohs(eth_proto), skb->len, skb->priority);

    /* ── VLAN 태그 처리 ── */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {

        int pcp = get_vlan_pcp(skb);
        if (pcp >= 0) {
            skb->priority = pcp;
            DBG_INFO("eg: VLAN pcp=%d → priority=%d", pcp, pcp);
        }

        struct vlan_hdr {
            __be16 h_vlan_TCI;
            __be16 h_vlan_encapsulated_proto;
        } *vhdr = l3_hdr;

        if ((void *)(vhdr + 1) > data_end) {
            DBG_ERR("eg: pkt too short for vlan hdr");
            return TC_ACT_OK;
        }

        inner_proto = vhdr->h_vlan_encapsulated_proto;
        l3_hdr = (void *)(vhdr + 1);
    }

    /* ── IP 프로토콜 확인 ── */
    if (inner_proto != bpf_htons(ETH_P_IP)) {
        DBG_TRACE("eg: not IP (inner_proto=0x%04x)", bpf_ntohs(inner_proto));
        stats_inc(STATS_BEST_EFF);
        return TC_ACT_OK;
    }

    struct iphdr *iph = l3_hdr;

    /* ── 경계 검사 2: IP 헤더 ── */
    if ((void *)(iph + 1) > data_end) {
        DBG_ERR("eg: pkt too short for ip hdr");
        return TC_ACT_OK;
    }

    if (iph->ihl < 5) {
        DBG_ERR("eg: invalid ihl=%d", iph->ihl);
        return TC_ACT_OK;
    }

    /* ── UDP만 분류 ── */
    if (iph->protocol != IPPROTO_UDP) {
        DBG_TRACE("eg: IP proto=%d (not UDP)", iph->protocol);
        stats_inc(STATS_BEST_EFF);
        return TC_ACT_OK;
    }

    struct udphdr *udph = (void *)iph + (iph->ihl * 4);

    /* ── 경계 검사 3: UDP 헤더 ── */
    if ((void *)(udph + 1) > data_end) {
        DBG_ERR("eg: pkt too short for udp hdr (ihl=%d)", iph->ihl);
        return TC_ACT_OK;
    }

    __u16 dport = bpf_ntohs(udph->dest);
    __u8  tc_class = priority_to_tc(skb->priority);

    /* ── time-sensitive 분류 카운트 ── */
    if (dport == 5000 || skb->priority == TSN_VLAN_PRI_HIGH) {
        DBG_INFO("eg: TSN pkt dport=%d pri=%d tc=%d", dport, skb->priority, tc_class);
        stats_inc(STATS_TSN);
    } else {
        DBG_TRACE("eg: best-effort dport=%d tc=%d", dport, tc_class);
        stats_inc(STATS_BEST_EFF);
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";

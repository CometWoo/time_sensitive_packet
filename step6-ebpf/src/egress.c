/* egress.c (eg) — 호스트 물리 NIC egress eBPF 프로그램
 *
 * 논문 Figure 1의 "eg" (egress) eBPF 프로그램.
 * underlay 네트워크로 나가는 패킷에 대해:
 *   1. 패킷 정보 기록 (QoS 통계)
 *   2. 패킷 우선순위(skb->priority) 설정 → mqprio/taprio TC 매핑
 *   3. time-sensitive 패킷의 전송 시각(txtime) 설정 가능
 *
 * TC에 attach 위치: 호스트 물리 NIC의 egress (clsact qdisc)
 *
 * 디버그:
 *   빌드: make EXTRA_CFLAGS="-DDEBUG_LEVEL=4"
 *   로그: sudo cat /sys/kernel/debug/tracing/trace_pipe
 *   통계: sudo bpftool map dump name pkt_stats
 *   디버그통계: sudo bpftool map dump name debug_stats
 *   egress 로그: sudo bpftool map dump name egress_log
 */
#include "common.h"

/* 패킷 전송 로그 맵 (ring buffer) — 측정용 */
struct pkt_log {
    __u64 timestamp_ns;
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u16 pkt_len;
    __u8  priority;
    __u8  tc_class;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);  /* 256KB */
} egress_log SEC(".maps");

/* skb->priority → TC class 매핑 (mqprio map과 일치해야 함) */
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

    dbgstats_inc(DBGSTAT_PROG_ENTER);

    /* ── 경계 검사 1: 이더넷 헤더 ── */
    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("eg: pkt too short for eth (len=%d)", skb->len);
        dbgstats_inc(DBGSTAT_ETH_TOO_SHORT);
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
        } else {
            DBG_WARN("eg: VLAN tag present but pcp parse failed");
        }

        struct vlan_hdr {
            __be16 h_vlan_TCI;
            __be16 h_vlan_encapsulated_proto;
        } *vhdr = l3_hdr;

        /* ── 경계 검사: VLAN 헤더 ── */
        if ((void *)(vhdr + 1) > data_end) {
            DBG_ERR("eg: pkt too short for vlan hdr");
            dbgstats_inc(DBGSTAT_VLAN_PARSE_FAIL);
            return TC_ACT_OK;
        }

        inner_proto = vhdr->h_vlan_encapsulated_proto;
        l3_hdr = (void *)(vhdr + 1);
    }

    /* ── IP 프로토콜 확인 ── */
    if (inner_proto != bpf_htons(ETH_P_IP)) {
        DBG_TRACE("eg: not IP (inner_proto=0x%04x)", bpf_ntohs(inner_proto));
        dbgstats_inc(DBGSTAT_NOT_IP);
        return TC_ACT_OK;
    }

    struct iphdr *iph = l3_hdr;

    /* ── 경계 검사 2: IP 헤더 ── */
    if ((void *)(iph + 1) > data_end) {
        DBG_ERR("eg: pkt too short for ip hdr");
        dbgstats_inc(DBGSTAT_IP_TOO_SHORT);
        return TC_ACT_OK;
    }

    /* IHL 유효성 검사 */
    if (iph->ihl < 5) {
        DBG_ERR("eg: invalid ihl=%d", iph->ihl);
        dbgstats_inc(DBGSTAT_IHL_INVALID);
        return TC_ACT_OK;
    }

    /* ── UDP 패킷만 상세 로깅 ── */
    if (iph->protocol != IPPROTO_UDP) {
        DBG_TRACE("eg: IP proto=%d (not UDP)", iph->protocol);
        dbgstats_inc(DBGSTAT_NOT_UDP);
        return TC_ACT_OK;
    }

    struct udphdr *udph = (void *)iph + (iph->ihl * 4);

    /* ── 경계 검사 3: UDP 헤더 ── */
    if ((void *)(udph + 1) > data_end) {
        DBG_ERR("eg: pkt too short for udp hdr (ihl=%d)", iph->ihl);
        dbgstats_inc(DBGSTAT_UDP_TOO_SHORT);
        return TC_ACT_OK;
    }

    __u16 dport = bpf_ntohs(udph->dest);
    __u16 sport = bpf_ntohs(udph->source);

    /* ── ring buffer에 로그 기록 ── */
    struct pkt_log *log;
    log = bpf_ringbuf_reserve(&egress_log, sizeof(*log), 0);
    if (log) {
        log->timestamp_ns = bpf_ktime_get_ns();
        log->src_ip = iph->saddr;
        log->dst_ip = iph->daddr;
        log->src_port = sport;
        log->dst_port = dport;
        log->pkt_len = bpf_ntohs(iph->tot_len);
        log->priority = skb->priority;
        log->tc_class = priority_to_tc(skb->priority);
        bpf_ringbuf_submit(log, 0);

        DBG_TRACE("eg: logged UDP %d→%d len=%d tc=%d",
                  sport, dport, bpf_ntohs(iph->tot_len), log->tc_class);
    } else {
        /* ring buffer 공간 부족 — 소비자(userspace)가 늦거나 버퍼 크기 부족
         * 해결: max_entries 늘리거나, userspace에서 더 빨리 소비 */
        DBG_WARN("eg: ringbuf reserve failed (full?)");
        dbgstats_inc(DBGSTAT_RINGBUF_FAIL);
    }

    /* ── time-sensitive 패킷 통계 ── */
    if (dport == 5000 || skb->priority == TSN_VLAN_PRI_HIGH) {
        DBG_INFO("eg: TSN pkt dport=%d pri=%d", dport, skb->priority);
        stats_inc(STATS_TSN);
    } else {
        stats_inc(STATS_BEST_EFF);
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";

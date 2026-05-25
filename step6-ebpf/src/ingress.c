/* ingress.c (ig) — 호스트 물리 NIC ingress eBPF 프로그램
 *
 * 논문 Figure 1의 "ig" (ingress) eBPF 프로그램.
 * 물리 NIC으로 수신된 패킷에 대해:
 *   1. 수신 타임스탬프 기록 (latency/jitter 측정용)
 *   2. time-sensitive 패킷 식별 및 통계
 *   3. XDP 영역에서 처리하여 커널 스택 바이패스 효과
 *
 * TC에 attach 위치: 호스트 물리 NIC의 ingress (clsact qdisc)
 * 또는 XDP로 attach 가능 (더 빠르지만 기능 제한)
 *
 * 디버그:
 *   빌드: make EXTRA_CFLAGS="-DDEBUG_LEVEL=4"
 *   로그: sudo cat /sys/kernel/debug/tracing/trace_pipe
 *   통계: sudo bpftool map dump name pkt_stats
 *   디버그통계: sudo bpftool map dump name debug_stats
 *   ingress 로그: sudo bpftool map dump name ingress_log
 *   jitter 맵: sudo bpftool map dump name last_arrival
 */
#include "common.h"

/* 수신 패킷 로그 맵 */
struct rx_log {
    __u64 timestamp_ns;
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u16 pkt_len;
    __u8  priority;
    __u8  _pad;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} ingress_log SEC(".maps");

/* 마지막 수신 시각 기록 (jitter 계산용) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u16);     /* dst_port */
    __type(value, __u64);   /* last timestamp_ns */
} last_arrival SEC(".maps");

SEC("tc")
int ingress_prog(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    dbgstats_inc(DBGSTAT_PROG_ENTER);

    /* ── 경계 검사 1: 이더넷 헤더 ── */
    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("ig: pkt too short for eth (len=%d)", skb->len);
        dbgstats_inc(DBGSTAT_ETH_TOO_SHORT);
        return TC_ACT_OK;
    }

    stats_inc(STATS_TOTAL);

    __u16 eth_proto = eth->h_proto;
    void *l3_hdr = (void *)(eth + 1);

    DBG_TRACE("ig: proto=0x%04x len=%d", bpf_ntohs(eth_proto), skb->len);

    /* ── VLAN 태그 처리 ── */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {

        dbgstats_inc(DBGSTAT_VLAN_TAGGED);

        struct vlan_hdr {
            __be16 h_vlan_TCI;
            __be16 h_vlan_encapsulated_proto;
        } *vhdr = l3_hdr;

        if ((void *)(vhdr + 1) > data_end) {
            DBG_ERR("ig: pkt too short for vlan hdr");
            dbgstats_inc(DBGSTAT_VLAN_PARSE_FAIL);
            return TC_ACT_OK;
        }

        __u16 tci = bpf_ntohs(vhdr->h_vlan_TCI);
        int pcp = (tci >> 13) & 0x7;
        DBG_INFO("ig: VLAN tci=0x%04x pcp=%d", tci, pcp);

        eth_proto = vhdr->h_vlan_encapsulated_proto;
        l3_hdr = (void *)(vhdr + 1);
    }

    /* ── IP 프로토콜 확인 ── */
    if (eth_proto != bpf_htons(ETH_P_IP)) {
        DBG_TRACE("ig: not IP (proto=0x%04x)", bpf_ntohs(eth_proto));
        dbgstats_inc(DBGSTAT_NOT_IP);
        return TC_ACT_OK;
    }

    struct iphdr *iph = l3_hdr;

    /* ── 경계 검사 2: IP 헤더 ── */
    if ((void *)(iph + 1) > data_end) {
        DBG_ERR("ig: pkt too short for ip hdr");
        dbgstats_inc(DBGSTAT_IP_TOO_SHORT);
        return TC_ACT_OK;
    }

    /* IHL 유효성 검사 */
    if (iph->ihl < 5) {
        DBG_ERR("ig: invalid ihl=%d", iph->ihl);
        dbgstats_inc(DBGSTAT_IHL_INVALID);
        return TC_ACT_OK;
    }

    if (iph->protocol != IPPROTO_UDP) {
        DBG_TRACE("ig: not UDP (proto=%d)", iph->protocol);
        dbgstats_inc(DBGSTAT_NOT_UDP);
        return TC_ACT_OK;
    }

    struct udphdr *udph = (void *)iph + (iph->ihl * 4);

    /* ── 경계 검사 3: UDP 헤더 ── */
    if ((void *)(udph + 1) > data_end) {
        DBG_ERR("ig: pkt too short for udp (ihl=%d)", iph->ihl);
        dbgstats_inc(DBGSTAT_UDP_TOO_SHORT);
        return TC_ACT_OK;
    }

    __u64 now = bpf_ktime_get_ns();
    __u16 dport = bpf_ntohs(udph->dest);
    __u16 sport = bpf_ntohs(udph->source);

    /* ── ring buffer에 수신 로그 기록 ── */
    struct rx_log *log;
    log = bpf_ringbuf_reserve(&ingress_log, sizeof(*log), 0);
    if (log) {
        log->timestamp_ns = now;
        log->src_ip = iph->saddr;
        log->dst_ip = iph->daddr;
        log->src_port = sport;
        log->dst_port = dport;
        log->pkt_len = bpf_ntohs(iph->tot_len);
        log->priority = skb->priority;
        log->_pad = 0;
        bpf_ringbuf_submit(log, 0);

        DBG_TRACE("ig: logged UDP %d→%d len=%d", sport, dport, log->pkt_len);
    } else {
        DBG_WARN("ig: ringbuf reserve failed (full?)");
        dbgstats_inc(DBGSTAT_RINGBUF_FAIL);
    }

    /* ── jitter 계산을 위한 마지막 수신 시각 갱신 ── */
    __u64 *prev_ts = bpf_map_lookup_elem(&last_arrival, &dport);
    if (prev_ts) {
        __u64 delta = now - *prev_ts;
        /* 예상 간격: 1ms = 1,000,000ns
         * jitter = |delta - 1ms| */
        __s64 jitter = (__s64)delta - 1000000LL;
        if (jitter < 0) jitter = -jitter;

        DBG_TRACE("ig: port=%d delta=%llu jitter=%lld",
                  dport, delta, jitter);

        /* jitter가 비정상적으로 큰 경우 (>100ms) 경고 */
        if (jitter > 100000000LL) {
            DBG_WARN("ig: extreme jitter=%lldns on port %d",
                     jitter, dport);
        }
    } else {
        DBG_INFO("ig: first pkt on port %d", dport);
    }

    long ret = bpf_map_update_elem(&last_arrival, &dport, &now, BPF_ANY);
    if (ret != 0) {
        DBG_ERR("ig: map update failed ret=%ld", ret);
        dbgstats_inc(DBGSTAT_MAP_UPDATE_FAIL);
    }

    /* ── 통계 ── */
    if (dport == 5000 || skb->priority == TSN_VLAN_PRI_HIGH) {
        DBG_INFO("ig: TSN pkt dport=%d pri=%d", dport, skb->priority);
        stats_inc(STATS_TSN);
    } else {
        stats_inc(STATS_BEST_EFF);
    }

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";

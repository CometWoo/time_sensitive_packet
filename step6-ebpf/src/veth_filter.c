/* veth_filter.c (vef) — veth 인터페이스 패킷 필터
 *
 * 논문 Figure 1의 "vef" (veth-filter) eBPF 프로그램.
 * 컨테이너에서 나가는 패킷이 vnic을 통과한 직후,
 * netfilter에 도달하기 전에 실행됨.
 *
 * 동작:
 *   1. 패킷 헤더에서 VLAN PCP 또는 AVTP 프로토콜 확인
 *   2. time-sensitive 패킷 → TC_ACT_OK (underlay 네트워크로 전달)
 *   3. 일반 패킷 → TC_ACT_UNSPEC (기존 overlay 경로 유지)
 *
 * TC에 attach 위치: 컨테이너의 veth peer (호스트 측)의 ingress
 *
 * 디버그:
 *   빌드: make EXTRA_CFLAGS="-DDEBUG_LEVEL=4"
 *   로그: sudo cat /sys/kernel/debug/tracing/trace_pipe
 *   통계: sudo bpftool map dump name pkt_stats
 *   디버그통계: sudo bpftool map dump name debug_stats
 */
#include "common.h"

/* time-sensitive 패킷 판별 기준:
 * - VLAN PCP가 TSN_VLAN_PRI_HIGH(3)인 패킷
 * - EtherType이 AVTP(0x22F0)인 패킷
 * - 또는 특정 UDP 포트를 사용하는 패킷 (실험용)
 */
#define TSN_UDP_PORT 5000  /* talker/listener 실험용 포트 */

SEC("tc")
int veth_filter(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    dbgstats_inc(DBGSTAT_PROG_ENTER);

    /* ── 경계 검사 1: 이더넷 헤더 ── */
    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("vef: pkt too short for eth hdr (len=%d)", skb->len);
        dbgstats_inc(DBGSTAT_ETH_TOO_SHORT);
        stats_inc(STATS_DROPPED);
        return TC_ACT_UNSPEC;
    }

    stats_inc(STATS_TOTAL);

    __u16 eth_proto = eth->h_proto;
    DBG_TRACE("vef: proto=0x%04x len=%d", bpf_ntohs(eth_proto), skb->len);

    /* ── Case 1: AVTP 프로토콜 — 무조건 time-sensitive ── */
    if (eth_proto == bpf_htons(ETH_P_AVTP)) {
        DBG_INFO("vef: AVTP pkt detected → TSN (tc0)");
        dbgstats_inc(DBGSTAT_AVTP_PKT);
        stats_inc(STATS_TSN);
        skb->priority = TSN_VLAN_PRI_HIGH;
        return TC_ACT_OK;
    }

    /* ── Case 2: VLAN 태그 패킷 — PCP 기반 분류 ── */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {

        int pcp = get_vlan_pcp(skb);  /* common.h에서 디버그 로그 포함 */

        if (pcp < 0) {
            /* VLAN 헤더 파싱 실패 — 이미 get_vlan_pcp()에서 로그됨 */
            DBG_WARN("vef: vlan pcp parse failed, pass as best-effort");
            stats_inc(STATS_BEST_EFF);
            return TC_ACT_UNSPEC;
        }

        skb->priority = pcp;
        DBG_INFO("vef: VLAN pkt pcp=%d", pcp);

        if (pcp == TSN_VLAN_PRI_HIGH) {
            DBG_INFO("vef: VLAN PCP=3 → TSN (tc0)");
            dbgstats_inc(DBGSTAT_TSN_BY_PCP);
            stats_inc(STATS_TSN);
            return TC_ACT_OK;
        }

        stats_inc(STATS_BEST_EFF);
        return TC_ACT_UNSPEC;
    }

    /* ── Case 3: 비태그 IP/UDP 패킷 — 포트 기반 분류 (실험용) ──
     * 실제 TSN은 VLAN 태그를 사용하지만,
     * VM 환경에서 VLAN 설정이 복잡할 수 있으므로
     * UDP 포트 기반 대안 제공
     */
    if (eth_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *iph = (void *)(eth + 1);

        /* ── 경계 검사 2: IP 헤더 ── */
        if ((void *)(iph + 1) > data_end) {
            DBG_ERR("vef: pkt too short for ip hdr");
            dbgstats_inc(DBGSTAT_IP_TOO_SHORT);
            stats_inc(STATS_BEST_EFF);
            return TC_ACT_UNSPEC;
        }

        /* IHL(IP Header Length) 유효성 검사: 최소 5 (20바이트) */
        if (iph->ihl < 5) {
            DBG_ERR("vef: invalid ihl=%d (expected >=5)", iph->ihl);
            dbgstats_inc(DBGSTAT_IHL_INVALID);
            stats_inc(STATS_BEST_EFF);
            return TC_ACT_UNSPEC;
        }

        if (iph->protocol == IPPROTO_UDP) {
            /* ── 경계 검사 3: UDP 헤더 ──
             * ihl*4 = 실제 IP 헤더 크기 (옵션 포함)
             * BPF verifier는 변수 오프셋 접근 시 경계 검사 필수
             */
            struct udphdr *udph = (void *)iph + (iph->ihl * 4);
            if ((void *)(udph + 1) > data_end) {
                DBG_ERR("vef: pkt too short for udp hdr (ihl=%d)", iph->ihl);
                dbgstats_inc(DBGSTAT_UDP_TOO_SHORT);
                stats_inc(STATS_BEST_EFF);
                return TC_ACT_UNSPEC;
            }

            __u16 dport = bpf_ntohs(udph->dest);
            DBG_TRACE("vef: UDP dport=%d", dport);

            if (dport == TSN_UDP_PORT) {
                DBG_INFO("vef: UDP port %d → TSN (tc0)", dport);
                dbgstats_inc(DBGSTAT_TSN_BY_PORT);
                stats_inc(STATS_TSN);
                skb->priority = TSN_VLAN_PRI_HIGH;
                return TC_ACT_OK;
            }
        } else {
            DBG_TRACE("vef: IP proto=%d (not UDP)", iph->protocol);
            dbgstats_inc(DBGSTAT_NOT_UDP);
        }
    } else {
        DBG_TRACE("vef: unknown ethertype=0x%04x", bpf_ntohs(eth_proto));
        dbgstats_inc(DBGSTAT_UNKNOWN_PROTO);
    }

    stats_inc(STATS_BEST_EFF);
    return TC_ACT_UNSPEC;
}

char _license[] SEC("license") = "GPL";

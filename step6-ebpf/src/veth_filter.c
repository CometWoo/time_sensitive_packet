/* veth_filter.c (vef) — veth 인터페이스 패킷 카운터/분류기
 *
 * 논문 Figure 1의 "vef" (veth-filter) eBPF 프로그램.
 * 컨테이너에서 나가는 패킷이 호스트측 veth(lxc<hash>)로 진입한 직후 실행.
 *
 * 2026-06 감사 (pkt_stats 0 문제 대응):
 *   - 본 프로그램은 이제 **항상 TC_ACT_UNSPEC** 을 반환하는 "안전한 카운터"다.
 *     이유: Cilium 과 공존하려면 tcx 체인에서 Cilium(cil_from_container)보다
 *     먼저 실행되어야 하는데(아래 attach 설명), 만약 TC_ACT_OK 를 반환하면
 *     tcx 가 그 verdict 을 채택해 **Cilium 이 스킵되어 Pod 네트워킹이 깨진다**.
 *     UNSPEC 을 반환하면 카운트만 하고 다음 프로그램(Cilium)으로 진행한다.
 *     → 우리가 먼저 실행되든(카운트됨) 나중이든(스킵되어 무해) 양쪽 모두 안전.
 *   - skb->priority 는 더 이상 건드리지 않는다. 우선순위는 talker 의
 *     SO_PRIORITY=3 + prio qdisc(band 0) 가 담당하므로 vef 의 설정은 불필요하며,
 *     Cilium 이전 단계에서 패킷을 수정하지 않는 편이 안전하다.
 *   - debug_stats / ring buffer 제거. 디버그는 런타임 debug_level map.
 *
 * attach (deploy-experiment.sh setup_ebpf):
 *   기본은 legacy clsact(`tc filter ... ingress`). kernel >= 6.6 + Cilium tcx
 *   환경에서 카운터를 찍으려면 tcx_ingress 로 Cilium 보다 앞에 붙여야 한다
 *   (BPF_F_BEFORE). bpftool 로 시도하며, 실패 시 clsact 로 폴백한다.
 *
 * 디버그:
 *   런타임 레벨: sudo bpftool map update name debug_level key 0 0 0 0 value 4 0 0 0
 *   통계:        sudo bpftool map dump name pkt_stats
 */
#include "common.h"

#define TSN_UDP_PORT 5000  /* talker/listener 실험용 포트 */

SEC("tc")
int veth_filter(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    /* ── 경계 검사: 이더넷 헤더 ── */
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_UNSPEC;  /* 카운터 — 항상 다음 프로그램으로 진행 */

    stats_inc(STATS_TOTAL);

    __u16 eth_proto = eth->h_proto;

    /* ── AVTP → time-sensitive ── */
    if (eth_proto == bpf_htons(ETH_P_AVTP)) {
        DBG_INFO("vef: AVTP pkt → TSN");
        stats_inc(STATS_TSN);
        return TC_ACT_UNSPEC;
    }

    /* ── VLAN 태그 → PCP 기반 분류 ── */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {
        int pcp = get_vlan_pcp(skb);
        if (pcp == TSN_VLAN_PRI_HIGH) {
            DBG_INFO("vef: VLAN PCP=3 → TSN");
            stats_inc(STATS_TSN);
        } else {
            stats_inc(STATS_BEST_EFF);
        }
        return TC_ACT_UNSPEC;
    }

    /* ── 비태그 IP/UDP → 포트 기반 분류 (plain UDP 실험 트래픽) ── */
    if (eth_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *iph = (void *)(eth + 1);
        if ((void *)(iph + 1) > data_end) {
            stats_inc(STATS_BEST_EFF);
            return TC_ACT_UNSPEC;
        }
        if (iph->ihl >= 5 && iph->protocol == IPPROTO_UDP) {
            struct udphdr *udph = (void *)iph + (iph->ihl * 4);
            if ((void *)(udph + 1) > data_end) {
                stats_inc(STATS_BEST_EFF);
                return TC_ACT_UNSPEC;
            }
            if (bpf_ntohs(udph->dest) == TSN_UDP_PORT) {
                DBG_INFO("vef: UDP port %d → TSN", TSN_UDP_PORT);
                stats_inc(STATS_TSN);
                return TC_ACT_UNSPEC;
            }
        }
    }

    stats_inc(STATS_BEST_EFF);
    return TC_ACT_UNSPEC;
}

char _license[] SEC("license") = "GPL";

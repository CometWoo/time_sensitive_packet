/* xdp_vlan_avtp.c — XDP 레벨 VLAN/AVTP 지원 프로그램
 *
 * 논문: "we enhance Cilium's functionality by adding support for
 *        vlan802.3 and avtp in the XDP program"
 *
 * XDP(eXpress Data Path)는 드라이버 수준에서 패킷을 처리하여
 * 커널 네트워크 스택 진입 전에 고속 분류/필터링 수행.
 * TC보다 먼저 실행되므로 latency 감소 효과.
 *
 * 동작:
 *   1. VLAN 802.1Q/802.1AD 태그 패킷의 PCP 확인
 *   2. IEEE 1722 AVTP(EtherType 0x22F0) 프로토콜 감지
 *   3. time-sensitive 패킷 → XDP_PASS (커널 스택으로 진행, TC에서 처리)
 *   4. 일반 패킷 → XDP_PASS (변경 없이 통과)
 *   5. 잘못된 패킷 → XDP_DROP (선택적)
 *
 * Attach 위치: 호스트 물리 NIC의 XDP hook
 *   ip link set dev eth0 xdpgeneric obj build/xdp_vlan_avtp.bpf.o sec xdp
 *
 * ⚠️ VM 제한:
 *   - virtio-net은 native XDP 미지원 → xdpgeneric 모드 사용 (성능 이점 없음)
 *   - 물리 NIC(i210, i225 등)에서만 native XDP로 실제 성능 향상
 *
 * 디버그:
 *   빌드: make DEBUG=4
 *   로그: sudo cat /sys/kernel/debug/tracing/trace_pipe
 *   통계: sudo bpftool map dump name xdp_stats
 */
#include "common.h"

/* XDP 전용 통계 맵 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 8);
    __type(key, __u32);
    __type(value, __u64);
} xdp_stats SEC(".maps");

#define XDPSTAT_TOTAL         0
#define XDPSTAT_VLAN_TAGGED   1
#define XDPSTAT_AVTP          2
#define XDPSTAT_TSN_PASS      3
#define XDPSTAT_BEST_EFFORT   4
#define XDPSTAT_DROP          5
#define XDPSTAT_PARSE_ERROR   6

static __always_inline void xdpstats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&xdp_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}

SEC("xdp")
int xdp_vlan_avtp_prog(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;

    xdpstats_inc(XDPSTAT_TOTAL);

    /* ── 경계 검사: 이더넷 헤더 ── */
    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("xdp: pkt too short for eth");
        xdpstats_inc(XDPSTAT_PARSE_ERROR);
        return XDP_DROP;
    }

    __u16 eth_proto = eth->h_proto;

    /* ══════════════════════════════════════════
     * Case 1: IEEE 1722 AVTP (EtherType 0x22F0)
     * 논문: "adding support for avtp"
     * AVTP는 L2 프로토콜이므로 IP 파싱 불필요
     * ══════════════════════════════════════════ */
    if (eth_proto == bpf_htons(ETH_P_AVTP)) {
        DBG_INFO("xdp: AVTP pkt detected (0x22F0) → PASS");
        xdpstats_inc(XDPSTAT_AVTP);
        xdpstats_inc(XDPSTAT_TSN_PASS);
        /* XDP에서는 skb가 없으므로 priority 설정 불가.
         * TC 프로그램(vef/eg)이 이후에 priority를 설정함.
         * XDP의 역할: 빠른 분류 + 불필요한 패킷 조기 드롭 */
        return XDP_PASS;
    }

    /* ══════════════════════════════════════════
     * Case 2: VLAN 802.1Q / 802.1AD
     * 논문: "adding support for vlan802.3"
     * IEEE 802.3은 VLAN 태그를 포함하는 이더넷 프레임
     * ══════════════════════════════════════════ */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {

        xdpstats_inc(XDPSTAT_VLAN_TAGGED);

        /* VLAN 헤더 파싱 */
        struct vlan_hdr {
            __be16 h_vlan_TCI;
            __be16 h_vlan_encapsulated_proto;
        } *vhdr = (void *)(eth + 1);

        if ((void *)(vhdr + 1) > data_end) {
            DBG_ERR("xdp: VLAN hdr too short");
            xdpstats_inc(XDPSTAT_PARSE_ERROR);
            return XDP_DROP;
        }

        __u16 tci = bpf_ntohs(vhdr->h_vlan_TCI);
        int pcp = (tci >> 13) & 0x7;
        __u16 inner_proto = vhdr->h_vlan_encapsulated_proto;

        DBG_TRACE("xdp: VLAN tci=0x%04x pcp=%d inner=0x%04x",
                  tci, pcp, bpf_ntohs(inner_proto));

        /* VLAN 내부에 AVTP가 있을 수도 있음 (802.1Q + AVTP) */
        if (inner_proto == bpf_htons(ETH_P_AVTP)) {
            DBG_INFO("xdp: VLAN+AVTP pkt (pcp=%d) → PASS", pcp);
            xdpstats_inc(XDPSTAT_AVTP);
            xdpstats_inc(XDPSTAT_TSN_PASS);
            return XDP_PASS;
        }

        /* PCP 기반 분류 */
        if (pcp == TSN_VLAN_PRI_HIGH) {
            DBG_INFO("xdp: VLAN pcp=%d → TSN PASS", pcp);
            xdpstats_inc(XDPSTAT_TSN_PASS);
        } else {
            DBG_TRACE("xdp: VLAN pcp=%d → best-effort PASS", pcp);
            xdpstats_inc(XDPSTAT_BEST_EFFORT);
        }

        return XDP_PASS;
    }

    /* ══════════════════════════════════════════
     * Case 3: 일반 패킷 (IP 등) → 통과
     * ══════════════════════════════════════════ */
    xdpstats_inc(XDPSTAT_BEST_EFFORT);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";

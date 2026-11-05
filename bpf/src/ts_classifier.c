// SPDX-License-Identifier: GPL-2.0
/*
 * ts_classifier: 호스트 NIC egress 에서 TS 패킷에 skb->priority 와 DSCP 를 붙인다.
 *
 * 컨테이너 안에서 준 priority 는 veth 를 건널 때 ____dev_forward_skb() 가 0 으로 지운다
 * (include/linux/netdevice.h). 그래서 분류는 호스트 쪽, qdisc 에 들어가기 직전에 한다.
 *
 * kernel >= 6.6 에서는 tcx 프로그램이 TC_ACT_UNSPEC 이 아닌 값을 돌려주면 sch_handle_egress()
 * 가 legacy tc 필터를 건너뛴다. Cilium 처럼 TC_ACT_OK 를 돌려주는 tcx 프로그램이 이미 있는
 * NIC 에서는 tools/tcx_attach 로 체인 맨 앞(BPF_F_BEFORE)에 붙인다. 이 프로그램은 항상
 * TC_ACT_UNSPEC(= TCX_NEXT)을 돌려주므로 뒤 프로그램도 그대로 돈다.
 *
 * TS 판별: AVTP EtherType, 바깥 VLAN 태그 PCP >= 5, IPv4/UDP 목적지 포트 6000 또는
 * ts_udp_ports map 에 넣은 포트. TS 가 아니면 priority 를 건드리지 않는다.
 *
 *   tc filter add dev $IF egress bpf da obj build/ts_classifier.bpf.o sec tc
 *   tools/tcx_attach attach $IF build/ts_classifier.bpf.o /sys/fs/bpf/ts_clsf egress before
 */

#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include "ts_common.h"

char _license[] SEC("license") = "GPL";

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct ts_config);
} ts_config SEC(".maps");

/* 추가 TS 포트. key 는 호스트 바이트 오더 u16 */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 64);
	__type(key, __u16);
	__type(value, __u8);
} ts_udp_ports SEC(".maps");

/* CPU 별로 세고 사용자 공간에서 더한다. 원자 연산이 필요 없다 */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, CNT_MAX);
	__type(key, __u32);
	__type(value, __u64);
} ts_counters SEC(".maps");

static __always_inline void count(__u32 idx)
{
	__u64 *v = bpf_map_lookup_elem(&ts_counters, &idx);

	if (v)
		(*v)++;
}

struct vlan_hdr {
	__be16 tci;
	__be16 encap_proto;
};

struct parse_result {
	__u32 reason;   /* enum ts_counter */
	__u32 ip_off;   /* IPv4 헤더 오프셋 (0 = IPv4 아님) */
};

/*
 * TS 면 1. pr->reason 에 카운터 인덱스를 남긴다.
 * VLAN 은 QinQ 까지 2겹만 본다. 루프를 펼쳐야 verifier 가 오프셋 범위를 안다.
 */
static __always_inline int classify(struct __sk_buff *skb, const struct ts_config *cfg,
				    struct parse_result *pr)
{
	void *data     = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;
	struct ethhdr *eth = data;
	__u32 off = sizeof(*eth);
	__be16 proto;
	__u8 pcp = 0;
	int has_pcp = 0;

	if ((void *)(eth + 1) > data_end) {
		pr->reason = CNT_PARSE_SHORT;
		return 0;
	}
	proto = eth->h_proto;

	/* 드라이버가 태그를 skb 메타데이터로 떼어 낸 경우 */
	if (skb->vlan_present) {
		pcp = (skb->vlan_tci >> 13) & 0x7;
		has_pcp = 1;
	}

	/* 패킷에 남은 태그. 스위치가 보는 건 바깥 태그의 PCP 다. */
#pragma unroll
	for (int i = 0; i < 2; i++) {
		struct vlan_hdr *vh;

		if (proto != bpf_htons(ETH_P_8021Q) && proto != bpf_htons(ETH_P_8021AD))
			break;
		vh = data + off;
		if ((void *)(vh + 1) > data_end) {
			pr->reason = CNT_PARSE_SHORT;
			return 0;
		}
		if (!has_pcp) {
			pcp = (bpf_ntohs(vh->tci) >> 13) & 0x7;
			has_pcp = 1;
		}
		proto = vh->encap_proto;
		off += sizeof(*vh);
	}

	/* AVTP 는 L2 프레임이라 여기서 끝 */
	if (proto == bpf_htons(AVTP_ETHERTYPE)) {
		pr->reason = CNT_TS_AVTP;
		return 1;
	}

	/* PCP 로 TS 가 돼도 IPv4 면 DSCP 를 찍어야 하니 ip_off 를 계속 찾는다 */
	if (has_pcp && pcp >= TS_VLAN_PCP_MIN)
		pr->reason = CNT_TS_PCP;

	if (proto == bpf_htons(ETH_P_IP)) {
		struct iphdr *ip = data + off;
		__u32 ihl;

		if ((void *)(ip + 1) > data_end) {
			if (pr->reason != CNT_TS_PCP)
				pr->reason = CNT_PARSE_SHORT;
			return pr->reason == CNT_TS_PCP;
		}
		if (ip->version != 4)
			goto done;
		ihl = ip->ihl * 4;              /* 옵션 포함 헤더 길이 */
		if (ihl < sizeof(*ip))
			goto done;
		/* 단편은 일반 패킷으로 둔다(ip_is_fragment() 와 같은 판정). UDP 헤더는 첫 단편에만
		 * 있어서, 포트로 나누면 한 데이터그램의 조각이 서로 다른 band 로 갈라진다. */
		if (ip->frag_off & bpf_htons(TS_IP_MF | TS_IP_OFFSET))
			goto done;
		pr->ip_off = off;

		if (ip->protocol == IPPROTO_UDP) {
			struct udphdr *udp = data + off + ihl;
			__u16 dport;

			if ((void *)(udp + 1) > data_end)
				goto done;
			dport = bpf_ntohs(udp->dest);
			if (!(cfg->flags & TS_CFG_DISABLE_UDP_DEFAULT) &&
			    dport == TS_DEFAULT_UDP_PORT) {
				if (pr->reason != CNT_TS_PCP)
					pr->reason = CNT_TS_UDP;
				return 1;
			}
			if (bpf_map_lookup_elem(&ts_udp_ports, &dport)) {
				if (pr->reason != CNT_TS_PCP)
					pr->reason = CNT_TS_UDP;
				return 1;
			}
		}
	}
done:
	if (pr->reason == CNT_TS_PCP)
		return 1;
	pr->reason = CNT_NORMAL;
	return 0;
}

/*
 * DSCP 를 바꿨으면 1, 이미 같으면 0, 실패하면 -1. ECN 2비트는 그대로 둔다.
 * TOS 는 헤더 첫 16비트 워드의 아래 바이트라서 그 워드만으로 체크섬을 증분 갱신한다(RFC 1624).
 */
static __always_inline int mark_dscp(struct __sk_buff *skb, __u32 ip_off, __u8 dscp)
{
	__u8 hdr[2];
	__u8 old_tos, new_tos;
	__u16 old_w, new_w;

	if (bpf_skb_load_bytes(skb, ip_off, hdr, sizeof(hdr)) < 0)
		return -1;
	old_tos = hdr[1];
	new_tos = (__u8)((dscp << 2) | (old_tos & 0x3));
	if (new_tos == old_tos)
		return 0;

	__builtin_memcpy(&old_w, hdr, 2);
	hdr[1] = new_tos;
	__builtin_memcpy(&new_w, hdr, 2);

	if (bpf_l3_csum_replace(skb, ip_off + offsetof(struct iphdr, check),
				old_w, new_w, sizeof(__u16)) < 0)
		return -1;
	if (bpf_skb_store_bytes(skb, ip_off + 1, &new_tos, 1, 0) < 0)
		return -1;
	return 1;
}

SEC("tc")
int ts_classifier(struct __sk_buff *skb)
{
	__u32 zero = 0;
	struct ts_config cfg = {};
	struct ts_config *p = bpf_map_lookup_elem(&ts_config, &zero);
	struct parse_result pr = {};

	if (p)
		cfg = *p;

	if (!classify(skb, &cfg, &pr)) {
		count(pr.reason);
		return TC_ACT_UNSPEC;          /* priority 그대로 다음 프로그램으로 */
	}

	skb->priority = cfg.priority ? cfg.priority : TS_DEFAULT_PRIORITY;
	count(pr.reason);

	if ((cfg.flags & TS_CFG_MARK_DSCP) && pr.ip_off) {
		__u8 dscp = (__u8)(cfg.dscp ? cfg.dscp : TS_DEFAULT_DSCP) & 0x3f;

		if (mark_dscp(skb, pr.ip_off, dscp) > 0)
			count(CNT_DSCP_MARKED);
	}

	return TC_ACT_UNSPEC;                  /* TCX_NEXT: 뒤 tcx 프로그램도 돈다 */
}

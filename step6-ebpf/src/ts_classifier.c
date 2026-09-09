// SPDX-License-Identifier: GPL-2.0
/*
 * ts_classifier.c — 호스트 물리 NIC egress 의 time-sensitive 패킷 분류기
 * ---------------------------------------------------------------------------
 * 어디에 붙는가 (설계 결정: docs/adr/0003-classify-at-host-nic-egress.md):
 *   호스트 netns 의 **물리 NIC egress** hook. 패킷이 qdisc 에 enqueue 되기 직전
 *   (__dev_queue_xmit → sch_handle_egress → __dev_xmit_skb) 에 실행되므로,
 *   여기서 설정한 skb->priority 를 prio / pfifo_fast / mqprio 가 그대로 본다.
 *
 *   Pod 내부(eth0 egress)나 SO_PRIORITY 로 설정한 priority 는 veth 를 건너는 순간
 *   ____dev_forward_skb() 가 `skb->priority = 0` 으로 지워 버린다
 *   (include/linux/netdevice.h: v5.15 L4140, v6.8 L4110). 컨테이너 안에서 무엇을
 *   하든 호스트 qdisc 는 priority 0 만 본다 — 분류는 반드시 호스트 쪽, qdisc 직전.
 *
 * Cilium(tcx) 과의 공존:
 *   kernel >= 6.6 에서 Cilium 은 tcx 로 붙고, cil_to_netdev 가 TC_ACT_OK 를 반환하면
 *   legacy clsact 필터는 실행되지 않는다 (net/core/dev.c sch_handle_egress:
 *   tcx_run() 결과가 TC_ACT_UNSPEC 이 아니면 tc_run() 을 건너뜀).
 *   → 이 프로그램은 tcx 체인의 **맨 앞(BPF_F_BEFORE)** 에 붙이고(tools/tcx_attach.c)
 *     TC_ACT_UNSPEC(= TCX_NEXT) 을 반환해 Cilium 프로그램이 이어서 실행되게 한다.
 *   legacy clsact(kernel < 6.6) 에서도 UNSPEC 은 "다음 필터로 계속" 이라 안전하다.
 *
 * 하는 일:
 *   1. TS 판별: AVTP EtherType(0x22F0) | 802.1Q/802.1ad 외곽 태그 PCP >= 5 |
 *      IPv4/UDP 목적지 포트 == 6000(기본) 또는 ts_udp_ports map 에 등록된 포트
 *   2. TS 면 skb->priority = cfg.priority (기본 6). **TS 가 아니면 건드리지 않는다**
 *      (다른 애플리케이션이 설정한 priority 를 지우지 않기 위해 — ADR-0004).
 *   3. (옵션) TS 이고 IPv4 이면 DSCP 재기록 + IPv4 헤더 체크섬 증분 갱신
 *      → 물리 패브릭 스위치가 큐/PFC 클래스로 매핑할 수 있는 유일한 신호.
 *   4. PERCPU 카운터로 분류 사유별 통계 (bpftool map dump name ts_counters)
 *
 * 빌드/테스트: make -C step6-ebpf && sudo make -C step6-ebpf test
 * 로드 (legacy clsact):
 *   tc qdisc add dev $IF clsact
 *   tc filter add dev $IF egress bpf da obj build/ts_classifier.bpf.o sec tc
 * 로드 (tcx, Cilium 앞):
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

/* ── maps ───────────────────────────────────────────────────────────────── */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct ts_config);
} ts_config SEC(".maps");

/* 런타임에 추가하는 TS UDP 목적지 포트 (호스트 바이트 오더 u16 → 1) */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 64);
	__type(key, __u16);
	__type(value, __u8);
} ts_udp_ports SEC(".maps");

/* PERCPU: 원자 연산 없이 코어별 증가 → 사용자 공간에서 합산 */
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
 * 반환: 1 = TS 패킷, 0 = 일반 패킷.  pr->reason 에 분류 사유(카운터 인덱스) 기록.
 *
 * verifier 규칙: 모든 헤더 접근 전에 (ptr + 1) > data_end 검사.
 * VLAN 태그는 최대 2겹(802.1ad QinQ) 까지만 본다 — 루프 언롤로 오프셋을 상수화.
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

	/* 드라이버가 VLAN 태그를 skb 메타데이터로 뺀 경우 (vlan_present) */
	if (skb->vlan_present) {
		pcp = (skb->vlan_tci >> 13) & 0x7;
		has_pcp = 1;
	}

	/* 인라인 VLAN 태그 (802.1Q / 802.1ad). 외곽 태그의 PCP 가 스위치가 보는 값. */
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

	/* 분류 1: AVTP (IEEE 1722) — L2 프레임, IP 아님 */
	if (proto == bpf_htons(AVTP_ETHERTYPE)) {
		pr->reason = CNT_TS_AVTP;
		return 1;
	}

	/* 분류 2: VLAN PCP >= 5. IP 라면 DSCP 마킹을 위해 ip_off 도 계속 찾는다. */
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
		ihl = ip->ihl * 4;              /* 4-bit 필드 → 0..60, 옵션 포함 길이 */
		if (ihl < sizeof(*ip))
			goto done;
		pr->ip_off = off;

		/* 분류 3: UDP 목적지 포트 */
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
 * IPv4 DSCP 재기록. 반환: 1 = 변경함, 0 = 이미 같은 값, <0 = 실패
 *
 * TOS 바이트는 IPv4 헤더 첫 16-bit 워드(version/IHL | TOS)의 하위 바이트.
 * 헤더 체크섬은 bpf_l3_csum_replace 로 해당 워드만 증분 갱신한다
 * (RFC 1624 방식 — 전체 재계산 불필요). ECN 비트(하위 2bit)는 보존.
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
		return TC_ACT_UNSPEC;          /* 일반 패킷: priority 그대로, 다음 프로그램으로 */
	}

	skb->priority = cfg.priority ? cfg.priority : TS_DEFAULT_PRIORITY;
	count(pr.reason);

	if ((cfg.flags & TS_CFG_MARK_DSCP) && pr.ip_off) {
		__u8 dscp = (__u8)(cfg.dscp ? cfg.dscp : TS_DEFAULT_DSCP) & 0x3f;

		if (mark_dscp(skb, pr.ip_off, dscp) > 0)
			count(CNT_DSCP_MARKED);
	}

	return TC_ACT_UNSPEC;                  /* TCX_NEXT: Cilium 등 뒤 프로그램 계속 실행 */
}

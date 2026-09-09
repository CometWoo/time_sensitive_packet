// SPDX-License-Identifier: GPL-2.0
/*
 * prio_probe.c — skb->priority 히스토그램 프로브
 *
 * 목적: "Pod 안에서 SO_PRIORITY=6 을 설정해도 veth 를 건너면 0 이 된다" 를
 *       추측이 아니라 **측정**으로 보이기 위한 관찰 도구.
 *
 * 사용: 호스트측 veth(lxc* / veth-s) ingress 와 물리 NIC egress 양쪽에 붙이고
 *       bpftool map dump name prio_hist 로 값 분포를 비교한다.
 *         tc qdisc add dev veth-s clsact
 *         tc filter add dev veth-s ingress bpf da obj build/prio_probe.bpf.o sec tc
 *
 * 반환 TC_ACT_UNSPEC: 관찰만 하고 패킷 처리에는 관여하지 않는다.
 */
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

char _license[] SEC("license") = "GPL";

#define PRIO_HIST_BUCKETS 16   /* priority 0..14, 15 = "15 이상" (TC_H_MAJ 형식 등) */

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, PRIO_HIST_BUCKETS);
	__type(key, __u32);
	__type(value, __u64);
} prio_hist SEC(".maps");

SEC("tc")
int prio_probe(struct __sk_buff *skb)
{
	__u32 idx = skb->priority;
	__u64 *v;

	if (idx >= PRIO_HIST_BUCKETS)
		idx = PRIO_HIST_BUCKETS - 1;
	v = bpf_map_lookup_elem(&prio_hist, &idx);
	if (v)
		(*v)++;
	return TC_ACT_UNSPEC;
}

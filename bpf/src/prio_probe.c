// SPDX-License-Identifier: GPL-2.0
/*
 * prio_probe: 지나가는 패킷의 skb->priority 를 히스토그램으로 센다. 패킷은 건드리지 않는다.
 *
 * 테스트베드는 veth 를 막 건넌 지점(vs_host ingress)과 NIC 역할의 vr_host egress 에 붙여서,
 * 송신 소켓이 SO_PRIORITY 6 을 줘도 veth 뒤에서는 0 이라는 걸 숫자로 확인한다.
 *
 *   tc filter add dev $IF ingress bpf da obj build/prio_probe.bpf.o sec tc
 */
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

char _license[] SEC("license") = "GPL";

#define PRIO_HIST_BUCKETS 16   /* 0..14, 마지막 칸은 15 이상(classid 형식 priority 포함) */

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

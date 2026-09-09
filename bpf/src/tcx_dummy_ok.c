// SPDX-License-Identifier: GPL-2.0
/*
 * tcx_dummy_ok.c — Cilium 의 cil_to_netdev 처럼 "TC_ACT_OK 를 반환하는 tcx 프로그램" 흉내
 *
 * 용도 (tests/test_tcx_chain.sh, kernel >= 6.6 전용):
 *   1) 이 프로그램을 tcx egress 에 붙인 뒤 legacy clsact 필터를 붙이면
 *      clsact 필터가 **실행되지 않음** 을 카운터로 증명한다
 *      (sch_handle_egress: tcx_run() != TC_ACT_UNSPEC → tc_run() 스킵).
 *   2) ts_classifier 를 BPF_F_BEFORE 로 앞에 붙이면 둘 다 실행됨을 증명한다.
 */
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

char _license[] SEC("license") = "GPL";

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} dummy_hits SEC(".maps");

SEC("tc")
int tcx_dummy_ok(struct __sk_buff *skb)
{
	__u32 zero = 0;
	__u64 *v = bpf_map_lookup_elem(&dummy_hits, &zero);

	if (v)
		(*v)++;
	return TC_ACT_OK;   /* 체인 종료: 뒤에 오는 tcx / legacy clsact 프로그램은 실행되지 않는다 */
}

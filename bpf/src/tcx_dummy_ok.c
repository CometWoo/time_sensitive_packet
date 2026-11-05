// SPDX-License-Identifier: GPL-2.0
/*
 * tcx_dummy_ok: TC_ACT_OK 를 돌려주는 tcx 프로그램. tests/test_tcx_chain.sh 에서 Cilium 의
 * cil_to_netdev 자리를 대신해 두 가지를 확인한다.
 *   1) 이 프로그램 뒤에 붙인 legacy tc 필터는 실행되지 않는다.
 *   2) ts_classifier 를 BPF_F_BEFORE 로 앞에 붙이면 둘 다 실행된다.
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
	return TC_ACT_OK;   /* 체인을 여기서 끝낸다 */
}

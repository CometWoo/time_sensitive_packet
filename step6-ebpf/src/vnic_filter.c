// SPDX-License-Identifier: GPL-2.0
/*
 * vnic_filter.c
 * --------------------------------------------------------------
 * eBPF TC egress 패킷 분류 프로그램 (단일 프로그램 설계)
 *
 * 동작:
 *   1. Pod 내부 eth0의 TC egress hook에서 호출됨
 *      (Cilium tcx가 가로채기 전 지점이라 카운터가 확실히 찍힘)
 *   2. 패킷 헤더를 검사하여 시간 민감(TS) 패킷 판별
 *      - AVTP EtherType (0x22F0)
 *      - VLAN PCP >= 5
 *      - UDP destination port == 6000 (실험용)
 *   3. TS 패킷이면 skb->priority = 6 (prio 기본 priomap → band 0)
 *   4. BPF MAP에 패킷 카운터 누적 (key 0=일반, key 1=TS)
 *
 * 빌드 (make -C step6-ebpf):
 *   clang -O2 -g -target bpf -D__TARGET_ARCH_x86 \
 *         -I/usr/include -I/usr/include/x86_64-linux-gnu \
 *         -c src/vnic_filter.c -o build/vnic_filter.bpf.o
 *
 * 로드 (Pod eth0, netns 내부 — step6-ebpf/attach-vnic.sh 가 자동화):
 *   sudo nsenter -t $PID -n -- tc qdisc add dev eth0 clsact
 *   sudo nsenter -t $PID -n -- tc filter add dev eth0 egress \
 *       bpf da obj build/vnic_filter.bpf.o sec tc
 *
 * 카운터 확인:
 *   sudo nsenter -t $PID -n -- bpftool map dump name pkt_count
 * --------------------------------------------------------------
 */

#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* TS 패킷 판별 기준 */
#define AVTP_ETHERTYPE  0x22F0   /* IEEE 1722 AVTP */
#define TS_VLAN_PCP_MIN 5        /* VLAN PCP 5,6,7 = TS 트래픽 */
#define TS_UDP_PORT     6000     /* 실험용 TS UDP 포트 */
#define TS_PRIORITY     6        /* skb->priority: prio 기본 priomap → band 0 */

/* 패킷 카운터 MAP
 *   key 0: 일반 패킷 누적 수
 *   key 1: TS 패킷 누적 수
 *
 * 사용자 공간에서 확인:
 *   sudo bpftool map dump name pkt_count
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 2);
	__type(key, __u32);
	__type(value, __u64);
} pkt_count SEC(".maps");

#define CNT_NORMAL 0
#define CNT_TS     1


/*
 * TS 패킷 판별 함수
 * 반환: 1 = TS 패킷, 0 = 일반 패킷
 *
 * BPF verifier 요구사항:
 *   - 모든 메모리 접근 전 경계 검사(data + N > data_end) 필수
 *   - __always_inline으로 점프 분석 가능하게 함
 */
static __always_inline int is_ts_pkt(struct __sk_buff *skb)
{
	void *data     = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;

	/* Ethernet 헤더 경계 검사 */
	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end)
		return 0;

	__u16 proto = bpf_ntohs(eth->h_proto);

	/* 분류 1: AVTP EtherType */
	if (proto == AVTP_ETHERTYPE)
		return 1;

	/* 분류 2: VLAN 802.1Q PCP >= 5 */
	if (proto == ETH_P_8021Q) {
		__u16 *tci = (void *)(eth + 1);
		if ((void *)(tci + 1) > data_end)
			return 0;
		/* TCI 16bits: PCP(3) | DEI(1) | VID(12) */
		__u8 pcp = (bpf_ntohs(*tci) >> 13) & 0x7;
		if (pcp >= TS_VLAN_PCP_MIN)
			return 1;
	}

	/* 분류 3: UDP destination port == 6000 */
	if (proto == ETH_P_IP) {
		struct iphdr *ip = (void *)(eth + 1);
		if ((void *)(ip + 1) > data_end)
			return 0;

		if (ip->protocol != IPPROTO_UDP)
			return 0;

		/* IP 헤더 길이는 옵션 포함 ihl * 4 바이트 */
		struct udphdr *udp = (void *)ip + (ip->ihl * 4);
		if ((void *)(udp + 1) > data_end)
			return 0;

		if (bpf_ntohs(udp->dest) == TS_UDP_PORT)
			return 1;
	}

	return 0;
}


/*
 * 메인 진입점: TC egress 클래시파이어
 *
 * SEC("tc"):
 *   - ELF 섹션명. tc filter 명령에서 'sec tc'로 참조됨
 *
 * 반환 TC_ACT_OK:
 *   - 패킷을 정상 통과시킴 (drop 아님)
 */
SEC("tc")
int vnic_filter(struct __sk_buff *skb)
{
	__u32 key;
	__u64 *cnt;

	if (is_ts_pkt(skb)) {
		/* TS 패킷: 우선순위 6 (prio qdisc 기본 priomap에 의해 band 0) */
		skb->priority = TS_PRIORITY;
		key = CNT_TS;
	} else {
		/* 일반 패킷 */
		skb->priority = 0;
		key = CNT_NORMAL;
	}

	/* 카운터 원자적 증가 (멀티코어 race condition 방지) */
	cnt = bpf_map_lookup_elem(&pkt_count, &key);
	if (cnt)
		__sync_fetch_and_add(cnt, 1);

	return TC_ACT_OK;
}

/* GPL 라이선스 선언 (GPL-only helper 사용을 위해 필수) */
char _license[] SEC("license") = "GPL";

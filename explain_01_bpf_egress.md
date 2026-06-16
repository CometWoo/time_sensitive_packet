# explain_01 — vnic_filter BPF 프로그램 (Pod eth0 egress 분류 + pkt_count)

> 대상 파일: `step6-ebpf/src/vnic_filter.c` (단일 eBPF 프로그램)
> Pod 내부 eth0 의 TC egress hook 에 attach 되어 TS 패킷을 분류하고,
> `skb->priority=6` 을 설정하며 `pkt_count` 카운터를 증가시킨다.

## 코드

```c
// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define AVTP_ETHERTYPE  0x22F0   /* IEEE 1722 AVTP */
#define TS_VLAN_PCP_MIN 5        /* VLAN PCP 5,6,7 = TS */
#define TS_UDP_PORT     6000     /* 실험용 TS UDP 포트 */
#define TS_PRIORITY     6        /* prio 기본 priomap → band 0 */

/* 패킷 카운터: key 0 = 일반, key 1 = TS */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u64);
} pkt_count SEC(".maps");

static __always_inline int is_ts_pkt(struct __sk_buff *skb)
{
    void *data     = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return 0;
    __u16 proto = bpf_ntohs(eth->h_proto);

    if (proto == AVTP_ETHERTYPE) return 1;                     /* 분류 1: AVTP */

    if (proto == ETH_P_8021Q) {                               /* 분류 2: VLAN PCP>=5 */
        __u16 *tci = (void *)(eth + 1);
        if ((void *)(tci + 1) > data_end) return 0;
        __u8 pcp = (bpf_ntohs(*tci) >> 13) & 0x7;
        if (pcp >= TS_VLAN_PCP_MIN) return 1;
    }

    if (proto == ETH_P_IP) {                                  /* 분류 3: UDP:6000 */
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end) return 0;
        if (ip->protocol != IPPROTO_UDP) return 0;
        struct udphdr *udp = (void *)ip + (ip->ihl * 4);
        if ((void *)(udp + 1) > data_end) return 0;
        if (bpf_ntohs(udp->dest) == TS_UDP_PORT) return 1;
    }
    return 0;
}

SEC("tc")
int vnic_filter(struct __sk_buff *skb)
{
    __u32 key;
    __u64 *cnt;
    if (is_ts_pkt(skb)) { skb->priority = TS_PRIORITY; key = 1; }
    else                { skb->priority = 0;           key = 0; }
    cnt = bpf_map_lookup_elem(&pkt_count, &key);
    if (cnt) __sync_fetch_and_add(cnt, 1);
    return TC_ACT_OK;
}
char _license[] SEC("license") = "GPL";
```

빌드/로드:
```bash
make -C step6-ebpf                       # → build/vnic_filter.bpf.o
# Pod eth0(netns 내부)에 attach (attach-vnic.sh 가 자동화):
sudo nsenter -t $PID -n -- tc qdisc add dev eth0 clsact
sudo nsenter -t $PID -n -- tc filter add dev eth0 egress bpf da obj build/vnic_filter.bpf.o sec tc
```

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **vnic_filter BPF 프로그램(Pod eth0 egress 분류 + pkt_count)** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `vnic_filter(struct __sk_buff *skb)`: TC egress 콜백. 입력은 Pod eth0 로 나가는 패킷, 출력은 `TC_ACT_OK`. TS면 priority 6 설정 + pkt_count[1]++, 아니면 priority 0 + pkt_count[0]++.
   - `is_ts_pkt()`: AVTP(0x22F0) / VLAN PCP≥5 / UDP dport 6000 세 가지 분류 기준과 각 경계 검사.
   - `pkt_count` (ARRAY[2], u64): key 0=일반, key 1=TS. `__sync_fetch_and_add` 원자적 증가.
   - `struct ethhdr/iphdr/udphdr`, `skb->data/data_end/priority` 의미.
2. 코드, 문법 부분 설명
   - `(void *)(long)skb->data` 형변환, `(void *)(eth+1) > data_end` 경계 검사가 BPF verifier 에 필수인 이유.
   - `bpf_ntohs`, VLAN TCI 의 `(tci>>13)&0x7` PCP 추출, `ip->ihl*4` 가변 헤더 길이.
   - `SEC("tc")`, `__always_inline`, `char _license[]="GPL"`.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `step6-ebpf/attach-vnic.sh` 가 `crictl`+`nsenter` 로 talker Pod eth0 egress 에 attach.
   - `deploy-experiment.sh run_experiment()` 가 talker Pod Running 시 attach-vnic.sh 를 호출.
   - 설정한 priority 6 이 enp0s3 의 `prio` qdisc(기본 priomap → band 0)로 이어진다.
   - talker.py 도 `SO_PRIORITY=6` 을 설정하므로 priority 6 은 이중 보장된다.
4. 실험 결과(pkt_count, jitter)와 이 코드의 연결 고리
   - 왜 Pod eth0 egress(netns 내부)에 붙여야 Cilium tcx 우회 없이 pkt_count 가 찍히는지.
   - priority 6 + prio qdisc(band 0)가 baseline(fq_codel) 대비 p99 latency/jitter 를 어떻게 줄이는지. (jitter 측정 자체는 listener.py 가 담당)

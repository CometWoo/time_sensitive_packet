# explain_01 — egress BPF 프로그램 (TC 분류 + pkt_stats)

> 대상 파일: `step6-ebpf/src/egress.c` (+ 공유 헤더 `step6-ebpf/src/common.h`)
> 논문 Figure 1의 "eg" 프로그램. 호스트 물리 NIC egress(clsact)에 attach되어
> 송신 패킷을 분류하고 `pkt_stats` 카운터를 증가시킨다.

## 코드

```c
/* egress.c (eg) — 호스트 물리 NIC egress eBPF 프로그램 */
#include "common.h"

/* skb->priority → TC class 매핑 (prio/mqprio priomap과 일치해야 함) */
static __always_inline __u8 priority_to_tc(__u8 prio)
{
    switch (prio) {
    case 3:  return TC_CLASS_HIGH;  /* tc0 */
    case 2:  return TC_CLASS_MED;   /* tc1 */
    default: return TC_CLASS_LOW;   /* tc2 */
    }
}

SEC("tc")
int egress_prog(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("eg: pkt too short for eth (len=%d)", skb->len);
        return TC_ACT_OK;
    }
    stats_inc(STATS_TOTAL);

    __u16 eth_proto = eth->h_proto;
    __u16 inner_proto = eth_proto;
    void *l3_hdr = (void *)(eth + 1);

    DBG_TRACE("eg: proto=0x%04x len=%d pri=%d",
              bpf_ntohs(eth_proto), skb->len, skb->priority);

    /* VLAN 태그 처리 */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {
        int pcp = get_vlan_pcp(skb);
        if (pcp >= 0) {
            skb->priority = pcp;
            DBG_INFO("eg: VLAN pcp=%d → priority=%d", pcp, pcp);
        }
        struct vlan_hdr {
            __be16 h_vlan_TCI;
            __be16 h_vlan_encapsulated_proto;
        } *vhdr = l3_hdr;
        if ((void *)(vhdr + 1) > data_end) {
            DBG_ERR("eg: pkt too short for vlan hdr");
            return TC_ACT_OK;
        }
        inner_proto = vhdr->h_vlan_encapsulated_proto;
        l3_hdr = (void *)(vhdr + 1);
    }

    if (inner_proto != bpf_htons(ETH_P_IP)) {
        DBG_TRACE("eg: not IP (inner_proto=0x%04x)", bpf_ntohs(inner_proto));
        stats_inc(STATS_BEST_EFF);
        return TC_ACT_OK;
    }

    struct iphdr *iph = l3_hdr;
    if ((void *)(iph + 1) > data_end) {
        DBG_ERR("eg: pkt too short for ip hdr");
        return TC_ACT_OK;
    }
    if (iph->ihl < 5) {
        DBG_ERR("eg: invalid ihl=%d", iph->ihl);
        return TC_ACT_OK;
    }
    if (iph->protocol != IPPROTO_UDP) {
        DBG_TRACE("eg: IP proto=%d (not UDP)", iph->protocol);
        stats_inc(STATS_BEST_EFF);
        return TC_ACT_OK;
    }

    struct udphdr *udph = (void *)iph + (iph->ihl * 4);
    if ((void *)(udph + 1) > data_end) {
        DBG_ERR("eg: pkt too short for udp hdr (ihl=%d)", iph->ihl);
        return TC_ACT_OK;
    }

    __u16 dport = bpf_ntohs(udph->dest);
    __u8  tc_class = priority_to_tc(skb->priority);

    if (dport == 5000 || skb->priority == TSN_VLAN_PRI_HIGH) {
        DBG_INFO("eg: TSN pkt dport=%d pri=%d tc=%d", dport, skb->priority, tc_class);
        stats_inc(STATS_TSN);
    } else {
        DBG_TRACE("eg: best-effort dport=%d tc=%d", dport, tc_class);
        stats_inc(STATS_BEST_EFF);
    }
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
```

> 참고: 2026-06 감사로 이 프로그램에서 ring buffer 로깅(egress_log)과 debug_stats
> map이 제거되었고, 컴파일타임 DEBUG_LEVEL 매크로는 런타임 `debug_level` BPF map
> 기반(common.h의 `DBG_*` 매크로 → `dbg_level()`)으로 통일되었다.

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **egress BPF 프로그램(TC 분류 + pkt_stats)** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `egress_prog(struct __sk_buff *skb)`: TC(clsact) egress 훅 콜백. 입력은 송신 패킷의 `__sk_buff`, 출력은 TC action(`TC_ACT_OK`). 이더넷→(VLAN)→IP→UDP 헤더를 경계 검사하며 파싱하고 `pkt_stats`를 증가시키는 흐름을 설명해줘.
   - `priority_to_tc(__u8 prio)`: `skb->priority`(SO_PRIORITY로 설정됨)를 TC class(tc0/tc1/tc2)로 매핑. prio 3→tc0, 2→tc1, 그 외→tc2가 왜 이렇게 매핑되는지(논문 Table I) 설명해줘.
   - `struct __sk_buff`, `struct ethhdr/iphdr/udphdr`: 각 필드(`data`, `data_end`, `priority`, `h_proto`, `ihl`, `protocol`, `dest`)의 의미.
   - `pkt_stats` map: `STATS_TOTAL/TSN/BEST_EFF` 인덱스의 의미.
2. 코드, 문법 부분 설명
   - `void *data = (void *)(long)skb->data;` 형변환이 왜 필요한지, BPF verifier의 경계 검사(`(void *)(eth+1) > data_end`)가 왜 필수인지.
   - `bpf_htons/bpf_ntohs`(바이트 오더), `iph->ihl * 4`(가변 IP 헤더 길이) 계산.
   - `SEC("tc")`, `__always_inline`, `char _license[] SEC("license")="GPL"`의 역할.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `common.h`의 `stats_inc()`, `get_vlan_pcp()`, `DBG_*`(런타임 debug_level) 매크로, `pkt_stats` map 정의를 공유한다.
   - `deploy-experiment.sh`의 `setup_ebpf()`가 `tc filter add dev <PHYS_IF> egress bpf da obj egress.bpf.o`로 attach한다.
   - 송신 측 `talker.py`가 `SO_PRIORITY=3`을 설정해 `skb->priority=3`이 되고, 이 프로그램은 그것을 읽어 분류한다(직접 바꾸지 않음).
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - 이 프로그램의 `STATS_TSN` 카운트가 실제로 0이 아닐 조건(Cilium tcx 우회와의 관계)을 설명하고, latency/jitter 측정 자체는 listener.py가 담당하며 이 프로그램은 "TSN 패킷이 NIC egress까지 분류되어 도달했는가"의 가시성을 제공한다는 점을 연결해줘.

# explain_02 — ingress BPF 프로그램 (수신 카운트 + 타임스탬프)

> 대상 파일: `step6-ebpf/src/ingress.c` (+ 공유 헤더 `step6-ebpf/src/common.h`)
> 논문 Figure 1의 "ig" 프로그램. 수신측 호스트 물리 NIC ingress(clsact)에 attach.
> 2026-06 감사로 두 가지 역할만 남도록 단순화됨: (1) pkt_stats 카운트, (2) jitter용 타임스탬프.

## 코드

```c
/* ingress.c (ig) — 호스트 물리 NIC ingress eBPF 프로그램 (단순화됨) */
#include "common.h"

/* 마지막 수신 시각 기록 (jitter 계산용)
 *   key   = dst_port, value = 직전 수신 timestamp(ns, CLOCK_MONOTONIC) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u16);
    __type(value, __u64);
} last_arrival SEC(".maps");

SEC("tc")
int ingress_prog(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    /* 최소 파싱 1: 이더넷 */
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    /* 최소 파싱 2: IP */
    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return TC_ACT_OK;
    if (iph->ihl < 5)
        return TC_ACT_OK;
    if (iph->protocol != IPPROTO_UDP)
        return TC_ACT_OK;

    /* 최소 파싱 3: UDP */
    struct udphdr *udph = (void *)iph + (iph->ihl * 4);
    if ((void *)(udph + 1) > data_end)
        return TC_ACT_OK;

    __u16 dport = bpf_ntohs(udph->dest);
    __u64 now = bpf_ktime_get_ns();

    /* (1) 카운트 */
    stats_inc(STATS_TOTAL);
    if (dport == 5000)
        stats_inc(STATS_TSN);
    else
        stats_inc(STATS_BEST_EFF);

    /* (2) jitter 타임스탬프 기록 */
    __u64 *prev_ts = bpf_map_lookup_elem(&last_arrival, &dport);
    if (prev_ts) {
        __s64 jitter = (__s64)(now - *prev_ts) - 1000000LL; /* 예상 간격 1ms */
        if (jitter < 0)
            jitter = -jitter;
        DBG_TRACE("ig: port=%d jitter=%lld ns", dport, jitter);
    } else {
        DBG_INFO("ig: first pkt on port %d", dport);
    }
    bpf_map_update_elem(&last_arrival, &dport, &now, BPF_ANY);

    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
```

> 참고: 단순화 전 ingress.c에는 VLAN/AVTP 파싱, ring buffer(ingress_log), debug_stats가
> 있었으나 모두 제거되었다. 최소 파싱(이더넷→IP→UDP)은 dport(=flow 식별)와 수신 시각을
> 얻기 위한 것이며, 분류/필터링은 하지 않는다.

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **ingress BPF 프로그램(수신 카운트 + 타임스탬프)** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `ingress_prog(struct __sk_buff *skb)`: TC(clsact) ingress 훅 콜백. 입력은 수신 패킷, 출력은 항상 `TC_ACT_OK`(통과). 두 가지 역할(카운트, 타임스탬프)만 수행하는 이유를 설명해줘.
   - `last_arrival` (BPF_MAP_TYPE_HASH): key=dst_port(u16), value=직전 수신 시각(ns). 왜 ARRAY가 아니라 HASH를 쓰는지(동적 포트 키), max_entries 64의 의미.
   - `bpf_ktime_get_ns()`: 어떤 시계(CLOCK_MONOTONIC)를 반환하는지, talker의 `time.time_ns()`(CLOCK_REALTIME)와 epoch이 달라 직접 빼면 안 되는 이유.
   - `pkt_stats` map의 `STATS_TOTAL/TSN/BEST_EFF` 의미.
2. 코드, 문법 부분 설명
   - `__s64 jitter = (__s64)(now - *prev_ts) - 1000000LL;` 에서 1000000LL(=1ms ns)을 빼는 의미와 부호 처리(`if (jitter < 0) jitter = -jitter;`).
   - `bpf_map_lookup_elem`/`bpf_map_update_elem`(BPF_ANY)의 동작과 반환값 처리.
   - 최소 파싱에서 경계 검사(`> data_end`)가 verifier 통과에 왜 필수인지.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `common.h`의 `stats_inc()`, `pkt_stats`, `DBG_*`(runtime debug_level)를 공유한다.
   - `deploy-experiment.sh setup_ebpf receiver`가 `tc filter add dev <PHYS_IF> ingress bpf da obj ingress.bpf.o`로 attach한다.
   - 같은 jitter를 userspace `listener.py`도 독립적으로 계산한다(이중 측정). 둘의 차이가 무엇을 의미하는지.
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - 이 프로그램의 `last_arrival` 기반 커널-사이드 jitter가 listener.py의 userspace jitter와 어떻게 교차검증되는지, 그리고 Cilium tcx 우회로 인해 이 카운터가 0일 수 있는 조건을 설명해줘.

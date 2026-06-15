/* common.h — 공통 헤더 및 상수 정의
 * 논문의 eBPF 프로그램: veth-filter(vef), egress(eg), ingress(ig)
 *
 * 2026-06 감사 변경:
 *   - 실제 커널/libbpf 헤더 사용 (stub-headers 제거). 빌드에는
 *     linux-libc-dev(또는 linux-headers-*) + libbpf-dev 가 필요하다.
 *       sudo apt install clang make libbpf-dev linux-libc-dev
 *   - 컴파일타임 DEBUG_LEVEL 매크로 제거 → 런타임 debug_level BPF map 으로 단일화.
 *   - debug_stats map 제거 (실험과 무관한 파싱/분류 통계).
 *
 * 빌드: make -C step6-ebpf
 */
#ifndef __TSN_COMMON_H__
#define __TSN_COMMON_H__

/* ── 실제 커널 UAPI 헤더 ── (이전 stub-headers 대체)
 *   linux/*  : linux-libc-dev (/usr/include/linux, /usr/include/<arch>-linux-gnu)
 *   bpf/*    : libbpf-dev      (/usr/include/bpf)
 */
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* ============================================================
 * VLAN priority → TC 매핑 (논문 Table I)
 * ============================================================ */
#define TSN_VLAN_PRI_HIGH   3   /* time-sensitive → tc0 */
#define TSN_VLAN_PRI_MED    2   /* medium → tc1 */
#define TSN_VLAN_PRI_LOW    0   /* best-effort → tc2 */

#define TC_CLASS_HIGH   0   /* tc0 */
#define TC_CLASS_MED    1   /* tc1 */
#define TC_CLASS_LOW    2   /* tc2 */

/* ============================================================
 * 프로토콜 상수
 * ============================================================ */
#ifndef ETH_P_AVTP
#define ETH_P_AVTP 0x22F0  /* IEEE 1722 AVTP (UAPI에 없으면 자체 정의) */
#endif

/* ============================================================
 * 런타임 디버그 레벨 (BPF map flag) — 컴파일타임 매크로 대체
 *
 * debug_level[0] 값으로 동적 토글:
 *   0 = off
 *   1 = ERR
 *   2 = +WARN
 *   3 = +INFO (패킷 분류 결과)
 *   4 = +TRACE (모든 패킷 — 성능 저하 주의)
 *
 * 런타임 변경:
 *   sudo bpftool map update name debug_level key 0 0 0 0 value 3 0 0 0
 * 로그 확인:
 *   sudo cat /sys/kernel/debug/tracing/trace_pipe
 * ============================================================ */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u32);
} debug_level SEC(".maps");

static __always_inline __u32 dbg_level(void)
{
    __u32 key = 0;
    __u32 *v = bpf_map_lookup_elem(&debug_level, &key);
    return v ? *v : 0;
}

/* bpf_printk 래퍼 — 런타임 레벨별 출력
 * 주의: bpf_printk는 최대 3개 인자만 지원 (BPF verifier 제한)
 */
#define DBG_ERR(fmt, ...)   do { if (dbg_level() >= 1) bpf_printk("[ERR ] " fmt, ##__VA_ARGS__); } while (0)
#define DBG_WARN(fmt, ...)  do { if (dbg_level() >= 2) bpf_printk("[WARN] " fmt, ##__VA_ARGS__); } while (0)
#define DBG_INFO(fmt, ...)  do { if (dbg_level() >= 3) bpf_printk("[INFO] " fmt, ##__VA_ARGS__); } while (0)
#define DBG_TRACE(fmt, ...) do { if (dbg_level() >= 4) bpf_printk("[TRAC] " fmt, ##__VA_ARGS__); } while (0)

/* ============================================================
 * 패킷 통계 맵 (pkt_stats) — 실험의 유일한 카운터 맵
 * ============================================================ */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} pkt_stats SEC(".maps");

#define STATS_TOTAL     0
#define STATS_TSN       1
#define STATS_BEST_EFF  2
#define STATS_DROPPED   3

/* 통계 카운터 원자적 증가 */
static __always_inline void stats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&pkt_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}

/* ============================================================
 * VLAN 헤더에서 PCP(Priority Code Point) 추출
 * VLAN TCI: [PCP(3bit)][DEI(1bit)][VID(12bit)]
 * 반환: PCP 값 (0~7), 비-VLAN/파싱 실패 시 -1
 * ============================================================ */
static __always_inline int get_vlan_pcp(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    if ((void *)(eth + 1) > data_end)
        return -1;

    if (eth->h_proto != bpf_htons(ETH_P_8021Q) &&
        eth->h_proto != bpf_htons(ETH_P_8021AD))
        return -1;

    struct vlan_hdr {
        __be16 h_vlan_TCI;
        __be16 h_vlan_encapsulated_proto;
    } *vhdr = (void *)(eth + 1);

    if ((void *)(vhdr + 1) > data_end)
        return -1;

    __u16 tci = bpf_ntohs(vhdr->h_vlan_TCI);
    return (tci >> 13) & 0x7;
}

#endif /* __TSN_COMMON_H__ */

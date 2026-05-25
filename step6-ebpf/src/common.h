/* common.h — 공통 헤더 및 상수 정의
 * 논문의 eBPF 프로그램: veth-filter(vef), egress(eg), ingress(ig)
 * 커널 5.15 기준 BPF helper 및 구조체 사용
 *
 * 빌드: clang + stub-headers만 사용 (커널 내부 헤더 불필요)
 *   sudo apt install clang make
 */
#ifndef __TSN_COMMON_H__
#define __TSN_COMMON_H__

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* ============================================================
 * 디버그 설정
 *
 * DEBUG_LEVEL:
 *   0 = 디버그 off (프로덕션)
 *   1 = 오류만 출력
 *   2 = 오류 + 경고
 *   3 = 오류 + 경고 + 정보 (패킷 분류 결과 등)
 *   4 = 전체 (모든 패킷 상세 로그 — 성능 저하 주의)
 *
 * 빌드 시 설정: clang -DDEBUG_LEVEL=3 ...
 * 로그 확인: sudo cat /sys/kernel/debug/tracing/trace_pipe
 * ============================================================ */
#ifndef DEBUG_LEVEL
#define DEBUG_LEVEL 2
#endif

/* bpf_printk 래퍼 — 레벨별 출력 매크로
 * 주의: bpf_printk는 최대 3개 인자만 지원 (BPF verifier 제한)
 *       fmt 문자열은 512바이트 이하여야 함
 */
#if DEBUG_LEVEL >= 1
#define DBG_ERR(fmt, ...)   bpf_printk("[ERR ] " fmt, ##__VA_ARGS__)
#else
#define DBG_ERR(fmt, ...)   do {} while(0)
#endif

#if DEBUG_LEVEL >= 2
#define DBG_WARN(fmt, ...)  bpf_printk("[WARN] " fmt, ##__VA_ARGS__)
#else
#define DBG_WARN(fmt, ...)  do {} while(0)
#endif

#if DEBUG_LEVEL >= 3
#define DBG_INFO(fmt, ...)  bpf_printk("[INFO] " fmt, ##__VA_ARGS__)
#else
#define DBG_INFO(fmt, ...)  do {} while(0)
#endif

#if DEBUG_LEVEL >= 4
#define DBG_TRACE(fmt, ...) bpf_printk("[TRAC] " fmt, ##__VA_ARGS__)
#else
#define DBG_TRACE(fmt, ...) do {} while(0)
#endif

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
#define ETH_P_AVTP 0x22F0  /* IEEE 1722 AVTP */
#endif

/* ============================================================
 * 디버그 통계 맵 — 오류 원인 추적용
 * ============================================================ */

/* 기본 패킷 통계 (4 엔트리) */
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

/* 확장 디버그 통계 맵 (16 엔트리) — 오류 분류별 카운트 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u64);
} debug_stats SEC(".maps");

/* debug_stats 인덱스 */
#define DBGSTAT_ETH_TOO_SHORT     0  /* 이더넷 헤더 파싱 실패 (패킷 너무 짧음) */
#define DBGSTAT_VLAN_PARSE_FAIL   1  /* VLAN 헤더 파싱 실패 */
#define DBGSTAT_IP_TOO_SHORT      2  /* IP 헤더 파싱 실패 */
#define DBGSTAT_UDP_TOO_SHORT     3  /* UDP 헤더 파싱 실패 */
#define DBGSTAT_NOT_IP            4  /* IP가 아닌 패킷 */
#define DBGSTAT_NOT_UDP           5  /* UDP가 아닌 IP 패킷 */
#define DBGSTAT_VLAN_TAGGED       6  /* VLAN 태그 패킷 수 */
#define DBGSTAT_AVTP_PKT          7  /* AVTP 프로토콜 패킷 수 */
#define DBGSTAT_TSN_BY_PORT       8  /* UDP 포트 기반 TSN 분류 수 */
#define DBGSTAT_TSN_BY_PCP        9  /* VLAN PCP 기반 TSN 분류 수 */
#define DBGSTAT_RINGBUF_FAIL      10 /* ring buffer reserve 실패 */
#define DBGSTAT_MAP_UPDATE_FAIL   11 /* map update 실패 */
#define DBGSTAT_UNKNOWN_PROTO     12 /* 알 수 없는 EtherType */
#define DBGSTAT_PROG_ENTER        13 /* 프로그램 진입 횟수 */
#define DBGSTAT_IHL_INVALID       14 /* IP IHL 값 비정상 */

/* ============================================================
 * 유틸리티 함수
 * ============================================================ */

/* 통계 카운터 원자적 증가 */
static __always_inline void stats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&pkt_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}

/* 디버그 통계 카운터 원자적 증가 */
static __always_inline void dbgstats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&debug_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}

/* VLAN 헤더에서 PCP(Priority Code Point) 추출
 * VLAN TCI: [PCP(3bit)][DEI(1bit)][VID(12bit)]
 * 반환: PCP 값 (0~7), 실패 시 -1
 */
static __always_inline int get_vlan_pcp(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    if ((void *)(eth + 1) > data_end) {
        DBG_ERR("vlan_pcp: eth hdr overflow");
        dbgstats_inc(DBGSTAT_ETH_TOO_SHORT);
        return -1;
    }

    /* 802.1Q VLAN 태그 확인 */
    if (eth->h_proto != bpf_htons(ETH_P_8021Q) &&
        eth->h_proto != bpf_htons(ETH_P_8021AD)) {
        DBG_TRACE("vlan_pcp: not vlan (proto=0x%x)", bpf_ntohs(eth->h_proto));
        return -1;
    }

    /* VLAN 헤더 파싱 */
    struct vlan_hdr {
        __be16 h_vlan_TCI;
        __be16 h_vlan_encapsulated_proto;
    } *vhdr;

    vhdr = (void *)(eth + 1);
    if ((void *)(vhdr + 1) > data_end) {
        DBG_ERR("vlan_pcp: vlan hdr overflow");
        dbgstats_inc(DBGSTAT_VLAN_PARSE_FAIL);
        return -1;
    }

    __u16 tci = bpf_ntohs(vhdr->h_vlan_TCI);
    int pcp = (tci >> 13) & 0x7;
    DBG_TRACE("vlan_pcp: tci=0x%04x pcp=%d", tci, pcp);

    dbgstats_inc(DBGSTAT_VLAN_TAGGED);
    return pcp;
}

#endif /* __TSN_COMMON_H__ */

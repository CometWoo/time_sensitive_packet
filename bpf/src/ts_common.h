/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ts_common.h — ts_classifier 와 사용자 공간 도구(tests/, tools/)가 공유하는 정의
 *
 * BPF 프로그램과 로더/테스트가 같은 상수를 보도록 한 곳에 모아 둔다.
 * 값을 바꾸면 tests/bpf_harness.py 의 동일 상수도 함께 확인할 것.
 */
#ifndef TS_COMMON_H
#define TS_COMMON_H

#include <linux/pkt_sched.h>   /* TC_PRIO_INTERACTIVE (=6), TC_PRIO_CONTROL (=7) */

/* IPv4 frag_off 필드 비트 (커널 내부 include/net/ip.h 의 IP_MF/IP_OFFSET — UAPI 에는 없어 여기 정의) */
#define TS_IP_MF      0x2000
#define TS_IP_OFFSET  0x1FFF

/* ── 기본 분류 기준 ─────────────────────────────────────────────────────── */
#define TS_DEFAULT_UDP_PORT  6000    /* 실험용 TS UDP 목적지 포트 (컴파일 타임 기본값) */
#define AVTP_ETHERTYPE       0x22F0  /* IEEE 1722 AVTP */
#define TS_VLAN_PCP_MIN      5       /* 802.1Q PCP 5,6,7 = time-sensitive */

/* ── 기본 마킹 값 ───────────────────────────────────────────────────────── */
/* skb->priority 6:
 *   - SO_PRIORITY 가 CAP_NET_ADMIN 없이 설정 가능한 범위가 0..6 (net/core/sock.c)
 *   - prio / pfifo_fast 의 기본 priomap "1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1" 에서
 *     priority 6,7 → band 0(최우선). 커스텀 priomap 없이도 동작하도록 6을 쓴다. */
#define TS_DEFAULT_PRIORITY  TC_PRIO_INTERACTIVE   /* = 6. TC_PRIO_CONTROL(7) 은 커널 제어 트래픽용으로 남겨 둔다 */
/* DSCP 46 = EF (Expedited Forwarding, RFC 3246).
 *   물리 패브릭(ToR/스파인)은 호스트의 skb->priority 를 볼 수 없다. 패브릭 전체
 *   QoS(스위치 큐, PFC/ECN 클래스)를 원하면 IP 헤더의 DSCP 가 유일한 신호다. */
#define TS_DEFAULT_DSCP      46

/* ── 런타임 설정 (ts_config ARRAY map, key 0) ───────────────────────────── */
enum ts_cfg_flags {
	TS_CFG_MARK_DSCP           = 1u << 0, /* TS 패킷의 IPv4 DSCP 를 cfg.dscp 로 재기록 */
	TS_CFG_DISABLE_UDP_DEFAULT = 1u << 1, /* 컴파일 타임 기본 포트(6000) 매칭 비활성 */
};

struct ts_config {
	__u32 priority;   /* 0 = TS_DEFAULT_PRIORITY */
	__u32 dscp;       /* 0 = TS_DEFAULT_DSCP (TS_CFG_MARK_DSCP 일 때만 사용) */
	__u32 flags;      /* enum ts_cfg_flags */
	__u32 reserved;
};

/* ── 카운터 (ts_counters PERCPU_ARRAY map) ─────────────────────────────── */
enum ts_counter {
	CNT_NORMAL = 0,     /* TS 아님 — priority 를 건드리지 않음 */
	CNT_TS_AVTP,        /* AVTP EtherType 으로 분류 */
	CNT_TS_PCP,         /* VLAN PCP >= TS_VLAN_PCP_MIN 으로 분류 */
	CNT_TS_UDP,         /* UDP 목적지 포트로 분류 */
	CNT_DSCP_MARKED,    /* DSCP 재기록 성공 */
	CNT_PARSE_SHORT,    /* 헤더가 잘려서 분류 불가 (경계 검사 실패) */
	CNT_MAX,
};

#endif /* TS_COMMON_H */

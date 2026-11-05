/* SPDX-License-Identifier: GPL-2.0 */
/* ts_classifier 와 사용자 공간 도구가 같이 쓰는 상수. 바꾸면 tests/bpf_harness.py 도 맞출 것. */
#ifndef TS_COMMON_H
#define TS_COMMON_H

#include <linux/pkt_sched.h>   /* TC_PRIO_INTERACTIVE */

/* include/net/ip.h 의 IP_MF/IP_OFFSET. UAPI 헤더에는 없다. */
#define TS_IP_MF      0x2000
#define TS_IP_OFFSET  0x1FFF

#define TS_DEFAULT_UDP_PORT  6000    /* 실험용 TS 흐름의 목적지 포트 */
#define AVTP_ETHERTYPE       0x22F0  /* IEEE 1722 */
#define TS_VLAN_PCP_MIN      5       /* PCP 5~7 을 TS 로 본다 */

/*
 * 6: SO_PRIORITY 를 권한 없이 줄 수 있는 최댓값이고, prio/pfifo_fast 기본 priomap 에서
 * band 0 으로 간다. 7(TC_PRIO_CONTROL)은 커널 제어 트래픽 몫으로 남긴다.
 */
#define TS_DEFAULT_PRIORITY  TC_PRIO_INTERACTIVE
/* EF (RFC 3246). skb->priority 는 호스트를 떠나면 없어지고, 스위치가 읽을 수 있는 건 DSCP 다. */
#define TS_DEFAULT_DSCP      46

/* ts_config map (ARRAY, key 0) */
enum ts_cfg_flags {
	TS_CFG_MARK_DSCP           = 1u << 0, /* TS 패킷의 IPv4 DSCP 를 다시 쓴다 */
	TS_CFG_DISABLE_UDP_DEFAULT = 1u << 1, /* 기본 포트 6000 매칭을 끈다 */
};

struct ts_config {
	__u32 priority;   /* 0 이면 TS_DEFAULT_PRIORITY */
	__u32 dscp;       /* 0 이면 TS_DEFAULT_DSCP */
	__u32 flags;      /* enum ts_cfg_flags */
	__u32 reserved;
};

/* ts_counters map (PERCPU_ARRAY) 인덱스 */
enum ts_counter {
	CNT_NORMAL = 0,     /* TS 아님, priority 는 그대로 */
	CNT_TS_AVTP,
	CNT_TS_PCP,
	CNT_TS_UDP,
	CNT_DSCP_MARKED,
	CNT_PARSE_SHORT,    /* 헤더가 잘려 판별 불가 */
	CNT_MAX,
};

#endif /* TS_COMMON_H */

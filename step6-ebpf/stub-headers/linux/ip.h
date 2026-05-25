/* stub: linux/ip.h */
#ifndef _STUB_LINUX_IP_H
#define _STUB_LINUX_IP_H
#include <linux/types.h>
#define IPPROTO_UDP 17
#define IPPROTO_TCP 6
struct iphdr {
#if defined(__LITTLE_ENDIAN_BITFIELD) || defined(_WINDOWS_STUB_)
    __u8 ihl:4, version:4;
#else
    __u8 version:4, ihl:4;
#endif
    __u8  tos;
    __be16 tot_len;
    __be16 id;
    __be16 frag_off;
    __u8  ttl;
    __u8  protocol;
    __u16 check;
    __be32 saddr;
    __be32 daddr;
};
#endif

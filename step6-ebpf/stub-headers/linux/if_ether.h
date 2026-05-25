/* stub: linux/if_ether.h */
#ifndef _STUB_LINUX_IF_ETHER_H
#define _STUB_LINUX_IF_ETHER_H
#include <linux/types.h>
#define ETH_ALEN    6
#define ETH_HLEN    14
#define ETH_P_IP    0x0800
#define ETH_P_8021Q 0x8100
#define ETH_P_8021AD 0x88A8
struct ethhdr {
    unsigned char h_dest[ETH_ALEN];
    unsigned char h_source[ETH_ALEN];
    __be16        h_proto;
};
#endif

/* stub: linux/udp.h */
#ifndef _STUB_LINUX_UDP_H
#define _STUB_LINUX_UDP_H
#include <linux/types.h>
struct udphdr {
    __be16 source;
    __be16 dest;
    __be16 len;
    __be16 check;
};
#endif

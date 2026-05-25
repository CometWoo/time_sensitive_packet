/* stub: bpf/bpf_endian.h */
#ifndef _STUB_BPF_ENDIAN_H
#define _STUB_BPF_ENDIAN_H
#include <linux/types.h>

#define bpf_htons(x) __builtin_bswap16(x)
#define bpf_ntohs(x) __builtin_bswap16(x)
#define bpf_htonl(x) __builtin_bswap32(x)
#define bpf_ntohl(x) __builtin_bswap32(x)

#endif

/* stub: bpf/bpf_helpers.h */
#ifndef _STUB_BPF_HELPERS_H
#define _STUB_BPF_HELPERS_H
#include <linux/types.h>

#define SEC(name) __attribute__((section(name), used))
#define __uint(field, val) int (*field)[val]
#define __type(field, val) typeof(val) *field

/* BPF helper 함수 스텁 (IntelliSense용) */
static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;
static long (*bpf_map_update_elem)(void *map, const void *key, const void *value, __u64 flags) = (void *)2;
static long (*bpf_map_delete_elem)(void *map, const void *key) = (void *)3;
static __u64 (*bpf_ktime_get_ns)(void) = (void *)5;
static long (*bpf_trace_printk)(const char *fmt, __u32 fmt_size, ...) = (void *)6;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *)131;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *)132;
static void (*bpf_ringbuf_discard)(void *data, __u64 flags) = (void *)133;

#define bpf_printk(fmt, ...)                                    \
({                                                              \
    char ____fmt[] = fmt;                                       \
    bpf_trace_printk(____fmt, sizeof(____fmt), ##__VA_ARGS__);  \
})

#endif

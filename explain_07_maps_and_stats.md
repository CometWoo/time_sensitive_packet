# explain_07 — BPF map 구조 전체 및 유저스페이스 접근 방식

> ⚠️ **2026-06 재설계 반영**: 단일 프로그램 설계에서 BPF map 은 **`pkt_count`(ARRAY[2]: key0=일반,
> key1=TS) 하나뿐**이다. `debug_level`/`pkt_stats`/`last_arrival`/ringbuf 는 모두 제거되었다.
> 또한 `pkt_count` 는 호스트가 아니라 **talker Pod 의 netns** 안에 있으므로 유저스페이스 접근은
> `nsenter` 로 들어가서 한다:
> ```bash
> sudo bash step6-ebpf/attach-vnic.sh show tsn-experiment <talker-pod>   # → pkt_count dump
> ```
> 아래 본문(debug_level/pkt_stats/last_arrival)은 옛 설계 기록이다.

---

> 대상: `step6-ebpf/src/common.h`(공유 map/헬퍼) + `step6-ebpf/debug-stats.sh`(유저스페이스 접근)
> + `ingress.c`의 `last_arrival` map.
> 2026-06 감사 후 남은 map은 **3개**: `debug_level`, `pkt_stats`, `last_arrival`.
> (제거됨: `debug_stats` ARRAY[16], `egress_log`/`ingress_log` RINGBUF)

## 코드 (common.h — map 정의 + 헬퍼)

```c
/* ── 런타임 디버그 레벨 (BPF map flag) — 컴파일타임 매크로 대체 ── */
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
#define DBG_ERR(fmt, ...)   do { if (dbg_level() >= 1) bpf_printk("[ERR ] " fmt, ##__VA_ARGS__); } while (0)
#define DBG_WARN(fmt, ...)  do { if (dbg_level() >= 2) bpf_printk("[WARN] " fmt, ##__VA_ARGS__); } while (0)
#define DBG_INFO(fmt, ...)  do { if (dbg_level() >= 3) bpf_printk("[INFO] " fmt, ##__VA_ARGS__); } while (0)
#define DBG_TRACE(fmt, ...) do { if (dbg_level() >= 4) bpf_printk("[TRAC] " fmt, ##__VA_ARGS__); } while (0)

/* ── 패킷 통계 (pkt_stats) — 실험의 유일한 카운터 맵 ── */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} pkt_stats SEC(".maps");
#define STATS_TOTAL 0
#define STATS_TSN 1
#define STATS_BEST_EFF 2
#define STATS_DROPPED 3

static __always_inline void stats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&pkt_stats, &idx);
    if (val) __sync_fetch_and_add(val, 1);
}
```

```c
/* ── jitter 타임스탬프 (ingress.c) ── */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u16);      /* dst_port */
    __type(value, __u64);    /* 직전 수신 ns */
} last_arrival SEC(".maps");
```

## 코드 (유저스페이스 접근 — debug-stats.sh 핵심)

```bash
# pkt_stats 덤프
bpftool map dump name pkt_stats          # [0]TOTAL [1]TSN [2]BEST_EFF [3]DROPPED

# debug_level 런타임 토글 (0~4)
bpftool map update name debug_level key 0 0 0 0 value 3 0 0 0
cat /sys/kernel/debug/tracing/trace_pipe # bpf_printk 로그 확인

# pkt_stats 0 초기화
for i in 0 1 2 3; do
  bpftool map update id "$MAP_ID" key "$i" 0 0 0 value 0 0 0 0 0 0 0 0
done

# jitter 타임스탬프 맵
bpftool map dump name last_arrival
```

> 핵심: `SEC(".maps")`로 선언된 map은 BPF 프로그램 LOAD 시 커널이 자동 생성(`BPF_MAP_CREATE`)하고,
> 유저스페이스는 `bpftool map`(내부적으로 `bpf()` syscall)으로 read/update한다. 즉 BPF VM과
> 유저스페이스가 같은 map을 공유 메모리처럼 본다. `__sync_fetch_and_add`로 멀티코어 카운트 경쟁을 막는다.

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **BPF map 구조 전체 및 유저스페이스 접근 방식** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `debug_level` (ARRAY[1], u32): 런타임 디버그 레벨. `dbg_level()`이 매 패킷 lookup하고 `DBG_*` 매크로가 그 값으로 `bpf_printk`를 게이트하는 원리. 컴파일타임 매크로 대비 장단점.
   - `pkt_stats` (ARRAY[4], u64): TOTAL/TSN/BEST_EFF/DROPPED. `stats_inc()`의 lookup+`__sync_fetch_and_add` 원자적 증가.
   - `last_arrival` (HASH[64], key=u16 dport, value=u64 ns): jitter 계산을 위한 직전 도착 시각. 왜 HASH인지.
   - 각 map의 `__uint(type,...)`, `__type(key/value,...)`, `SEC(".maps")` 선언 문법.
2. 코드, 문법 부분 설명
   - `bpf_map_lookup_elem`/`bpf_map_update_elem`의 반환값 처리와 null 가드.
   - `__sync_fetch_and_add`(원자적 연산)와 멀티코어 안전성.
   - `bpftool map dump/update name <map> key ... value ...`의 바이트(리틀엔디언) 표기.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `common.h`의 `pkt_stats`/`debug_level`은 egress.c·ingress.c·veth_filter.c가 공유한다.
   - `last_arrival`은 ingress.c 전용.
   - `debug-stats.sh`, `deploy-experiment.sh status`가 유저스페이스에서 이 map들을 읽고/토글한다.
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - `pkt_stats`의 TSN/TOTAL 카운트가 "패킷이 우리 BPF를 통과했는가"를, `last_arrival`이 커널-사이드 jitter를 제공한다는 점, 그리고 Cilium tcx 우회 시 `pkt_stats`가 0이어도 실험(listener.py)은 유효한 이유를 설명해줘.
```
```

# ADR-0003 — TS 분류·마킹은 호스트 물리 NIC egress(qdisc 직전)에서 한다

- 상태: **채택 (2026-09)** — ADR-0003(구) "Pod eth0 egress(netns 내부) attach" 를 대체
- 관련: [ADR-0005](0005-tcx-before-cilium.md) (Cilium tcx 와의 순서), [ADR-0004](0004-non-ts-priority-untouched.md)

## 문제

"time-sensitive(TS) 패킷에 높은 `skb->priority` 를 주면 호스트 NIC 의 `prio` qdisc 가 먼저 내보낸다"
가 이 프로젝트의 핵심 메커니즘이다. 문제는 **어디서 priority 를 설정하느냐** 이다. 이 저장소는
세 번 자리를 옮겼다.

| 세대 | 시점 | 설정 지점 | 결과 |
|---|---|---|---|
| 1 (2026-05) | 논문 Fig.1 대로 | Pod 소켓 `SO_PRIORITY=3` + 호스트측 veth(lxc*) / NIC 의 legacy clsact BPF(vef/eg/ig) | BPF 카운터 전부 0 (Cilium tcx 가 clsact 를 건너뜀). 측정은 SO_PRIORITY 에 의존 |
| 2 (2026-06) | 정적 재설계 | Pod **내부** eth0 egress 에 `vnic_filter` 를 nsenter 로 attach + `SO_PRIORITY=6` | 클러스터 미검증. 카운터는 찍히지만… |
| 3 (2026-09, 본 ADR) | 커널 소스 검증 | **호스트 물리 NIC egress** (`ts_classifier`, tcx BEFORE / clsact) | 아래 근거 |

## 발견 — Pod 안에서 설정한 priority 는 호스트에 도달하지 않는다

세대 1·2 는 모두 같은 가정 위에 서 있었다: *Pod 에서 설정한 `skb->priority` 가 veth 를 지나
호스트 qdisc 까지 살아남는다.* 커널 소스는 그 반대다.

```c
/* include/linux/netdevice.h (v5.15 L4128-4142, v6.8 L4098-4112) */
static __always_inline int ____dev_forward_skb(struct net_device *dev,
                                               struct sk_buff *skb,
                                               const bool check_mtu)
{
        if (skb_orphan_frags(skb, GFP_ATOMIC) ||
            unlikely(!__is_skb_forwardable(dev, skb, check_mtu))) { ... }

        skb_scrub_packet(skb, !net_eq(dev_net(dev), dev_net(skb->dev)));
        skb->priority = 0;          /* ← 여기 */
        return 0;
}
```

호출 경로: `veth_xmit()` → `veth_forward_skb()` → `__dev_forward_skb()` → `__dev_forward_skb2()` →
`____dev_forward_skb()` (drivers/net/veth.c L316-322, net/core/dev.c L2149-2166, v6.8).
즉 **veth 쌍을 건너는 모든 패킷의 priority 는 무조건 0** 이 된다. `SO_PRIORITY` 든 Pod eth0
egress 의 BPF 든, Pod 쪽에서 무엇을 하든 호스트측 lxc 디바이스에 도착한 순간 지워진다.

### 실측 (testbed/, WSL2 5.15, 2026-09-09)

`prio_probe` 를 호스트측 veth ingress 와 NIC egress 양쪽에 붙이고 talker 가 `SO_PRIORITY=6` 으로
3,000 개, BE 홍수가 24,110 개를 보냈다.

| 관측 지점 | priority 0 | priority 6 |
|---|---|---|
| veth 를 건넌 직후 (vs_host ingress) | **27,110** | **0** |
| NIC egress, ts_classifier 뒤 (vr_host egress) | 24,110 | **3,000** |

세대 1 의 5월 측정에서 "proposed" 는 커스텀 priomap `2 2 1 0 …` 을 썼으므로 priority 0 →
**band 2(최하위)**. 즉 TS 패킷은 우선 처리는커녕 가장 낮은 밴드로 갔고, 경쟁 트래픽도 없었다
([ADR-0006](0006-testbed-needs-contention.md)). 5월 결과의 개선 폭은 우선순위 큐 효과로
설명할 수 없다 ([docs/RESULTS.md](../RESULTS.md) 재해석).

## 결정

분류와 `skb->priority`(및 선택적 DSCP) 설정은 **호스트 netns 의 물리 NIC egress hook** 에서
한다. 이 hook 은 `__dev_queue_xmit()` 안에서 `sch_handle_egress()` 로 qdisc enqueue
(`__dev_xmit_skb()`) **직전**에 실행되므로 (net/core/dev.c v6.8 L4293 vs L4317), 여기서 쓴
priority 를 `prio`/`pfifo_fast`/`mqprio` 가 그대로 본다. Cilium 의 `bpf_redirect()` 로 lxc 에서
NIC 로 넘어온 패킷도 같은 `__dev_queue_xmit(NIC)` 경로를 타므로 예외가 없다.

## 고려한 대안

| 대안 | 장점 | 단점 / 기각 사유 |
|---|---|---|
| Pod 내부 eth0 egress BPF (세대 2) | Cilium 을 건드리지 않음, 카운터 확실 | priority 가 veth 에서 0 으로 리셋 — **목적 달성 불가** |
| 호스트측 lxc(veth) ingress BPF (세대 1, 논문 vef 위치) | 논문과 동일한 위치 | kernel ≥ 6.6 에서 Cilium tcx(`cil_from_container`, REDIRECT 반환) 가 먼저 실행돼 legacy clsact 가 스킵됨. tcx BEFORE 로 붙이면 되지만 여기서 설정한 priority 는 이후 `bpf_redirect()` 경로에서는 살아남으나 lxc→NIC 가 라우팅(non-redirect) 경로일 때 보장이 약함 |
| **호스트 NIC egress, tcx BEFORE + TCX_NEXT (채택)** | qdisc 직전이라 확실, Cilium 정책·데이터패스 무간섭(UNSPEC 반환), Cilium 재시작에도 링크 유지 | libbpf 로더가 필요(bpftool 은 순서 플래그 없음) → `tools/tcx_attach.c` 작성 |
| cgroup/sockops 로 소켓 priority 설정 | 애플리케이션 수정 불필요 | 역시 veth 에서 리셋 |
| Cilium 확장(custom calls / Tetragon) | 통합 | 실험 목적에 과함, 버전 종속 |
| `tc filter u32/flower` + `action skbedit priority` (BPF 없이) | 도구만으로 가능 | 헤더 파싱 조건(AVTP/QinQ/포트 map)과 DSCP 재기록·카운터를 한 프로그램에서 하려면 BPF 가 단순. 다만 단순 포트 매칭만 필요하면 이 방법이 더 가볍다 — 문서에 명시 |

## 결과

- `step6-ebpf/src/ts_classifier.c`, `tools/tcx_attach.c`, `testbed/` 로 구현·검증.
- K8s 경로 `deploy-experiment.sh` 는 sender 노드 NIC 에 attach 하도록 재작성.
- 논문 Fig.1 의 "vef(veth 필터)" 는 이 저장소에서 **의도적으로 구현하지 않는다** — vef 의 역할
  (overlay 우회) 은 Cilium native routing 에서 이미 무의미하고, priority 설정은 veth 뒤에서만
  유효하기 때문이다.

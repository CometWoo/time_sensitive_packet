# ADR-0005 — Cilium(tcx) 앞에 BPF_F_BEFORE 로 붙이고 TC_ACT_UNSPEC(TCX_NEXT) 을 반환한다

- 상태: 채택 (2026-09)
- 관련: [ADR-0003](0003-classify-at-host-nic-egress.md)

## 문제

kernel ≥ 6.6 에서 Cilium(≥ 1.16) 은 legacy `clsact` 대신 **tcx**(multi-prog, `bpf_mprog`) 로
프로그램을 붙인다. 같은 hook 에 `tc filter add … bpf da` 로 붙인 우리 프로그램은 어떻게 되는가?

```c
/* net/core/dev.c v6.8 L4042-4083 */
sch_handle_egress(struct sk_buff *skb, int *ret, struct net_device *dev)
{
        ...
        if (static_branch_unlikely(&tcx_needed_key)) {
                sch_ret = tcx_run(entry, skb, false);
                if (sch_ret != TC_ACT_UNSPEC)
                        goto egress_verdict;          /* ← legacy tc_run() 건너뜀 */
        }
        sch_ret = tc_run(tcx_entry(entry), skb, &drop_reason);
```

tcx 체인이 `TC_ACT_UNSPEC`(= `TCX_NEXT`) 이 아닌 값을 반환하면 legacy 필터는 실행되지 않는다.
Cilium 의 `cil_to_netdev`(NIC egress) 는 정상 경로에서 `TC_ACT_OK` 를, `cil_from_container`
(lxc ingress) 는 `TC_ACT_REDIRECT` 를 반환한다. → **5월 실험에서 호스트측 BPF 카운터가 전부 0
이었던 진짜 이유**. (당시 README 는 ingress 쪽 원인은 맞게 짚었지만 "attach 순서를 바꾸지 않는다"
로 결론냈다.)

tcx 체인 안에서도 규칙은 같다: 앞 프로그램이 `TCX_NEXT` 를 반환할 때만 다음 프로그램이 실행된다
(`tcx_run()` → `bpf_mprog_run`).

## 결정

1. `ts_classifier` 를 **tcx 링크로, `BPF_F_BEFORE`(relative 없음 = 체인 맨 앞)** 에 붙인다.
   커널 `bpf_mprog_attach()`: BEFORE + relative 없음 → idx = -1(맨 앞), AFTER → idx = total(맨 뒤)
   (kernel/bpf/mprog.c v6.8 L193-223, 260-283).
2. 프로그램은 항상 **`TC_ACT_UNSPEC`** 을 반환해 뒤의 Cilium 프로그램이 그대로 실행되게 한다.
   legacy clsact 에서도 UNSPEC 은 "다음 필터로 계속" 이라 kernel < 6.6 에서도 안전하다.
3. 링크는 bpffs 에 pin 해 로더 프로세스가 끝나도 유지되고, Cilium agent 가 재시작해 자기 링크를
   교체해도 우리 링크는 남는다(mprog 는 링크 단위로 관리).
4. bpftool 은 순서 플래그를 노출하지 않으므로 libbpf(≥ 1.3) 로 60줄짜리 로더
   `tools/tcx_attach.c` 를 작성했다. `bpf_program__attach_tcx()` 는 프로그램의
   `expected_attach_type` 을 `BPF_LINK_CREATE` 의 attach_type 으로 쓰므로 **로드 전에**
   `BPF_TCX_EGRESS` 로 설정해야 한다(로드 후 설정은 -EBUSY 로 무시 → 커널 EINVAL — CI 에서 실제로
   겪은 버그).

## 검증

- `bpf/tests/test_tcx_chain.sh` (kernel ≥ 6.6, CI ubuntu-24.04):
  - Phase A: `tcx_dummy_ok`(OK 반환, Cilium 흉내) + legacy clsact `ts_classifier` → 분류기 카운터 0
  - Phase B: `ts_classifier` 를 BEFORE 로 → 둘 다 실행
- BPF_PROG_TEST_RUN 단위 테스트가 반환값 `TC_ACT_UNSPEC` 을 고정한다.

## 고려한 대안

| 대안 | 기각 사유 |
|---|---|
| legacy clsact 만 사용 | kernel ≥ 6.6 + Cilium 에서 실행 안 됨 (위) |
| tcx AFTER(맨 뒤) | Cilium 이 OK 를 반환하면 우리 프로그램에 도달하지 않음 |
| Cilium 프로그램을 우리가 교체/래핑 | 정책·데이터패스 간섭, 업그레이드 취약 |
| `TC_ACT_OK` 반환 | tcx 체인이 거기서 끝나 **Cilium 이 실행되지 않음** → 정책/암호화/마스커레이드 우회. 절대 금지 |

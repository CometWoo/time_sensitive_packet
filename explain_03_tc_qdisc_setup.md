# explain_03 — TC qdisc 설정 스크립트 (mqprio / prio / ETF)

> 대상: `deploy-experiment.sh`의 `setup_tc_qdisc()` (메인 경로)
> + 참고용 `step5-tc-qdisc/01-setup-mqprio.sh`, `02-setup-etf.sh`, `setup-all-qdisc.sh`
> proposed 모드에서 호스트 물리 NIC(enp0s3)에 우선순위 큐를 설정한다.

## 코드 (메인 경로: deploy-experiment.sh `setup_tc_qdisc()`)

```bash
setup_tc_qdisc() {
    log_info "=== TC Qdisc 설정 (우선순위 큐) ==="
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true

    # ── TX queue 를 늘려 하드웨어 큐 분리 mqprio 를 노려본다 ──
    if command -v ethtool &>/dev/null; then
        local max_combined
        max_combined=$(ethtool -l "$PHYS_IF" 2>/dev/null | awk '/^Pre-set/{p=1} p&&/Combined:/{print $2; exit}')
        if [ -n "${max_combined:-}" ] && [ "$max_combined" -ge 3 ] 2>/dev/null; then
            log_info "virtio 멀티큐 가능 (최대 Combined=$max_combined) → 4 큐로 설정 시도"
            ethtool -L "$PHYS_IF" combined 4 2>/dev/null || ethtool -L "$PHYS_IF" combined "$max_combined" 2>/dev/null || true
        else
            log_info "virtio 멀티큐 미지원/불명 (Pre-set Combined=${max_combined:-?}) — 소프트웨어 mqprio 시도"
        fi
    fi

    local txq_count
    txq_count=$(ls -d /sys/class/net/"$PHYS_IF"/queues/tx-* 2>/dev/null | wc -l)
    log_info "NIC TX queue 수: $txq_count"
    local qdisc_ok=0

    # 시도 1a: 하드웨어 큐 분리 mqprio (TX queue >= 3)
    if [ "$txq_count" -ge 3 ]; then
        if tc qdisc add dev "$PHYS_IF" root handle 100: mqprio \
            num_tc 3 map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
            queues 1@0 1@1 1@2 hw 0 2>/dev/null; then
            log_info "mqprio(멀티큐) 설정 완료"; qdisc_ok=1
        else
            log_warn "mqprio(멀티큐) 실패"
        fi
    fi

    # 시도 1b: 소프트웨어 mqprio (단일 큐 — 모든 tc → 큐0)
    if [ "$qdisc_ok" -eq 0 ]; then
        if tc qdisc add dev "$PHYS_IF" root handle 100: mqprio \
            num_tc 3 map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
            queues 1@0 1@0 1@0 hw 0 2>/dev/null; then
            log_info "mqprio(소프트웨어) 설정 완료 (겹침 큐 허용 커널)"; qdisc_ok=1
        else
            log_warn "mqprio(소프트웨어) 실패 — 단일 virtio 큐는 보통 겹침 큐를 거부 (정상)"
        fi
    fi

    # 시도 2: prio qdisc (확실한 폴백 — 소프트웨어 strict-priority 3밴드)
    if [ "$qdisc_ok" -eq 0 ]; then
        if tc qdisc add dev "$PHYS_IF" root handle 100: prio \
            bands 3 priomap 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 2>/dev/null; then
            log_info "prio qdisc 설정 완료"; qdisc_ok=1
        else
            log_error "prio qdisc 설정도 실패"; tc qdisc show dev "$PHYS_IF"; return 1
        fi
    fi

    # ETF 자동 attach 제거됨 (2026-06): talker가 SO_TXTIME 미사용 →
    #   ETF(sch_etf)가 SOCK_TXTIME 없는 패킷을 qdisc_drop() → TSN 전량 드롭 위험.
    log_info "최종 Qdisc 상태:"
    tc qdisc show dev "$PHYS_IF"
}
```

> 핵심 매핑: `map/priomap 2 2 1 0 …` → priority 0→tc2/band2, 1→tc2, 2→tc1/band1,
> **3→tc0/band0(최우선)**. talker의 SO_PRIORITY=3 패킷이 band 0으로 들어가 먼저 dequeue된다.
> ETF는 메인 경로에서 제외(SO_TXTIME 부재로 드롭 위험), taprio+ETF 통합본은
> `step5-tc-qdisc/setup-all-qdisc.sh`에 참고용으로만 남아 있다(VM에서 결과가 깨짐).

## Gemini에게 보낼 설명 요청 프롬프트

다음은 Linux TSN(Time-Sensitive Networking) 실험 환경의 **TC qdisc 설정 스크립트(mqprio/prio/ETF)** 코드야. 아래 항목을 설명해줘:

1. 핵심 함수/구조체/map을 하나씩 설명 (입력, 출력, 동작 원리)
   - `setup_tc_qdisc()`의 3단계 폴백(하드웨어 mqprio → 소프트웨어 mqprio → prio)이 각각 무엇을 하는지.
   - `mqprio`의 `num_tc`, `map`, `queues 1@0 1@1 1@2`, `hw 0`의 의미. `map 2 2 1 0 …`이 VLAN priority→TC를 어떻게 매핑하는지(논문 Table I).
   - `prio bands 3 priomap 2 2 1 0 …`에서 band 0이 왜 최우선이며 strict priority dequeue가 어떻게 동작하는지.
   - `ethtool -l/-L combined`로 virtio 큐 수를 조회/변경하는 부분.
   - ETF(sch_etf)가 무엇이고 왜 메인 경로에서 제외됐는지(SO_TXTIME/SCM_TXTIME 부재 → SOCK_TXTIME 없는 패킷 드롭).
2. 코드, 문법 부분 설명
   - `tc qdisc add ... root handle 100:`의 handle/parent 표기, `2>/dev/null` 으로 실패를 흡수하고 다음 폴백으로 넘어가는 패턴.
   - `awk '/^Pre-set/{p=1} p&&/Combined:/{print $2; exit}'`의 파싱 로직.
3. 다른 파일과의 연관 관계 (어디서 호출되고 어디에 영향을 주는지)
   - `run_experiment proposed`일 때만 호출되고 baseline일 때는 `remove_tc_qdisc()`가 root qdisc를 제거한다.
   - egress.c의 `priority_to_tc()` 매핑과 이 qdisc의 priomap이 일치해야 한다는 점.
   - `talker.py`의 SO_PRIORITY=3 / `talker-job.yaml`의 `--vlan-priority=3`과의 관계.
4. 실험 결과(pkt_stats, jitter)와 이 코드의 연결 고리
   - 이 우선순위 큐(band 0 우선 dequeue)가 baseline(단일 FIFO) 대비 어떻게 p99 latency/jitter를 줄이는지, 그리고 VM에서 실제로 적용되는 qdisc가 보통 `prio`인 이유를 설명해줘.
```
```

## 부록: 참고용 step5 스크립트 (메인 미사용)

`step5-tc-qdisc/setup-all-qdisc.sh` (taprio+ETF, 논문 §IV 충실판이나 VM에서 결과 깨짐):

```bash
sudo tc qdisc replace dev "$IFACE" root handle 100: taprio \
    num_tc 3 map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
    queues 1@0 1@0 1@0 \
    base-time "$BASE_TIME" \
    sched-entry S 04 125000 \
    sched-entry S 02 125000 \
    sched-entry S 01 750000 \
    clockid CLOCK_TAI flags 0x1
sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf \
    clockid CLOCK_TAI delta 150000 offload off deadline_mode on
```

# ADR-0006 — 우선순위 큐 실험에는 병목 링크와 경쟁 트래픽이 있어야 한다

- 상태: 채택 (2026-09)
- 관련: [ADR-0010](0010-qdisc-conditions.md), [docs/RESULTS.md](../RESULTS.md)

## 문제

`prio`/`pfifo_fast` 같은 strict-priority qdisc 는 **동시에 큐에 들어 있는** 패킷의 순서만 바꾼다.
큐가 비어 있으면 어떤 qdisc 든 패킷을 즉시 내보내고, 우선순위는 아무 역할도 하지 않는다.

5월 K8s 실험은 1 ms 간격 128 B UDP 흐름 하나(실효 216-547 pkt/s, ≈ 30-70 KB/s)만 흘렸고,
NIC 에는 K8s/Cilium 제어 트래픽뿐이었다. CPU 부하(stress-ng)는 네트워크 큐를 채우지 않는다.
따라서 "prio vs fq_codel" 의 차이는 우선순위 dequeue 가 아니라 코드 경로·CoDel 상태·실행 간
잡음에서 나왔을 수밖에 없다 (감사 F03). 논문의 실험 서술은 같은 링크에 배경 부하가 있음을
전제한다.

## 결정

실험 모델을 "**병목 링크 + best-effort 경쟁 + TS 흐름**" 으로 정의한다.

- 병목: sender 측 NIC(테스트베드에서는 `vr_host`)에 `tbf rate 20mbit` (K8s 에서는 HTB 클래스
  `rate 20mbit`, u32 로 listener IP 만 매칭해 제어 평면 트래픽은 제한하지 않음) 을 두고 그 **자식**
  으로 조건별 qdisc(pfifo/fq_codel/pfifo_fast/prio)를 단다. TBF/HTB 는 자식 qdisc 를 peek/dequeue
  하므로 backlog 는 자식 안에 쌓이고, 우선순위 선택은 자식에서 일어난다.
- 경쟁: `workload/be_flood.py` 가 1400 B UDP 를 30 Mbit/s 로 제공(링크의 150 %) → 지속적 backlog.
  수신측 `udp_sink.py` 가 받아 버려서 ICMP unreachable 역방향 트래픽을 막는다.
- TS: `talker.py` 1 ms 간격 128 B UDP:6000, `listener.py` 가 one-way latency / jitter / 손실 /
  수신 TOS 를 기록.

기대 효과(직관): 20 Mbit/s 링크에서 1400 B 패킷 하나의 직렬화 시간 ≈ 0.56 ms. pfifo(limit 1000)
가 가득 차면 FIFO 대기는 최대 ≈ 560 ms. strict priority 면 TS 패킷은 현재 전송 중인 패킷 하나만
기다린다(≤ 0.56 ms + 오버헤드). 차이는 두 자릿수 이상이어야 하고, 잡음에 묻힐 수 없다.

## 고려한 대안

| 대안 | 기각/보류 사유 |
|---|---|
| CPU 부하만 (5월 방식) | 큐 경쟁 없음 → 우선순위 효과 측정 불가 |
| 실제 NIC 를 포화 (iperf3 -b 1G) | VM virtio 는 CPU 가 먼저 포화, 러너에선 불가. 셰이퍼가 재현성 높음 |
| netem 으로 지연/손실만 추가 | netem 은 자기 큐 안에서 시간 순으로만 내보내 자식 qdisc 의 우선순위가 무력화됨 |
| tap + 사용자 공간 링크 에뮬레이터(WSL 용) | tun/tap 은 링이 차면 **드롭**하지 큐를 멈추지 않아(`tun_net_xmit`) qdisc 에 backlog 가 안 생김 — 시도 후 폐기 |
| WSL2 커널 재빌드(sch_tbf 포함) | 사용자 PC 설정 변경. 대신 CI 러너(ubuntu-24.04, 모듈 있음)에서 실행 |

## 결과

- WSL2(모듈 없음)에서는 `SHAPER=none` 기능 검증 모드(priority 리셋 증명, DSCP 도착 확인)만 돈다.
- 경합 실험은 `.github/workflows/testbed.yml` 이 러너에서 3회 반복 실행해 아티팩트로 남기고,
  `results/testbed/` 에 커밋한다.

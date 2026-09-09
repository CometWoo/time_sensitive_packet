# ADR-0008 — talker 는 목적지 이름을 한 번만 해석하고, CPU quota 로 throttling 되지 않게 배치한다

- 상태: 채택 (2026-09)
- 관련: [ADR-0016](0016-results-provenance.md), [docs/RESULTS.md](../RESULTS.md)

## 발견

5월 CSV 의 `send_ns` 를 다시 보니 "1 ms 간격" 이 지켜지지 않았다.

| 파일 | 10,000 패킷 송신 구간 | 실효 속도 | 송신 간격 p50 / p99 |
|---|---|---|---|
| baseline_cpu10 | 38.9 s | 257 pkt/s | 1.81 / 14.0 ms |
| proposed_cpu10 | 20.5 s | 488 pkt/s | 1.60 / 4.3 ms |
| proposed_cpu99 | 46.3 s | 216 pkt/s | 1.84 / 12.6 ms |

두 가지 원인이 코드에 있었다.

1. **패킷마다 DNS 질의.** `sock.sendto(data, ("listener-svc.…svc.cluster.local", 6000))` —
   CPython 은 호스트 이름이 오면 **매 호출마다 `getaddrinfo()`** 를 부른다. 실측(WSL, strace):
   sendto 20회 → 53번 포트 질의 20회, 호출당 59 ms(WSL 리졸버 기준; 클러스터 CoreDNS 는
   0.5~2 ms). 게다가 `send_time_ns` 스탬프를 찍은 **뒤에** DNS 왕복이 일어나므로 그 시간이
   latency 에 그대로 포함됐고, CPU 부하가 CoreDNS 에도 걸리니 "CPU 부하 ↑ → latency ↑" 의
   상당 부분이 DNS 였을 수 있다.
2. **CFS quota throttling.** talker 컨테이너 `limits.cpu: 500m` = 100 ms 주기당 50 ms. busy-wait
   페이싱 루프는 quota 를 금방 소진해 50 ms 씩 멈춘다 — CSV 의 40~120 ms 송신 공백 수십 개와
   일치한다. 이 공백은 수신측에서 최대 latency "outlier"(1.5~3.8 s) 로도 나타났고, README 는
   이를 하이퍼바이저 스톨로 해석했었다.

## 결정

- `talker.py`: 시작 시 `getaddrinfo()` 한 번 → IP 리터럴로 `sendto`. (`socket.gethostbyname`
  도 가능하나 AF_INET 명시를 위해 getaddrinfo 사용.)
- K8s: talker Pod 는 `requests = limits = 1 CPU`(Guaranteed) 또는 limit 없음. 격리 코어가 있으면
  `--cpu` 로 고정.
- 분석 패키지가 **송신 페이싱 품질**(inter-send p50/p99, >10 ms 공백 수)을 함께 보고해, 이런
  교란을 데이터가 스스로 드러내게 한다.
- jitter 정의(`t_i − (t_{i−1} + T)`)는 송신 간격 오차를 그대로 포함하므로, 문서에서 "네트워크
  jitter" 가 아니라 "end-to-end 도착 간격 변동" 으로 부른다.

## 고려한 대안

| 대안 | 비고 |
|---|---|
| C + `clock_nanosleep(TIMER_ABSTIME)` talker | 페이싱 정밀도 최고. 파이썬 유지가 이식성·가독성에 유리해 보류(로드맵) |
| `SO_TXTIME` + ETF 로 커널이 페이싱 | 하드웨어·PTP 필요 ([ADR-0002](0002-prio-instead-of-mqprio-etf-taprio.md)) |
| `SCHED_FIFO` (`--realtime`) | 옵션으로 유지, `CAP_SYS_NICE` 필요 |

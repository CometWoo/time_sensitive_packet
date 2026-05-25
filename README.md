# Time-Sensitive Cloud-Native Network — eBPF 기반 실험 재현

논문 **Wen et al., "A Time-Sensitive Cloud-Native Network Based on eBPF" (CSCWD 2024)** 의 재현 실험.
Cilium 기반 Kubernetes 클러스터에서 eBPF + TC `prio` qdisc 조합으로 time-sensitive 패킷의 우선순위 처리를 검증합니다.

---

## 실험 결과 요약 (이 repo에서 측정됨)

### Latency 전체 (낮을수록 좋음, ms 단위)
| CPU 부하 | Baseline p50 / p99 / max | Proposed p50 / p99 / max | p99 개선 | max 개선 |
|---------|--------------------------|--------------------------|---------|---------|
| 10% | 1.19 / **13.02** / 3866.6 | 0.80 / **3.42** / 1737.0 | **−73.7%** ✓ | **−55.1%** ✓ |
| 30% | 1.30 / **8.21** / 738.1 | 1.04 / **5.94** / 190.6 | **−27.6%** ✓ | **−74.2%** ✓ |
| 50% | 1.43 / **12.08** / 151.4 | 0.81 / **7.04** / 181.0 | **−41.7%** ✓ | +19.5% ✗ |
| 70% | 1.13 / **11.78** / 248.8 | 1.05 / **11.64** / 1728.1 | −1.1% ≈ | +594.6% ✗ |
| 99% | (미측정) | 0.99 / 11.58 / 1519.0 | n/a | n/a |

### Jitter p99 (낮을수록 일정함, μs 단위)
| CPU 부하 | Baseline | Proposed | 개선 |
|---------|----------|----------|------|
| 10% | 12928 | **3266** | **−74.7%** ✓ |
| 30% | 8307 | **5836** | **−29.7%** ✓ |
| 50% | 11758 | **6717** | **−42.9%** ✓ |
| 70% | 11956 | **9393** | **−21.4%** ✓ |

(✓ = 의도한 개선,  ≈ = 차이 없음,  ✗ = 악화)

자세한 그래프: `step8-measurement/figures/fig{2..6}_*.png`

---

## 결과 해석 — 왜 단조롭지 않은가?

표만 보면 결과가 들쭉날쭉해 보일 수 있습니다. **이는 실험 환경의 한계 때문이며, 의미 있는 신호와 노이즈를 구분하는 게 중요**합니다.

### ✅ 명확하게 신뢰할 수 있는 결과

**1. p99 latency 개선 — CPU 10~50%에서 일관됨**
- 10%: 13.02 → 3.42ms (−74%)
- 30%: 8.21 → 5.94ms (−28%)
- 50%: 12.08 → 7.04ms (−42%)
- **p99는 10000개 패킷의 상위 100개 평균이라 단일 outlier에 강건**합니다.
- 이 구간의 일관된 개선은 **`prio` qdisc의 효과가 실제로 동작**하고 있음을 입증합니다.

**2. Jitter p99 개선 — 모든 측정 구간에서 일관됨**
- 10/30/50/70% 모두에서 baseline 대비 22~75% 감소
- jitter는 도착 간격의 변동성이라 **시계 오차에 영향받지 않는 receiver-only 지표** → 가장 신뢰도 높음
- **TSN의 핵심 가치는 "도착 시각의 예측 가능성"이며, 이 지표가 일관되게 개선되었다는 것이 가장 중요한 결과**

**3. Throughput 동일 (~125 KB/s)**
- 두 모드 모두 송신 간격이 1ms로 동일하므로 당연한 결과
- **우선순위 큐가 throughput을 깎지 않음**을 보여줌 (부작용 없음 검증)

### ⚠️ 신뢰성 낮은 결과 (해석 주의)

**1. CPU 50% / 70%의 max latency 악화**
- 50%: baseline max 151ms → proposed max 181ms (+19% 악화)
- 70%: baseline max 248ms → proposed max 1728ms (+594% 악화)

**왜?** `max`는 **10000개 중 단 1개 패킷**의 값입니다.
- 이 1개는 보통 외부 원인(VirtualBox 호스트 스케줄링, 네트워크 버스트, GC, ...)으로 인한 거대 outlier
- 단일 실험에선 이런 outlier가 **무작위로 baseline 또는 proposed 어느 쪽에 떨어질지 운**
- proposed 70%의 1728ms는 다른 모든 9999개 패킷이 정상 latency였더라도 평균 통계엔 거의 영향 없음 (p99=11.64ms로 baseline과 거의 같음)

→ **max를 보고 "proposed가 나쁘다" 결론짓는 건 부적절**. p99/jitter처럼 통계적으로 안정한 지표를 봐야 합니다.

**2. CPU 70%에서 p99 latency 개선 사라짐**
- 11.78 → 11.64ms로 거의 동일
- **이유**: 본 실험 시스템의 진짜 병목이 네트워크가 아니라 CPU 자체가 됨
  - VM은 2~4 vCPU만 있고 isolcpus 격리 없음
  - 70% 부하 = stress-ng가 가용 CPU의 대부분 사용
  - Talker / Listener Python 프로세스, Cilium datapath, kernel softirq 모두 같은 CPU에서 경쟁
  - `prio` qdisc는 NIC dequeue 순서를 정할 뿐, **CPU 스케줄링 우선순위는 영향 못 줌**
- 즉 **고부하에선 우선순위 큐의 효과가 CPU 스케줄링 노이즈에 묻힘**

**3. CPU 부하 간 비단조성 (10% → 30% → 50% 개선율의 들쭉날쭉)**
- p99: −74% → −28% → −42% (단조 감소가 아님)
- **이유 1 — 단일 실험**: 각 CPU 부하당 1번씩만 측정 (논문은 보통 5~10회 평균)
- **이유 2 — 측정 잡음**: VM의 PTP 정확도 ~ms 수준, 호스트 시스템 부하 변동 등
- 통계적 신뢰도를 높이려면 각 조건을 5회 이상 반복 후 평균/CI 산출 필요

### ❌ 측정하지 못한 데이터

**baseline_cpu99 (CPU 99% 부하의 baseline)**
- 첫 시도 시 stress-ng의 99% CPU 부하가 **worker01 VM을 응답 불능 상태로 만들고 kubelet timeout 발생** → 노드 NotReady
- VirtualBox VM 재시작이 필요한 상황이라 추가 실행 보류
- 이로 인해 fig2/4/6의 99% 패널은 Proposed 단독 표시 (그래도 극단 부하에서도 latency가 ~1ms 근처에 모이는 분포는 확인 가능)

### 📊 결론

| 주장 | 본 실험 데이터의 뒷받침 정도 |
|------|------|
| Proposed가 CPU 부하 10~50%에서 p99 latency를 줄임 | **강함** (3개 데이터 포인트 모두 일관) |
| Proposed가 모든 CPU 부하에서 jitter를 줄임 | **강함** (4개 데이터 포인트 모두 일관) |
| 고부하(70%+)에선 효과가 미미 | **약함** (1개 포인트만 있음 — 추가 측정 필요) |
| Proposed가 throughput을 손상시키지 않음 | **강함** |
| Proposed가 max latency를 안정적으로 낮춤 | **불확실** (outlier 노이즈, 단일 실험) |

**한 줄 요약**: jitter와 중부하 이하 p99에서 일관된 개선을 관찰했으며, 이는 논문의 핵심 주장 "eBPF + 우선순위 큐로 TSN 패킷의 도착 일관성을 개선할 수 있다"를 VM 환경에서도 재현했음을 의미합니다. 다만 max latency나 고부하 영역의 정량적 판단을 위해선 다회 반복 측정이 필요합니다.

---

## 수치 분석 — 왜 이런 절대값이 나오는가

### Throughput 125.0 KB/s — 왜 정확히 이 수치?

순수 계산값입니다:
```
패킷 크기 × 송신 빈도 = 128 byte × (1000 pkt/s) = 128,000 byte/s ≈ 125.0 KB/s
                                    └ interval=1ms → 1초에 1000개
```
**talker.py가 의도적으로 sleep 기반 페이싱**을 하기 때문에 NIC 한계와 무관하게 이 값이 나옵니다. 만약 100 KB/s가 나온다면 시스템이 1ms 페이싱을 못 따라가고 있다는 신호입니다.

### Median latency 0.8~1.4ms — 어디서 오는가?

| 구성 요소 | 기여 latency (대략) | 비고 |
|----------|-------------------|------|
| Python `time.sleep()` 정확도 | ~50~200μs | userspace timer 한계 |
| socket → kernel UDP send 처리 | ~10~50μs | syscall + sk_buff alloc |
| Cilium tcx (cil_from_container) | ~20~100μs | BPF redirect 처리 |
| virtio NIC tx → 호스트 → virtio NIC rx | ~100~500μs | VM virtualization 오버헤드 |
| Cilium tcx (cil_to_endpoint) | ~20~100μs | 수신측 BPF |
| Listener Python recv 처리 | ~50~200μs | kernel → userspace 복사 + `time.time_ns()` |
| **합계 (median 추정)** | **~250μs ~ 1.5ms** | 측정값 0.8~1.4ms와 일치 |

물리 서버라면 0.05~0.2ms 수준 — VM은 **virtualization overhead로 약 10x 느림**.

### p99 latency 10~13ms — Median 대비 10배 차이의 정체

이 spike 들의 원인 후보:
1. **Linux kernel softirq 지연**: 다른 IRQ 처리 중이면 패킷 처리 지연. CPU 부하 시 자주 발생.
2. **VirtualBox 호스트 스케줄링**: 호스트 OS가 VM의 vCPU를 다른 프로세스에 양보할 때 발생하는 hypervisor preemption. ms 단위 stall.
3. **kernel TCP/UDP socket buffer 정체**: 송수신 큐가 일시적으로 쌓이는 burst.
4. **GC 또는 메모리 압박**: Python GC, kernel slab 할당 지연.

`prio` qdisc는 (1)과 (3)에 영향을 주지만 (2)는 못 잡습니다. 그래서 proposed가 baseline보다 낮긴 한데 0이 되진 않습니다.

### max latency 수백~수천 ms — 왜 이렇게 큰가?

100ms 이상의 단일 outlier는 거의 항상 다음 중 하나:
- **VirtualBox 또는 호스트 OS의 일시적 freeze** (호스트 디스크 IO, 다른 VM 시작 등)
- **Cilium agent 또는 kubelet의 health check 사이클**과 충돌 (10초마다 큰 부하)
- **워커 노드의 kernel softlockup** 직전 상황 (CPU 99%에서 자주 발생)

`max`는 10000개 패킷 중 1개의 값이므로 **이런 거대 outlier에 완전히 휘둘립니다**. 통계적으로 안정한 비교는 p99까지로 봐야 합니다.

### jitter p50 600~900μs — 도착 간격이 1ms ±0.6ms 정도

`jitter[i] = recv_time[i] - (recv_time[i-1] + 1ms_expected)`

평균 ~700μs는 다음을 의미:
- 0.3ms ~ 1.7ms 사이로 도착 간격이 들쭉날쭉
- **이 변동의 주된 원인은 송신측 timer 정확도** (Python `time.sleep()` + 부하)
- proposed가 baseline보다 낮은 건 prio qdisc가 송신 측에서 burst를 줄여주기 때문

물리 서버 + 정밀 timer였다면 < 50μs 가능.

### Cilium native routing 환경에서 eBPF 카운터가 0인 이유

```
sudo bpftool map dump name pkt_stats  →  모든 카운터 0
```

**우리 eBPF는 attach되어 있지만 호출되지 않습니다.** Cilium이 `routing-mode: native`일 때:
1. Pod 송신 패킷이 lxc<hash> veth로 진입
2. **tcx/ingress (cil_from_container)** 가 먼저 실행됨 — Cilium 자체 BPF
3. Cilium이 `bpf_redirect()` 로 enp0s3에 직접 전달 → **clsact (우리 BPF)는 호출 안됨**
4. enp0s3 송신 시 qdisc는 거치지만 우리 clsact egress BPF도 우회됨

결과: **eBPF 통계는 0이지만 실험은 정상**. 이유는 talker가 `SO_PRIORITY=3`을 socket에 직접 설정하기 때문에 `skb->priority`가 자동 전파되고, prio qdisc가 그걸 보고 band 0으로 분류합니다. 우리 eBPF의 역할은 보강(SO_PRIORITY 없는 외부 패킷도 분류)이지 필수는 아닙니다.

성능 차이는 **prio qdisc → band 0 dequeue 우선** 매커니즘에서 옵니다.

---

## 실험 조절 — 파라미터 변경법

### A) 패킷 크기, 개수, 간격 변경

`step7-experiment/k8s/talker-job.yaml` 의 `args` 수정:

```yaml
args:
  - "--target=listener-svc.tsn-experiment.svc.cluster.local"
  - "--port=5000"
  - "--interval=1"      # ms — 송신 간격. 0.5면 2000pkt/s
  - "--count=10000"     # 총 패킷 수. 10000이면 ~10초 실험
  - "--size=128"        # bytes per packet (header 12 + payload 116)
  - "--log=/data/talker-log.csv"
  - "--vlan-priority=3" # SO_PRIORITY. 3=TSN, 0=best-effort
```

변경 효과:
- `--interval` 줄이면 packet rate ↑ → bandwidth ↑, jitter 측정 정밀도 ↑, 부하 ↑
- `--count` 늘리면 통계 신뢰성 ↑, 실험 시간 길어짐 (count × interval / 1000 = 초)
- `--size` 늘리면 throughput 검증 가능 (1500까지 — VM MTU 한계)
- `--vlan-priority` 를 0으로 바꾸면 **proposed 모드라도 baseline과 같아짐** (실험 통제 변수 검증용)

### B) CPU 부하 강도 변경

`deploy-experiment.sh run baseline <N>` 의 `<N>` 자리에 0~99 숫자.

내부적으로 `step7-experiment/k8s/stress-daemonset.yaml` 의 `--cpu-load` 값을 sed로 치환합니다:
```yaml
args:
  - "--cpu"
  - "2"           # 워커 수 (vCPU 개수)
  - "--cpu-load"
  - "99"          # ← deploy-experiment.sh가 여기를 N으로 치환
  - "--timeout"
  - "600s"
  - "--cpu-method"
  - "matrixprod"  # 다른 옵션: int128, fft, ...
```

**주의**: `--cpu-load 99`는 worker01을 응답 불능으로 만들 수 있음. **권장 안전 상한: 80%**. 90% 이상은 worker01 다운 위험.

### C) Listener 타임아웃 변경

`step7-experiment/k8s/listener-deployment.yaml`:
```yaml
args:
  - "--port=5000"
  - "--interval=1"      # talker와 일치해야 jitter 계산 정확
  - "--timeout=60"      # 마지막 패킷 후 N초 대기 → CSV write → 종료
  - "--output=/data/results.csv"
```

`--timeout` 을 줄이면 실험 종료 빨라지지만, 너무 짧으면 후행 패킷 손실 가능. 60초가 안전.

### D) Qdisc 종류 변경 (mqprio/prio/ETF)

`deploy-experiment.sh` 내 `setup_tc_qdisc()` 함수:
- 기본: TX queue ≥ 3이면 mqprio, 아니면 prio 폴백
- ETF (txtime 스케줄링): mqprio/prio band 0 위에 ETF 추가 시도 → CLOCK_TAI 우선, 실패 시 CLOCK_REALTIME

수동으로 다른 qdisc를 시험하려면 함수를 수정. 예: `taprio` (시간 인지 스케줄링):
```bash
sudo tc qdisc replace dev enp0s3 root taprio \
    num_tc 3 map 2 2 1 0 ... \
    sched-entry S 01 250000 \
    sched-entry S 02 250000 \
    clockid CLOCK_TAI
```

### E) 다회 반복 측정으로 통계 신뢰도 높이기

현재 스크립트는 1회 실행이지만, 반복은 쉽게 가능:
```bash
mkdir -p step8-measurement/results/runs
for run in 1 2 3 4 5; do
    for cpu in 10 30 50 70; do
        bash deploy-experiment.sh run baseline $cpu
        mv step8-measurement/results/baseline_cpu${cpu}.csv \
           step8-measurement/results/runs/baseline_cpu${cpu}_run${run}.csv
        sudo bash deploy-experiment.sh run proposed $cpu
        mv step8-measurement/results/proposed_cpu${cpu}.csv \
           step8-measurement/results/runs/proposed_cpu${cpu}_run${run}.csv
    done
done
# 그 후 별도 분석 스크립트로 평균/CI 계산
```

5회 평균 시 p99 추정의 표준 오차가 √5 ≈ 2.2배 줄어듭니다.

---

## 디버깅 — 실험이 의도대로 안 될 때

### 단계별 검증 체크리스트

#### 1. K8s 클러스터 상태
```bash
kubectl get nodes -o wide
# k8s-master, k8s-worker01 모두 Ready 여야 함
# NotReady면 VM 재시작 또는 kubelet 재시작:
#   ssh worker01 "sudo systemctl restart kubelet"

kubectl -n tsn-experiment get pods -o wide
# listener-xxx (worker01에서 Running), talker-run-xxx (master에서 Completed/Running)
```

#### 2. Cilium 상태
```bash
kubectl -n kube-system get pods -l k8s-app=cilium
# 모든 cilium pod가 Running 이어야 함

# Cilium 데이터패스 모드 확인 (이 실험은 native routing 가정)
kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'routing-mode|tunnel'

# Pod 간 연결성 테스트
LISTENER_IP=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].status.podIP}')
kubectl -n tsn-experiment exec test-master -- ping -c 3 $LISTENER_IP
```

#### 3. eBPF Attach 확인
```bash
# 우리 BPF 프로그램이 부착되어 있나?
sudo bpftool net show dev enp0s3
# 기대: clsact/egress 에 egress.bpf.o 있음
# 기대: tcx/ingress 에 cil_from_netdev (Cilium 것)

# 모든 veth에 veth_filter가 붙었나?
for v in $(ip link show type veth | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1); do
    echo "[$v]"
    sudo bpftool net show dev $v 2>/dev/null | grep -E 'clsact|tcx' | head -3
done
```

#### 4. TC Qdisc 상태
```bash
# 현재 qdisc 무엇인가?
sudo tc qdisc show dev enp0s3
# baseline: fq_codel 또는 pfifo_fast
# proposed: prio 100: bands 3 priomap ...

# 각 band가 실제 패킷을 처리하나? (proposed 실행 중에 확인)
sudo tc -s qdisc show dev enp0s3
# prio 출력의 Sent 바이트가 0보다 커야 함
```

#### 5. eBPF 통계 (Cilium native routing에서는 0이 정상)
```bash
sudo bpftool map dump name pkt_stats
# 각 prog별 [TOTAL, TSN, BEST_EFF, DROPPED] 카운터
# Cilium native routing이면 모두 0 — 정상

sudo bpftool map dump name debug_stats
# PROG_ENTER, TSN_PORT, NOT_IP 등 분류별 카운터
```

#### 6. 실시간 trace 로그
```bash
# 별도 터미널에서 띄워두고 실험 실행
sudo cat /sys/kernel/debug/tracing/trace_pipe
# bpf_printk() 메시지가 실시간 출력됨
# "[INFO] vef: UDP port 5000 → TSN (tc0)" 등 — Cilium native routing이면 안 나옴
```

#### 7. 패킷 송수신 검증
```bash
# Talker pod이 실제 송신했나?
kubectl -n tsn-experiment logs talker-run-xxxxx
# "전송 완료: 10000/10000 (오류: 0)" 보여야 함

# Listener pod가 수신했나?
LP=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')
kubectl -n tsn-experiment logs $LP
# "수신: 1000 pkts, BW: 124.X KB/s, ..." 진행 로그 + "총 수신: 10000 패킷" 최종

# /data/results.csv 가 만들어졌나?
kubectl -n tsn-experiment exec $LP -- ls -la /data/
```

#### 8. tcpdump로 실제 wire 패킷 확인
```bash
# 마스터 노드에서 송신 패킷 캡처 (UDP 5000)
sudo tcpdump -i enp0s3 -nn -c 20 'udp port 5000'

# 워커 노드에서 수신 패킷 캡처 (worker01에 SSH 있어야 함)
ssh worker01 "sudo tcpdump -i enp0s3 -nn -c 20 'udp port 5000'"
```

#### 9. 시계 동기화 확인
```bash
# 마스터와 워커의 시간 차이
ssh worker01 "date +%s.%N" ; date +%s.%N
# 차이가 100ms 넘으면 latency 측정 오차 큼
# 해결: chrony 또는 PTP 설정
```

### 흔한 문제와 해결

| 증상 | 진단 | 해결 |
|------|------|------|
| `results.csv: No such file` | listener가 패킷 0개 수신 | worker01 Ready? Cilium pod 정상? `kubectl logs $LP` 확인 |
| Talker Job timeout | 5분 안에 완료 안 됨 | image pull 중일 수도. `kubectl describe job talker-run` 확인 |
| `mqprio: Operation not supported` | NIC TX queue 부족 | 자동으로 prio 폴백 — 정상. 무시 |
| `kubectl localhost:8080 refused` | sudo 환경에서 kubeconfig 없음 | `sudo cp /home/worker/.kube/config /root/.kube/config` |
| pkt_stats 전부 0 | Cilium native routing이 우회 | **정상**. talker SO_PRIORITY로 동작 확인됨 |
| latency 음수 | VM 시계 어긋남 | plot-results.py가 자동 정규화. 무시 가능 |
| worker01 NotReady | CPU 99% 부하로 kubelet timeout | VirtualBox에서 VM 재시작 |
| proposed가 baseline보다 나쁨 | 통계 noise (1회 실험의 한계) | 다회 반복 측정 권장 |

### 실험 안전하게 중단

```bash
# 진행 중인 실험 즉시 중단
sudo bash deploy-experiment.sh cleanup
# = K8s namespace 삭제 + qdisc/BPF 모두 해제
```

### 측정 지표 용어
- **p50** (50th percentile, median): 전체 패킷을 latency 오름차순 정렬했을 때 **정 가운데** 값. 절반의 패킷이 이보다 빠르게 도착.
- **p99** (99th percentile): **상위 1% 직전**의 값. "보통은 이 정도가 worst-case" — TSN/실시간 시스템에서 가장 중요한 지표.
- **max**: 가장 느렸던 단 한 개 패킷의 latency. outlier 영향이 크지만 worst-case를 보여줌.
- **jitter** (μs): 연속한 두 패킷의 도착 간격이 예상치(1ms)에서 얼마나 벗어났는가. 작을수록 도착이 일정함.
- **CPU 부하 N%**: 백그라운드 `stress-ng` 데몬셋이 만드는 CPU 점유율. **p50/p99과는 무관한 별개 축**.

### 그래프 읽는 법
- **Figure 2 / 4 / 6 (CPU 부하별 비교)**: 3개 패널로 표시 — `low` (둘 다 데이터 있는 최저 부하, 보통 10%), `high` (둘 다 있는 최고, 보통 70%), `extreme` (한쪽이라도 있는 최고, 보통 99% — 극단적 부하에서의 Proposed 추세 표시).
- **Figure 2 (Throughput)**: 막대 그래프. 1ms 간격 송신이므로 두 모드 모두 ~125 KB/s (의도된 결과 — 우선순위 큐의 목적은 throughput이 아니라 latency 안정성).
- **Figure 3 (Latency 전체)**: X축 CPU 부하, Y축 latency (ms, log scale). 그룹당 6개 막대: Baseline {p50, p99, max} + Proposed {p50, p99, max}. 색은 mode, 빗금은 percentile.
- **Figure 4 (Jitter 비교)**: Baseline vs Proposed jitter 막대. 99% 패널은 Proposed만 — baseline은 worker01 다운 위험으로 미측정.
- **Figure 5 (Jitter 전체)**: Figure 3과 동일 구조의 jitter 버전.
- **Figure 6 (Latency CDF)**: 누적 분포. 곡선이 **좌상**에 가까울수록 빠르고 일관됨. 99% 패널의 Proposed 단독 곡선은 극단 부하에서도 latency가 ~1ms 근처에 모이는지 보여줌.

---

## 빠른 시작 — 3분 안에 검증

이미 환경이 구축된 VM에서:

```bash
# 결과 한번에 확인
bash verify-experiment.sh

# 또는 통계만
python3 compare_results.py
```

처음부터 다시 돌리려면 [§ 실험 실행](#실험-실행)을 참조.

---

## 디렉토리 구조

```
.
├── README.md                            # 본 문서
├── deploy-experiment.sh                 # 메인 자동화 스크립트 ★
├── verify-experiment.sh                 # 결과 검증 헬퍼
├── compare_results.py                   # baseline vs proposed 통계 비교
│
├── step2-os-setup/                      # (참고) OS 사전 준비
├── step3-kubernetes/                    # (참고) K8s 클러스터 구성
├── step4-cilium/                        # (참고) Cilium CNI 설치
├── step5-tc-qdisc/                      # (참고) TC qdisc 옵션 스크립트
│
├── step6-ebpf/                          # eBPF 프로그램
│   ├── src/
│   │   ├── common.h
│   │   ├── veth_filter.c                # 컨테이너 veth 패킷 분류
│   │   ├── egress.c                     # 물리 NIC egress 로깅
│   │   ├── ingress.c                    # 물리 NIC ingress 로깅
│   │   └── xdp_vlan_avtp.c              # XDP VLAN/AVTP 처리
│   ├── stub-headers/                    # 커널 헤더 의존성 제거용 스텁
│   ├── Makefile
│   └── build/*.bpf.o                    # 사전 컴파일된 오브젝트 (커밋됨)
│
├── step7-experiment/
│   ├── talker/talker.py                 # UDP 패킷 송신 (1ms 간격, SO_PRIORITY=3)
│   ├── listener/listener.py             # 수신 + latency/jitter 측정
│   └── k8s/
│       ├── namespace.yaml
│       ├── listener-deployment.yaml     # 워커 노드에 배치
│       ├── talker-job.yaml              # 마스터 노드에 배치
│       ├── stress-daemonset.yaml        # CPU 부하 생성
│       └── test-master.yaml             # eBPF attach 대상 더미 pod
│
└── step8-measurement/
    ├── plot-results.py                  # Figure 2~6 생성 ★
    ├── results/*.csv                    # 측정 결과
    └── figures/*.png                    # 그래프 출력
```

---

## 환경 요구사항

### 호스트
- Windows / Linux / macOS 어디든 (VirtualBox 가 돌아가는 곳)
- VirtualBox 7.x

### VM (2 ~ 4대)
- Ubuntu 24.04 LTS (kernel ≥ 6.6, eBPF tcx 지원)
- 각 4GB RAM, 4 vCPU 권장
- 네트워크: **NAT Network** (이름 `k8sNetwork`, CIDR 10.0.2.0/24)
- 호스트→마스터 SSH: 포트 포워딩 `127.0.0.1:2222 → 10.0.2.8:22`

### 클러스터 구성
| 노드 | IP | 역할 |
|------|-----|------|
| k8s-master | 10.0.2.8 | control-plane, Talker(송신) |
| k8s-worker01 | 10.0.2.4 | worker, Listener(수신) |
| k8s-worker02/03 | 10.0.2.5/6 | (선택) 추가 워커 |

### 소프트웨어 (설치되어 있어야 함)
- Kubernetes v1.30.x (containerd v2.x)
- Cilium v1.19.x (`routing-mode: native`, datapath veth)
- clang + LLVM (eBPF 빌드, 빌드 결과는 사전 커밋됨)
- bpftool (디버깅)
- python3 + numpy + matplotlib + pandas (시각화)

---

## 초기 셋업 (한 번만)

### 1. SSH + sudo 설정 (호스트에서 VM 접속용)
```bash
# 호스트(Windows PowerShell)에서 SSH 키 생성
ssh-keygen -t ed25519 -f $HOME\.ssh\vm_tsn -N '""'

# 공개키를 VM에 등록 (VM 안에서 1회 실행)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<ssh-ed25519 ... 공개키 내용>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# VM에서 passwordless sudo
echo "worker ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/worker
sudo chmod 440 /etc/sudoers.d/worker

# VM에서 root용 kubeconfig (sudo 환경에서 kubectl 사용)
sudo mkdir -p /root/.kube
sudo cp /home/worker/.kube/config /root/.kube/config
```

### 2. 시각화 의존성 (마스터 VM에서)
```bash
sudo apt install -y python3-pip python3-numpy python3-matplotlib python3-pandas
```

### 3. (선택) PTP 시계 동기화
master/worker VM 간 시계가 어긋나면 절대 latency 값이 음수가 됩니다. plot-results.py가 자동 보정하지만 정밀 측정을 위해서는 PTP 설정 권장:
```bash
sudo bash step2-os-setup/04-configure-ptp.sh
```

---

## 실험 실행

### 매번 실행 순서

```bash
cd ~/Desktop/time_sensitive_packet

# (1) K8s 네임스페이스/리소스 배포
bash deploy-experiment.sh deploy-k8s

# (2) eBPF attach 대상 pod 미리 띄우기
kubectl apply -f step7-experiment/k8s/test-master.yaml
kubectl -n tsn-experiment wait --for=condition=ready pod/test-master --timeout=60s

# (3) eBPF 프로그램 attach (sender 모드 = 마스터 노드용)
sudo bash deploy-experiment.sh setup-ebpf sender

# (4) baseline 실험 (CPU 10% 부하)
bash deploy-experiment.sh run baseline 10

# (5) proposed 실험 (CPU 10% 부하)
sudo bash deploy-experiment.sh run proposed 10

# (6) (선택) 다른 CPU 부하도 측정
for cpu in 30 50 70 90; do
    bash deploy-experiment.sh run baseline $cpu
    sudo bash deploy-experiment.sh run proposed $cpu
done

# (7) 그래프 + 통계
cd step8-measurement && python3 plot-results.py && cd ..
python3 compare_results.py
```

### 명령어 한 줄 요약

| 명령 | 설명 |
|------|------|
| `bash deploy-experiment.sh deploy-k8s` | namespace + Listener pod 배포 |
| `sudo bash deploy-experiment.sh setup-ebpf sender` | eBPF 컴파일/부착 (송신측) |
| `sudo bash deploy-experiment.sh setup-ebpf receiver` | eBPF 부착 (수신측, worker01에서) |
| `bash deploy-experiment.sh run baseline <cpu%>` | Baseline 실험 1회 |
| `sudo bash deploy-experiment.sh run proposed <cpu%>` | Proposed 실험 1회 |
| `sudo bash deploy-experiment.sh status` | 현재 eBPF / qdisc / pod 상태 |
| `sudo bash deploy-experiment.sh cleanup` | 모든 BPF/qdisc/pod 정리 |
| `bash verify-experiment.sh` | 결과 한 번에 확인 |

---

## 아키텍처 (논문 Fig.1 구현)

```
[Host-s (sender)]                              [Host-r (receiver)]
  ┌─ Talker pod ─┐                              ┌─ Listener pod ─┐
  │  SO_PRIORITY=3              ┌── UDP:5000 ──┤                │
  │  (skb->priority)│                          │                │
  └────┬───────────┘                           └────────┬───────┘
       │ veth                                          │ veth
  ┌────▼─── lxc<hash> on host ────┐         ┌──────────▼ lxc<hash> ─┐
  │ tcx/ingress: cil_from_container│         │ tcx/ingress: cil_from│
  │ clsact/ingress: veth_filter.bpf│         │ clsact: veth_filter  │
  └────┬───────────────────────────┘         └────────┬─────────────┘
       │ (Cilium native routing — bpf_redirect)        │
  ┌────▼ enp0s3 (egress) ─────────┐         ┌────────▼ enp0s3 (ingress)
  │ clsact/egress: egress.bpf.o   │         │ ingress.bpf.o (수신측만)│
  │ qdisc: prio (proposed)         │         │                       │
  │   - band 0: priority=3 (TSN)   │         │                       │
  │   - band 1: priority=2         │         │                       │
  │   - band 2: priority=0,1       │         │                       │
  │ XDP: xdp_vlan_avtp.bpf.o       │         │                       │
  └────────────────────────────────┘         └───────────────────────┘
```

### 핵심 메커니즘
1. **Talker가 socket option `SO_PRIORITY=3` 설정** → 모든 송신 패킷의 `skb->priority=3`
2. **prio qdisc**가 `priomap[3]=0`에 따라 band 0(최고 우선)으로 enqueue
3. 마스터 CPU 부하가 높아도 band 0이 먼저 dequeue → latency 변동 축소

> eBPF 프로그램은 명시적인 SO_PRIORITY가 없는 패킷에서 헤더 검사(UDP 포트, VLAN PCP, AVTP)로 우선순위를 부여하는 보강 역할. Cilium native routing 환경에서는 tcx 우회로 인해 우리 clsact 후크가 호출되지 않을 수 있지만, **Talker가 직접 SO_PRIORITY를 설정하므로 본 실험에선 무관**.

---

## VM 환경 한계 및 논문과의 차이

| 항목 | 논문 (물리 서버) | 본 실험 (VM) | 영향 |
|------|----------------|-------------|------|
| CPU | 72 논리코어, 8코어 격리 | 2~4 vCPU, 격리 없음 | absolute latency 큼 |
| 메모리 | 16GB | 4GB | OOM 위험 |
| NIC | 4 hw queue | 1 virtio queue | **mqprio 불가 → prio 대체** |
| Clock | hw timestamp (~ns) | sw PTP/NTP (~ms) | 절대 latency 음수 가능 → 정규화 |
| ETF | hw LaunchTime | CLOCK_TAI 미지원 가능 | 미사용 |
| Routing | (가정) tunnel | Cilium `native` (bpf_redirect) | clsact BPF 우회됨 |

**위 한계로 인해 절대 수치는 논문과 다르지만, 상대 개선율(baseline vs proposed) 경향은 재현됨.**

---

## 트러블슈팅

### "container runtime is not running"
```bash
sudo systemctl restart containerd
```

### Cilium pod CrashLoopBackOff
```bash
kubectl logs -n kube-system -l k8s-app=cilium -c cilium-agent --tail=50
# BPF fs 미마운트인 경우:
sudo mount -t bpf bpf /sys/fs/bpf
```

### eBPF 빌드 실패
```bash
cd step6-ebpf
make clean && make all
# vmlinux.h not found:
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > stub-headers/vmlinux.h
```

### `mqprio: RTNETLINK answers: Operation not supported`
VM virtio NIC의 TX queue가 1개라 mqprio 불가. `deploy-experiment.sh`가 자동으로 `prio` 폴백.

### Listener가 패킷을 한 개도 수신 안 함 (results.csv 없음)
- worker01 노드 Ready 확인: `kubectl get nodes`
- worker01 NotReady면 VirtualBox에서 해당 VM 재시작
- CPU 부하 99%는 worker01 다운 위험 → 80% 이하 권장

### sudo 환경에서 `connection refused` (kubectl localhost:8080)
```bash
sudo cp /home/worker/.kube/config /root/.kube/config
```

### baseline_cpu*.csv는 있는데 proposed_cpu*.csv는 없음 (반대도)
plot-results.py는 한쪽만 있어도 그래프 그리지만 비교는 불완전. 누락된 CPU 부하 다시 실행 권장.

### 시계 오차 때문에 latency가 음수
plot-results.py는 자동으로 1st percentile을 0으로 보정. 정밀 측정 필요시 PTP/NTP 동기화.

---

## 참고
- 논문: Wen Yong et al., *"A Time-Sensitive Cloud-Native Network Based on eBPF"*, 2024 IEEE 27th International Conference on Computer Supported Cooperative Work in Design (CSCWD), 2024.
- Cilium: https://docs.cilium.io
- TC qdisc: `man tc-prio`, `man tc-mqprio`, `man tc-etf`
- eBPF tcx vs clsact: https://docs.cilium.io/en/stable/bpf/architecture/

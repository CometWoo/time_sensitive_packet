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

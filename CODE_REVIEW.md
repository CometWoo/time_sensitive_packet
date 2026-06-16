# CODE_REVIEW.md — 논문 「A Time-Sensitive Cloud-Native Network Based on eBPF」(Wen et al., CSCWD 2024) 재현 코드 정밀 리뷰

> ⚠️ **이 문서는 이전(3-프로그램 vef/eg/ig) 설계 기준입니다.** 이후 코드는 **단일 프로그램
> 설계로 전면 교체**되었습니다(2026-06). 현재 구조 요약:
> - eBPF 1개: `step6-ebpf/src/vnic_filter.c` — talker **Pod eth0 egress(netns)** 에 attach
>   (`attach-vnic.sh`, `nsenter`). TS 판별(AVTP/PCP≥5/UDP:6000) → `skb->priority=6` → `pkt_count`.
> - qdisc: proposed=`prio`(기본 priomap, priority 6→band 0), baseline=`fq_codel`.
> - 포트 **6000**, priority **6**. 실제 커널/libbpf 헤더. 수신측 측정은 `listener.py` 단독.
> - 제거됨: vef/eg/ig, common.h, XDP, debug_level/pkt_stats/debug_stats/ringbuf, host-side/tcx attach.
> - 최신 코드 설명은 `explain_01_bpf_egress.md`(vnic_filter) 및 README "코드 감사 > 최종 재설계" 절 참조.
> 아래 §1~§21 은 그 이전 설계에 대한 상세 기록으로 보존합니다.

---


> 본 문서는 본 repo에 있는 모든 코드 (eBPF C, 유저스페이스 Python, TC/qdisc 설정 셸, K8s/Cilium YAML, 시각화 스크립트 등) 를 위 논문의 본문/그림/표와 1:1로 매핑하여, 각 코드 블록이 "무엇을 하는지", "논문의 어디에 대응하는지", "왜 필요한지", "누가/언제 실행하는지", "어떤 대안이 있었고 왜 이걸 골랐는지", "VM 환경에서의 한계는 무엇인지" 를 모두 다룹니다. eBPF 프로그램은 추가로 attach 훅 / 커널 스택 경로 / 액션 / BPF map 사용 / 패킷 분류 기준을 별도로 분석하고, 마지막에 End-to-End 패킷 경로 다이어그램을 둡니다.

---

## 📑 목차 (Table of Contents)

1. [개요 및 논문 핵심 요약](#1-개요-및-논문-핵심-요약)
2. [디렉토리 구조 및 파일 카테고리](#2-디렉토리-구조-및-파일-카테고리)
3. [환경설정 (step2-os-setup)](#3-환경설정-step2-os-setup)
   - 3.1 [`01-check-prerequisites.sh`](#31-step2-os-setup01-check-prerequisitessh)
   - 3.2 [`02-install-packages.sh`](#32-step2-os-setup02-install-packagessh)
   - 3.3 [`03-configure-isolcpus.sh`](#33-step2-os-setup03-configure-isolcpussh)
   - 3.4 [`04-configure-ptp.sh`](#34-step2-os-setup04-configure-ptpsh)
4. [Kubernetes 클러스터 (step3-kubernetes)](#4-kubernetes-클러스터-step3-kubernetes)
   - 4.1 [`01-prepare-node.sh`](#41-step3-kubernetes01-prepare-nodesh)
   - 4.2 [`02-init-control-plane.sh`](#42-step3-kubernetes02-init-control-planesh)
   - 4.3 [`03-join-worker.sh`](#43-step3-kubernetes03-join-workersh)
5. [Cilium CNI (step4-cilium)](#5-cilium-cni-step4-cilium)
   - 5.1 [`01-install-cilium.sh`](#51-step4-cilium01-install-ciliumsh)
   - 5.2 [`02-verify-cilium.sh`](#52-step4-cilium02-verify-ciliumsh)
6. [TC / Qdisc 우선순위 큐 (step5-tc-qdisc)](#6-tc--qdisc-우선순위-큐-step5-tc-qdisc)
   - 6.1 [`01-setup-mqprio.sh`](#61-step5-tc-qdisc01-setup-mqpriosh)
   - 6.2 [`02-setup-etf.sh`](#62-step5-tc-qdisc02-setup-etfsh)
   - 6.3 [`03-setup-ets.sh`](#63-step5-tc-qdisc03-setup-etssh)
   - 6.4 [`setup-all-qdisc.sh`](#64-step5-tc-qdiscsetup-all-qdiscsh)
7. [eBPF 프로그램 — 빌드 시스템 (step6-ebpf)](#7-ebpf-프로그램--빌드-시스템-step6-ebpf)
   - 7.1 [`Makefile`](#71-step6-ebpfmakefile)
   - 7.2 [`stub-headers/`](#72-step6-ebpfstub-headers)
8. [eBPF 프로그램 — 공통 헤더 `common.h`](#8-ebpf-프로그램--공통-헤더-commonh)
   - 8.1 [디버그 매크로 시스템](#81-디버그-매크로-시스템-debug_level)
   - 8.2 [VLAN priority ↔ TC class 상수](#82-vlan-priority--tc-class-상수)
   - 8.3 [`pkt_stats` / `debug_stats` BPF maps](#83-pkt_stats--debug_stats-bpf-maps)
   - 8.4 [`stats_inc()` / `dbgstats_inc()` 유틸](#84-stats_inc--dbgstats_inc-유틸)
   - 8.5 [`get_vlan_pcp()` 인라인 함수](#85-get_vlan_pcp-인라인-함수)
9. [eBPF — `veth_filter.c` (논문 Fig.1 "vef")](#9-ebpf--veth_filterc-논문-fig1-vef)
10. [eBPF — `egress.c` (논문 Fig.1 "eg")](#10-ebpf--egressc-논문-fig1-eg)
11. [eBPF — `ingress.c` (논문 Fig.1 "ig")](#11-ebpf--ingressc-논문-fig1-ig)
12. [eBPF — `xdp_vlan_avtp.c` (논문의 "VLAN 802.3 + AVTP 지원")](#12-ebpf--xdp_vlan_avtpc-논문의-vlan-8023--avtp-지원)
13. [eBPF Attach 스크립트](#13-ebpf-attach-스크립트)
   - 13.1 [`step6-ebpf/attach-ebpf.sh`](#131-step6-ebpfattach-ebpfsh)
   - 13.2 [`step6-ebpf/debug-stats.sh`](#132-step6-ebpfdebug-statssh)
14. [실험 워크로드 — Talker / Listener (step7-experiment)](#14-실험-워크로드--talker--listener-step7-experiment)
   - 14.1 [`talker/talker.py`](#141-step7-experimenttalkertalkerpy)
   - 14.2 [`listener/listener.py`](#142-step7-experimentlistenerlistenerpy)
   - 14.3 [`Dockerfile` 두 개](#143-talker--listener-dockerfile)
15. [Kubernetes 매니페스트 (step7-experiment/k8s)](#15-kubernetes-매니페스트-step7-experimentk8s)
   - 15.1 [`namespace.yaml`](#151-namespaceyaml)
   - 15.2 [`listener-deployment.yaml`](#152-listener-deploymentyaml-configmap--service--deployment)
   - 15.3 [`talker-job.yaml`](#153-talker-jobyaml-configmap--job)
   - 15.4 [`stress-daemonset.yaml`](#154-stress-daemonsetyaml)
   - 15.5 [`test-master.yaml`](#155-test-masteryaml)
   - 15.6 [`build-and-deploy.sh`](#156-build-and-deploysh)
16. [메인 자동화 — `deploy-experiment.sh`](#16-메인-자동화--deploy-experimentsh)
   - 16.1 [`setup_ebpf()`](#161-setup_ebpf)
   - 16.2 [`setup_tc_qdisc()` / `remove_tc_qdisc()`](#162-setup_tc_qdisc--remove_tc_qdisc)
   - 16.3 [`deploy_k8s()`](#163-deploy_k8s)
   - 16.4 [`run_experiment()`](#164-run_experiment)
   - 16.5 [`cleanup()` / `status()`](#165-cleanup--status)
17. [측정·분석 (step8-measurement)](#17-측정분석-step8-measurement)
   - 17.1 [`plot-results.py`](#171-step8-measurementplot-resultspy)
   - 17.2 [`compare_results.py`](#172-루트compare_resultspy)
   - 17.3 [`verify-experiment.sh`](#173-루트verify-experimentsh)
18. [전체 End-to-End 패킷 경로 (Time-Sensitive vs Best-Effort)](#18-전체-end-to-end-패킷-경로-time-sensitive-vs-best-effort)
19. [논문 ↔ 코드 차이 표](#19-논문--코드-차이-표-vm-환경의-우회-및-타협)
20. [논문 외 추가 구현 모음](#20-논문-외-추가-구현-모음)
21. [코드 감사 변경 요약 (2026-06)](#21-코드-감사-변경-요약-2026-06)

---

## 1. 개요 및 논문 핵심 요약

### 1.1 논문 (Wen et al., CSCWD 2024) 의 핵심 주장

논문은 **Cilium 기반 클라우드 네이티브 네트워크**에 eBPF 프로그램을 추가하고, **Linux 커널의 TC qdisc (mqprio / ETF / ETS)** 와 결합하여, time-sensitive 트래픽(예: AVTP, VLAN PCP=3)에 대해 **bounded latency / low jitter** 를 보장하는 아키텍처를 제안합니다. 핵심 구성 요소:

| 구성 요소 | 논문에서의 역할 |
|---|---|
| **vef** (veth-filter) | 컨테이너 veth peer에 attach. 패킷 헤더(VLAN PCP, AVTP, …) 검사 후 time-sensitive 패킷에만 `TC_ACT_OK`(underlay 직행), 일반 패킷은 `TC_ACT_UNSPEC`(기존 overlay 경로) |
| **eg** (egress) | 호스트 물리 NIC egress에 attach. `skb->priority` 를 TC class에 매핑하여 mqprio 큐로 분류 |
| **ig** (ingress) | 호스트 물리 NIC ingress에 attach. 수신 타임스탬프 기록, time-sensitive 패킷 통계 |
| **XDP VLAN/AVTP** | Cilium XDP 드라이버에 VLAN 802.1Q/802.1AD + AVTP(IEEE 1722, EtherType 0x22F0) 파싱 추가 |
| **mqprio** | 4개 하드웨어 TX 큐를 3개 트래픽 클래스(tc0/tc1/tc2)에 매핑. tc0 → queue 1 (TSN), tc1 → queue 2, tc2 → queue 3,4 |
| **ETF** | mqprio tc0 큐 위에 child qdisc로 추가, CLOCK_TAI 기준 delta 150μs 로 txtime 스케줄링 |
| **ETS / taprio** | 게이트 제어 리스트(1ms 주기, slot당 125μs/125μs/750μs) 로 IEEE 802.1Qbv 시간 인지 셰이퍼 흉내 |
| **PTP** | NIC 하드웨어 타임스탬프로 ns 정밀도의 시간 동기화 |
| **isolcpus** | 72코어 중 8코어를 격리하여 네트워크 데이터패스 전용 사용 |

### 1.2 본 repo (재현 실험) 의 환경 차이 (요약)

| 항목 | 논문 (물리 서버) | 본 repo (VirtualBox VM) |
|---|---|---|
| CPU | 72 논리코어, 8코어 격리 | 2~4 vCPU, isolcpus 미적용 |
| RAM | 16 GB | 4 GB |
| NIC | 하드웨어 큐 4개 (i225 등) | virtio-net, TX queue 1개 |
| Clock | 하드웨어 PTP (~ns) | 소프트웨어 PTP/chrony (~ms) |
| XDP | native 모드 (driver hook) | xdpgeneric 모드 (skb 경유) |
| Routing | (가정) overlay/tunnel | Cilium `routing-mode: native` (bpf_redirect) → clsact 우회 |
| ETF clockid | CLOCK_TAI hw offload | CLOCK_REALTIME 폴백, software-only |
| qdisc | `mqprio` 가능 | `prio` 폴백 (queue 부족) |

이로 인해 본 repo의 절대 지연 값은 논문 대비 약 10× 큽니다(VM 가상화 오버헤드). 그러나 **상대 개선율 (Baseline vs Proposed)** 경향은 재현됩니다 (CPU 10~50% 부하에서 p99 latency 28~74% 감소, 모든 부하에서 jitter p99 21~75% 감소; 자세한 수치는 [README.md](README.md) 참조).

### 1.3 논문 Figure 1 (시스템 아키텍처) 의 본 repo 매핑

논문 Fig.1 은 sender host (Host-s)와 receiver host (Host-r)를 그리고, 각 호스트 안에서:
- pod 의 송신 패킷 → veth → **vef** → underlay or overlay 분기
- underlay 경로의 NIC egress 직전 → **eg**
- NIC ingress 직후 → **ig**
- 4-queue NIC → mqprio + ETF/ETS

본 repo는 이를 다음과 같이 구현합니다.

```
[Host-s = k8s-master (10.0.2.8)]                [Host-r = k8s-worker01 (10.0.2.4)]
  ┌─ talker pod ─────┐                          ┌─ listener pod ───┐
  │ talker.py        │                          │ listener.py      │
  │ SO_PRIORITY=3    │── UDP:5000 ──────────────▶                  │
  └────┬─────────────┘                          └────────┬─────────┘
       │ veth (pod 쪽)                                   │ veth (pod 쪽)
   lxc<hash> (호스트 쪽)                             lxc<hash> (호스트 쪽)
       │ ← clsact ingress: veth_filter.bpf.o  ←── 논문 "vef"
       │ ← (Cilium tcx: cil_from_container)
       │ bpf_redirect(enp0s3, ...)
   enp0s3 egress                                  enp0s3 ingress
       │ ← clsact egress: egress.bpf.o ←── "eg"       │ ← clsact ingress: ingress.bpf.o ←── "ig"
       │ ← xdpgeneric: xdp_vlan_avtp.bpf.o
       │ ← qdisc: prio bands 3 (proposed) / fq_codel (baseline)
       ▼                                              ▼
    NAT Network 10.0.2.0/24 (VirtualBox)
```

---

## 2. 디렉토리 구조 및 파일 카테고리

실행 시간 순으로 카테고리를 묶으면:

| 카테고리 | 디렉토리 / 파일 | 역할 |
|---|---|---|
| **0. 문서** | `README.md`, `CODE_REVIEW.md`(본 문서) | 사용 가이드, 본 리뷰 |
| **1. OS 사전 준비** | `step2-os-setup/01-check-prerequisites.sh`<br>`step2-os-setup/02-install-packages.sh`<br>`step2-os-setup/03-configure-isolcpus.sh`<br>`step2-os-setup/04-configure-ptp.sh` | 커널/도구/CPU 격리/PTP 설정 |
| **2. Kubernetes 클러스터** | `step3-kubernetes/01-prepare-node.sh`<br>`step3-kubernetes/02-init-control-plane.sh`<br>`step3-kubernetes/03-join-worker.sh` | kubeadm + containerd 클러스터 |
| **3. Cilium CNI** | `step4-cilium/01-install-cilium.sh`<br>`step4-cilium/02-verify-cilium.sh` | Cilium 1.15.6 helm 설치, kube-proxy 대체, native routing |
| **4. TC / Qdisc** | `step5-tc-qdisc/01-setup-mqprio.sh`<br>`step5-tc-qdisc/02-setup-etf.sh`<br>`step5-tc-qdisc/03-setup-ets.sh`<br>`step5-tc-qdisc/setup-all-qdisc.sh`<br>(+ `deploy-experiment.sh` 내 `setup_tc_qdisc()`) | 우선순위 큐 / txtime / 게이트 제어 |
| **5. eBPF 빌드 시스템** | `step6-ebpf/Makefile`<br>`step6-ebpf/stub-headers/` | clang BPF 타겟 빌드, IntelliSense 스텁 |
| **6. eBPF 소스** | `step6-ebpf/src/common.h`<br>`step6-ebpf/src/veth_filter.c` (**vef**)<br>`step6-ebpf/src/egress.c` (**eg**)<br>`step6-ebpf/src/ingress.c` (**ig**)<br>`step6-ebpf/src/xdp_vlan_avtp.c` | 논문 Fig.1 의 데이터 평면 |
| **7. eBPF Attach / 디버그** | `step6-ebpf/attach-ebpf.sh`<br>`step6-ebpf/debug-stats.sh` | tc filter + xdp link, bpftool map dump |
| **8. 실험 워크로드** | `step7-experiment/talker/talker.py`<br>`step7-experiment/listener/listener.py`<br>`step7-experiment/talker/Dockerfile`<br>`step7-experiment/listener/Dockerfile` | 1ms 간격 UDP 송수신, latency/jitter 측정 |
| **9. K8s 매니페스트** | `step7-experiment/k8s/namespace.yaml`<br>`step7-experiment/k8s/listener-deployment.yaml`<br>`step7-experiment/k8s/talker-job.yaml`<br>`step7-experiment/k8s/stress-daemonset.yaml`<br>`step7-experiment/k8s/test-master.yaml` | pod 배치, CPU 부하, ConfigMap 주입 |
| **10. 통합 자동화** | `deploy-experiment.sh` (★)<br>`step7-experiment/build-and-deploy.sh`<br>`verify-experiment.sh` | 메인 진입점, 빌드/배포/실행/검증 |
| **11. 측정·시각화** | `step8-measurement/plot-results.py`<br>`step8-measurement/results/*.csv`<br>`step8-measurement/figures/*.png`<br>`compare_results.py` | Figure 2~6 생성, baseline vs proposed 통계 비교 |

리뷰 순서는 위 카테고리 번호 순서 (= 실행 순서) 입니다.

---

## 3. 환경설정 (step2-os-setup)

### 3.1 `step2-os-setup/01-check-prerequisites.sh`

**코드 (핵심 발췌)**

```bash
NCPU=$(nproc)
if [ "$NCPU" -ge 4 ]; then pass "최소 4코어 충족"; else fail "..."; fi
...
TX_QUEUES=$(ls -d /sys/class/net/$DEFAULT_IF/queues/tx-* 2>/dev/null | wc -l)
echo "  논문 요구: 4 tx/rx 큐 (하드웨어)"
if [ "$TX_QUEUES" -lt 4 ]; then
    warn "TX 큐 ${TX_QUEUES}개 < 논문 요구 4개. VM virtio NIC는 보통 1~2개."
    warn "→ Step 5에서 소프트웨어 mqprio 대안 사용 예정"
fi
...
MODULES=("br_netfilter" "overlay" "sch_mqprio" "sch_etf" "sch_ets" "cls_bpf" "act_bpf")
for mod in "${MODULES[@]}"; do
    if modprobe -n "$mod" 2>/dev/null; then pass "모듈 $mod 사용 가능"; fi
done
```

**1. 무엇을 하는 코드인가**
호스트 OS 환경이 논문 재현 실험의 요구사항(OS 버전, kernel ≥ 5.15, CPU 코어 수 ≥ 4, RAM ≥ 4GB, NIC TX queue, eBPF/TC qdisc 관련 커널 모듈, BPF FS, eBPF 컴파일 도구)을 만족하는지 [PASS]/[WARN]/[FAIL] 로 분류해 출력하는 게이트키퍼 스크립트.

**2. 논문과의 매핑**
논문은 §III(Implementation) 첫 문단에서 "Ubuntu 22.04, kernel 5.15.0-72-generic, 72 cores, 16GB RAM, NIC with 4 tx/rx queues, PTP synchronization" 을 명시. 이 스크립트는 그 명세를 자동 점검합니다. `sch_mqprio`, `sch_etf`, `sch_ets`, `cls_bpf`, `act_bpf` 모듈 체크는 논문의 mqprio + ETF + ETS qdisc + cls_bpf(TC eBPF) 사용을 자동 검증.

**3. 왜 필요한가 (Why)**
- BPF FS 미마운트 / `cls_bpf` 부재 시 모든 TC eBPF attach가 실패.
- TX queue 1~2개인 VM에서 mqprio `hw 1` 명령은 `RTNETLINK answers: Operation not supported` 에러로 즉시 실패 → 사용자는 원인을 못 찾을 수 있음. 사전 경고로 폴백 경로(prio qdisc)로 자동 전환됨을 사용자에게 알림.

**4. 누가, 언제 실행하는가**
- 실행 주체: **사용자가 수동** (`bash step2-os-setup/01-check-prerequisites.sh`)
- 실행 시점: VM 프로비저닝 직후 1회, 또는 환경 변경 후 검증용
- 호출 체인: (사용자) → 이 스크립트 → 결과만 보고함 (다른 스크립트 트리거 안 함)

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **이 방식 (커스텀 셸 스크립트)** | 가벼움, 의존성 없음, OS 명령만으로 검증 | OS 분기 어려움, 출력이 정형화 안 됨 |
| Ansible/preflight 플레이북 | 멱등성, 다중 노드 검증 자동화 | Ansible 설치 필요, 학습 곡선 |
| `kubeadm preflight check` | k8s 공식 검증 | TC/BPF/PTP 등 본 논문 특화 검증 부재 |

→ **커스텀 셸 스크립트 선택**: 본 repo는 2~4대 VM 클러스터 + 논문 특화 검증이므로 Ansible은 과잉, kubeadm은 부족. 셸이 적절.

**6. 한계 및 주의사항**
- ⚠️ VM virtio-net 은 `ethtool -L` 로 TX queue를 늘리려 해도 보통 1개만 노출 → [FAIL]이 아닌 [WARN]으로 처리하지만 실제로는 mqprio 미사용을 의미.
- ⚠️ 이 스크립트는 검사만 하며, [FAIL] 발견 시 자동 수정하지 않음. 사용자가 `02-install-packages.sh` 등을 수동으로 실행해야 함.

---

### 3.2 `step2-os-setup/02-install-packages.sh`

**코드 (핵심 발췌)**

```bash
sudo apt-get install -y -qq \
    linux-headers-$(uname -r) \
    linux-tools-$(uname -r) \
    bpfcc-tools libbpf-dev bpftool \
    clang llvm gcc-multilib build-essential libelf-dev pkg-config

# 컨테이너 런타임
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# PTP + stress + Python
sudo apt-get install -y -qq linuxptp chrony stress-ng python3 python3-pip
pip3 install --quiet matplotlib numpy pandas

# 커널 모듈 자동 로드
MODULES=(br_netfilter overlay sch_mqprio sch_etf sch_ets cls_bpf act_bpf veth)
```

**1. 무엇을 하는 코드인가**
재현 실험에 필요한 모든 패키지 (eBPF 빌드 체인, bpftool, containerd, linuxptp, stress-ng, Python 분석 도구, Docker) 를 일괄 설치하고, containerd cgroup driver를 `systemd` 로 강제, 부팅 시 필수 커널 모듈이 자동 로드되도록 `/etc/modules-load.d/tsn-reproduction.conf` 를 생성.

**2. 논문과의 매핑**
- `clang llvm` → §III "We use clang to compile eBPF programs"
- `bpftool` → §III 디버깅·검증 도구
- `linuxptp` → §III "PTP for time synchronization"
- `stress-ng` → §IV-A Experimental Setup "background CPU load via stress-ng"
- `containerd + SystemdCgroup=true` → k8s 1.28 + cgroup v2 환경의 표준 요구사항 (논문 외 — k8s 표준)
- `sch_mqprio / sch_etf / sch_ets` 모듈 적재 → 논문 §IV TC qdisc 설정의 전제

**3. 왜 필요한가**
- clang 없으면 eBPF C → BPF bytecode 컴파일 자체 불가.
- `SystemdCgroup=true` 가 없으면 kubelet ↔ containerd 가 cgroup 누수로 kubelet OOM kill 가능.
- `stress-ng` 가 없으면 논문이 다루는 "CPU 부하 변동 하의 latency 안정성" 시나리오 자체 재현 불가.

**4. 누가, 언제 실행하는가**
- 실행 주체: **사용자 (root)**
- 시점: VM 첫 셋업 1회. 추가 노드 합류 시 그 노드에서도 1회.
- 호출 체인: 없음 (다음 단계 `step3-kubernetes/01-prepare-node.sh` 의 전제)

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **apt + pip (현 방식)** | Ubuntu 기본 환경, 즉시 가능 | clang 버전이 OS에 종속됨 |
| LLVM 공식 .deb (apt.llvm.org) | 최신 clang 16+ 사용 가능 | 저장소 등록 필요 |
| 컨테이너에서 빌드 후 .o 복사 | 호스트 패키지 오염 없음 | containerd 이미 있어야 함, 순환 의존 |

→ **apt + pip 선택**: 논문이 Ubuntu 22.04 기본 환경을 가정. Ubuntu 22.04의 `clang-14` 는 eBPF 빌드에 충분.

**6. 한계 및 주의사항**
- ⚠️ `pip3 install matplotlib numpy pandas` 가 `--break-system-packages` 없이 호출됨 → Ubuntu 24.04 (PEP 668) 에서 실패 가능. README는 Ubuntu 24.04를 권장하므로 실제 환경과 미스매치 — 회피책: `sudo apt install python3-numpy python3-matplotlib python3-pandas` 사용 (README §초기 셋업에서 그렇게 안내).

---

### 3.3 `step2-os-setup/03-configure-isolcpus.sh`

**코드 (핵심 발췌)**

```bash
ISOLATED_CPUS="2,3"  # VM 4코어 기준: CPU 0,1은 시스템, CPU 2,3은 네트워크 전용
...
NEW_PARAMS=$(echo "$NEW_PARAMS" | sed "s/\"$/ isolcpus=$ISOLATED_CPUS nohz_full=$ISOLATED_CPUS rcu_nocbs=$ISOLATED_CPUS\"/")
sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$NEW_PARAMS|" /etc/default/grub
sudo update-grub
```

**1. 무엇을 하는 코드인가**
GRUB 커맨드라인에 `isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3` 을 추가해 부팅 시 CPU 2번과 3번을 일반 스케줄러에서 격리. 격리된 코어는 명시적 `taskset` / `sched_setaffinity` 로만 사용 가능 → talker/listener 및 BPF 핫패스 전용으로 활용 가능.

**2. 논문과의 매핑**
논문 §III "we isolate 8 cores out of 72 for the network data plane via `isolcpus`". 본 repo는 4 vCPU 중 2코어를 격리하여 비율을 흉내냄 (8/72 ≈ 11%, 2/4 = 50% 이지만 절대 코어 수의 한계).

**3. 왜 필요한가**
- 격리 없이는 stress-ng 의 `--cpu 2 --cpu-load 99` 가 talker/listener와 같은 CPU에서 경쟁 → latency가 CPU 스케줄링 지터에 압도되어 prio qdisc 효과 측정 불가.
- `nohz_full` 은 격리 코어에서 주기적 timer tick 제거 → ns 단위 jitter 감소.
- `rcu_nocbs` 는 격리 코어에서 RCU callback 처리를 제거.

**4. 누가, 언제 실행하는가**
- 실행 주체: **사용자(root)**
- 시점: VM 셋업 1회. **재부팅 필수** (커널 부팅 파라미터 변경).
- 호출 체인: (사용자) → grub-update → 재부팅 → 커널이 `init/main.c` 파싱 시 적용

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **`isolcpus` (현 방식)** | 부팅 시 격리, 가장 강력 | 재부팅 필요, 정적 |
| cgroup v2 cpuset (런타임) | 재부팅 불필요, k8s `cpu-manager-policy=static` 와 통합 | 격리 강도 약함 (커널 daemon 침입 가능) |
| `taskset` 단발성 바인딩 | 즉시, 다른 프로세스 영향 없음 | 다른 프로세스가 격리 코어를 자유롭게 쓸 수 있음 |

→ **isolcpus 선택**: 논문 §III와 정확히 일치. cgroup cpuset은 부드러운 격리이고, taskset은 격리가 아닌 affinity일 뿐. 논문이 명시적으로 `isolcpus` 를 썼으므로 충실히 재현.

**6. 한계 및 주의사항**
- ⚠️ **본 repo의 README 상태표 §VM 환경 한계 표는 "isolcpus 미적용" 으로 기록** — 즉 이 스크립트는 제공만 되고 실제 실험은 격리 없이 진행한 듯. 따라서 결과는 격리 없이 측정된 값. 격리를 적용하려면 사용자가 명시적으로 실행 후 재부팅 필요.
- ⚠️ kernel 5.15부터 `isolcpus` 는 deprecated 경고 출력. 권장 대체는 `nohz_full=` + cgroup cpuset 조합. 본 스크립트는 둘 다 추가하므로 호환.
- ⚠️ 4 vCPU 중 2개를 격리하면 시스템에 2개만 남아 kubelet/containerd/Cilium agent 가 경합 → 부하 99% 시나리오에서 worker01 NotReady 가능 (README 트러블슈팅 참고).

---

### 3.4 `step2-os-setup/04-configure-ptp.sh`

**코드 (핵심 발췌)**

```bash
HW_TS=$(ethtool -T "$DEFAULT_IF" 2>/dev/null | grep "hardware-transmit" || true)
if [ -n "$HW_TS" ]; then PTP_MODE="hardware"; else PTP_MODE="software"; fi

if [ "$PTP_MODE" = "software" ]; then
    cat <<'CONF' | sudo tee /etc/linuxptp/ptp4l-sw.conf > /dev/null
[global]
...
time_stamping       software
CONF
    echo "sudo ptp4l -i $DEFAULT_IF -f /etc/linuxptp/ptp4l-sw.conf -S -m"
fi
```

**1. 무엇을 하는 코드인가**
NIC의 하드웨어 타임스탬프 지원 여부를 `ethtool -T` 로 검사하고, 미지원이면 (= VM virtio) `time_stamping software` 모드의 ptp4l 설정 파일을 만들어 둠. chrony NTP 동기화도 동시에 활성화 (백업).

**2. 논문과의 매핑**
논문 §III "Host clocks are synchronized via PTP, allowing latency measurements with sub-microsecond accuracy." 본 repo는 VM 한계로 ns 정밀도 불가 → 소프트웨어 PTP + chrony 로 ~수백 μs ~ ms 정밀도로 타협. README §결과 해석 의 "VM간 시계 오차 보정 (1st percentile → 0 정규화)" 의 근본 원인.

**3. 왜 필요한가**
- master ↔ worker 간 시계가 어긋나면 `latency_ms = recv_ns - send_ns` 가 **음수** 가 됨 (listener.py:89).
- 보정이 없으면 CDF 그래프의 X축이 음의 영역으로 늘어남 → 가독성 파괴.

**4. 누가, 언제 실행하는가**
- 실행 주체: **사용자(root)** — 다만 스크립트가 ptp4l 데몬을 직접 시작하지 않고 "이렇게 실행하세요" 가이드만 출력. 사용자가 별도 `systemctl start ptp4l` 또는 수동 실행해야 함.
- 시점: VM 셋업 후 1회 (설정 파일 생성). 실제 PTP 데몬은 실험 시작 전까지 띄워둬야 함.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **하드웨어 PTP (`time_stamping hardware`)** | ns 정밀도 | virtio NIC 미지원 |
| **소프트웨어 PTP (현 폴백)** | virtio에서도 동작 | ~수백 μs 정밀도 |
| chrony / NTP만 | 설정 가장 단순 | ms 단위 정밀도, 보통 PTP보다 부정확 |
| 단일 노드에서 송수신 (`hostNetwork`, loopback) | 시계 동기화 불필요 | 단일 호스트라 NIC 경로 미실험 → 논문 의도 깨짐 |
| `compare_results.py` 의 1st percentile 정규화 | 시계 동기화 없이도 상대 비교 가능 | 절대값 의미 상실 |

→ **소프트웨어 PTP + 1st percentile 정규화** 조합 선택: 동기화는 비공식 수준으로만 시도하고, 분석 단계에서 보정. VM이면 사실상 다른 선택지가 없음.

**6. 한계 및 주의사항**
- ⚠️ 스크립트가 ptp4l 데몬을 자동 시작하지 않음 → 사용자가 명령을 잊으면 동기화 안 됨. 본 repo README의 측정 결과는 시계 보정 후의 값임.
- ⚠️ 호스트 OS (Windows) 자체가 VirtualBox VM의 시각을 주기적으로 보정 → PTP가 동작 중에도 갑작스러운 step 발생 가능. `chronyc tracking` 으로 모니터링 권장.

---

## 4. Kubernetes 클러스터 (step3-kubernetes)

### 4.1 `step3-kubernetes/01-prepare-node.sh`

**코드 (핵심 발췌)**

```bash
sudo swapoff -a && sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0   # ← Cilium native routing 필수
EOF
sudo modprobe br_netfilter overlay
# kubeadm/kubelet/kubectl 1.28 설치 + apt-mark hold
```

**1. 무엇을 하는 코드인가**
모든 k8s 노드(master + worker)에 공통적으로 필요한 사전 작업:
- swap 비활성화 (kubelet의 hard 요구사항)
- bridge netfilter & ip_forward 활성화 (Pod-to-Pod 통신)
- `rp_filter=0` (Cilium native routing 시 비대칭 라우팅 허용)
- kubeadm/kubelet/kubectl v1.28.x 설치 + `apt-mark hold` 로 자동 업그레이드 차단
- kubelet에 resource reservation (4GB VM 보호)

**2. 논문과의 매핑**
논문 §III 는 Kubernetes 위에서 동작함을 전제로 하지만, kubeadm 설치 절차는 직접 다루지 않음. 이 스크립트는 **논문에 명시되지 않은 구현 디테일** 이며, k8s 공식 가이드 + 논문이 가정하는 "k8s 1.x 클러스터" 환경을 만들기 위한 표준 절차.

**3. 왜 필요한가**
- swap 활성화 상태에서는 kubelet이 시작을 거부 → 클러스터 미생성.
- `bridge-nf-call-iptables=0` 이면 Service VIP의 SNAT 처리 실패.
- 4GB RAM VM은 systemReserved 없이 두면 부하 시 kubelet OOM kill → 노드 NotReady.

**4. 누가, 언제 실행하는가**
- 실행 주체: 사용자 (sudo)
- 시점: VM 셋업 → 패키지 설치 (`02-install-packages.sh`) → 이 스크립트 → control-plane init 또는 join
- 호출 체인: (사용자) → 본 스크립트 → (다음) `02-init-control-plane.sh` 또는 `03-join-worker.sh`

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **kubeadm v1.28 (현)** | 안정, Cilium 1.15.x 와 검증된 조합 | 최신 기능(예: 1.30 의 PodSecurity) 부재 |
| k3s/minikube | 단일 바이너리, 설치 간단 | 본 논문 시나리오(Cilium native + kube-proxy 대체)를 깔끔히 지원 안 함 |
| kubespray (Ansible) | 멀티 노드 자동화 | 학습 곡선, 4GB VM에 무거움 |

→ kubeadm 1.28: README는 1.30을 권장하지만 본 스크립트는 1.28을 박아둠. Cilium 1.15.6 (다음 단계) 의 검증 표에서 가장 안정적인 조합.

**6. 한계 및 주의사항**
- ⚠️ `rp_filter=0` 은 보안적으로 비대칭 라우팅을 허용 → 프로덕션에서는 위험. 실험 환경에서만 사용해야 함.
- ⚠️ README와 스크립트 간 kubernetes 버전 불일치 (스크립트 1.28, README 1.30). 실제 빌드된 본 repo 환경은 스크립트의 1.28이 기준.

---

### 4.2 `step3-kubernetes/02-init-control-plane.sh`

**코드 (핵심 발췌)**

```bash
cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
EOF
sudo kubeadm init --config=/tmp/kubeadm-config.yaml \
    --skip-phases=addon/kube-proxy 2>&1 | tee /tmp/kubeadm-init.log
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
echo "$JOIN_CMD" > "$HOME/worker-join-command.txt"
```

**1. 무엇을 하는 코드인가**
master 노드에서 kubeadm으로 control-plane을 부트스트랩. **핵심 옵션**: `--skip-phases=addon/kube-proxy` — kube-proxy를 설치하지 않음. 이후 Cilium 이 `kubeProxyReplacement=true` 로 그 자리를 대체.

**2. 논문과의 매핑**
논문 §III "We replace kube-proxy with Cilium's eBPF-based service routing, which uses sock_ops and tc programs instead of iptables." 정확히 `--skip-phases=addon/kube-proxy` 가 이 결정에 해당.

**3. 왜 필요한가**
- kube-proxy가 함께 살아 있으면 Service VIP에 iptables/IPVS 규칙이 박힘 → Cilium이 만든 eBPF 규칙과 충돌 / 우선순위 꼬임.
- TSN 패킷의 SO_PRIORITY를 유지하기 위해서는 iptables MASQUERADE 같은 추가 hop이 제거되어야 latency가 일관됨.

**4. 누가, 언제 실행하는가**
- 실행 주체: 사용자 (master 노드에서)
- 시점: 노드 준비(`01-prepare-node.sh`) 완료 후 1회
- 호출 체인: (사용자) → kubeadm init → kubelet 시작 → static pod (etcd, kube-apiserver, kube-controller-manager, kube-scheduler) 기동 → 다음 단계 Cilium 설치 대기

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **`--skip-phases=addon/kube-proxy` (현)** | Cilium full replacement 가능 | kube-proxy 의존 도구(예: kubectl proxy 일부) 영향 |
| 설치 후 `kubectl -n kube-system delete ds kube-proxy` | 같은 효과 | 잠시 동안 두 시스템 공존 → 잠재 충돌 |
| `kube-proxy --proxy-mode=ipvs` 유지 | 인터넷 표준 | Cilium의 socket-level LB와 충돌 |

→ skip 선택: Cilium 1.15.6의 권장 설치 절차에 따른 것.

**6. 한계 및 주의사항**
- ⚠️ 노드 IP 자동 감지(`ip -4 addr show scope global`) 는 단일 NIC 가정. 다중 NIC 환경에서는 잘못된 IP를 advertise할 수 있음.
- ⚠️ `kubernetesVersion: stable` 은 apt에 설치된 kubelet과 다를 수 있음. 실패 시 명시적 버전(`v1.28.x`)로 변경 필요.

---

### 4.3 `step3-kubernetes/03-join-worker.sh`

**코드 (핵심 발췌)**

```bash
if [ $# -ge 1 ]; then JOIN_CMD="$*"; else read -r JOIN_CMD; fi
eval "$JOIN_CMD"
```

**1. 무엇을 하는 코드인가**
master에서 `02-init-control-plane.sh` 가 출력한 `kubeadm join …` 명령을 worker 노드에서 실행하기 위한 단순 wrapper. 인자로 받거나 stdin에서 읽음.

**2. 논문과의 매핑**
논문에 명시되지 않은 구현 디테일. 멀티 노드 클러스터 구성을 위한 표준 단계.

**3. 왜 필요한가**
master/worker가 같은 클러스터에 있어야 listener pod(worker)와 talker pod(master)가 같은 CNI(Cilium)로 통신 가능. 단일 호스트 실험은 NIC을 거치지 않으므로 논문 의도와 맞지 않음.

**4. 누가, 언제 실행하는가**
- 실행 주체: 사용자 (각 worker 노드에서 root로)
- 시점: master init 직후
- 호출 체인: (사용자) → kubeadm join → kubelet이 control-plane으로부터 CA cert + bootstrap token으로 인증 → API server에 NodeReady 등록

**5. 대안과 선택 이유**
- (alt 1) 직접 `kubeadm join …` 입력 → 토큰을 손으로 옮겨야 함. (alt 2) 본 스크립트 wrapper → 동일하지만 prompt가 있어 ergonomic. **선택은 사용성 차이뿐.**

**6. 한계 및 주의사항**
- ⚠️ `eval` 사용 — join 명령에 쉘 메타 문자 들어오면 인젝션 가능. 본 실험 환경에서는 신뢰된 명령만 들어오므로 무시 가능.

---

## 5. Cilium CNI (step4-cilium)

### 5.1 `step4-cilium/01-install-cilium.sh`

**코드 (핵심 발췌)**

```bash
helm install cilium cilium/cilium --version 1.15.6 \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${NODE_IP}" --set k8sServicePort=6443 \
    --set routingMode=native \
    --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
    --set autoDirectNodeRoutes=true \
    --set ipam.mode=kubernetes \
    --set bpf.masquerade=true \
    --set bpf.hostLegacyRouting=false \
    --set devices="${DEFAULT_IF}" \
    --set enableIPv6=false
```

**1. 무엇을 하는 코드인가**
Cilium 1.15.6 을 helm 으로 설치. 핵심 옵션:
- `kubeProxyReplacement=true` — kube-proxy를 eBPF가 대체
- `routingMode=native` — VXLAN/Geneve 없이 호스트 라우팅 (논문이 의도하는 underlay 직행 경로)
- `autoDirectNodeRoutes=true` — 노드 간 라우팅 자동 설정
- `bpf.masquerade=true` — iptables 대신 eBPF SNAT
- `bpf.hostLegacyRouting=false` — 호스트 라우팅 테이블 우회, BPF만 사용
- `devices="${DEFAULT_IF}"` — Cilium이 BPF를 attach할 NIC을 명시

**2. 논문과의 매핑**
- 논문 §III "Cilium with native routing mode" → `routingMode=native`
- 논문 §III "kube-proxy replacement" → `kubeProxyReplacement=true`
- 논문 §III "BPF-based masquerading" → `bpf.masquerade=true`
- 논문 §IV "XDP attachment on physical NIC" → `devices=enp0s3`

**3. 왜 필요한가**
- `routingMode=tunnel` (VXLAN) 이면 패킷이 VXLAN 헤더 캡슐화를 거쳐 추가 50바이트 + UDP 추가 처리 → latency 증가 + skb->priority 정보 손실 위험.
- `bpf.hostLegacyRouting=true` 이면 라우팅이 host stack을 거침 → veth_filter 이후 clsact egress까지 도달하기 전 iptables / netfilter hop 추가 → 측정 latency가 증가, 일관성 떨어짐.

**4. 누가, 언제 실행하는가**
- 실행 주체: 사용자 (master 노드, kubeconfig 보유 상태)
- 시점: kubeadm init 직후
- 호출 체인: helm → k8s API → Cilium operator + DaemonSet 배포 → 각 노드에서 `cilium-agent` 컨테이너가 BPF 프로그램을 `enp0s3` 와 `lxc*` veth에 attach → 노드 Ready

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **Cilium native (현)** | 논문 의도, BPF만으로 처리, 최소 latency | XDP 우회 가능 (Cilium tcx 가 먼저 실행) — 본 repo의 `pkt_stats=0` 현상의 원인 |
| Cilium tunnel (VXLAN) | 다중 클라우드/라우터 호환 | 50B 캡슐화 오버헤드, latency↑, XDP에서 분류 어려움 |
| Calico (iptables) | 안정적, 널리 쓰임 | iptables 사용 → BPF 우선순위 이점 없음, 논문 의도와 다름 |
| Flannel + host-gw | 단순 | 우선순위 제어 어려움, BPF 미사용 |
| Cilium 1.16+ | 최신 기능 | 1.15 대비 일부 옵션 키 변경, 안정성 검증 부족 |

→ **Cilium 1.15.6 native** 선택: 논문 의도 그대로 + helm 옵션이 안정적으로 검증된 버전.

**6. 한계 및 주의사항**
- ⚠️ **Cilium의 tcx hook (cil_from_container) 이 본 repo의 clsact veth_filter 보다 먼저 실행됨.** 그 결과 Cilium이 `bpf_redirect()` 로 패킷을 enp0s3에 직접 보내고, `veth_filter`/`egress` BPF가 호출되지 않는 경우가 있음. → `pkt_stats` 모든 카운터가 0이 되지만, 실험 자체는 talker의 `SO_PRIORITY=3` + prio qdisc 조합으로 정상 동작 (README §결과 해석 의 설명 참조).
- ⚠️ Helm 차트의 `devices=enp0s3` 가 worker 노드의 NIC 이름과 다르면(예: `ens3`) Cilium BPF attach 위치가 어긋남 → Pod 통신 자체가 불가.

---

### 5.2 `step4-cilium/02-verify-cilium.sh`

**코드 (핵심 발췌)**

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium -o wide
cilium status 2>/dev/null || kubectl exec -n kube-system ds/cilium -- cilium status
KUBE_PROXY_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l)
if [ "$KUBE_PROXY_PODS" -eq 0 ]; then echo "정상"; fi
kubectl exec -n kube-system ds/cilium -- cilium status 2>/dev/null | grep -i "routing"
kubectl exec -n kube-system ds/cilium -- cilium bpf endpoint list 2>/dev/null | head -10
```

**1. 무엇을 하는 코드인가**
Cilium 설치 직후 상태(파드 Running, kube-proxy 제거됨, routing mode = native, BPF endpoint 로드됨, 노드 Ready) 를 한 번에 검증.

**2. 논문과의 매핑**
논문에 직접 매핑되지 않는 운영 헬퍼. 다만 논문이 가정하는 환경(native routing + kube-proxy 대체) 이 실제 클러스터에 반영됐는지 확인.

**3. 왜 필요한가**
- Cilium 설치는 helm 명령은 성공해도 cilium-agent가 CrashLoopBackOff 일 수 있음 (BPF FS 미마운트, 커널 기능 부재 등). 이 스크립트로 빠르게 catch.
- routing mode가 의도와 다르면 (e.g., 디폴트 fallback이 tunnel) 본 실험의 native 가정이 깨짐.

**4. 누가, 언제 실행하는가**
- 사용자, Cilium 설치 후, 그리고 매 실험 전 sanity check.

**5. 대안과 선택 이유**
- `cilium connectivity test` (몇 분 소요, 완전 검증) vs 본 스크립트(즉시, 핵심만). 빠른 피드백 우선이라 본 스크립트.

**6. 한계 및 주의사항**
- ⚠️ `cilium connectivity test` 까지 실행하면 더 신뢰성 있는 검증이 되지만 시간(~5분) 과 리소스를 소모하므로 매 실험 전 실행은 비현실적.

---

## 6. TC / Qdisc 우선순위 큐 (step5-tc-qdisc)

### 6.1 `step5-tc-qdisc/01-setup-mqprio.sh`

**코드 (핵심 발췌)**

```bash
TX_QUEUES=$(ls -d /sys/class/net/$IFACE/queues/tx-* 2>/dev/null | wc -l)

if [ "$TX_QUEUES" -ge 4 ]; then
    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@1 2@2 \
        hw 1 \
        mode dcb
else
    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@0 1@0 \
        hw 0
fi
```

**1. 무엇을 하는 코드인가**
NIC TX queue 수에 따라 분기:
- **TX queue ≥ 4**: 논문 원본 — 하드웨어 mqprio (`hw 1 mode dcb`), 3개 트래픽 클래스, queue 1@0 (tc0 단독), 1@1 (tc1 단독), 2@2 (tc2가 queue 2,3 공유). `map 2 2 1 0 …` 은 VLAN priority(0~15) → TC index 매핑: pri 0,1 → tc2 / pri 2 → tc1 / pri 3 → tc0 / 그 외 → tc2.
- **TX queue < 4** (VM): 소프트웨어 mqprio (`hw 0`), 모든 TC가 같은 queue 0 공유. 우선순위 분리는 kernel `mq` 스케줄러가 수행.

**2. 논문과의 매핑**
- 논문 §IV-A Multiqueue Priority 「tc0 corresponds to queue 1, tc1 corresponds to queue 2, tc2 corresponds to queue 3,4」 = `queues 1@0 1@1 2@2`
- 논문 Table I "VLAN priority and TC mapping" : pri 3 → tc0, pri 2 → tc1, pri 0,1,4-15 → tc2 = `map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2`
- VM 폴백(`hw 0`) 은 **논문에 없음** — VM virtio NIC가 TX queue 1개만 노출하기 때문에 추가한 우회로.

**3. 왜 필요한가**
- mqprio 없이는 모든 패킷이 단일 FIFO에 들어가 시간 민감 패킷이 best-effort burst 뒤에 줄을 섬 → tail latency 폭증.
- 하드웨어 mqprio 는 multiqueue NIC의 dedicated TX queue 에 direct mapping → DMA 단계부터 분리.

**4. 누가, 언제 실행하는가**
- 사용자(root). proposed 실험 모드 시작 시 1회. baseline 모드에서는 이 qdisc 제거.
- 호출 체인: (사용자 / deploy-experiment.sh setup_tc_qdisc) → tc → kernel net/sched/sch_mqprio → NIC driver(ndo_setup_tc)

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **mqprio hw 1 (논문)** | 하드웨어 큐 분리, ns 정밀도 | NIC가 mqprio offload 지원해야 함 |
| **mqprio hw 0 (현 VM 폴백)** | 어디서나 동작 | 큐가 1개라 실질적인 큐 분리 안 됨, kernel 측 정렬만 |
| **prio qdisc (deploy-experiment.sh의 추가 폴백)** | 가장 단순, 어디서나 동작 | 클래스 그룹 없이 strict band priority만 |
| **htb / hfsc** | shaping (bandwidth limit) 가능 | 우선순위가 strict 가 아닌 가중치 기반 — TSN에 부적합 |
| **fq / fq_codel** | airtime fairness, AQM | 우선순위 개념 없음, TSN에 부적합 |

→ VM 환경에서는 mqprio `hw 0` 도 실효성이 작아 `deploy-experiment.sh` 는 **prio 로 추가 폴백** 한다 (다음 [§16.2](#162-setup_tc_qdisc--remove_tc_qdisc)). 본 스크립트는 단계별 학습용으로 mqprio만 다룸.

**6. 한계 및 주의사항**
- ⚠️ VM virtio-net 에서 `hw 1` 시도 시 `RTNETLINK answers: Operation not supported`. 본 스크립트는 사전에 TX queue ≥ 4 검사하여 `hw 0` 으로 폴백.
- ⚠️ `hw 0` 모드는 결국 단일 물리 큐를 공유 → 하드웨어 dequeue 순서가 큐 분리 효과를 거의 못 줌. 측정된 개선은 **kernel 큐(prio) 의 dequeue 정책** 이 만든다 (다음 단계 ETF/prio 결합).

---

### 6.2 `step5-tc-qdisc/02-setup-etf.sh`

**코드 (핵심 발췌)**

```bash
if python3 -c "import time; time.clock_gettime(time.CLOCK_TAI)" 2>/dev/null; then
    CLOCKID="CLOCK_TAI"
else
    CLOCKID="CLOCK_REALTIME"
fi
sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf \
    clockid "$CLOCKID" \
    delta 150000 \
    offload off \
    deadline_mode on
```

**1. 무엇을 하는 코드인가**
mqprio의 첫 번째 child class (`100:1` = tc0 = TSN) 위에 ETF (Earliest TxTime First) qdisc를 추가. 송신 패킷이 `SCM_TXTIME` ancillary message로 전송 시각을 지정하면 ETF가 그 시각까지 패킷을 보관 후 정확한 시점에 dequeue.

- `clockid CLOCK_TAI`: 논문 원본 (TAI는 UTC와 약 37초 차이가 있는 atomic time scale, 윤초의 영향을 받지 않아 TSN에 권장)
- `delta 150000`: 150 μs — txtime 보다 150μs 전에 미리 보내기 시작 (driver/wire 지연 마진)
- `offload off`: 하드웨어 LaunchTime 미사용 (VM 한계)
- `deadline_mode on`: txtime 지난 패킷은 드롭

**2. 논문과의 매핑**
- 논문 §IV-B "Earliest TxTime First (ETF) is added as a child qdisc to tc0, with delta = 150μs and CLOCK_TAI"
- "offload off" 는 논문에 없음 — VM 환경 때문에 추가.

**3. 왜 필요한가**
- ETF 없이는 송신자가 `SCM_TXTIME` 으로 미래 시각을 지정해도 즉시 send → mqprio가 정렬해 줄 뿐. 시간 인지 셰이핑 없음.
- `deadline_mode on` 은 늦은 패킷이 link을 막아 다른 TSN 패킷의 HOL blocking 일으키는 것을 방지.

**4. 누가, 언제 실행하는가**
- 사용자(root). proposed 모드 진입 시. 본 repo의 메인 자동화(`deploy-experiment.sh`)는 ETF attach를 시도하고 실패하면 무시.
- 호출 체인: tc → sch_etf → net/sched/sch_etf.c (kernel ≥ 4.19)

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **ETF + CLOCK_TAI (논문)** | TSN 표준 호환, 정확한 launch time | 하드웨어 LaunchTime 미지원 NIC에서는 software-only |
| **ETF + CLOCK_REALTIME (폴백)** | TAI namespace 없는 환경에서도 동작 | NTP 보정 시 시각 jump 영향 받음 |
| **ETF + CLOCK_MONOTONIC** | jump 없음 | 송신자 ↔ 큐 간 clock domain 불일치 — `SO_TXTIME` 와 부합 안 됨 |
| **taprio (게이트 제어)** | 시간 슬롯 기반 스케줄 | 정해진 슬롯만 가능, per-packet txtime 불가 |
| **ETF 없음 (mqprio만)** | 단순 | 정확한 시점 전송 불가, jitter 큼 |

→ ETF + CLOCK_TAI 시도 후 폴백: 논문 충실성 + 실용성 양립.

**6. 한계 및 주의사항**
- ⚠️ talker.py 는 `SO_TXTIME` 를 사용하지 않음 (`sock.sendto()` 만 호출). 즉 ETF는 attach되더라도 **실제로 사용되지 않음**. talker는 단지 sleep으로 페이싱하고 즉시 send. ETF 단계는 인프라 측 코드일 뿐.
- ⚠️ CLOCK_TAI 사용 시 호스트의 UTC↔TAI 오프셋 (tai offset) 이 설정되어 있어야 정확. `chronyc tracking | grep "Leap"` 로 확인.

---

### 6.3 `step5-tc-qdisc/03-setup-ets.sh`

**코드 (핵심 발췌)**

```bash
if $TAPRIO_AVAIL; then
    BASE_TIME=$(date +%s)000000000
    sudo tc qdisc replace dev "$IFACE" root handle 100: taprio \
        num_tc 3 map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@0 1@0 \
        base-time "$BASE_TIME" \
        sched-entry S 04 125000 \
        sched-entry S 02 125000 \
        sched-entry S 01 750000 \
        clockid CLOCK_TAI \
        flags 0x1
elif $ETS_AVAIL; then
    sudo tc qdisc add dev "$IFACE" parent 100:3 handle 30: ets \
        strict 1 quanta 2500 1500
else
    sudo tc qdisc add dev "$IFACE" root handle 100: prio bands 3
fi
```

**1. 무엇을 하는 코드인가**
시간 인지 셰이핑(time-aware shaping)을 3단계 폴백으로 시도:
1. **taprio** (선호) — gate control list 로 IEEE 802.1Qbv 흉내. 1ms 주기로 `S 04 125000` (gate mask 0b100 = tc2 만 열림, 125 μs), `S 02 125000` (tc1, 125 μs), `S 01 750000` (tc0, 750 μs) 슬롯. `flags 0x1` = software 모드.
2. **ets** (sch_ets) — strict priority 1개 클래스 + 잔여 2개 클래스에 quanta(2500, 1500 byte) 가중치.
3. **prio** (최후 폴백) — 단순 3-band strict priority.

**2. 논문과의 매핑**
- 논문 §IV-C "Enhancements for Scheduled Traffic (ETS) … 3 queues, 3 priority levels … gate schedule: tc2 → tc1 → tc0 with 1ms cycle"
- gate mask `S 04`(0b100) / `S 02`(0b010) / `S 01`(0b001) 의 비트 순서는 **논문 Fig. 2 의 좌→우 순서와 동일** (tc0가 가장 낮은 비트).
- ⚠️ 논문이 명시한 slot 길이("125μs/125μs/750μs") 는 본 repo의 슬롯과 정확히 같음.

**3. 왜 필요한가**
- mqprio + ETF 만으로는 best-effort 트래픽이 끊임없이 dequeue되며 tc0의 idle 슬롯을 침범.
- taprio의 gate control은 "tc0의 dedicated slot 동안에는 tc1/tc2가 송신 자체 불가" 를 강제 → bounded tail latency.

**4. 누가, 언제 실행하는가**
- 사용자(root). proposed 모드.
- 호출 체인: tc → sch_taprio (kernel ≥ 5.0)

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **taprio software (현)** | IEEE 802.1Qbv 의 가장 가까운 SW 구현 | 시계 정밀도가 슬롯 정확도 결정 |
| taprio + `flags 0x2` (offload) | hw gate, 진짜 ns 정밀도 | NIC 지원 필요 (i225, Mellanox 등) |
| **sch_ets** | strict priority 기반 가중치 | 게이트 개념 없음 — TSN 표준과 거리 있음 |
| **prio bands 3** | 모든 커널에서 동작 | 시간 슬롯 없음, 단순 strict priority |
| **htb + class hierarchy** | bandwidth shaping 가능 | TSN 의도와 직교, 게이트 없음 |

→ 3단계 폴백 구조: 환경에 따라 최선의 구현 선택. 본 repo VM에서는 `prio` 가 실제 사용됨 ([§16.2](#162-setup_tc_qdisc--remove_tc_qdisc) 참조).

**6. 한계 및 주의사항**
- ⚠️ `flags 0x1` (software taprio) 는 hrtimer 정밀도(VM 에서 ~수십 μs) 에 의존 → 슬롯 boundary가 흐려져 논문의 ns 정밀도 미달.
- ⚠️ `base-time` 가 현재 시각의 정수 초로 설정 → cluster의 PTP 가 동기화돼 있어야 master/worker의 슬롯이 일치. 동기화 없으면 슬롯 시작 시각이 노드마다 달라 의미 없음.
- ⚠️ taprio child로 ETF 를 추가하는 것은 커널 버전에 따라 거부될 수 있음 (`setup-all-qdisc.sh` 가 시도 후 실패 시 무시).

---

### 6.4 `step5-tc-qdisc/setup-all-qdisc.sh`

**코드 (핵심 발췌)**

```bash
if [ "$MODE" = "full" ]; then
    sudo tc qdisc replace dev "$IFACE" root handle 100: taprio ...
    sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf \
        clockid CLOCK_TAI delta 150000 offload off deadline_mode on
elif [ "$MODE" = "simple" ]; then
    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio ... hw 0
    sudo tc qdisc add dev "$IFACE" parent 100:1 handle 10: etf ...
fi
```

**1. 무엇을 하는 코드인가**
01/02/03 스크립트의 결합 버전. `full` 모드는 taprio + ETF (논문에 가장 가까움), `simple` 모드는 mqprio + ETF (taprio 미지원 환경).

**2. 논문과의 매핑**
논문 §IV 전체(mqprio + ETF + ETS) 의 통합. 본 스크립트가 deploy-experiment.sh 보다 더 충실한 논문 재현이지만, **메인 실험에서는 deploy-experiment.sh 가 호출되며 본 스크립트는 사용되지 않음** (deploy-experiment.sh의 prio 폴백이 VM에서 실용적이라 채택).

**3. 왜 필요한가**
한 번에 모든 qdisc 를 셋업하고 싶은 사용자의 편의용. 디버깅 / 실험적 비교용.

**4. 누가, 언제 실행하는가**
사용자(root). 메인 자동화에서 호출되지 않음. 수동 실험용.

**5. 대안과 선택 이유**
- vs `deploy-experiment.sh setup-tc`: 본 스크립트는 taprio 시도, deploy-experiment.sh는 prio 폴백. **선택: deploy-experiment.sh** (VM 호환성 우선).

**6. 한계 및 주의사항**
- ⚠️ `full` 모드는 taprio child로 ETF를 시도 — 커널 버전에 따라 `tc qdisc add` 실패 가능. 실패해도 진행.

---

## 7. eBPF 프로그램 — 빌드 시스템 (step6-ebpf)

### 7.1 `step6-ebpf/Makefile`

**코드 (핵심 발췌)**

```makefile
DEBUG    ?= 2
BPF_CFLAGS := -g -O2 \
    -target bpf \
    -D__TARGET_ARCH_$(ARCH) \
    -D__LITTLE_ENDIAN_BITFIELD \
    -DDEBUG_LEVEL=$(DEBUG) \
    -Istub-headers \
    -Isrc \
    -Wall -Wno-unused-value \
    $(EXTRA_CFLAGS)

PROGS    := veth_filter egress ingress xdp_vlan_avtp
OBJS     := $(addprefix $(BUILDDIR)/, $(addsuffix .bpf.o, $(PROGS)))

$(BUILDDIR)/%.bpf.o: $(SRCDIR)/%.c $(SRCDIR)/common.h
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
```

**1. 무엇을 하는 코드인가**
clang 을 `-target bpf` 로 호출하여 src/*.c 를 BPF bytecode (ELF object) 로 컴파일. `-Istub-headers` 가 최우선이라 커널 내부 헤더가 아닌 자체 스텁 헤더만 사용. `-DDEBUG_LEVEL=N` 으로 빌드 시 디버그 매크로 레벨 결정. `check-env` 타겟은 빌드 전 도구·헤더·모듈 가용성 사전 점검.

**2. 논문과의 매핑**
논문 §III "We compile eBPF programs with clang -target bpf". 본 Makefile은 그 표준 절차의 충실한 구현. `stub-headers` 사용은 **논문에 없는 추가 구현** — 커널 6.x 의 일부 내부 헤더가 BPF target과 호환되지 않아 (`__cold`, `unlikely` 매크로 정의 차이) 빌드 실패하는 문제를 회피.

**3. 왜 필요한가**
- BPF bytecode는 일반 x86 / arm64 와 다른 ISA. `-target bpf` 없이는 컴파일 결과를 BPF verifier가 거부.
- `stub-headers` 가 없으면 호스트가 Windows + VS Code인 경우 IntelliSense가 동작 안 함 (코드 편집 ergonomic 측면).
- `-O2` 는 verifier가 좋아하는 형태로 IR 생성 (loop unroll, dead code elim). `-O0` 으로 빌드한 BPF는 verifier가 거부하는 경우 많음.

**4. 누가, 언제 실행하는가**
- 사용자가 `make` 또는 `deploy-experiment.sh build-ebpf` 호출 시 1회.
- 빌드 후 `build/*.bpf.o` 는 git에 커밋되어 있어, 빌드 도구 없는 노드에서도 attach 가능.
- 호출 체인: make → clang → ELF object → 이후 `tc filter add` 또는 `ip link set xdp` 에서 BPF syscall (`bpf(BPF_PROG_LOAD)`) → kernel verifier → JIT compile → attach.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **clang + Makefile (현)** | 가장 가벼움, 의존성 적음 | libbpf-bootstrap 만큼 자동화 안 됨 |
| libbpf-bootstrap (cmake) | skeleton 자동 생성, BPF CO-RE 활용 | 학습 곡선, 커널 BTF 필요 |
| bcc (Python 런타임 컴파일) | 빠른 프로토타이핑 | 런타임 clang 호출 → 성능 / 안정성 ↓ |
| pre-built `.o` 만 사용 | 빌드 의존성 zero | 코드 수정 시 다른 노드에서 재빌드 불가 |

→ Makefile + stub-headers + pre-built `.o` git commit 의 조합 = 가장 portable.

**6. 한계 및 주의사항**
- ⚠️ stub-headers 는 IntelliSense용 — 실제 빌드 시에는 clang 이 BPF target 으로 빌드하므로 일부 typedef 가 누락되어 있어도 (e.g., `_Atomic`) 컴파일은 통과하지만 가독성 저하.
- ⚠️ kernel 5.15와 6.x 의 일부 BPF helper signature 차이 — 본 Makefile은 5.15 기준이라 6.x에서 컴파일은 되지만 verifier가 거부할 수 있음. README §VM 한계 표는 kernel 6.6+ 권장.

---

### 7.2 `step6-ebpf/stub-headers/`

**코드 (대표: `stub-headers/bpf/bpf_helpers.h`)**

```c
#define SEC(name) __attribute__((section(name), used))
#define __uint(field, val) int (*field)[val]
#define __type(field, val) typeof(val) *field

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;
static long (*bpf_map_update_elem)(void *, const void *, const void *, __u64) = (void *)2;
static __u64 (*bpf_ktime_get_ns)(void) = (void *)5;
static void *(*bpf_ringbuf_reserve)(void *, __u64, __u64) = (void *)131;
...
#define bpf_printk(fmt, ...) ({ char ____fmt[] = fmt; bpf_trace_printk(____fmt, sizeof(____fmt), ##__VA_ARGS__); })
```

그리고 `stub-headers/linux/bpf.h`, `if_ether.h`, `pkt_cls.h`, `udp.h`, `ip.h`, `if_vlan.h`, `types.h` — 모두 BPF C 코드가 참조하는 최소 매크로/구조체만 정의.

**1. 무엇을 하는 코드인가**
실제 커널의 `linux/bpf.h`, `bpf/bpf_helpers.h` 등은 컴파일러/매크로 의존이 복잡해 BPF target 으로 직접 include 시 실패하는 경우가 있음. 본 디렉토리는 BPF 프로그램이 실제 사용하는 식별자(`TC_ACT_OK`, `struct __sk_buff`, `bpf_map_lookup_elem` 등)만 추출해 둔 **경량 스텁**. Makefile이 `-Istub-headers` 로 최우선 검색하여 실제 시스템 헤더를 가림.

**2. 논문과의 매핑**
논문에 없는 구현 디테일. 논문이 "kernel 5.15.0-72-generic" 단일 환경을 가정하므로 헤더 호환 문제가 없지만, 본 repo는 다양한 OS/커널 버전을 지원하기 위해 도입.

**3. 왜 필요한가**
- Ubuntu 24.04 kernel 6.6에서 `<bpf/bpf_helpers.h>` 의 일부 매크로가 LLVM 17+ 에서만 컴파일됨 → 시스템에 따라 빌드 실패.
- Windows 호스트의 VS Code에서 BPF 소스를 열면 IntelliSense가 `linux/*` 헤더를 못 찾아 모든 식별자에 빨간 줄. 스텁이 있으면 ergonomic.

**4. 누가, 언제 실행하는가**
컴파일 시 (`make`) clang preprocessor 가 자동으로 include. 사용자가 직접 실행할 일 없음.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **stub-headers (현)** | OS/커널 무관, IntelliSense friendly | 커널 헤더 업데이트 반영 안 됨 |
| `vmlinux.h` (`bpftool btf dump`) | 전체 커널 BTF 동기화, CO-RE 가능 | 노드별 BTF 필요, vmlinux.h가 매우 큼 |
| 시스템 헤더 직접 사용 | 표준 | 커널/clang 버전 의존, 빌드 실패 잦음 |

→ stub-headers: 본 repo가 다루는 BPF 식별자가 적어 (수십 개) 스텁이 실용적.

**6. 한계 및 주의사항**
- ⚠️ stub-headers는 진짜 커널 ABI가 아니므로, 새로운 BPF helper를 사용하려면 수동으로 추가해야 함. e.g., `bpf_skb_change_proto()` 같은 함수가 필요하면 스텁에 prototype 추가 + Makefile.

---

## 8. eBPF 프로그램 — 공통 헤더 `common.h`

`step6-ebpf/src/common.h` 는 모든 BPF 프로그램이 공유하는 매크로, 상수, 자료구조, 인라인 유틸을 정의. 의미 단위로 5개 블록으로 나눕니다.

### 8.1 디버그 매크로 시스템 (`DEBUG_LEVEL`)

**코드**

```c
#ifndef DEBUG_LEVEL
#define DEBUG_LEVEL 2
#endif

#if DEBUG_LEVEL >= 1
#define DBG_ERR(fmt, ...)   bpf_printk("[ERR ] " fmt, ##__VA_ARGS__)
#else
#define DBG_ERR(fmt, ...)   do {} while(0)
#endif

#if DEBUG_LEVEL >= 2
#define DBG_WARN(fmt, ...)  bpf_printk("[WARN] " fmt, ##__VA_ARGS__)
#endif
/* INFO, TRACE 동일 패턴 */
```

**1. 무엇을 하는 코드인가**
컴파일 시 `-DDEBUG_LEVEL=N` 으로 레벨을 결정하여 `bpf_printk()` 호출을 조건부 컴파일. 레벨 0 = off, 1 = ERR, 2 = +WARN (기본), 3 = +INFO, 4 = +TRACE (모든 패킷 로그). 레벨보다 낮은 매크로는 `do {} while(0)` 빈 문장으로 치환되어 코드가 사라짐.

**2. 논문과의 매핑**
**논문에 없는 추가 구현.** 논문은 디버깅 로그를 다루지 않지만, 본 repo는 VM 환경의 다양한 fail-mode 디버깅을 위해 도입.

**3. 왜 필요한가**
- `bpf_printk()` 는 매 호출마다 trace_pipe buffer 에 string write → 성능 큰 오버헤드. 프로덕션에서는 반드시 off.
- 그러나 개발 중에는 패킷 분류 결과를 확인해야 verifier failure / wrong classification 을 디버깅 가능.
- 매크로 시스템 없이 매번 코드 주석 처리하면 실수 잦음.

**4. 누가, 언제 실행하는가**
- 컴파일 시 macro expansion → 런타임에는 분기 자체가 사라짐.
- 디버그 빌드의 `bpf_printk()` 는 패킷마다 1회 실행 (커널 BPF VM).

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **컴파일타임 매크로 (현)** | 런타임 오버헤드 0 | 빌드 시 결정, 동적 토글 불가 |
| 런타임 BPF map flag (`debug_level`) | 동적 on/off | 매 패킷 map lookup 오버헤드 |
| bpf_printk 직접 호출 | 단순 | 프로덕션 빌드에 디버그 코드 남음 |
| BPF event ringbuf | 구조화된 데이터 | 더 복잡, 디버깅에 과함 |

→ 컴파일타임: 디버그 코드가 프로덕션 .o 에 흔적 없이 사라지는 게 가장 깔끔.

**6. 한계 및 주의사항**
- ⚠️ `bpf_printk()` 는 BPF verifier가 fmt 문자열을 인자 3개까지만 허용. 4개 인자가 필요하면 분할 호출.
- ⚠️ DEBUG_LEVEL=4 빌드는 매 패킷마다 trace_pipe write → 1000pkt/s 부하에서 trace_pipe 가 즉시 가득. 짧은 디버깅 세션에만 사용.

---

### 8.2 VLAN priority ↔ TC class 상수

**코드**

```c
/* VLAN priority → TC 매핑 (논문 Table I) */
#define TSN_VLAN_PRI_HIGH   3   /* time-sensitive → tc0 */
#define TSN_VLAN_PRI_MED    2   /* medium → tc1 */
#define TSN_VLAN_PRI_LOW    0   /* best-effort → tc2 */

#define TC_CLASS_HIGH   0   /* tc0 */
#define TC_CLASS_MED    1   /* tc1 */
#define TC_CLASS_LOW    2   /* tc2 */

#ifndef ETH_P_AVTP
#define ETH_P_AVTP 0x22F0  /* IEEE 1722 AVTP */
#endif
```

**1. 무엇을 하는 코드인가**
논문 Table I "VLAN priority and TC class mapping" 을 매크로로 표현. AVTP EtherType (IEEE 1722, 0x22F0) 도 정의. 이 상수들이 모든 BPF 프로그램에서 사용됨.

**2. 논문과의 매핑**
- 논문 Table I: `vlan pri 3 → tc 0`, `vlan pri 2 → tc 1`, `vlan pri 0,1 → tc 2`
- 본 코드의 `TSN_VLAN_PRI_HIGH=3`, `TC_CLASS_HIGH=0` 등이 정확히 그 표를 매핑.
- mqprio 의 `map 2 2 1 0 …` 옵션 ([§6.1](#61-step5-tc-qdisc01-setup-mqpriosh)) 과 일관: index 3 → value 0 (= tc0).

**3. 왜 필요한가**
매직 넘버를 코드 곳곳에 흩어 두면 논문 표와 비교 / 수정 시 누락 위험. 한 곳에 모아 단일 진실 원천(single source of truth).

**4. 누가, 언제 실행하는가**
컴파일 타임 substitution. 런타임에는 그냥 정수 비교.

**5. 대안과 선택 이유**
- (a) `#define` 매크로 (현) — 단순, 빠름. (b) `enum` — type safety, 디버거 친화적. **선택: 매크로** — BPF C는 enum 디버깅이 어차피 제한적이라 단순함이 유리.

**6. 한계 및 주의사항**
- ⚠️ priority 0 과 1 은 모두 best-effort로 매핑되어야 함 (논문 Table I). 본 코드는 `TSN_VLAN_PRI_LOW=0` 만 정의했으므로, 코드에서 명시적 비교는 `pri == TSN_VLAN_PRI_HIGH` 만 수행 → 그 외는 모두 best-effort로 처리되어 의도 일치.

---

### 8.3 `pkt_stats` / `debug_stats` BPF maps

**코드**

```c
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} pkt_stats SEC(".maps");

#define STATS_TOTAL     0
#define STATS_TSN       1
#define STATS_BEST_EFF  2
#define STATS_DROPPED   3

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, __u64);
} debug_stats SEC(".maps");

#define DBGSTAT_ETH_TOO_SHORT     0
#define DBGSTAT_VLAN_PARSE_FAIL   1
/* … 15개 인덱스 정의 … */
```

**1. 무엇을 하는 코드인가**
모든 BPF 프로그램이 공유하는 두 개의 카운터 맵:
- `pkt_stats`: 4 entry — 총 / TSN / best-effort / dropped 패킷 수
- `debug_stats`: 16 entry — 파싱 실패 분류, AVTP 카운트, port-based vs PCP-based TSN 분류 카운트 등

**2. 논문과의 매핑**
- 논문 §IV "we collect packet statistics via BPF maps" — pkt_stats 가 이에 대응.
- `debug_stats` 는 **논문에 없는 추가 구현** — VM 환경 디버깅용. 어떤 패킷이 왜 BPF 프로그램에 도달하지 못했는지 (Cilium native routing의 우회 등) 진단.

**3. 왜 필요한가**
- BPF 프로그램 내부에서 `printf` 같은 디버깅이 어렵기 때문에 카운터 맵으로 동작 검증.
- 유저스페이스 `bpftool map dump name pkt_stats` 로 즉시 확인 가능.
- README 의 "pkt_stats 가 0인 이유" 설명을 데이터 기반으로 진단 가능.

**4. BPF map 상세 (eBPF 추가 분석)**

| 속성 | 값 |
|---|---|
| **Map type** | `BPF_MAP_TYPE_ARRAY` |
| **Key** | `__u32` (배열 인덱스) |
| **Value** | `__u64` (원자적 카운터) |
| **max_entries** | 4 (pkt_stats), 16 (debug_stats) |
| **Pinned** | 아니오 (anonymous) → BPF program 가 unload되면 map도 소멸 |
| **유저스페이스 접근** | `bpftool map dump name <name>` / libbpf `bpf_map_lookup_elem` syscall |
| **동시성** | `__sync_fetch_and_add` 으로 원자적 증가 — race-free |

**ARRAY 선택 이유**: key 가 고정된 enum-style 인덱스라 HASH map 보다 빠르고 메모리 효율적. ARRAY는 BPF program load 시점에 모든 entry가 0으로 초기화됨 → reset 코드 불필요.

**5. 누가, 언제 실행하는가**
- map 정의는 컴파일 타임. map 인스턴스 생성은 BPF program load 시점 (`bpf(BPF_PROG_LOAD)` 직후 kernel이 `.maps` 섹션 파싱하여 `bpf(BPF_MAP_CREATE)`).
- map update는 매 패킷 (각 BPF program이 호출될 때).
- 유저스페이스 read는 `debug-stats.sh` 또는 `deploy-experiment.sh status` 에서 1초/수동.

**6. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **ARRAY (현)** | O(1) lookup, 메모리 압축, 자동 초기화 | 동적 키 추가 불가 |
| HASH | 동적 키 (e.g., IP-별 통계) 가능 | hash collision, lookup 비용 |
| PERCPU_ARRAY | per-CPU 카운터 — 경쟁 없음 | 합산 시 유저스페이스 추가 작업 |
| RINGBUF (Egress/Ingress용) | 패킷 단위 로그 | 카운터로는 과함, 소비자 필요 |

→ ARRAY 선택: 카운터 용도에 정확히 맞음. PERCPU_ARRAY 가 더 빠르지만 본 실험은 1000 pkt/s 부하라 ARRAY로 충분 + 합산 로직 불필요.

---

### 8.4 `stats_inc()` / `dbgstats_inc()` 유틸

**코드**

```c
static __always_inline void stats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&pkt_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}

static __always_inline void dbgstats_inc(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&debug_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, 1);
}
```

**1. 무엇을 하는 코드인가**
BPF map 카운터를 원자적으로 1 증가. `__always_inline` 으로 함수 호출 오버헤드 제거 (BPF verifier 가 inline 강제 가능).

**2. 논문과의 매핑**
논문에 없는 헬퍼 함수. 표준 BPF 패턴.

**3. 왜 필요한가**
- 같은 카운터 증가 코드를 매번 4줄 (lookup → null check → update) 쓰면 가독성 ↓. 인라인 함수로 추상화.
- `__sync_fetch_and_add` 가 multi-CPU race를 해결.

**4. 누가, 언제 실행하는가**
매 패킷마다 BPF program이 분류 결정을 내릴 때 호출. 즉 1000 pkt/s 부하라면 초당 수천 번 호출.

**5. 대안과 선택 이유**
- (a) 매크로 — preprocessor side effect 위험. (b) inline 함수 (현) — type safe + inline 보장. **선택: inline 함수**.

**6. 한계**
- ⚠️ ARRAY map의 lookup은 사실상 실패하지 않지만, BPF verifier 는 nullable로 처리하므로 `if (val)` 가드 필수.

---

### 8.5 `get_vlan_pcp()` 인라인 함수

**코드**

```c
static __always_inline int get_vlan_pcp(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    if ((void *)(eth + 1) > data_end) {
        dbgstats_inc(DBGSTAT_ETH_TOO_SHORT);
        return -1;
    }

    if (eth->h_proto != bpf_htons(ETH_P_8021Q) &&
        eth->h_proto != bpf_htons(ETH_P_8021AD)) {
        return -1;
    }

    struct vlan_hdr {
        __be16 h_vlan_TCI;
        __be16 h_vlan_encapsulated_proto;
    } *vhdr = (void *)(eth + 1);
    if ((void *)(vhdr + 1) > data_end) {
        dbgstats_inc(DBGSTAT_VLAN_PARSE_FAIL);
        return -1;
    }
    __u16 tci = bpf_ntohs(vhdr->h_vlan_TCI);
    int pcp = (tci >> 13) & 0x7;
    dbgstats_inc(DBGSTAT_VLAN_TAGGED);
    return pcp;
}
```

**1. 무엇을 하는 코드인가**
`__sk_buff` 컨텍스트에서 패킷의 이더넷 헤더를 파싱하여 802.1Q/802.1AD VLAN 태그가 있으면 TCI(Tag Control Information) 16비트의 상위 3비트(PCP) 를 추출. 비-VLAN 패킷은 -1 반환.

**2. 논문과의 매핑**
- 논문 §IV "the vef program extracts the VLAN PCP and maps it to the corresponding TC class"
- VLAN TCI 비트 레이아웃: `PCP(3) | DEI(1) | VID(12)` — 표준 802.1Q.

**3. 왜 필요한가**
- veth_filter, egress, ingress 셋 다 PCP 추출이 필요 → 한 곳에 정의하지 않으면 중복.
- BPF verifier 는 패킷 데이터 접근 시 매번 `data + offset > data_end` 검사를 요구 — 누락 시 verifier reject. 본 함수가 그 검사를 안전하게 캡슐화.

**4. 누가, 언제 실행하는가**
모든 BPF program이 매 패킷 호출 (인라인이므로 함수 호출 없이 그대로 inline 확장).

**5. 대안과 선택 이유**
- `bpf_skb_load_bytes()` — BPF helper로 명시적 byte load. 검증은 helper가 해줌. 그러나 직접 dereference (`data + offset`) 보다 느림.
- 본 코드 (direct pointer + verifier check) — 가장 빠름, BPF 관용구.

**6. 한계 및 주의사항**
- ⚠️ 이중 태그 VLAN (Q-in-Q, 802.1AD outer + 802.1Q inner) 의 경우 outer PCP만 추출. inner PCP 추출이 필요하면 추가 파싱 필요.
- ⚠️ Cilium native routing 환경에서는 Pod 송신 패킷에 VLAN 태그가 없음 (talker.py는 VLAN 미설정) → get_vlan_pcp() 는 항상 -1 반환 → UDP port-based 분류로 폴백. (`veth_filter.c` Case 3 참조)

---

## 9. eBPF — `veth_filter.c` (논문 Fig.1 "vef")

**코드 (요약 발췌; 전체는 [src/veth_filter.c](step6-ebpf/src/veth_filter.c))**

```c
SEC("tc")
int veth_filter(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;
    dbgstats_inc(DBGSTAT_PROG_ENTER);
    if ((void *)(eth + 1) > data_end) {
        stats_inc(STATS_DROPPED); return TC_ACT_UNSPEC;
    }
    stats_inc(STATS_TOTAL);
    __u16 eth_proto = eth->h_proto;

    /* Case 1: AVTP — TSN */
    if (eth_proto == bpf_htons(ETH_P_AVTP)) {
        stats_inc(STATS_TSN);
        skb->priority = TSN_VLAN_PRI_HIGH;
        return TC_ACT_OK;
    }

    /* Case 2: VLAN PCP-based */
    if (eth_proto == bpf_htons(ETH_P_8021Q) ||
        eth_proto == bpf_htons(ETH_P_8021AD)) {
        int pcp = get_vlan_pcp(skb);
        if (pcp < 0) { stats_inc(STATS_BEST_EFF); return TC_ACT_UNSPEC; }
        skb->priority = pcp;
        if (pcp == TSN_VLAN_PRI_HIGH) {
            stats_inc(STATS_TSN);
            return TC_ACT_OK;
        }
        stats_inc(STATS_BEST_EFF);
        return TC_ACT_UNSPEC;
    }

    /* Case 3: UDP port-based (VM 실험용 추가) */
    if (eth_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *iph = (void *)(eth + 1);
        if ((void *)(iph + 1) > data_end) { stats_inc(STATS_BEST_EFF); return TC_ACT_UNSPEC; }
        if (iph->ihl < 5)              { stats_inc(STATS_BEST_EFF); return TC_ACT_UNSPEC; }
        if (iph->protocol == IPPROTO_UDP) {
            struct udphdr *udph = (void *)iph + (iph->ihl * 4);
            if ((void *)(udph + 1) > data_end) { stats_inc(STATS_BEST_EFF); return TC_ACT_UNSPEC; }
            __u16 dport = bpf_ntohs(udph->dest);
            if (dport == TSN_UDP_PORT) {  /* 5000 */
                stats_inc(STATS_TSN);
                skb->priority = TSN_VLAN_PRI_HIGH;
                return TC_ACT_OK;
            }
        }
    }
    stats_inc(STATS_BEST_EFF);
    return TC_ACT_UNSPEC;
}
char _license[] SEC("license") = "GPL";
```

**1. 무엇을 하는 코드인가**
Pod 컨테이너의 veth peer(호스트 쪽 `lxc<hash>`) 의 ingress 방향에서 호출되어:
- AVTP(0x22F0) 패킷 → 무조건 TSN으로 분류, `skb->priority=3` 설정, `TC_ACT_OK` (즉시 통과)
- VLAN 태그가 있고 PCP=3 → TSN 처리
- VLAN 태그가 있고 PCP≠3 → best-effort, `TC_ACT_UNSPEC` (Cilium의 다음 처리에 위임)
- 비-VLAN UDP dest port 5000 → TSN으로 우대 (VM 실험 편의용)
- 그 외 → best-effort

`TC_ACT_UNSPEC` 의 의미: "이 filter에서 결정 내리지 않음, 다음 classifier(또는 Cilium tcx)에 패스". `TC_ACT_OK` 는 "OK, 다음 stage로 진행 — drop하지 마라" — 본 코드에서는 동일하게 다음 단계로 통과시키지만 카운터 분류만 다름.

**2. 논문과의 매핑**
- 논문 §IV "vef (veth-filter) attaches to the veth peer in the host namespace. It examines the VLAN PCP or AVTP header and selects between underlay direct path (TC_ACT_OK) and overlay path (TC_ACT_UNSPEC)."
- AVTP, VLAN PCP 분기는 논문 의도 충실 재현.
- **UDP port 5000 분기 (Case 3)** 는 **논문에 없는 추가 구현** — README §아키텍처 에서 명시: "실제 TSN은 VLAN 태그를 사용하지만 VM에서 VLAN 설정이 복잡하여 UDP 포트 기반 대안 제공." talker.py가 VLAN 태그를 추가하지 않고 단순 UDP 송신하므로 이 분기가 실질적으로 동작하는 분류 경로.

**3. 왜 필요한가**
- 이 프로그램 없이는 모든 패킷이 동일하게 처리되어 best-effort 트래픽이 TSN 트래픽의 latency를 침해. `skb->priority` 설정으로 이후 qdisc(prio/mqprio) 가 우선순위 정렬 가능.
- Cilium native routing 의 우회 경로 ([§5.1](#51-step4-cilium01-install-ciliumsh) 한계 참조) 가 활성화된 상황에서는 vef 가 호출되지 않을 수 있지만, talker.py 가 `SO_PRIORITY=3` 을 socket 옵션으로 설정하므로 skb->priority가 사용자가 직접 설정되어 prio qdisc 동작 보장.

**4. 누가, 언제 실행하는가**
- 실행 주체: **커널 (BPF VM)** — `clsact ingress` 콜백.
- 시점: Pod → veth → 호스트의 lxc<hash> 인터페이스에 패킷이 들어오는 매 순간.
- 호출 체인:
```
talker.py sock.sendto()
  → kernel UDP send
  → talker pod의 eth0 (veth interior)
  → 호스트의 lxc<hash> (veth exterior)
  → __netif_receive_skb_core → sch_handle_ingress → clsact ingress
  → [veth_filter.bpf.o 실행 ← 여기]
  → Cilium tcx (cil_from_container) — Cilium native routing의 경우
  → bpf_redirect(enp0s3, EGRESS)
  → enp0s3 dev_queue_xmit
  → clsact egress (egress.bpf.o)
  → qdisc prio
  → virtio-net driver
```

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **TC ingress on veth peer (현)** | Pod 출발 직후 캡처, skb->priority 설정 가능 | TC_ACT_UNSPEC vs OK 의미 미묘 |
| **TC egress on veth peer** | "Pod 들어가는 방향" 처리 | 송신 패킷은 ingress 쪽으로 들어옴 → 의미 안 맞음 |
| **XDP on veth peer** | 더 빠름 | XDP는 ingress only, skb 없음 → priority 설정 불가, ring buffer 등 helper 제한 |
| **cgroup BPF (skb)** | Pod 단위 정책 | sock 단위라 packet 헤더 검사 어려움 |
| **iptables/nftables mark + tc filter handle** | 표준 도구 | iptables hop 추가 latency, Cilium의 BPF 정책과 충돌 |

→ **TC clsact ingress 가 최적**: Cilium의 BPF chain과 자연스럽게 결합, skb->priority 설정으로 후단 qdisc에 신호 전파 가능.

**6. 한계 및 주의사항**
- ⚠️ Cilium tcx hook 이 clsact 보다 먼저 실행되는 경우 (Cilium 1.13+) → 본 program이 우회됨. README §5.1 한계 참조.
- ⚠️ `TC_ACT_UNSPEC` 반환 시 다음 classifier로 위임되는데, Cilium이 attach한 다음 classifier가 본 program의 `skb->priority` 설정을 덮어쓸 수 있음.

### 9.X eBPF 훅 및 네트워크 레이어 상세 분석 (veth_filter)

**훅 종류**
- BPF program type: `BPF_PROG_TYPE_SCHED_CLS` (`SEC("tc")`)
- Attach point: **TC clsact qdisc → ingress hook** (veth interface)
- 방향: **ingress** (호스트 입장에서 lxc<hash> 안으로 들어오는 = Pod에서 송출된 패킷)

**Attach 인터페이스**
- 본 repo: `lxc<hash>` (Cilium이 만든 veth peer의 호스트 쪽) 모두에 attach.
- attach 명령: `tc qdisc add dev lxc... clsact` + `tc filter add dev lxc... ingress bpf da obj veth_filter.bpf.o sec tc`
- Figure 1의 "vef" 라벨과 정확히 대응.

**패킷이 이 훅에 도달하기까지의 커널 경로**

```
[talker.py user process]
   sock.sendto()
        │ syscall
        ▼
   sys_sendto / __sys_sendto
        │
   sock->ops->sendmsg() → udp_sendmsg → udp_send_skb
        │
   ip_local_out → __ip_local_out → ip_output → ip_finish_output
        │
   neigh_output → dev_queue_xmit (talker pod의 eth0)
        │
   veth_xmit (drivers/net/veth.c)
        │ (peer로 packet 전달, NAPI를 통해 ksoftirqd가 처리)
        ▼
   __netif_receive_skb_core (호스트의 lxc<hash> ingress)
        │
   sch_handle_ingress
        │
   ★ TC clsact ingress hook ──→ [ veth_filter.bpf.o 실행 ]
        │
   (반환 후) tcx_ingress (Cilium cil_from_container)
        │
   bpf_redirect → enp0s3 egress 경로로 진입
```

**액션 선택의 이유**

| 반환값 | 본 코드에서의 사용 | 이유 |
|---|---|---|
| `TC_ACT_OK` | TSN으로 분류된 패킷 | "분류 완료, drop 없이 진행". 우선순위 설정 + 후속 BPF/qdisc로 전달 |
| `TC_ACT_UNSPEC` | best-effort 또는 분류 불가 | "내 결정 없음, 다음 classifier가 결정" — Cilium tcx 가 정상 처리하도록 위임 |
| `TC_ACT_SHOT` | 사용 안 함 | Drop 의미. vef는 분류만 하고 패킷 폐기는 안 함 |
| `TC_ACT_REDIRECT` | 사용 안 함 | `bpf_redirect()` 헬퍼와 조합 필요. Cilium이 이미 redirect 담당 |

**BPF map 사용 요약**
- `pkt_stats` (ARRAY[4]) — TOTAL / TSN / BEST_EFF / DROPPED 카운터
- `debug_stats` (ARRAY[16]) — 파싱 실패 분류, AVTP 카운트, port-vs-PCP 분류 등
- 둘 다 BPF_MAP_TYPE_ARRAY — 유저스페이스는 `bpf(BPF_MAP_LOOKUP_ELEM)` 으로 read-only 접근. read-modify-write 의 race는 BPF 내부에서 `__sync_fetch_and_add` 로 처리.

**패킷 분류 기준 ↔ 논문 Table I 비교**

| 코드 분기 | 코드 조건 | 결과 priority | TC class | 논문 Table I 매핑 |
|---|---|---|---|---|
| Case 1 | `eth_proto == ETH_P_AVTP` | 3 | tc0 | AVTP는 TSN으로, Table I는 직접 다루지 않으나 §IV "AVTP support" 와 일치 |
| Case 2a | VLAN tag + PCP==3 | 3 | tc0 | pri 3 → tc 0 ✓ |
| Case 2b | VLAN tag + PCP==2 | 2 | tc1 | pri 2 → tc 1 ✓ |
| Case 2c | VLAN tag + PCP∈{0,1} | 0,1 | tc2 | pri 0,1 → tc 2 ✓ |
| Case 3 | UDP dport==5000 | 3 | tc0 | **논문 외 추가** — 실험 편의 |
| 그 외 | — | (변경 없음) | tc2 | 기본값 |

---

## 10. eBPF — `egress.c` (논문 Fig.1 "eg")

**코드 (요약 발췌)**

```c
static __always_inline __u8 priority_to_tc(__u8 prio)
{
    switch (prio) {
    case 3:  return TC_CLASS_HIGH;  /* tc0 */
    case 2:  return TC_CLASS_MED;   /* tc1 */
    default: return TC_CLASS_LOW;   /* tc2 */
    }
}

SEC("tc")
int egress_prog(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;
    dbgstats_inc(DBGSTAT_PROG_ENTER);
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    stats_inc(STATS_TOTAL);

    /* VLAN 처리 + l3_hdr inner_proto 추출 */
    if (eth_proto == VLAN) { pcp = get_vlan_pcp(...); skb->priority = pcp; ... }
    if (inner_proto != IP) return TC_ACT_OK;
    /* IP/UDP 헤더 파싱 + bounds check */

    /* UDP 패킷 ring buffer 로깅 */
    struct pkt_log *log = bpf_ringbuf_reserve(&egress_log, sizeof(*log), 0);
    if (log) {
        log->timestamp_ns = bpf_ktime_get_ns();
        log->src_ip = iph->saddr; log->dst_ip = iph->daddr;
        log->src_port = sport; log->dst_port = dport;
        log->pkt_len = bpf_ntohs(iph->tot_len);
        log->priority = skb->priority;
        log->tc_class = priority_to_tc(skb->priority);
        bpf_ringbuf_submit(log, 0);
    } else dbgstats_inc(DBGSTAT_RINGBUF_FAIL);

    if (dport == 5000 || skb->priority == TSN_VLAN_PRI_HIGH)
        stats_inc(STATS_TSN);
    else
        stats_inc(STATS_BEST_EFF);
    return TC_ACT_OK;
}
```

추가로 ring buffer map 정의:
```c
struct pkt_log {
    __u64 timestamp_ns; __u32 src_ip; __u32 dst_ip;
    __u16 src_port; __u16 dst_port; __u16 pkt_len;
    __u8 priority; __u8 tc_class;
};
struct { __uint(type, BPF_MAP_TYPE_RINGBUF); __uint(max_entries, 256 * 1024); }
    egress_log SEC(".maps");
```

**1. 무엇을 하는 코드인가**
호스트 물리 NIC (`enp0s3`) 의 egress 방향에서 호출. 송신 패킷의 (timestamp, 5-tuple, priority, tc_class) 를 ring buffer에 기록. VLAN PCP 가 있으면 `skb->priority` 동기화. TSN/best-effort 카운터 증가. 패킷은 항상 `TC_ACT_OK` 로 통과 (드롭 안 함).

**2. 논문과의 매핑**
- 논문 §IV "eg (egress) attaches to the physical NIC egress. It sets skb->priority based on packet classification, enabling mqprio to route the packet to the correct TX queue."
- 본 코드는 `skb->priority` 를 직접 set 하기보다는 **이미 vef 가 설정한 값을 신뢰**하고, VLAN tag PCP가 있는 경우에만 재설정 — 논문 의도와 일치.
- ring buffer 로깅 (`bpf_ringbuf_*`) 은 **논문에 없는 추가 구현** — 실시간 패킷 trace를 유저스페이스에서 소비하기 위함. 본 repo에서는 소비자가 없어 ring buffer는 가득 차고 새 패킷 로그는 버려지지만, debug 시점에 `bpftool map dump name egress_log` 로 일부 확인 가능.

**3. 왜 필요한가**
- 패킷 별 송신 시점 측정 → 유저스페이스 latency 보다 정확한 NIC-egress 시점 기록 가능 (실제로 본 repo는 활용 안 하지만 인프라 제공).
- VLAN 태그 패킷의 PCP가 vef 단계에서 누락되어도 eg가 마지막 보루로 동기화.

**4. 누가, 언제 실행하는가**
- 실행 주체: **커널 BPF VM**, clsact egress hook
- 시점: enp0s3 로 패킷이 송출되기 직전 (qdisc enqueue 직전)
- 호출 체인 (sender 측):
```
prev (vef 또는 Cilium tcx)
  → bpf_redirect(enp0s3) or 호스트 라우팅 lookup
  → enp0s3 dev_queue_xmit
  → __dev_queue_xmit
  → sch_handle_egress (clsact egress)
  → [egress.bpf.o 실행 ← 여기]
  → 반환 후 qdisc enqueue (prio band, mqprio class)
  → qdisc dequeue → virtio-net hard_start_xmit
```

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **TC clsact egress (현)** | 모든 outgoing 패킷 캡처, skb->priority 수정 가능 | qdisc 직전이라 NIC level 정밀도는 제한 |
| **XDP egress** (kernel 5.10+) | 더 빠름 | skb 없음, priority 수정 불가, helper 제한 |
| **netfilter NF_INET_POST_ROUTING** (iptables) | mature | iptables hop, BPF 우선순위와 별개 |
| **kprobe on `dev_queue_xmit`** | 어디서나 attach | helper 제한, mark만 가능, performance ↓ |

→ TC clsact egress: 본 논문 시나리오에 정확히 부합.

**6. 한계 및 주의사항**
- ⚠️ ring buffer `bpf_ringbuf_reserve` 가 실패하는 경우 (256KB가 가득 + userspace consumer 없음) → 패킷은 정상 통과하지만 로그 누락. 본 repo는 소비자 없어 거의 항상 가득 → DBGSTAT_RINGBUF_FAIL 카운터가 빠르게 증가.
- ⚠️ Cilium native routing의 경우 Cilium의 `to-netdev` BPF 가 enp0s3 egress에 먼저 부착되어 있을 수 있음 — chain 동작 여부는 attach 순서에 의존.

### 10.X eBPF 훅 및 네트워크 레이어 상세 분석 (egress)

**훅 종류 / Attach**
- `BPF_PROG_TYPE_SCHED_CLS`, `SEC("tc")`, **clsact egress** on `enp0s3`
- Figure 1 의 "eg" (egress) 와 대응. sender 호스트(Host-s)에서만 attach.

**패킷 도달 경로 (Host-s 입장)**

```
veth_filter (vef) → bpf_redirect or routing lookup
    │
    ▼
enp0s3 (호스트 NIC) — dev_queue_xmit 진입
    │
qdisc skb_queue / clsact egress hook
    │
★ egress.bpf.o 실행 ── (TC_ACT_OK)
    │
prio qdisc enqueue (priomap[skb->priority] → band)
    │
prio qdisc dequeue (band 0 우선) → ETF qdisc (있다면)
    │
virtio-net driver hard_start_xmit → 가상 NIC PCI → 호스트 vhost-net
    │
호스트 VM bridge → NAT Network → 상대 VM
```

**액션 선택**: 항상 `TC_ACT_OK` — 모든 패킷을 통과시킴. eg는 분류·로깅만 하고 drop / redirect 안 함. 이유: egress 단계에서 drop은 송신자에게 silent failure → 디버깅 어려움.

**BPF map 사용**

| Map | Type | Key | Value | 용도 |
|---|---|---|---|---|
| `pkt_stats` | ARRAY[4] | u32 idx | u64 cnt | TOTAL / TSN / BEST_EFF / DROPPED (공유) |
| `debug_stats` | ARRAY[16] | u32 idx | u64 cnt | 파싱 실패 분류 (공유) |
| `egress_log` | RINGBUF | (없음) | struct pkt_log | 송신 패킷 trace (eg 전용) |

RINGBUF 의 user-space 교환: `bpf(BPF_RINGBUF_PROCESS)` 또는 libbpf `ring_buffer__poll()`. 본 repo는 consumer 미구현 — 인프라만 제공.

**패킷 분류 기준 (Table I 매핑)**

eg는 vef와 동일한 분류 기준을 사용하지만 **추가로 `priority_to_tc()` 함수로 명시적 매핑**:

| skb->priority | priority_to_tc() 결과 | TC class | 논문 Table I |
|---|---|---|---|
| 3 | TC_CLASS_HIGH (0) | tc0 | ✓ |
| 2 | TC_CLASS_MED (1) | tc1 | ✓ |
| 0, 1, 그 외 | TC_CLASS_LOW (2) | tc2 | ✓ |

이 매핑은 `egress_log.tc_class` 필드에 기록되지만 실제 qdisc routing은 `priomap` (qdisc 측 설정) 에 의해 결정 — 즉 BPF 측 매핑과 qdisc priomap이 일치해야 함. 본 repo는 둘 다 일치 (코드의 매핑과 mqprio `map 2 2 1 0 …` 가 같은 결과).

---

## 11. eBPF — `ingress.c` (논문 Fig.1 "ig")

**코드 (요약 발췌)**

```c
struct rx_log { __u64 timestamp_ns; __u32 src_ip; __u32 dst_ip; ...; __u8 priority; };
struct { __uint(type, BPF_MAP_TYPE_RINGBUF); __uint(max_entries, 256*1024); }
    ingress_log SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u16);     /* dst_port */
    __type(value, __u64);   /* last timestamp_ns */
} last_arrival SEC(".maps");

SEC("tc")
int ingress_prog(struct __sk_buff *skb)
{
    /* eth/VLAN/IP/UDP 헤더 파싱 + bounds check */
    __u64 now = bpf_ktime_get_ns();
    __u16 dport = bpf_ntohs(udph->dest);

    struct rx_log *log = bpf_ringbuf_reserve(&ingress_log, sizeof(*log), 0);
    if (log) { log->timestamp_ns = now; log->src_ip = iph->saddr; ...; bpf_ringbuf_submit(log, 0); }

    __u64 *prev_ts = bpf_map_lookup_elem(&last_arrival, &dport);
    if (prev_ts) {
        __u64 delta = now - *prev_ts;
        __s64 jitter = (__s64)delta - 1000000LL;  /* 1ms 예상 */
        if (jitter < 0) jitter = -jitter;
        if (jitter > 100000000LL) DBG_WARN("extreme jitter=%lld", jitter);
    }
    bpf_map_update_elem(&last_arrival, &dport, &now, BPF_ANY);

    if (dport == 5000 || skb->priority == TSN_VLAN_PRI_HIGH) stats_inc(STATS_TSN);
    else stats_inc(STATS_BEST_EFF);
    return TC_ACT_OK;
}
```

**1. 무엇을 하는 코드인가**
receiver 호스트의 enp0s3 ingress에서 호출. UDP 패킷마다 수신 타임스탬프(`bpf_ktime_get_ns()`) 기록, port별 last_arrival 맵으로 inter-packet delta 계산 후 1ms 예상치와의 차이를 jitter로 추정. 100ms 초과 jitter는 WARN 로그.

**2. 논문과의 매핑**
- 논문 §IV "ig (ingress) attaches to the physical NIC ingress. Records arrival timestamps and TSN packet statistics."
- jitter 측정 코드는 listener.py 의 측정과 중복이지만 **kernel-side ground truth**를 제공 — 유저스페이스 측정과의 차이가 userspace scheduling 노이즈를 정량화하는 데 활용 가능.
- `last_arrival` HASH map은 **논문에 없는 추가 구현** — 실험 디버깅용.

**3. 왜 필요한가**
- receiver 측 BPF 통계로 패킷이 실제 NIC에 도착한 시점을 알 수 있음 (Cilium tcx 이전 단계의 진실).
- listener.py의 latency가 비정상적으로 크면 BPF level에서 이미 늦었는지, userspace 처리에서 늦었는지 구분 가능.

**4. 누가, 언제 실행하는가**
- 커널 BPF VM. clsact ingress on enp0s3 (receiver host).
- 매 수신 UDP 패킷.
- 호출 체인 (receiver 측):
```
virtio-net rx interrupt
  → NAPI poll
  → netif_receive_skb_core
  → sch_handle_ingress (clsact ingress)
  → [ingress.bpf.o 실행 ← 여기]
  → 반환 후 ip_rcv → ... → udp_rcv → listener pod 의 sk_buff queue
  → recvfrom() syscall return → listener.py
```

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **TC clsact ingress (현)** | skb timestamp, 다양한 helper | XDP보다 약간 늦음 |
| **XDP** | 가장 빠름 | skb 없음 → skb->priority 못 봄, ring buffer는 가능하지만 일부 helper 제한 |
| **kprobe `udp_rcv`** | 어디서나 attach | 패킷 헤더가 sk_buff에서 손쉽게 접근 안 됨, slower |

→ TC clsact ingress: skb 정보 활용 + 정밀도 충분.

**6. 한계 및 주의사항**
- ⚠️ `bpf_ktime_get_ns()` 는 CLOCK_MONOTONIC. talker.py의 `time.time_ns()` 는 CLOCK_REALTIME. 두 시계는 다른 epoch — 비교 시 epoch 차이 보정 필요.
- ⚠️ HASH map의 update는 lock free 가 아니므로 multi-core race에 약함. 같은 port를 처리하는 CPU가 여러 개면 일부 update가 손실 가능 (단, 본 실험은 단일 port 5000이라 영향 미미).

### 11.X eBPF 훅 및 네트워크 레이어 상세 분석 (ingress)

**훅 종류 / Attach**
- `BPF_PROG_TYPE_SCHED_CLS`, **clsact ingress** on `enp0s3` (receiver host)
- Figure 1 "ig" 와 대응.

**도달 경로 (Host-r 입장)**

```
NIC wire 패킷 도착
   │
virtio-net rx ring buffer → IRQ
   │
NAPI poll (softirq)
   │
__netif_receive_skb_core
   │
GRO (Generic Receive Offload, packet aggregation)
   │
sch_handle_ingress (clsact ingress)
   │
★ ingress.bpf.o 실행 ── (TC_ACT_OK)
   │
tcx_ingress (Cilium cil_from_netdev) — IP/L4 lookup, endpoint 매핑
   │
ip_rcv → ip_local_deliver → udp_rcv
   │
sk_receive_skb → sk_buff enqueue
   │
recvfrom() syscall return → listener.py user process
```

**액션**: 항상 `TC_ACT_OK` — 패킷은 정상 통과. ig 는 측정만.

**BPF map 사용**

| Map | Type | Key | Value | 용도 |
|---|---|---|---|---|
| `pkt_stats` | ARRAY[4] | u32 | u64 | 공유 카운터 |
| `debug_stats` | ARRAY[16] | u32 | u64 | 공유 디버그 카운터 |
| `ingress_log` | RINGBUF | — | struct rx_log | 수신 패킷 trace |
| `last_arrival` | HASH | u16 (dport) | u64 (ns) | port별 마지막 도착 시각 |

**HASH 선택 이유**: dport는 동적이고 0~65535 범위라 ARRAY로 잡으면 65536 entry × 8B = 512KB 메모리 낭비. HASH는 실제 사용된 dport만 entry 차지.

**패킷 분류 기준**
ingress는 분류보다는 측정에 집중. dport==5000 또는 priority==3 인 패킷만 STATS_TSN 카운트.

---

## 12. eBPF — `xdp_vlan_avtp.c` (논문의 "VLAN 802.3 + AVTP 지원")

> ⚠️ **2026-06 코드 감사로 이 프로그램은 제거되었습니다.** 실험 트래픽이 plain UDP라 XDP의 VLAN/AVTP 분류가 한 번도 호출되지 않는 dead code였기 때문입니다. 아래 분석은 제거 이전 코드에 대한 기록으로 남겨 둡니다. 상세 근거는 [§21 코드 감사 변경 요약](#21-코드-감사-변경-요약-2026-06)을 참조하세요.

**코드 (요약 발췌)**

```c
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 8); } xdp_stats SEC(".maps");

SEC("xdp")
int xdp_vlan_avtp_prog(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    xdpstats_inc(XDPSTAT_TOTAL);
    if ((void *)(eth + 1) > data_end) { xdpstats_inc(XDPSTAT_PARSE_ERROR); return XDP_DROP; }

    __u16 eth_proto = eth->h_proto;

    /* Case 1: AVTP */
    if (eth_proto == bpf_htons(ETH_P_AVTP)) {
        xdpstats_inc(XDPSTAT_AVTP);
        xdpstats_inc(XDPSTAT_TSN_PASS);
        return XDP_PASS;  /* skb 없음 → priority 설정 불가, TC가 처리 */
    }

    /* Case 2: VLAN */
    if (eth_proto == bpf_htons(ETH_P_8021Q) || eth_proto == bpf_htons(ETH_P_8021AD)) {
        xdpstats_inc(XDPSTAT_VLAN_TAGGED);
        struct vlan_hdr { __be16 tci; __be16 inner; } *vhdr = (void *)(eth + 1);
        if ((void *)(vhdr + 1) > data_end) return XDP_DROP;
        __u16 tci = bpf_ntohs(vhdr->tci);
        int pcp = (tci >> 13) & 0x7;
        if (vhdr->inner == bpf_htons(ETH_P_AVTP)) { xdpstats_inc(XDPSTAT_AVTP); xdpstats_inc(XDPSTAT_TSN_PASS); return XDP_PASS; }
        if (pcp == TSN_VLAN_PRI_HIGH) xdpstats_inc(XDPSTAT_TSN_PASS);
        else xdpstats_inc(XDPSTAT_BEST_EFFORT);
        return XDP_PASS;
    }
    xdpstats_inc(XDPSTAT_BEST_EFFORT);
    return XDP_PASS;
}
```

**1. 무엇을 하는 코드인가**
호스트 NIC의 XDP hook에서 호출. AVTP / VLAN 802.1Q/802.1AD 헤더를 빠르게 식별하여 카운팅하고 PASS. XDP 단계에서는 `skb` 가 없어 `skb->priority` 설정 불가 — 분류만 하고 실제 우선순위 적용은 후속 TC hook(vef/eg)이 담당.

**2. 논문과의 매핑**
- 논문 §IV "we enhance Cilium's functionality by adding support for vlan802.3 and avtp in the XDP program"
- 본 코드는 그 강화의 단순 구현. Cilium 원본 XDP는 일반 IP만 처리하고 VLAN/AVTP에는 무관심 — 본 program은 그것을 보강.

**3. 왜 필요한가**
- VLAN 태그 패킷을 XDP에서 drop하지 않고 PASS로 통과시켜야 후속 TC vef 가 PCP 분류 가능.
- AVTP는 L2-only 프로토콜이라 일반 IP 파서가 처리 못 함 → XDP 단에서 인식해 통과 보장.
- XDP는 NIC driver 직후라 가장 빠름 — bad packet 조기 drop으로 후속 stage 부하 감소.

**4. 누가, 언제 실행하는가**
- 커널 BPF VM. **XDP hook** (native: NIC driver-level, generic: `__netif_receive_skb_core` 직전 단계).
- VM virtio-net 은 native XDP 미지원 → `xdpgeneric` 모드 — 사실상 첫 번째 BPF hook이지만 속도 이점 없음.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **XDP generic (현 VM)** | 어디서나 동작 | skb 할당 후 호출 → native 대비 속도 이점 없음 |
| **XDP native** (i225/Mellanox) | NIC driver-level, 최고 성능 | 하드웨어 한정 |
| **TC ingress only (XDP 생략)** | 단순 | XDP의 조기 drop 기회 상실 |
| **AF_XDP** | userspace 직접 전달 | 본 시나리오와 무관 (kernel stack 우회) |

→ XDP generic: VM에서 가능한 유일한 옵션. 효과는 카운팅 + 통과 보장에 그침.

**6. 한계 및 주의사항**
- ⚠️ XDP는 `XDP_DROP`/`XDP_PASS`/`XDP_TX`/`XDP_REDIRECT` 만 가능. priority 설정 불가 (skb 없음) → 분류 결과를 다음 stage에 전달할 정형 채널 없음 (xdp_metadata로 일부 가능하나 본 코드는 미사용).
- ⚠️ Cilium이 이미 XDP를 attach한 NIC에 본 program을 또 attach하면 충돌 — Cilium XDP 가 우선이거나 본 program이 덮어쓰기 → 본 repo의 `attach-ebpf.sh` 는 `xdpgeneric off` 후 본 program을 attach하지만, Cilium은 native XDP를 사용하지 않으므로 충돌 없음.

### 12.X eBPF 훅 및 네트워크 레이어 상세 분석 (XDP)

**훅 종류**
- `BPF_PROG_TYPE_XDP`, `SEC("xdp")`
- Attach mode: `xdpgeneric` (VM virtio-net) — `XDP_FLAGS_SKB_MODE`. 다른 모드: `xdpdrv` (native), `xdpoffload` (NIC hw).
- Direction: **ingress only** — XDP는 receive 방향만 존재 (egress XDP는 5.10+이지만 본 코드는 미사용).
- Attach interface: `enp0s3` (호스트 NIC).

**도달 경로**

```
NIC driver IRQ
   │
NAPI poll
   │
[xdpgeneric mode 의 경우: skb 미리 할당]
   │
★ XDP hook 실행 ── xdp_vlan_avtp.bpf.o (XDP_PASS)
   │
__netif_receive_skb_core
   │
sch_handle_ingress (clsact ingress)
   │
TC ingress BPF (ingress.bpf.o, receiver의 경우)
   │
... (이후 IP/UDP/user)
```

(native XDP의 경우 NIC driver가 skb 할당 전에 호출 → packet drop이 가장 저렴)

**액션**

| XDP action | 본 코드에서 사용 | 의미 |
|---|---|---|
| `XDP_PASS` | 모든 정상 경로 | 일반 kernel stack으로 진행 |
| `XDP_DROP` | 헤더 파싱 실패 시 | 패킷 폐기. 가장 저렴 |
| `XDP_TX` | 미사용 | 패킷을 같은 인터페이스로 다시 송출 |
| `XDP_REDIRECT` | 미사용 | 다른 인터페이스/CPU로 redirect |

**BPF map**

| Map | Type | Entries | 용도 |
|---|---|---|---|
| `xdp_stats` | ARRAY | 8 | TOTAL/VLAN/AVTP/TSN_PASS/BEST_EFF/DROP/PARSE_ERROR |

XDP에서는 `pkt_stats`/`debug_stats` 와 분리된 자체 stats 사용 (XDP는 별도 attach 단계라 공유 의미가 약함).

**패킷 분류 기준**

| 코드 분기 | 결과 | 논문 §IV "vlan802.3 + avtp" 매핑 |
|---|---|---|
| ethProto == 0x22F0 (AVTP) | XDPSTAT_TSN_PASS + PASS | ✓ AVTP 인식 |
| ethProto == 0x8100 (802.1Q) | PCP 추출 → TSN or BE 카운트 + PASS | ✓ vlan802.3 인식 |
| ethProto == 0x88A8 (802.1AD) | 같음 | ✓ (논문은 8021AD 명시 안 하지만 본 코드는 추가 지원) |
| VLAN 안에 AVTP (이중 캡슐) | TSN_PASS + PASS | 본 코드의 추가 기능 |

---

## 13. eBPF Attach 스크립트

### 13.1 `step6-ebpf/attach-ebpf.sh`

**코드 (핵심 발췌)**

```bash
PHYS_IF="${1:-$(ip route show default | awk '/default/ {print $5}' | head -1)}"
VETH_IF="${2:-}"

# 0. XDP
sudo ip link set dev "$PHYS_IF" xdpgeneric off 2>/dev/null || true
sudo ip link set dev "$PHYS_IF" xdpgeneric obj "$BUILDDIR/xdp_vlan_avtp.bpf.o" sec xdp

# 1. clsact
sudo tc qdisc add dev "$PHYS_IF" clsact 2>/dev/null || true

# 2. egress
sudo tc filter del dev "$PHYS_IF" egress 2>/dev/null || true
sudo tc filter add dev "$PHYS_IF" egress bpf da obj "$BUILDDIR/egress.bpf.o" sec tc

# 3. ingress
sudo tc filter add dev "$PHYS_IF" ingress bpf da obj "$BUILDDIR/ingress.bpf.o" sec tc

# 4. veth_filter (lxc* 자동 감지)
VETH_LIST=$(ip link show | grep -oP 'lxc\w+' | sort -u || true)
for veth in $VETH_LIST; do
    sudo tc qdisc add dev "$veth" clsact 2>/dev/null || true
    sudo tc filter add dev "$veth" ingress bpf da obj "$BUILDDIR/veth_filter.bpf.o" sec tc
done
```

**1. 무엇을 하는 코드인가**
빌드된 `.bpf.o` 파일들을 각각의 정해진 위치에 attach. 순서: XDP (PHYS_IF) → clsact qdisc (PHYS_IF) → egress filter → ingress filter → veth peer (lxc*) ingress filter. 마지막에 `tc filter show` 로 검증 출력.

**2. 논문과의 매핑**
논문 Fig.1 의 vef/eg/ig/XDP 위치를 그대로 시스템에 반영. 논문은 attach 절차의 세부 명령은 다루지 않으므로 이 스크립트는 그 격차를 메움.

**3. 왜 필요한가**
- BPF 프로그램은 build (`make`) 후 자동으로 동작하지 않음 — 명시적 attach 필요.
- 인터페이스 이름이 환경마다 다르므로 (`enp0s3`, `ens3`, `eth0`) 자동 감지 (`ip route show default`) 가 필요.
- veth 이름이 Cilium-생성 동적 이름 (`lxc<hash>`) 이라 와일드카드 매칭 필요.

**4. 누가, 언제 실행하는가**
- 사용자 (root). proposed 실험 전, eBPF attach 단계.
- 호출 체인: (사용자) → `ip link set xdp obj` → kernel `bpf(BPF_PROG_LOAD)` + `bpf_link_create` → XDP link 활성화 → `tc qdisc add clsact` → `tc filter add` → tc filter chain에 등록.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **셸 스크립트 + tc/ip (현)** | 가벼움, 표준 도구 | 멱등성 부분적, manual 검증 |
| **libbpf C 로더** | type-safe link, lifetime 관리 | 별도 빌드 |
| **bpf-loader (cilium/tetragon 등 데몬)** | 자동 재attach | 복잡, 본 실험에 과함 |
| **systemd-bpf-loader (kernel 6.5+)** | OS level 통합 | 신규 기능, 미숙 |

→ 셸: 본 실험은 한 번 실행 + 디버깅이 주라 가장 단순한 선택.

**6. 한계 및 주의사항**
- ⚠️ veth가 동적으로 생성/소멸 — Pod 재시작 시 새 lxc<hash> 가 생성되면 본 스크립트 재실행 필요. **자동 재attach 없음**.
- ⚠️ `tc filter del … 2>/dev/null || true` 로 멱등성 일부 제공하지만 chain priority 충돌 시 silent failure.

---

### 13.2 `step6-ebpf/debug-stats.sh`

**코드 (핵심 발췌)**

```bash
dump_map() {
    VALUES=$(bpftool map dump name "$MAP_NAME" 2>/dev/null || echo "")
    # bpftool 출력 파싱 — "value" 추출
    while IFS= read -r line; do
        if echo "$line" | grep -q '"value"'; then
            VAL=$(echo "$line" | grep -oP '\d+' | tail -1)
            ...
        fi
    done <<< "$VALUES"
}
print_stats() {
    dump_map "pkt_stats" PKTSTAT_NAMES
    dump_map "debug_stats" DBGSTAT_NAMES
    bpftool prog list 2>/dev/null | grep -E "tc|xdp"
    bpftool map list
}
```

옵션: `--watch` (1초마다 갱신), `--reset` (모든 카운터 0으로), `--trace` (`trace_pipe` tail).

**1. 무엇을 하는 코드인가**
사용자 친화적 BPF map 카운터 뷰어. bpftool의 raw JSON을 사람이 읽기 좋은 라벨 + 색상 (오류성 카운터는 빨간색) 으로 출력.

**2. 논문과의 매핑**
논문 외 운영 헬퍼. 실험 디버깅용.

**3. 왜 필요한가**
- 본 repo의 BPF map indices (`STATS_TOTAL=0`, `DBGSTAT_TSN_PORT=8` 등) 가 매크로로만 정의 → bpftool 의 숫자 dump만 보면 의미 모름. 본 스크립트가 라벨링.
- README의 "Cilium native routing이면 pkt_stats=0 정상" 같은 진단을 사용자가 즉시 확인.

**4. 누가, 언제 실행하는가**
사용자가 디버깅 세션에서 수동 실행. `--watch` 로 실시간 모니터링.

**5. 대안과 선택 이유**
- bpftool 직접 사용 — 빠르지만 가독성 ↓.
- 본 스크립트 — 라벨 + 색상으로 가독성 ↑.

**6. 한계**
- ⚠️ `--reset` 은 ARRAY map 만 동작. RINGBUF는 reset 불가 (drain 필요).

---

## 14. 실험 워크로드 — Talker / Listener (step7-experiment)

### 14.1 `step7-experiment/talker/talker.py`

#### 14.1.1 패킷 형식 및 페이싱 루프

**코드**

```python
PKT_HEADER_FMT = "!IQ"  # network byte order: uint32(seq) + uint64(send_time_ns)
PKT_HEADER_SIZE = struct.calcsize(PKT_HEADER_FMT)
...
for seq in range(args.count):
    scheduled_ns = start_time + int(seq * interval_s * 1e9)
    now = time.time_ns()
    while now < scheduled_ns:
        if scheduled_ns - now > 500_000:  # 0.5ms 이상 남으면 sleep
            time.sleep((scheduled_ns - now - 200_000) / 1e9)
        now = time.time_ns()
    send_time_ns = time.time_ns()
    header = struct.pack(PKT_HEADER_FMT, seq, send_time_ns)
    pkt = header + padding
    sock.sendto(pkt, target)
```

**1. 무엇을 하는 코드인가**
지정된 시작 시각 기준으로 `seq * interval` 마다 송신 타임 스탬프를 헤더에 포함하여 UDP 패킷 송출. 200μs 마진으로 sleep 후 spin-loop로 ±수μs 정확도 추구 (Python `time.sleep` 정확도 한계 회피).

**2. 논문과의 매핑**
- 논문 §IV-A "Talker sends UDP packets every 1ms (T=1ms), each packet carrying its send timestamp."
- `PKT_HEADER_FMT = "!IQ"`: seq(4B) + send_time_ns(8B) = 12B 헤더. 논문도 동일한 페이로드 구조를 암시 (latency 측정용).
- 페이싱 알고리즘 (sleep + spin-loop) 은 **논문에 명시 안 됨** — Python `time.sleep` 의 큰 jitter를 보완하기 위한 추가 구현.

**3. 왜 필요한가**
- 단순 `time.sleep(0.001)` 만 쓰면 Linux scheduler granularity 때문에 실제 sleep 시간이 1.5~3ms로 변동 → 1000pkt/s 불가.
- spin-loop만 쓰면 CPU 100% 점유. sleep + spin 조합이 trade-off.

**4. 누가, 언제 실행하는가**
- 사용자 (=k8s Job pod 안의 python3 entrypoint). 실험 1회당 10000 패킷 (10초).
- 호출 체인: kubectl apply → kubelet → containerd → python3 talker.py → kernel UDP socket.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **Python sleep + spin (현)** | 구현 단순, 라이브러리 불요 | μs 정밀도 한계, CPU 사용 약간 |
| C `clock_nanosleep(TIMER_ABSTIME)` | 정확한 sleep, 적은 CPU | 별도 바이너리 빌드 |
| `SO_TXTIME` + ETF qdisc | kernel이 정확한 시각에 송출 | talker 측 코드 복잡, ETF 의존 |
| iperf3/netperf | 표준 도구 | 사용자 정의 헤더(seq+send_ns) 추가 어려움 |

→ Python 스크립트: 컨테이너 이미지를 가볍게 (python:3.11-slim + ConfigMap) 만들 수 있어 본 repo의 빠른 반복 실험에 적합. 정밀도 한계는 README §결과 해석에서 명시.

**6. 한계 및 주의사항**
- ⚠️ Python GC 가 spin-loop 중 발생하면 페이싱 jitter 수십μs 발생.
- ⚠️ `time.time_ns()` 는 CLOCK_REALTIME → NTP step 시 시각 jump. CLOCK_MONOTONIC을 쓰지 않는 이유는 receiver의 `recv_ns - send_ns` 비교를 위해 epoch이 일치해야 하기 때문.

#### 14.1.2 SO_PRIORITY 설정

**코드**

```python
parser.add_argument("--vlan-priority", type=int, default=-1,
                    help="SO_PRIORITY 설정 (VLAN PCP 매핑)")
...
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
if args.vlan_priority >= 0:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, args.vlan_priority)
    print(f"SO_PRIORITY 설정: {args.vlan_priority}")
```

**1. 무엇을 하는 코드인가**
유저스페이스에서 `SO_PRIORITY` socket option 으로 `skb->priority` 를 강제 설정. talker-job.yaml 은 `--vlan-priority=3` 으로 호출 → 모든 송신 패킷의 priority가 3.

**2. 논문과의 매핑**
- 논문 §IV "the application sets SO_PRIORITY=3, which is propagated to skb->priority and used by mqprio's priomap to enqueue into TC class 0."
- 정확히 일치.

**3. 왜 필요한가**
- 본 repo의 **실질적 동작 원리는 이 옵션이다**. README §아키텍처 가 명시: "Cilium native routing이 우리 clsact BPF를 우회해도, SO_PRIORITY=3 이 직접 skb->priority=3 을 설정 → prio qdisc가 priomap[3]=0 으로 band 0 enqueue → tail latency 개선."
- BPF 분류가 동작하지 않아도 우선순위 큐 자체가 동작하도록 보장하는 안전망.

**4. 누가, 언제 실행하는가**
talker.py 시작 시 socket option 1회 설정. 이후 모든 sendto() 가 자동으로 priority=3 패킷 생성.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **SO_PRIORITY (현)** | 모든 패킷에 자동 적용, 가장 단순 | UDP 송신자만 영향 — 라우터/수신자는 못 봄 |
| `setsockopt(SO_MARK)` + `tc filter handle …` | iptables/firewall와 호환 | mqprio priomap 직접 사용 안 됨 |
| 패킷마다 `sendmsg` + `SCM_TXTIME` | 정확한 송신 시각 지정 | ETF qdisc 의존, 코드 복잡 |
| VLAN 태그 설정 (`sock.setsockopt(SO_BINDTODEVICE)` + VLAN device) | 표준 TSN | VM 환경에서 VLAN device 설정 복잡 |

→ SO_PRIORITY: TSN 시나리오에서 가장 직접적. README도 "본 실험의 핵심 동작 메커니즘" 으로 명시.

**6. 한계 및 주의사항**
- ⚠️ root 권한이 필요할 수 있음 (priority 6, 7 은 root only — but 3 은 unprivileged 가능, 본 실험은 OK).
- ⚠️ 컨테이너의 securityContext 가 capabilities (`NET_ADMIN`, `SYS_NICE`) 를 추가해야 함 — `talker-job.yaml`이 그렇게 설정.

#### 14.1.3 부가 기능 (CPU affinity, RT 스케줄링, drift logging)

**코드**

```python
def set_cpu_affinity(cpu_id): os.sched_setaffinity(0, {cpu_id})
def set_realtime_priority(priority=50):
    param = os.sched_param(priority)
    os.sched_setscheduler(0, os.SCHED_FIFO, param)
...
if args.cpu >= 0: set_cpu_affinity(args.cpu)
if args.realtime: set_realtime_priority()
...
if log_file:
    drift_us = (send_time_ns - scheduled_ns) / 1000.0
    log_file.write(f"{seq},{send_time_ns},{scheduled_ns},{send_time_ns},{drift_us:.2f}\n")
```

**1. 무엇을 하는 코드인가**
선택적 기능:
- `--cpu` : CPU affinity 설정 → isolcpus 격리 코어로 talker를 바인딩
- `--realtime` : SCHED_FIFO 실시간 스케줄러 사용 (root 필요)
- `--log` : 송신 시각 ↔ 예정 시각 차이(drift) CSV 기록 (페이싱 정확도 측정)

**2. 논문과의 매핑**
- isolcpus + CPU affinity 조합은 논문 §III 와 일치.
- SCHED_FIFO 는 논문에 명시 안 됨 — **추가 구현** (jitter 최소화 목적).
- drift logging은 **논문에 없는 추가** (페이싱 정확도 자가 검증).

**3. 왜 필요한가**
- CPU 부하 99% 시나리오에서 talker 가 stress-ng 와 같은 CPU에 있으면 페이싱 무너짐 → affinity로 분리.
- SCHED_FIFO 는 일반 CFS 보다 latency 보장 우수.

**4. 누가, 언제 실행하는가**
- 본 repo의 `talker-job.yaml` 은 `--cpu`, `--realtime` 옵션을 안 줌 → 이 기능들은 사용 안 됨.
- 사용자가 수동으로 talker.py 를 더 정밀하게 돌릴 때 활용.

**5. 대안과 선택 이유**
- `taskset` + `chrt` 외부 도구 — 단순. 본 코드는 Python 내장이라 컨테이너 의존성 추가 없음.

**6. 한계**
- ⚠️ SCHED_FIFO 는 cgroup `rt_runtime_us` 제한 안에서만. K8s pod의 기본 cgroup은 RT throttling 활성 가능 → 부분만 동작.

---

### 14.2 `step7-experiment/listener/listener.py`

#### 14.2.1 수신 루프 + latency/jitter 계산

**코드**

```python
expected_interval_ns = int(args.interval * 1e6)  # ms → ns
...
while True:
    data, addr = sock.recvfrom(65535)
    recv_ns = time.time_ns()
    if start_time is None: start_time = recv_ns
    if len(data) < PKT_HEADER_SIZE: continue
    seq, send_ns = struct.unpack(PKT_HEADER_FMT, data[:PKT_HEADER_SIZE])
    pkt_size = len(data); total_bytes += pkt_size

    # ── latency ──
    latency_ns = recv_ns - send_ns
    latency_ms = latency_ns / 1e6

    # ── jitter: Jitter(i) = t_i - (t_{i-1} + T) ──
    jitter_us = 0.0
    if prev_recv_ns is not None:
        expected_recv = prev_recv_ns + expected_interval_ns
        jitter_ns = recv_ns - expected_recv
        jitter_us = jitter_ns / 1e3
    prev_recv_ns = recv_ns

    results.append({"seq": seq, "send_ns": send_ns, "recv_ns": recv_ns,
                    "latency_ms": latency_ms, "jitter_us": jitter_us, "pkt_size": pkt_size})
```

**1. 무엇을 하는 코드인가**
UDP 소켓에서 패킷 수신 → `seq`, `send_ns` 추출 → 현재 `recv_ns` 와 비교하여 latency 계산. 이전 수신 시각 대비 jitter 계산. 통계는 results 리스트에 누적 → 마지막에 CSV 저장.

**2. 논문과의 매핑 (수식 줄 단위)**

논문의 수식:
```
Jitter(i) = t_i − (t_{i-1} + T)
```
여기서 t_i 는 i번째 패킷 수신 시각, T 는 예상 송신 간격(=1ms).

코드의 줄 단위 대응:
```python
expected_interval_ns = int(args.interval * 1e6)     # T (ns)
expected_recv = prev_recv_ns + expected_interval_ns  # t_{i-1} + T
jitter_ns = recv_ns - expected_recv                  # t_i - (t_{i-1} + T)  ← 논문 수식
jitter_us = jitter_ns / 1e3                          # 단위 변환
```

**완벽히 일치**. 부호는 코드가 signed 로 유지하지만 (양수 = 늦음, 음수 = 일찍), `compare_results.py` 와 `plot-results.py` 가 `abs()` 로 처리.

Latency:
```
Latency(i) = t_recv(i) - t_send(i)
```
코드:
```python
latency_ns = recv_ns - send_ns
```

⚠️ master/worker 시계가 다르면 (PTP 미동기) latency_ns 가 clock skew 만큼 ms 단위 오프셋 가짐 → `compare_results.py` / `plot-results.py` 가 1st percentile 정규화로 보정.

**3. 왜 필요한가**
- Latency: 송신 → 수신 end-to-end 시간 = 네트워크 + 스택 + 큐잉의 합.
- Jitter: 수신 간격의 일관성 = TSN의 핵심 KPI. throughput은 같아도 jitter가 작아야 실시간 제어 가능.

**4. 누가, 언제 실행하는가**
listener pod의 python3 entrypoint. talker가 송신 시작하면 자동 수신. talker 종료 + 60s 타임아웃 후 결과 CSV 작성.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **Python recv loop (현)** | 단순, 즉시 확장 가능 | μs 정밀도 한계 |
| C epoll + recv | 더 정확 | 별도 빌드 |
| `iperf3 -u --get-server-output` | 표준 | seq+send_ns header 활용 불가 |
| `ingress.bpf.o` 의 last_arrival map만 사용 | kernel-side ground truth | userspace에서 dump → 후처리 복잡 |

→ Python: README §결과 해석의 "0.8~1.4ms median latency" 가 VM 가상화 오버헤드 안에 들어가므로 Python 정밀도 한계가 bottleneck 아님.

**6. 한계 및 주의사항**
- ⚠️ `recvfrom(65535)` 는 syscall blocking — userspace scheduling jitter 가 recv_ns에 반영. kernel-level 측정 (ingress.bpf.o) 이 더 정확하지만 본 코드는 사용자 친화성 우선.
- ⚠️ `sock.settimeout(args.timeout)` — 60초 동안 패킷 미수신 시 break. talker가 늦게 시작하면 listener가 먼저 종료될 수 있음. listener-deployment.yaml 이 항상 먼저 ready 되도록 deploy-experiment.sh가 보장.

#### 14.2.2 CSV 출력 및 통계 요약

**코드**

```python
elapsed_s = (results[-1]["recv_ns"] - results[0]["recv_ns"]) / 1e9
latencies = [r["latency_ms"] for r in results]
jitters = [abs(r["jitter_us"]) for r in results[1:]]  # 첫 패킷 jitter 제외

print(f"Bandwidth: {total_bytes / elapsed_s / 1024:.2f} KB/s")
print(f"Latency (ms): min={min(latencies):.3f}, median={sorted(latencies)[len(latencies)//2]:.3f}, max={max(latencies):.3f}")
...
with open(args.output, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=results[0].keys())
    writer.writeheader()
    writer.writerows(results)
```

**1. 무엇을 하는 코드인가**
실험 종료 후 throughput / latency 분포 / jitter 분포를 stdout에 출력하고, 전체 패킷 단위 데이터를 `/data/results.csv` 에 저장.

**2. 논문과의 매핑**
- Throughput = 논문 Figure 2 데이터 소스
- Latency p50/p99/max = 논문 Figure 3 데이터 소스
- Jitter p50/p99 = 논문 Figure 4/5 데이터 소스
- CDF용 raw latency = 논문 Figure 6 데이터 소스

CSV 컬럼 (`seq, send_ns, recv_ns, latency_ms, jitter_us, pkt_size`) 이 모든 figure 생성의 단일 입력.

**3. 왜 필요한가**
실험 후 분석 (plot-results.py, compare_results.py) 의 입력. raw 데이터 보존으로 재분석 가능.

**4. 누가, 언제 실행하는가**
listener pod 종료 직전. `deploy-experiment.sh` 가 `kubectl cp` 로 호스트의 `step8-measurement/results/{mode}_cpu{N}.csv` 로 복사.

**5. 대안**: parquet / JSON — CSV가 universal하고 작은 파일 크기에서 충분.

**6. 한계**
- ⚠️ 10000 행 CSV ≈ 1MB. K8s pod의 emptyDir 위에 작성 → pod 삭제 시 사라짐. `kubectl cp` 로 즉시 빼내야 함.

---

### 14.3 Talker / Listener Dockerfile

**코드 (talker/Dockerfile)**

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY talker.py .
RUN apt-get update && apt-get install -y --no-install-recommends \
    stress-ng iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["python3", "talker.py"]
```

**1. 무엇을 하는 코드인가**
얇은 Python 3.11 + 디버깅용 도구(iproute2, ping, stress-ng) 이미지. talker.py 를 entrypoint로 실행.

**2. 논문과의 매핑**
논문 외 — 본 repo의 컨테이너 패키징.

**3. 왜 필요한가**
사전 빌드 후 K8s 이미지로 push해두면 매 실행마다 build 불필요. 그러나 본 repo의 **실제 K8s manifest 는 Dockerfile을 사용하지 않고 ConfigMap으로 talker.py 를 주입**하여 base `python:3.11-slim` 만 사용. 이 Dockerfile은 alternative 옵션.

**4. 누가, 언제 실행하는가**
사용자가 `docker build` 를 수동 실행 시. 본 repo의 자동화는 사용하지 않음.

**5. 대안과 선택 이유**
- (a) Dockerfile build → registry push. (b) ConfigMap inject (현 실제 사용). **선택: ConfigMap** — 코드 변경 시 image rebuild + push 불필요, 빠른 반복.

**6. 한계**
- ⚠️ Dockerfile은 본 repo의 메인 경로에서 미사용 — 코드 변경 사항이 Dockerfile 경로에는 반영 안 될 수 있음. ConfigMap (talker-job.yaml) 의 inline 스크립트와 src/talker.py 의 두 사본이 존재 → drift 위험.

---

## 15. Kubernetes 매니페스트 (step7-experiment/k8s)

### 15.1 `namespace.yaml`

**코드**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tsn-experiment
  labels:
    purpose: tsn-reproduction
```

**1.** 모든 실험 리소스를 격리하는 namespace. `kubectl delete ns tsn-experiment` 한 번에 정리.
**2. 매핑**: 논문 외 — k8s 표준 격리 패턴.
**3. Why**: 실수로 기존 워크로드를 건드리는 일을 방지.
**4. Who/When**: deploy-experiment.sh 가 최초 1회 apply.
**5. 대안**: 기본 namespace 사용 → drop. 격리 안 됨.
**6. 한계**: namespace finalizer가 stuck 시 강제 삭제 로직 (`deploy_k8s()` 안에 finalizer patch) 필요.

---

### 15.2 `listener-deployment.yaml` (ConfigMap + Service + Deployment)

**코드 (요약 발췌)**

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: listener-script, namespace: tsn-experiment }
data:
  listener.py: |
    # ... (listener.py 내용 inline) ...
---
apiVersion: v1
kind: Service
metadata: { name: listener-svc, namespace: tsn-experiment }
spec:
  selector: { app: listener }
  ports: [{ protocol: UDP, port: 5000, targetPort: 5000 }]
  clusterIP: None      # headless service → DNS round-robin
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: listener, namespace: tsn-experiment }
spec:
  replicas: 1
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: node-role.kubernetes.io/control-plane, operator: DoesNotExist }
      containers:
        - name: listener
          image: python:3.11-slim
          command: ["python3", "/app/listener.py"]
          args: ["--port=5000", "--interval=1", "--timeout=60", "--output=/data/results.csv"]
          volumeMounts:
            - { name: script, mountPath: /app }
            - { name: data, mountPath: /data }
          securityContext:
            capabilities: { add: ["NET_ADMIN", "SYS_NICE"] }
      volumes:
        - { name: script, configMap: { name: listener-script } }
        - { name: data, emptyDir: {} }
```

**1. 무엇을 하는 코드인가**
3 가지 K8s 리소스를 한 파일에:
- **ConfigMap** : listener.py 소스를 inline으로 넣어 mount → 이미지 build 불필요.
- **Service** : headless (`clusterIP: None`) UDP 5000 — DNS lookup 시 직접 Pod IP 반환.
- **Deployment** : replicas=1, worker 노드(`control-plane 라벨 없는 노드`) 에 배치, `python:3.11-slim` 기본 이미지로 ConfigMap 마운트하여 실행.

**2. 논문과의 매핑**
- 논문 §IV-A "Listener (Host-r) receives UDP packets" — 본 Deployment가 그것.
- worker 노드 배치 → "Host-r = worker01" 매핑.

**3. 왜 필요한가**
- listener 가 항상 미리 떠 있어야 talker가 송신 시작할 때 패킷 손실 없음.
- headless Service: K8s ClusterIP가 일반 Service라면 NAT가 추가되어 latency / priority 영향. headless 는 NAT 없이 직접 통신.
- `securityContext.capabilities: NET_ADMIN, SYS_NICE`: SO_PRIORITY 설정 + cpu affinity / nice 변경 권한.

**4. 누가, 언제 실행하는가**
- deploy-experiment.sh `deploy_k8s()` 가 `kubectl apply -f listener-deployment.yaml` 호출.
- kubelet이 worker01에 pod 스케줄 → containerd → python3 listener.py 시작.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **Deployment + ConfigMap (현)** | 코드 변경 시 image rebuild 불필요 | ConfigMap 용량 제한 1MB |
| StatefulSet | DNS 안정성 (listener-0) | 본 시나리오에 overkill |
| Custom image (Dockerfile) | self-contained | iteration 느림 |
| DaemonSet | 노드별 listener | 시나리오와 무관 (단일 listener) |
| **ClusterIP Service (NAT 포함)** | 표준 | NAT 추가 hop → priority 손실, latency 증가 |

→ Deployment + ConfigMap + headless Service: **빠른 반복 + 최소 hop**.

**6. 한계 및 주의사항**
- ⚠️ headless Service 라 DNS 캐시가 stale 시 talker 가 옛 Pod IP에 송신할 수 있음. talker-job 의 `--target=listener-svc.tsn-experiment.svc.cluster.local` 는 매번 DNS 해소 → 보통 정상.
- ⚠️ `emptyDir` 는 pod 재시작 시 results.csv 삭제 → `kubectl cp` 로 즉시 빼내야 함.

---

### 15.3 `talker-job.yaml` (ConfigMap + Job)

**코드 (요약 발췌)**

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: talker-script, namespace: tsn-experiment }
data:
  talker.py: |
    # ... (talker.py 내용 inline) ...
---
apiVersion: batch/v1
kind: Job
metadata: { name: talker-run, namespace: tsn-experiment }
spec:
  backoffLimit: 1
  template:
    spec:
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
      nodeSelector: { node-role.kubernetes.io/control-plane: "" }
      restartPolicy: Never
      containers:
        - name: talker
          image: python:3.11-slim
          command: ["python3", "/app/talker.py"]
          args:
            - "--target=listener-svc.tsn-experiment.svc.cluster.local"
            - "--port=5000"
            - "--interval=1"
            - "--count=10000"
            - "--size=128"
            - "--log=/data/talker-log.csv"
            - "--vlan-priority=3"   # SO_PRIORITY=3 → prio qdisc band 0 (TSN)
```

**1. 무엇을 하는 코드인가**
1회 실행 Job. master 노드(`control-plane` 라벨 있음)에 배치 (toleration + nodeSelector). `--vlan-priority=3` 으로 SO_PRIORITY 설정. 1ms 간격으로 10000 패킷 → 10초 실험.

**2. 논문과의 매핑**
- 논문 §IV-A "Talker (Host-s) sends UDP packets every 1ms"
- `--vlan-priority=3` 의 의미는 §IV "SO_PRIORITY → skb->priority → mqprio priomap" 그대로.

**3. 왜 필요한가**
- Job 으로 1회 실행 → 완료 후 `complete` condition 으로 deploy-experiment.sh가 대기 종료.
- master 노드 배치: Host-s = master, Host-r = worker01 의 논문 토폴로지 흉내.

**4. 누가, 언제 실행하는가**
deploy-experiment.sh `run_experiment()` 가 baseline/proposed 각각 1회 apply.

**5. 대안과 선택 이유**
- Deployment + replicas=1 — long-running. Job 이 의도(1회 실험) 와 일치.

**6. 한계**
- ⚠️ `backoffLimit: 1` — 실패 시 한 번 재시도. 잘못된 결과 누적 위험 (재시도 시 listener는 이미 종료) → 본 repo는 보통 첫 실행이 성공함.

---

### 15.4 `stress-daemonset.yaml`

**코드**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: cpu-stress, namespace: tsn-experiment }
spec:
  template:
    spec:
      tolerations: [{ operator: Exists }]  # 모든 노드
      containers:
        - name: stress
          image: alexeiled/stress-ng:latest
          args:
            - "--cpu"
            - "2"
            - "--cpu-load"
            - "99"                # ← deploy-experiment.sh 가 sed로 치환
            - "--timeout"
            - "600s"
            - "--cpu-method"
            - "matrixprod"
          resources:
            requests: { cpu: "100m", memory: "32Mi" }
            limits: { cpu: "2000m", memory: "64Mi" }
```

**1. 무엇을 하는 코드인가**
모든 노드(master + worker)에서 stress-ng로 CPU 부하 생성. `--cpu 2` = 2개 워커, `--cpu-load 99` = 목표 사용률 99%, `--cpu-method matrixprod` = 부하 종류 (행렬 곱). deploy-experiment.sh 가 sed로 99 → 사용자 지정 값(10/30/50/70 등) 치환.

**2. 논문과의 매핑**
- 논문 §IV-A "We vary CPU utilization from 10% to 99% via stress-ng background workload."
- 정확히 동일한 도구 + 옵션.

**3. 왜 필요한가**
- TSN의 가치는 "고부하 환경에서의 latency 안정성"이라, 부하 없이는 baseline vs proposed 차이가 거의 안 보임.
- DaemonSet 으로 master/worker 양쪽에 부하 → 양쪽 노드의 데이터패스 모두 stressed.

**4. 누가, 언제 실행하는가**
deploy-experiment.sh `run_experiment()` 가 talker Job 시작 전에 적용 → 5초 안정화 대기.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **stress-ng matrixprod (현)** | 표준 도구, 다양한 method | 부하 패턴이 단순 |
| `dd if=/dev/urandom of=/dev/null` | minimal | CPU 보다 disk/random 의존 |
| iperf3 부하 | 네트워크 부하 | CPU 가 아님 |
| Python loop | 단순 | 비효율, CPU 100% 도달 어려움 |

→ stress-ng: 논문 일치 + 잘 검증.

**6. 한계 및 주의사항**
- ⚠️ `cpu-load 99` 가 4 vCPU VM의 stress + kubelet + Cilium agent + 실험 워크로드를 모두 경쟁시켜 worker01 NotReady 가능 (README 트러블슈팅). 안전 상한 80% 권장.
- ⚠️ DaemonSet은 master에도 배치 → talker 자체의 페이싱도 영향. 의도된 동작 (논문도 양 노드 부하).

---

### 15.5 `test-master.yaml`

**코드**
```yaml
apiVersion: v1
kind: Pod
metadata: { name: test-master, namespace: tsn-experiment, labels: { app: test-master } }
spec:
  tolerations: [{ key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }]
  nodeSelector: { node-role.kubernetes.io/control-plane: "" }
  containers:
    - { name: sender, image: python:3.11-slim, command: ["sleep", "3600"] }
```

**1. 무엇을 하는 코드인가**
master 노드에 sleep 3600 으로 1시간 동안 살아있는 더미 pod. **유일한 목적**: Cilium이 이 pod를 위해 호스트에 `lxc<hash>` veth peer를 만들도록 유도 → eBPF attach 가능한 인터페이스 확보.

**2. 논문과의 매핑**
논문 외 — 본 repo의 운영 디테일. 실제 실험 시 talker job 이 같은 역할(veth 생성)을 하지만, eBPF attach 는 talker 시작 전 수행하므로 미리 lxc 가 있어야 함 → 더미 pod 필요.

**3. 왜 필요한가**
- attach-ebpf.sh 가 lxc<hash> 가 없으면 veth_filter를 attach할 곳이 없음 → silent failure.
- master 노드는 listener를 받지 않으므로 (control-plane taint) 빈 노드에 lxc 가 생성되지 않을 수 있음 → 더미 pod 으로 강제.

**4. 누가, 언제 실행하는가**
README 의 실험 실행 순서 (2) 단계에서 사용자가 수동 apply. eBPF attach 직전.

**5. 대안과 선택 이유**
- talker pod를 미리 띄워두고 sleep — talker.py에 sleep 옵션 추가 복잡. 더미 pod 가 단순.

**6. 한계**
- ⚠️ test-master pod이 OOM kill 되거나 evicted 되면 lxc<hash> 가 사라져 다음 실험에서 attach 실패. resource limit가 작아 OOM은 드물지만 가능.

---

### 15.6 `build-and-deploy.sh`

**코드 (핵심 발췌)**

```bash
build_images() {
    if sudo ctr -n k8s.io images ls 2>/dev/null | grep -q "python.*3.11-slim"; then
        echo "python:3.11-slim 이미지 이미 존재"
    else
        sudo ctr -n k8s.io images pull docker.io/library/python:3.11-slim
    fi
    echo "talker/listener 스크립트는 ConfigMap으로 전달됩니다."
}
deploy() {
    kubectl apply -f $K8S_DIR/namespace.yaml
    kubectl apply -f $K8S_DIR/listener-deployment.yaml
    kubectl -n $NAMESPACE wait --for=condition=ready pod -l app=listener --timeout=120s
}
run_experiment() {
    local CPU_LOAD="${1:-10}"; local LABEL="${2:-idle}"
    sed "s/\"99\"/\"$CPU_LOAD\"/" $K8S_DIR/stress-daemonset.yaml | kubectl apply -f -
    kubectl apply -f $K8S_DIR/talker-job.yaml
    kubectl wait --for=condition=complete job/talker-run --timeout=300s
    LISTENER_POD=$(...)
    kubectl cp "$LISTENER_POD:/data/results.csv" "results-${LABEL}-cpu${CPU_LOAD}.csv"
}
```

**1. 무엇을 하는 코드인가**
독립 실행 가능한 단순 워크플로 스크립트: `build` (이미지 pull), `deploy` (namespace+listener), `run-idle/mid/heavy` (실험 + CSV 회수). `deploy-experiment.sh` 의 간이 버전.

**2. 논문과의 매핑**
논문 외 운영. 메인 자동화는 root level `deploy-experiment.sh` 가 담당하며, 이 스크립트는 step7 디렉토리에 남은 초기 버전.

**3. 왜 필요한가**
빠른 sanity check 용. eBPF attach 없이 baseline 동작 확인 가능.

**4. 누가, 언제 실행하는가**
사용자가 수동 (`bash step7-experiment/build-and-deploy.sh run-idle`).

**5. 대안과 선택 이유**
**현재는 deploy-experiment.sh 가 master 스크립트**이며 본 파일은 historical/sanity 용도. **선택은 deploy-experiment.sh** (eBPF attach + qdisc 설정 포함).

**6. 한계**
- ⚠️ eBPF attach 단계가 빠져 있음 → proposed 모드 실행 불가. baseline 만 의미 있음.

---

## 16. 메인 자동화 — `deploy-experiment.sh`

본 repo의 **단일 진입점**. 600줄 가량의 셸 스크립트로 모든 단계 (eBPF 컴파일 / attach / TC qdisc / K8s 배포 / 실험 실행 / 정리 / 상태) 를 함수로 분리.

### 16.1 `setup_ebpf()`

**코드 (핵심 발췌)**

```bash
setup_ebpf() {
    local ROLE="${1:-sender}"
    cd "$EBPF_DIR"
    if ls build/*.bpf.o &>/dev/null; then
        log_info "사전 빌드된 eBPF 오브젝트 발견 — 컴파일 생략"
    else
        make clean 2>/dev/null || true
        make all DEBUG=2
    fi

    tc qdisc del dev "$PHYS_IF" clsact 2>/dev/null || true
    ip link set dev "$PHYS_IF" xdp off 2>/dev/null || true
    tc qdisc add dev "$PHYS_IF" clsact

    if [ "$ROLE" = "sender" ]; then
        tc filter add dev "$PHYS_IF" egress bpf da obj build/egress.bpf.o sec tc
        for veth in $(ip link show type veth | awk -F': ' '/^[0-9]/{print $2}' | cut -d'@' -f1); do
            tc qdisc add dev "$veth" clsact 2>/dev/null || true
            tc filter add dev "$veth" ingress bpf da obj build/veth_filter.bpf.o sec tc 2>/dev/null
        done
    fi
    if [ "$ROLE" = "receiver" ]; then
        tc filter add dev "$PHYS_IF" ingress bpf da obj build/ingress.bpf.o sec tc
    fi
    ip link set dev "$PHYS_IF" xdpgeneric obj build/xdp_vlan_avtp.bpf.o sec xdp 2>/dev/null
}
```

**1. 무엇을 하는 코드인가**
역할(sender/receiver) 에 따라 attach할 BPF를 분기. sender는 egress + veth_filter (모든 veth), receiver는 ingress. XDP는 양쪽 모두.

**2. 논문과의 매핑**
- 논문 Fig.1 의 Host-s 는 vef + eg, Host-r 은 ig 를 가짐 → 역할 분기와 일치.
- sender에서 veth_filter를 모든 veth에 attach 하는 것은 논문이 명시 안 함 — vef 의 attach 대상 식별 자동화는 본 repo의 추가.

**3. 왜 필요한가**
- 사전 빌드된 `.o` 가 git에 커밋되어 있어 clang 없는 노드에서도 attach 가능 — VM에 clang 없는 경우(저성능 노드) 유용.
- 빈 clsact qdisc 부터 add → 깨끗한 시작.

**4. 누가, 언제 실행하는가**
사용자 root. proposed 실험 직전 1회 (또는 보통 실험 시작 직전).

**5. 대안과 선택 이유**
- 매 실험마다 detach + re-attach: 안전. (vs) attach 후 유지하고 실험 반복: 빠르지만 attach 상태 stale 위험. **본 코드는 매번 detach → re-attach** 채택.

**6. 한계 및 주의사항**
- ⚠️ veth가 동적 생성 — pod 재시작 시 새 lxc<hash> 가 만들어지면 본 함수 재실행 필요. 본 함수는 polling으로 자동 재attach 안 함.
- ⚠️ XDP attach 실패는 무시 (`|| 무시 가능`). VM에서 일관성 위해.

---

### 16.2 `setup_tc_qdisc()` / `remove_tc_qdisc()`

**코드**

```bash
setup_tc_qdisc() {
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
    local txq_count=$(ls -d /sys/class/net/"$PHYS_IF"/queues/tx-* 2>/dev/null | wc -l)
    local qdisc_ok=0

    # 시도 1: mqprio (TX queue ≥ 3)
    if [ "$txq_count" -ge 3 ]; then
        if tc qdisc add dev "$PHYS_IF" root handle 100: mqprio \
            num_tc 3 map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
            queues 1@0 1@1 1@2 hw 0 2>/dev/null; then qdisc_ok=1; fi
    fi
    # 시도 2: prio (VM 폴백)
    if [ "$qdisc_ok" -eq 0 ]; then
        tc qdisc add dev "$PHYS_IF" root handle 100: prio \
            bands 3 \
            priomap 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2
    fi
    # ETF 시도 (시도 후 실패 시 무시)
    if tc qdisc add dev "$PHYS_IF" parent 100:1 handle 10: etf \
        clockid CLOCK_TAI delta 150000 deadline_mode on 2>/dev/null; then
        log_info "ETF 설정 완료 (CLOCK_TAI)"
    elif tc qdisc add dev "$PHYS_IF" parent 100:1 handle 10: etf \
        clockid CLOCK_REALTIME delta 150000 deadline_mode on 2>/dev/null; then
        log_info "ETF 설정 완료 (CLOCK_REALTIME)"
    else
        log_warn "ETF 미지원"
    fi
}

remove_tc_qdisc() {
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
}
```

**1. 무엇을 하는 코드인가**
proposed 모드 활성화 시 3단계 폴백:
1. mqprio `hw 0` (TX queue ≥ 3일 때)
2. **prio bands 3 + priomap `2 2 1 0 …`** (실제 VM에서 사용되는 경로)
3. ETF child qdisc on band 0 (CLOCK_TAI → CLOCK_REALTIME 폴백, 둘 다 실패 시 skip)

baseline 모드는 `remove_tc_qdisc()` 로 root qdisc 제거 → 시스템 기본(fq_codel/pfifo_fast)로 회귀.

**2. 논문과의 매핑**
- 논문은 mqprio + ETF + ETS 조합. 본 코드는 ETS/taprio 미시도 (간소화).
- `prio` 폴백: 논문 외 — VM virtio가 mqprio offload 거부 시 유일한 옵션.
- `priomap 2 2 1 0 …`: priority 3 → band 0, priority 2 → band 1, priority 0/1 → band 2. mqprio의 `map` 옵션과 동일한 의미.

**3. 왜 필요한가**
- 본 repo의 **실제 동작 핵심**: prio band 0 dequeue 우선 — talker의 SO_PRIORITY=3 → priomap[3]=0 → band 0 enqueue → dequeue 우선.
- baseline은 단일 FIFO → 부하 시 패킷 burst 가 줄지어 latency tail 폭증.

**4. 누가, 언제 실행하는가**
- root. `run_experiment proposed <cpu>` 시작 시 `setup_tc_qdisc()` 호출. `run_experiment baseline <cpu>` 시 `remove_tc_qdisc()`.
- 호출 체인: tc → kernel net/sched/sch_prio (또는 sch_mqprio).

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **prio bands 3 (VM 폴백, 실제 사용)** | 어디서나 동작, 단순 strict priority | 단일 NIC queue → 하드웨어 dequeue 분리 없음 |
| mqprio hw 0 | tc class hierarchy + 후속 child qdisc | VM에서 효과 없음 |
| mqprio hw 1 (논문) | 하드웨어 dequeue | virtio 거부 |
| taprio software | 시간 슬롯 게이트 | clockid 정밀도 한계 |
| qdisc 없음 (baseline 자체) | 가장 단순 | 우선순위 효과 없음 |

→ **prio 채택**: VM 호환성 + 논문 의도(우선순위 dequeue) 만 보존하는 최소 구현.

**6. 한계 및 주의사항**
- ⚠️ ETF attach 가 성공해도 talker.py 가 `SO_TXTIME` 미사용 → ETF는 작동만 하고 실효성 없음.
- ⚠️ prio qdisc는 dequeue 만 우선순위 정렬, enqueue 시 backpressure 없음 → best-effort burst가 충분히 크면 queue 가 가득 차 tail drop 가능. 본 실험은 throughput 125 KB/s 라 queue 크기 안에 들어감.

---

### 16.3 `deploy_k8s()`

**코드 (핵심 발췌)**

```bash
deploy_k8s() {
    if kubectl get namespace tsn-experiment &>/dev/null; then
        kubectl -n tsn-experiment delete job --all --force --grace-period=0 2>/dev/null || true
        kubectl -n tsn-experiment delete daemonset --all --force --grace-period=0 2>/dev/null || true
        kubectl delete namespace tsn-experiment --timeout=30s 2>/dev/null || {
            # Finalizer 제거하여 강제 삭제
            kubectl get namespace tsn-experiment -o json | \
                sed 's/"finalizers": \[[^]]*\]/"finalizers": []/' | \
                kubectl replace --raw "/api/v1/namespaces/tsn-experiment/finalize" -f -
        }
    fi
    kubectl apply -f "$K8S_DIR/namespace.yaml"
    kubectl apply -f "$K8S_DIR/listener-deployment.yaml"
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=180s
}
```

**1. 무엇을 하는 코드인가**
기존 tsn-experiment namespace 가 있으면 모든 리소스 강제 삭제 → namespace 삭제 → 새로 생성 → listener 배포 → ready 대기. namespace `Terminating` stuck 시 finalizer 강제 제거 (last resort).

**2. 논문과의 매핑**
논문 외. K8s 운영 패턴.

**3. 왜 필요한가**
- 직전 실험의 stale 리소스가 남아 있으면 새 실험에 영향 (e.g., 옛 cpu-stress가 부하 유지). 매번 클린 슬레이트.
- namespace `Terminating` stuck은 K8s 운영의 흔한 함정 — finalizer 강제 제거가 마지막 수단.

**4. 누가, 언제 실행하는가**
사용자. 매 실험 세션 시작 시 1회.

**5. 대안**: 매번 `kubectl delete --all` 만 → namespace 자체 유지. 본 코드는 더 강력하게 namespace까지 삭제.

**6. 한계**
- ⚠️ finalizer 강제 제거는 일부 controller 가 cleanup 미완료 상태로 leave → 다음 실험에 부수 효과 가능. 본 repo의 cilium 등은 보통 영향 없음.

---

### 16.4 `run_experiment()`

**코드 (핵심 발췌)**

```bash
run_experiment() {
    local MODE="${1:-baseline}"     # baseline 또는 proposed
    local CPU_LOAD="${2:-10}"
    mkdir -p "$RESULTS_DIR"

    if [ "$MODE" = "proposed" ]; then
        [ "$(id -u)" -ne 0 ] && { log_error "sudo 필요"; exit 1; }
        setup_tc_qdisc
    else
        remove_tc_qdisc
    fi

    kubectl -n tsn-experiment delete job talker-run --ignore-not-found=true
    kubectl -n tsn-experiment delete daemonset cpu-stress --ignore-not-found=true
    sleep 3

    # Listener 재시작 (이전 실행 후 종료 → CrashLoopBackOff 방지)
    kubectl -n tsn-experiment delete pod -l app=listener --grace-period=5
    kubectl -n tsn-experiment wait --for=condition=ready pod -l app=listener --timeout=120s
    LISTENER_POD=$(kubectl -n tsn-experiment get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')

    # CPU 부하
    sed "s/\"99\"/\"$CPU_LOAD\"/" "$K8S_DIR/stress-daemonset.yaml" | kubectl apply -f -
    sleep 5

    # Talker
    kubectl apply -f "$K8S_DIR/talker-job.yaml"
    kubectl wait --for=condition=complete job/talker-run --timeout=300s

    # Listener 결과 대기 (최대 90초 polling)
    for i in $(seq 1 18); do
        kubectl exec "$LISTENER_POD" -- test -f /data/results.csv && break
        sleep 5
    done
    kubectl cp "$LISTENER_POD:/data/results.csv" "$RESULTS_DIR/${MODE}_cpu${CPU_LOAD}.csv"

    kubectl -n tsn-experiment delete daemonset cpu-stress --ignore-not-found=true

    # eBPF 통계 출력
    bpftool map dump name pkt_stats | python3 -c "..."
    bpftool map dump name debug_stats | python3 -c "..."
}
```

**1. 무엇을 하는 코드인가**
1회 실험의 전체 라이프사이클:
1. 모드별 qdisc 설정 (proposed=prio, baseline=default)
2. 이전 talker/stress 리소스 정리
3. listener pod 재시작 (clean state 보장)
4. stress daemonset 적용 (sed로 cpu-load 치환)
5. talker job 적용 → completion 대기
6. listener에서 results.csv 복사
7. stress 정리
8. eBPF 통계 dump

**2. 논문과의 매핑**
논문 §IV-A 의 실험 절차 충실 구현. 특히 CPU 부하 변동에 따른 baseline vs proposed 비교 (논문 Figure 2~6) 의 데이터 생성.

**3. 왜 필요한가**
- listener pod 재시작 없이는 이전 실험에서 종료된 Python 프로세스 때문에 새 talker 의 패킷을 못 받음.
- 90초 polling은 listener의 `--timeout=60` (마지막 패킷 후 60초 대기 후 CSV 작성) 을 커버.
- bpftool dump는 디버깅용 — 본 repo는 native routing이라 카운터 0이지만 정상 동작 확인 메시지 출력.

**4. 누가, 언제 실행하는가**
- 사용자. baseline 1회 + proposed 1회 = 한 CPU 부하 비교. 여러 CPU 부하 (10, 30, 50, 70, 99) 반복 → README 결과 표 채움.

**5. 대안과 선택 이유**
- 함수 한 개로 baseline/proposed 통합 (현) vs 따로 (분리) → 통합 채택 (코드 중복 제거).

**6. 한계**
- ⚠️ `sed "s/\"99\"/\"$CPU_LOAD\"/"` — stress-daemonset.yaml 의 cpu-load 값이 "99" 라는 가정. 다른 값으로 바꾸면 sed 실패. 안정성 trade-off.
- ⚠️ talker job 의 backoffLimit=1 → 첫 시도 실패 시 자동 재시도되며 listener는 이미 결과 작성. 잘못된 데이터 위험.

---

### 16.5 `cleanup()` / `status()`

**코드 (요약)**

```bash
cleanup() {
    kubectl delete namespace tsn-experiment 2>/dev/null || true
    tc qdisc del dev "$PHYS_IF" clsact 2>/dev/null || true
    tc qdisc del dev "$PHYS_IF" root 2>/dev/null || true
    ip link set dev "$PHYS_IF" xdp off 2>/dev/null || true
    for veth in $(ip link show type veth | …); do
        tc qdisc del dev "$veth" clsact 2>/dev/null || true
    done
}

status() {
    kubectl get nodes -o wide
    ls -d /sys/class/net/$PHYS_IF/queues/tx-* | wc -l
    ethtool -i $PHYS_IF
    tc filter show dev $PHYS_IF egress
    tc filter show dev $PHYS_IF ingress
    # veth + BPF attach 여부
    # qdisc
    # XDP
    # bpftool prog list / map dump
    # Cilium routing mode
    # K8s pods
    # trace_pipe 최근 로그
}
```

**1. 무엇을 하는 코드인가**
- `cleanup`: 모든 실험 리소스 (k8s namespace, qdisc, XDP, veth clsact) 일괄 제거.
- `status`: 현재 시스템 상태 전체 점검 (노드, NIC queue, BPF attach, qdisc, XDP, BPF map 카운터, Cilium routing, k8s pod, trace_pipe).

**2. 매핑**: 논문 외 운영.

**3. Why**: 실험 후 시스템을 깨끗한 상태로 되돌려 다음 실험이나 일반 사용에 지장 없도록. status는 문제 진단의 시작점.

**4. Who/When**: 사용자. cleanup은 세션 종료 시, status는 문제 발생 시 또는 검증 시.

**5. 대안**: 개별 명령 직접 — 가능하지만 사람이 모두 기억하기 어려움. 본 함수가 단일 진입점.

**6. 한계**:
- ⚠️ cleanup이 BPF program 자체를 unload하지 않음 (kernel이 attach 해제 후 보통 자동 GC).

---

## 17. 측정·분석 (step8-measurement)

### 17.1 `step8-measurement/plot-results.py`

#### 17.1.1 데이터 로딩 + clock skew 정규화

**코드**

```python
def load_results(mode, cpu_load, normalize_skew=True):
    path = RESULTS_DIR / f"{mode}_cpu{cpu_load}.csv"
    if not path.exists(): return None
    data = {"latency_ms": [], "jitter_us": [], "pkt_size": [], "seq": []}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            data["latency_ms"].append(float(row["latency_ms"]))
            data["jitter_us"].append(float(row["jitter_us"]))
            ...
    if normalize_skew and data["latency_ms"]:
        skew = float(np.percentile(data["latency_ms"], 1))
        data["latency_ms"] = [v - skew for v in data["latency_ms"]]
        data["_clock_skew_ms"] = skew
    return data
```

**1. 무엇을 하는 코드인가**
listener의 CSV를 읽고, latency_ms의 1st percentile 값을 0으로 빼서 음수 latency 보정. 보정량은 `_clock_skew_ms` 에 기록.

**2. 논문과의 매핑**
- 논문은 PTP 동기화 가정 (skew 없음) → 정규화 불필요.
- 본 repo는 PTP 부정확 → 정규화로 우회. **논문 외 추가 구현**.

**3. 왜 필요한가**
- listener의 `latency_ms = recv_ns - send_ns` 가 master/worker 시계가 1ms 어긋나면 모두 -1ms 오프셋. 음수 latency는 의미 없음 + 로그 스케일 그래프에 표시 불가.
- 1st percentile (≈ 최소 근처지만 outlier에 강건) 을 0으로 잡으면 모든 latency 가 ≥ 0이 되어 그래프 정상.

**4. 누가, 언제 실행하는가**
plot-results.py 실행 시 각 CSV 1회 호출.

**5. 대안과 선택 이유**

| 대안 | 장점 | 단점 |
|---|---|---|
| **1st percentile → 0 (현)** | outlier 강건 | 음수 latency 손실 |
| min → 0 | 가장 단순 | 단일 outlier에 취약 (negative spike → 모든 값이 양수 큰 값) |
| median → 0 | 통계적 안정 | 절대값 의미 완전 상실 |
| 보정 안 함 | 절대값 유지 | 음수 표시, 로그 그래프 불가 |
| PTP 정확히 설정 → 보정 불필요 | 근본 해결 | VM에서 어려움 |

→ 1st percentile: README 가 명시한 "VM 한계 우회" 의 표준 접근.

**6. 한계 및 주의사항**
- ⚠️ 보정 후 latency 는 **상대값**. baseline vs proposed 비교에는 유효하나, "실제 latency가 몇 ms 였는지" 의 절대 해석은 불가.
- ⚠️ baseline과 proposed의 skew가 다르면 (예: 실험 사이에 NTP step) 각각 다른 보정 → 비교가 약간 어긋남. 본 repo는 같은 세션에서 baseline → proposed 순으로 실행하여 skew drift 최소화.

#### 17.1.2 비교 패널 선택 로직

**코드**

```python
def select_comparison_cpu_loads():
    """- low: both 있는 최저, high: both 있는 최고, extreme: 한쪽이라도 최고"""
    both = get_available_cpu_loads()      # baseline+proposed 모두 있음
    partial = get_partial_cpu_loads()     # 한쪽이라도 있음
    selected = set()
    if both:
        selected.add(both[0])   # low
        selected.add(both[-1])  # high
    if partial:
        selected.add(partial[-1])  # extreme
    return sorted(selected)
```

**1. 무엇을 하는 코드인가**
Figure 2/4/6 (3-패널 비교 그래프) 에 표시할 CPU 부하 자동 선택. 보통 `{10, 70, 99}` 가 선택됨 (10% = both, 70% = both, 99% = proposed only).

**2. 논문과의 매핑**
- 논문 Figure 2/4/6 은 "low CPU utilization" 과 "high CPU utilization" 두 패널.
- 본 repo는 99% baseline 측정 실패 (README 명시) → "extreme" 패널 추가하여 proposed 단독으로 극단 부하 추세 표시.

**3. 왜 필요한가**
- 측정 데이터의 부분 누락(예: 99% baseline) 에도 그래프가 무너지지 않도록 동적 선택.
- 부하 단계 모두 표시하면 그래프가 너무 빽빽 → 대표 3개만.

**4. 누가, 언제 실행하는가**
plot-results.py 실행 시 1회.

**5. 대안과 선택 이유**
- 고정 부하 (e.g., 10%, 70%) 만 표시 — 부분 누락 시 빈 패널.
- 본 동적 선택 — 누락 robust.

**6. 한계**
- 측정 부하 종류가 늘어도 그래프는 3 패널 — 정보 손실. Figure 3/5는 전체 부하를 grouped bar로 표시하여 보완.

#### 17.1.3 Figure 2 — Throughput

**코드**

```python
def figure2_throughput():
    targets = select_comparison_cpu_loads()
    fig, axes = plt.subplots(1, len(targets), figsize=(6 * len(targets), 5))
    for ax, cpu in zip(axes, targets):
        for mode, label in SOLUTIONS.items():
            d = load_results(mode, cpu)
            total_bytes = sum(d["pkt_size"])
            duration_s = max((len(d["pkt_size"]) - 1) * 0.001, 0.001)
            bws.append(total_bytes / duration_s / 1024.0)
        ax.bar(modes, bws, color=colors)
        ax.set_ylabel("Bandwidth (KB/s)")
```

**1. 무엇을 하는 코드인가**
패킷 크기 합 ÷ 추정 duration (10000 패킷 × 1ms = 10 초) → KB/s. 두 모드 막대 비교.

**2. 매핑**: 논문 Figure 2 그대로.

**3. Why**: throughput이 prio qdisc 적용으로 깎이지 않는지 (부작용 검증).

**4. When**: 분석 단계.

**5. 대안**: real elapsed time (last_recv_ns - first_recv_ns) 사용 — 약간 더 정확. 본 코드는 단순화.

**6. 한계**:
- ⚠️ duration은 패킷 수 기반 추정 → 실제 송신 시간과 미세 차이 가능. throughput 절대값 약간 부정확하나 baseline vs proposed 비교에는 영향 없음.

#### 17.1.4 Figure 3/5 — Grouped percentile bars

**코드**

```python
def grouped_percentile_bars(metric_key, metric_label, unit, percentiles, ...):
    avail = get_partial_cpu_loads()
    bar_width = 0.8 / (n_modes * n_pct)
    ...
    for m_idx, (mode, _) in enumerate(SOLUTIONS.items()):
        for p_idx, p_name in enumerate(percentiles):
            heights = []
            for cpu in avail:
                d = load_results(mode, cpu)
                values = d[metric_key]
                if metric_key == "jitter_us":
                    values = [abs(v) for v in values[1:]]
                if p_name == "max": heights.append(max(values))
                else: heights.append(percentile(values, int(p_name[1:])))
            ax.bar(x, heights, ..., color=color, alpha=0.85 - p_idx * 0.18, hatch=pct_hatches[p_name])
```

**1. 무엇을 하는 코드인가**
X축: CPU 부하 (10/30/50/70/99%). 각 부하마다 [Baseline p50, Baseline p99, Baseline max, Proposed p50, Proposed p99, Proposed max] 6개 막대 (Figure 3) 또는 4개 (Figure 5). 색 = 모드, hatch = percentile.

**2. 매핑**: 논문 Figure 3 (latency), 5 (jitter) 와 동일한 구조.

**3. Why**: 한 그래프로 모든 부하 + 두 모드 + 3 percentile 동시 비교.

**4. When**: 분석.

**5. 대안**: line plot으로 cpu→metric 곡선 — percentile 동시 표시 어려움. **선택: bar grouping**.

**6. 한계**:
- ⚠️ y축 log scale — 0 값 표시 못 함 (자동 무시).
- ⚠️ percentile 라벨이 작음 (n_cpu>4 시 90도 회전).

#### 17.1.5 Figure 6 — CDF

**코드**

```python
def figure6_cdf():
    targets = select_comparison_cpu_loads()
    for ax, cpu in zip(axes, targets):
        for mode, label in SOLUTIONS.items():
            d = load_results(mode, cpu)
            lat = np.sort(d["latency_ms"])
            cdf = np.arange(1, len(lat) + 1) / len(lat)
            ax.plot(lat, cdf, color=COLORS[mode], linewidth=2.0, label=label)
        ax.set_xscale("log")
```

**1. 무엇을 하는 코드인가**
누적 분포 함수 (CDF) 곡선. X축 = latency (ms, log scale). Y축 = 누적 확률 (0~1). 좌상단에 가까울수록 빠르고 일관됨.

**2. 매핑**: 논문 Figure 6 그대로.

**3. Why**: percentile 표 한두 개로 못 보는 분포 전체 형태 visualisation. tail latency 패턴 비교에 핵심.

**4. When**: 분석.

**5. 대안**: histogram — bin 선택에 따라 인상이 달라짐. CDF 가 robust.

**6. 한계**: log scale X축 → 0 또는 음수 latency 처리 (정규화로 해결됨).

---

### 17.2 (루트)`compare_results.py`

**코드 (핵심 발췌)**

```python
def load_csv(path, normalize=True):
    rows = list(csv.DictReader(open(path)))
    if normalize:
        lats = sorted(float(r["latency_ms"]) for r in rows)
        skew = lats[max(0, int(len(lats) * 0.01))]
        for r in rows:
            r["latency_ms"] = str(float(r["latency_ms"]) - skew)
    return rows

def stats(values):
    s = sorted(values)
    n = len(s)
    return {"min": s[0], "p50": s[n//2], "p90": s[int(n*0.9)],
            "p99": s[int(n*0.99)], "max": s[-1],
            "mean": sum(s)/n, "stdev": statistics.stdev(s) if n>1 else 0}

available_cpu = sorted(set(
    int(p.stem.split("_cpu")[1])
    for mode in ("baseline", "proposed")
    for p in RESULTS_DIR.glob(f"{mode}_cpu*.csv")
))
...
for cpu in available_cpu:
    for mode in ["baseline", "proposed"]:
        rows = load_csv(path, normalize=True)
        lat = [...]; jit = [abs(float(r["jitter_us"])) for r in rows[1:]]
        ls, js = stats(lat), stats(jit)
        # 표 형태로 print

# 개선율
for cpu in available_cpu:
    def imp(before, after):
        return f"{(after-before)/before*100:+.1f}%"
    print(f"  CPU {cpu}%: lat p99 {blat99} → {plat99}ms ({imp(...)}) | ...")
```

**1. 무엇을 하는 코드인가**
CSV들의 통계 (min/p50/p90/p99/max/mean/stdev) 를 표로 출력 + baseline vs proposed 개선율 계산. README의 결과 표를 자동 생성하는 도구.

**2. 매핑**: 논문 외. 본 repo의 README 의 수치 출처.

**3. Why**: plot 외에 숫자 비교 필요. compare_results.py 가 single source of truth.

**4. When**: 분석. verify-experiment.sh 가 자동 호출.

**5. 대안**: pandas df.describe() — 간단하지만 percentile 사용자 정의 어려움. 본 코드는 명시적.

**6. 한계**:
- ⚠️ p50 = `s[n//2]` 는 정확히는 50.0 percentile (`np.percentile` 결과와 미세 차이). 본 실험 정밀도에서는 무관.

---

### 17.3 (루트)`verify-experiment.sh`

**코드 (핵심 발췌)**

```bash
echo "[1] K8s 클러스터 상태"
kubectl get nodes | grep -q Ready

echo "[2] eBPF 프로그램 부착 상태"
sudo tc filter show dev enp0s3 egress | grep -c egress.bpf.o
ip link show enp0s3 | grep -c xdpgeneric
sudo bpftool net show | grep -c "veth_filter.bpf.o"

echo "[3] TC Qdisc"
sudo tc qdisc show dev enp0s3 | head -1   # prio = proposed, fq_codel = baseline

echo "[4] CSV 파일 목록"
ls $RESULTS_DIR/*.csv

echo "[5] Baseline vs Proposed 통계"
python3 compare_results.py $RESULTS_DIR

echo "[6] 그래프"
ls $FIG_DIR

echo "[7] eBPF pkt_stats"
sudo bpftool map dump name pkt_stats | python3 ...
```

**1. 무엇을 하는 코드인가**
실험 환경의 7개 측면 (k8s 상태, BPF attach, qdisc, CSV, 통계, 그래프, BPF 카운터) 를 한 번에 검증. 사용자가 "내 실험이 잘 됐나?" 를 빠르게 확인.

**2. 매핑**: 논문 외 운영. README "빠른 시작 — 3분 안에 검증" 의 도구.

**3. Why**: 환경 셋업이 복잡하므로 빠른 sanity check 가 필수.

**4. When**: 실험 직후, 또는 결과 의심스러울 때.

**5. 대안**: 각 명령 수동 실행 — 가능하지만 휴먼 에러.

**6. 한계**:
- ⚠️ `enp0s3` 가 하드코딩됨 → 다른 NIC 이름 환경에서는 [WARN] 출력. 본 repo의 VirtualBox NAT Network 기본 가정.

---

## 18. 전체 End-to-End 패킷 경로 (Time-Sensitive vs Best-Effort)

### 18.1 Time-Sensitive 패킷 (talker → listener, SO_PRIORITY=3, UDP:5000) — Proposed 모드

```
[Host-s = k8s-master]
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ STEP 1. Userspace: talker.py 송신                                        │
 │   - sock.setsockopt(SOL_SOCKET, SO_PRIORITY, 3)                          │
 │   - sock.sendto(pkt, ("listener-svc.tsn-experiment...", 5000))           │
 │   ▶ 코드: step7-experiment/talker/talker.py:80 (SO_PRIORITY)             │
 │           step7-experiment/talker/talker.py:114 (sendto)                 │
 │   ▶ 호출자: K8s Job (talker-job.yaml --vlan-priority=3)                  │
 └──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
 STEP 2. Kernel UDP send (udp_sendmsg → ip_output)
   - skb 할당, skb->priority = 3 자동 전파 (SO_PRIORITY 효과)
   ▶ 커널: net/ipv4/udp.c udp_sendmsg(), net/ipv4/ip_output.c

                              │
                              ▼
 STEP 3. talker pod의 eth0 (veth interior) dev_queue_xmit
   - veth driver의 veth_xmit() → peer napi schedule

                              │
                              ▼
 STEP 4. 호스트의 lxc<hash> (veth exterior) napi receive
   - __netif_receive_skb_core → sch_handle_ingress

                              │
                              ▼
 STEP 5. ★ clsact ingress hook on lxc<hash> ★
   - veth_filter.bpf.o 실행
     * eth->h_proto = ETH_P_IP (VLAN 없음)
     * UDP dport == 5000 → 분류 TSN
     * stats_inc(STATS_TSN), skb->priority = 3 (이미 3이지만 재확인)
     * return TC_ACT_OK
   ▶ 코드: step6-ebpf/src/veth_filter.c:127 (Case 3 UDP port)
   ▶ 주의: Cilium tcx (cil_from_container) 가 동일 hook 다음에 실행 가능

                              │
                              ▼
 STEP 6. Cilium tcx cil_from_container
   - IP/L4 정책 검사, bpf_redirect(enp0s3 ifindex, BPF_F_INGRESS=0)
   ▶ 외부 모듈 (Cilium agent)

                              │
                              ▼
 STEP 7. enp0s3 dev_queue_xmit
   - __dev_queue_xmit → sch_handle_egress

                              │
                              ▼
 STEP 8. ★ clsact egress hook on enp0s3 ★
   - egress.bpf.o 실행
     * stats_inc(STATS_TOTAL)
     * dport == 5000 → stats_inc(STATS_TSN)
     * priority_to_tc(3) → TC_CLASS_HIGH (=0)
     * ring buffer log 기록 (소비자 없으면 누락)
     * return TC_ACT_OK
   ▶ 코드: step6-ebpf/src/egress.c:48

                              │
                              ▼
 STEP 9. ★ enp0s3 의 prio qdisc enqueue ★ (proposed only)
   - priomap[skb->priority=3] = 0 → band 0
   - band 0 (TSN) FIFO에 enqueue
   ▶ 코드: deploy-experiment.sh:184 (priomap 2 2 1 0 ...)
   ▶ 커널: net/sched/sch_prio.c

                              │
                              ▼
 STEP 10. prio qdisc dequeue (band 0 우선)
   - band 0 empty 아니면 band 1/2 양보. TSN 패킷이 best-effort burst 앞에서 dequeue.
   ▶ baseline mode 와의 차이: baseline은 단일 FIFO

                              │
                              ▼
 STEP 11. virtio-net hard_start_xmit
   - vhost-net → 호스트 OS → VirtualBox vboxnet → NAT Network

                              │  (~수백μs ~ 수ms : VM virtualization overhead)
                              ▼
 [Host-r = k8s-worker01]
 STEP 12. virtio-net rx NAPI poll
   - skb 생성 → __netif_receive_skb_core

                              │
                              ▼
 STEP 13. ★ xdpgeneric hook on enp0s3 ★ (양쪽 모두)
   - xdp_vlan_avtp.bpf.o 실행
     * eth_proto = ETH_P_IP → Case 3 (default), XDPSTAT_BEST_EFFORT++, return XDP_PASS
     * (VLAN/AVTP 없으므로 TSN 분류 안 됨 — 이건 XDP의 의도 — 다음 stage가 처리)
   ▶ 코드: step6-ebpf/src/xdp_vlan_avtp.c

                              │
                              ▼
 STEP 14. ★ clsact ingress hook on enp0s3 ★
   - ingress.bpf.o 실행
     * now = bpf_ktime_get_ns()
     * dport == 5000 → stats_inc(STATS_TSN)
     * last_arrival map lookup → jitter 계산
     * ring buffer log 기록
     * return TC_ACT_OK
   ▶ 코드: step6-ebpf/src/ingress.c

                              │
                              ▼
 STEP 15. Cilium tcx cil_from_netdev → endpoint 매핑 → 라우팅

                              │
                              ▼
 STEP 16. ip_rcv → ip_local_deliver → udp_rcv → sk_receive_skb
   - listener pod의 sk_buff queue에 enqueue

                              │
                              ▼
 STEP 17. listener.py recvfrom() return
   - recv_ns = time.time_ns()
   - latency_ms = (recv_ns - send_ns) / 1e6
   - jitter_us = (recv_ns - prev_recv_ns - 1ms) / 1e3
   - results.append({...})
   ▶ 코드: step7-experiment/listener/listener.py:68~108
```

### 18.2 Best-Effort 패킷 (예: ping, kubelet health check, Cilium control) — 같은 NIC 통과

```
 STEP 1. (다른 프로세스) sock.sendto() 또는 시스템 패킷
 STEP 2. skb->priority = 0 (기본값, SO_PRIORITY 미설정)
 STEP 3~7. (talker와 동일한 경로)
 STEP 5. veth_filter:
   - eth_proto != ETH_P_AVTP, no VLAN, no UDP:5000 → STATS_BEST_EFF++, TC_ACT_UNSPEC
 STEP 8. egress.bpf.o:
   - dport != 5000, priority != 3 → STATS_BEST_EFF++, TC_ACT_OK
 STEP 9. prio qdisc (proposed):
   - priomap[0] = 2 → band 2 enqueue (best-effort)
 STEP 10. prio dequeue:
   - band 0 (TSN) 비어 있을 때만 band 2 dequeue → TSN 패킷이 모두 빠진 후 처리
   * baseline mode: 단일 FIFO → TSN 패킷과 같이 줄섬 → tail latency 큼
```

### 18.3 두 경로 차이 요약

| Stage | Time-Sensitive | Best-Effort | 차이 발생 지점 |
|---|---|---|---|
| Userspace | SO_PRIORITY=3 set | priority 기본 0 | talker.py:80 |
| veth_filter Case | UDP:5000 → TSN | 그 외 → BE | veth_filter.c:127 |
| egress.bpf.o classify | STATS_TSN++ | STATS_BEST_EFF++ | egress.c:166 |
| prio enqueue band | **band 0** | **band 2** | priomap 2 2 1 0 … |
| prio dequeue 우선순위 | 가장 먼저 | band 0 비었을 때만 | sch_prio.c |
| 측정값 (CPU 50% 기준) | p99 latency ~7ms | p99 ~12ms | README 결과 표 |

### 18.4 Baseline 모드와의 차이

| 단계 | Proposed | Baseline | 영향 |
|---|---|---|---|
| STEP 5/8 BPF | attach됨 | attach됨 (proposed와 동일) | 카운터만 다름 |
| STEP 9 qdisc | **prio bands 3** | fq_codel/pfifo (기본) | **핵심 차이** — 우선순위 dequeue 정책 |
| STEP 10 dequeue | band 0 strict 우선 | FIFO 순서 | proposed가 TSN tail latency 감소 |
| 측정 결과 | p99 ↓ 28~74% (CPU 10~50%) | (baseline 기준선) | README |

### 18.5 cross-reference 표

| Step | 파일:줄 | 함수/블록 |
|---|---|---|
| STEP 1 SO_PRIORITY | [step7-experiment/talker/talker.py:80](step7-experiment/talker/talker.py) | `sock.setsockopt(..., SO_PRIORITY, ...)` |
| STEP 1 페이싱 | [step7-experiment/talker/talker.py:99-114](step7-experiment/talker/talker.py) | `for seq in range(args.count):` |
| STEP 5 veth_filter | [step6-ebpf/src/veth_filter.c:29](step6-ebpf/src/veth_filter.c) | `int veth_filter(struct __sk_buff *skb)` |
| STEP 6 Cilium tcx | (Cilium 외부) | `cil_from_container` |
| STEP 8 egress.bpf.o | [step6-ebpf/src/egress.c:47](step6-ebpf/src/egress.c) | `int egress_prog(...)` |
| STEP 9 prio qdisc 설정 | [deploy-experiment.sh:182-185](deploy-experiment.sh) | `tc qdisc add ... prio bands 3 priomap 2 2 1 0` |
| STEP 9 priomap → tc class | [step6-ebpf/src/common.h:68-74](step6-ebpf/src/common.h) | `TSN_VLAN_PRI_HIGH / TC_CLASS_HIGH` |
| STEP 13 XDP | [step6-ebpf/src/xdp_vlan_avtp.c:54](step6-ebpf/src/xdp_vlan_avtp.c) | `int xdp_vlan_avtp_prog(...)` |
| STEP 14 ingress.bpf.o | [step6-ebpf/src/ingress.c:47](step6-ebpf/src/ingress.c) | `int ingress_prog(...)` |
| STEP 17 latency 계산 | [step7-experiment/listener/listener.py:89](step7-experiment/listener/listener.py) | `latency_ns = recv_ns - send_ns` |
| STEP 17 jitter 계산 | [step7-experiment/listener/listener.py:95-97](step7-experiment/listener/listener.py) | `jitter_ns = recv_ns - (prev + T)` |

---

## 19. 논문 ↔ 코드 차이 표 (VM 환경의 우회 및 타협)

| # | 논문 가정 | 본 repo 구현 | 코드 위치 | 우회 방식 / 타협 |
|---|---|---|---|---|
| 1 | NIC 4 hw TX queue | virtio-net 1 queue | `step5-tc-qdisc/01-setup-mqprio.sh`, `deploy-experiment.sh:setup_tc_qdisc` | mqprio `hw 0` 시도 → 실패 → prio qdisc 폴백 |
| 2 | CPU 72 코어, 8코어 isolcpus | 4 vCPU, isolcpus 미적용 | `step2-os-setup/03-configure-isolcpus.sh` (제공만, 비활성) | 격리 없이 측정 — 고부하 시 효과 제한 |
| 3 | 하드웨어 PTP (~ns) | 소프트웨어 PTP + chrony (~ms) | `step2-os-setup/04-configure-ptp.sh` | 1st percentile 정규화로 분석 단계 보정 |
| 4 | XDP native | xdpgeneric | `attach-ebpf.sh:36`, `deploy-experiment.sh:127` | XDP 성능 이점 사라짐 — 카운팅만 |
| 5 | ETF CLOCK_TAI hw offload | CLOCK_TAI 시도 → CLOCK_REALTIME 폴백, software-only | `deploy-experiment.sh:setup_tc_qdisc` | offload off — 정밀도 ↓ |
| 6 | mqprio map → 하드웨어 queue 분리 | prio bands → 단일 queue 내 정렬 | `deploy-experiment.sh:183-185` | 의도 (priority 정렬) 만 보존 |
| 7 | overlay/tunnel 가정 (vef의 underlay 분기 의미) | Cilium native routing | `step4-cilium/01-install-cilium.sh:56` (routingMode=native) | vef 의 TC_ACT_OK / UNSPEC 분기는 동작하나 Cilium이 우회하므로 효과 없음 — talker SO_PRIORITY로 보완 |
| 8 | VLAN 태그 + PCP 사용 | UDP port 5000 기반 분류 추가 | `step6-ebpf/src/veth_filter.c:127` Case 3 | VM에서 VLAN 설정 복잡 → port 기반 우회 |
| 9 | k8s 1.x + Cilium 임의 버전 | k8s 1.28 + Cilium 1.15.6 박음 | `step3-kubernetes/01-prepare-node.sh:55`, `step4-cilium/01-install-cilium.sh:51` | 검증된 조합 |
| 10 | 다회 반복 측정 + CI | 단일 회 측정 | (스크립트 외) | README 가 "단일 실험의 한계" 명시. 결과 들쭉날쭉 |
| 11 | Linux 5.15 | 5.15 또는 6.6+ | `step6-ebpf/Makefile`, `stub-headers/` | stub-headers 로 호환 |
| 12 | `taprio` / ETS 게이트 제어 | 시도 후 실패 시 prio 폴백 (메인 자동화) | `deploy-experiment.sh:198-210` | taprio 미사용 — 시간 슬롯 효과 없음 |
| 13 | latency 절대값 측정 | clock skew 정규화 후 상대값 | `step8-measurement/plot-results.py:67`, `compare_results.py:26` | 절대값 해석 불가, 상대 비교만 유효 |
| 14 | `pkt_stats` 가 실제 카운트 | Cilium tcx 우회로 모두 0 | `step6-ebpf/src/common.h:88`, README §결과 해석 | SO_PRIORITY가 실험 핵심 동작 → pkt_stats=0 은 정상 (README 설명) |

---

## 20. 논문 외 추가 구현 모음

| # | 추가 기능 | 코드 위치 | 추가 이유 |
|---|---|---|---|
| 1 | `DEBUG_LEVEL` 매크로 시스템 (0~4) | `step6-ebpf/src/common.h:33` | VM에서 다양한 fail-mode 디버깅. 컴파일 타임 분기로 런타임 오버헤드 0. |
| 2 | `debug_stats` BPF map (16 entry) | `step6-ebpf/src/common.h:101` | "패킷이 어디서 분류 실패했는지" 진단. ETH_TOO_SHORT, NOT_IP, RINGBUF_FAIL 등. |
| 3 | UDP port 5000 분류 분기 (Case 3) | `step6-ebpf/src/veth_filter.c:87` | VM에서 VLAN 태그 설정 복잡 → UDP port 기반 대안 |
| 4 | RINGBUF egress_log / ingress_log | `step6-ebpf/src/egress.c:32`, `step6-ebpf/src/ingress.c:34` | 패킷 단위 trace 인프라 (현재 소비자 없음) |
| 5 | last_arrival HASH map (jitter 추정) | `step6-ebpf/src/ingress.c:40` | kernel-side ground truth — listener.py의 jitter와 교차 검증 가능 |
| 6 | xdp generic mode fallback | `attach-ebpf.sh:36`, `deploy-experiment.sh:127` | virtio NIC native XDP 미지원 |
| 7 | mqprio → prio 자동 폴백 | `deploy-experiment.sh:181-194` | VM TX queue 부족 |
| 8 | ETF CLOCK_TAI → CLOCK_REALTIME 폴백 | `deploy-experiment.sh:198-210` | TAI namespace 미설정 환경 |
| 9 | talker `--realtime` (SCHED_FIFO) 옵션 | `step7-experiment/talker/talker.py:33-42` | userspace jitter 최소화 시도 |
| 10 | talker drift logging | `step7-experiment/talker/talker.py:122-123` | 페이싱 정확도 자가 검증 |
| 11 | 1st percentile clock skew 정규화 | `step8-measurement/plot-results.py:66-69`, `compare_results.py:24-28` | PTP 미정확으로 음수 latency 발생 시 분석 단계 보정 |
| 12 | `verify-experiment.sh` 7단계 검증 | 루트 | 환경 셋업 복잡 → 빠른 sanity check |
| 13 | `debug-stats.sh --watch/--reset/--trace` | `step6-ebpf/debug-stats.sh` | bpftool 의 raw JSON 을 사람 친화 라벨 + 색상 |
| 14 | `test-master.yaml` 더미 pod | `step7-experiment/k8s/test-master.yaml` | master 노드 lxc<hash> 가 미리 만들어져야 attach 가능 |
| 15 | listener `--timeout` polling + retry | `step7-experiment/listener/listener.py:69`, `deploy-experiment.sh:335-342` | 마지막 패킷 후 CSV 작성 보장 |
| 16 | finalizer 강제 제거 (namespace stuck 우회) | `deploy-experiment.sh:240-244` | K8s namespace Terminating stuck 디버깅 |
| 17 | stub-headers 디렉토리 | `step6-ebpf/stub-headers/` | 커널 6.x 호환 + Windows VS Code IntelliSense |
| 18 | `compare_results.py` 의 개선율 자동 계산 표 | 루트 | README 의 정량 수치 출처 |
| 19 | listener-deployment.yaml 의 ConfigMap 방식 | `step7-experiment/k8s/listener-deployment.yaml` | Docker build 없이 코드 변경 가능 |
| 20 | Figure 2/4/6 의 3-패널 동적 선택 (low/high/extreme) | `step8-measurement/plot-results.py:86-103` | 99% baseline 측정 실패 시에도 그래프 그림 |
| 21 | bpftool map dump의 Python JSON 파싱 + 라벨 | `deploy-experiment.sh:362-388`, `verify-experiment.sh:99-113` | bpftool 출력을 의미 있게 표시 |
| 22 | XDP attach 실패 silent 무시 | `deploy-experiment.sh:127-131`, `attach-ebpf.sh:35` | VM에서 XDP 미지원이 흔함 → 실패해도 진행 |
| 23 | Q-in-Q (802.1AD outer + 802.1Q inner) AVTP 인식 | `step6-ebpf/src/xdp_vlan_avtp.c:117` | 본 코드의 추가 강건성. 논문은 단일 태그만 다룸 |

---

## 부록 A. BPF map 카운터 의미 한눈 표

### `pkt_stats` (ARRAY[4]) — 모든 BPF program 공유

| Index | 매크로 | 의미 | 정상 동작 시 기대값 |
|---|---|---|---|
| 0 | STATS_TOTAL | 프로그램이 본 모든 패킷 | > 0 (Cilium 우회면 0) |
| 1 | STATS_TSN | TSN으로 분류된 패킷 (AVTP / PCP=3 / UDP:5000) | talker 실험 시 10000 근접 |
| 2 | STATS_BEST_EFF | best-effort로 분류 | 기타 트래픽 |
| 3 | STATS_DROPPED | 드롭 (현재 사용 안 함) | 0 |

### `debug_stats` (ARRAY[16])

| Index | 매크로 | 의미 |
|---|---|---|
| 0 | DBGSTAT_ETH_TOO_SHORT | 이더넷 헤더 파싱 실패 |
| 1 | DBGSTAT_VLAN_PARSE_FAIL | VLAN 헤더 파싱 실패 |
| 2 | DBGSTAT_IP_TOO_SHORT | IP 헤더 파싱 실패 |
| 3 | DBGSTAT_UDP_TOO_SHORT | UDP 헤더 파싱 실패 |
| 4 | DBGSTAT_NOT_IP | non-IP 패킷 |
| 5 | DBGSTAT_NOT_UDP | non-UDP IP 패킷 |
| 6 | DBGSTAT_VLAN_TAGGED | VLAN 태그 발견 |
| 7 | DBGSTAT_AVTP_PKT | AVTP 발견 |
| 8 | DBGSTAT_TSN_BY_PORT | UDP port 기반 TSN 분류 |
| 9 | DBGSTAT_TSN_BY_PCP | VLAN PCP 기반 TSN 분류 |
| 10 | DBGSTAT_RINGBUF_FAIL | ring buffer reserve 실패 |
| 11 | DBGSTAT_MAP_UPDATE_FAIL | map update 실패 |
| 12 | DBGSTAT_UNKNOWN_PROTO | unknown EtherType |
| 13 | DBGSTAT_PROG_ENTER | 프로그램 진입 (sanity) |
| 14 | DBGSTAT_IHL_INVALID | IHL 비정상 |

### `xdp_stats` (ARRAY[8]) — XDP 전용

| Index | 매크로 | 의미 |
|---|---|---|
| 0 | XDPSTAT_TOTAL | 전체 |
| 1 | XDPSTAT_VLAN_TAGGED | VLAN |
| 2 | XDPSTAT_AVTP | AVTP |
| 3 | XDPSTAT_TSN_PASS | TSN으로 PASS |
| 4 | XDPSTAT_BEST_EFFORT | BE PASS |
| 5 | XDPSTAT_DROP | 드롭 |
| 6 | XDPSTAT_PARSE_ERROR | 파싱 실패 |

---

## 부록 B. 논문 Figure ↔ 본 repo 출력 파일

| 논문 Figure | 의미 | 본 repo 출력 | 생성 함수 |
|---|---|---|---|
| Figure 1 | 시스템 아키텍처 (vef/eg/ig/XDP/mqprio/ETF) | README §아키텍처 ASCII art | (수동 문서) |
| Figure 2 | Throughput (low/high CPU) | `step8-measurement/figures/fig2_throughput.png` | `figure2_throughput()` |
| Figure 3 | Latency p50/p99/max across CPU | `figures/fig3_latency.png` | `figure3_latency()` (`grouped_percentile_bars`) |
| Figure 4 | Jitter p50/p99 (low/high) | `figures/fig4_jitter.png` | `figure4_jitter_subset()` |
| Figure 5 | Jitter percentiles across CPU | `figures/fig5_jitter_comparison.png` | `figure5_jitter_all()` |
| Figure 6 | Latency CDF (low/high) | `figures/fig6_cdf.png` | `figure6_cdf()` |

---

## 부록 C. 실험 한 사이클 명령 흐름 (사용자 시점)

```
# (1) OS / k8s / cilium 준비 — 1회
bash step2-os-setup/02-install-packages.sh
sudo bash step2-os-setup/03-configure-isolcpus.sh; sudo reboot   # 선택
sudo bash step2-os-setup/04-configure-ptp.sh   # 선택
sudo bash step3-kubernetes/01-prepare-node.sh
sudo bash step3-kubernetes/02-init-control-plane.sh
(worker에서) sudo bash step3-kubernetes/03-join-worker.sh "kubeadm join ..."
bash step4-cilium/01-install-cilium.sh
bash step4-cilium/02-verify-cilium.sh

# (2) eBPF 빌드 (선택 — pre-built .o 가 git에 있음)
bash deploy-experiment.sh build-ebpf

# (3) K8s 배포
bash deploy-experiment.sh deploy-k8s

# (4) eBPF attach (양 노드 각각)
ssh master   "sudo bash deploy-experiment.sh setup-ebpf sender"
ssh worker01 "sudo bash deploy-experiment.sh setup-ebpf receiver"

# (5) 실험 (CPU 부하별로 반복)
for cpu in 10 30 50 70; do
    bash deploy-experiment.sh run baseline $cpu
    sudo bash deploy-experiment.sh run proposed $cpu
done

# (6) 분석
cd step8-measurement && python3 plot-results.py && cd ..
python3 compare_results.py

# (7) 검증 / 정리
bash verify-experiment.sh
sudo bash deploy-experiment.sh cleanup
```

---

## 21. 코드 감사 변경 요약 (2026-06)

본 리뷰 작성 후, 7개 항목을 코드 라인 기준으로 재점검하고 일부를 수정했습니다. 위 §1~§20 의 일부 서술(특히 §12 XDP, §6.2/§16.2 ETF, §3.3 isolcpus, §5.1/§9 tcx 우회)은 **수정 이전 코드 기준**임에 유의하세요. 아래가 최신 상태입니다.

| 항목 | 결론 | 조치 | 근거 (코드 라인) |
|---|---|---|---|
| 1. isolcpus 미사용 | 격리만 하고 아무도 안 씀 | **수정**: `talker-job.yaml`·`listener-deployment.yaml` 에 `--cpu=2` 추가 → 격리 코어에 바인딩 | `talker.py:70-71` 의 `set_cpu_affinity`, 매니페스트 args |
| 2. ETF 우선순위 역전 | **역전 아님** (전제 오해) | 변경 없음 | `priomap 2 2 1 0` → pri 3=band 0(최우선); ETF는 tc0(TSN)에 정상 |
| 3. XDP VLAN/AVTP 미사용 | dead code | **제거**: 소스·오브젝트·빌드·attach·검증 전부 삭제 | 트래픽 plain UDP → `xdp_vlan_avtp.c` 가 항상 `XDP_PASS` only |
| 4. tcx vs clsact 순서 | tcx(Cilium)가 clsact보다 먼저 실행 → 우리 BPF 스킵 | 문서 정정(README) — attach 순서는 유지(Cilium 간섭 위험) | `net/core/dev.c sch_handle_ingress` (tcx_run→tc_run) |
| 5. mqprio vs prio | **실제로는 prio 적용** | 변경 없음(보고) | `deploy-experiment.sh:162` `txq_count -ge 3` → VM은 1개라 스킵 → `prio`(L181) |
| 6. ETF 실사용 여부 | SO_TXTIME 없어 ETF가 TSN 패킷 전량 드롭 위험 | **제거**: main 경로 ETF attach 삭제 | `talker.py` 에 `SO_TXTIME` 없음; `sch_etf` `is_packet_valid()` → drop |
| 7. 통합 스크립트 미사용 이유 | VM에서 attach는 되나 결과가 깨짐 | 변경 없음(보고) — `prio` 유지 | ETF drop + software taprio 정밀도 + CLOCK_TAI base-time 불일치 + 게이트 비동기 |

### 수정된 파일 목록
- `step7-experiment/k8s/talker-job.yaml` — `--cpu=2` 추가 (항목 1)
- `step7-experiment/k8s/listener-deployment.yaml` — `--cpu=2` 추가 (항목 1)
- `step6-ebpf/src/xdp_vlan_avtp.c` — **삭제** (항목 3)
- `step6-ebpf/build/xdp_vlan_avtp.bpf.o` — **삭제** (항목 3)
- `step6-ebpf/Makefile` — PROGS/타겟에서 xdp 제거 (항목 3)
- `step6-ebpf/attach-ebpf.sh` — XDP attach 단계 제거 (항목 3)
- `deploy-experiment.sh` — XDP attach + ETF attach 블록 제거 (항목 3·6)
- `verify-experiment.sh` — XDP 검증 제거 (항목 3)
- `step5-tc-qdisc/02-setup-etf.sh` — ETF drop 경고 주석 추가 (항목 6)
- `README.md` — "코드 감사" 절 + tcx 순서 정정 + 다이어그램/트리에서 XDP 제거

> ⚠️ 이 변경들은 Windows 호스트에서 정적 분석 + 커널 동작 추론 기반으로 수행됨. Linux VM에서 `make -C step6-ebpf`(3개 프로그램 빌드 확인) 및 `bash verify-experiment.sh`(`--cpu=2` 바인딩·prio-only 동작) 로 런타임 검증 권장.

---

## 끝.

위 모든 섹션이 본 repo의 모든 파일을 다룹니다(2026-06 감사 반영). 누락된 파일이 있으면 알려주세요 — 같은 형식으로 추가하겠습니다.





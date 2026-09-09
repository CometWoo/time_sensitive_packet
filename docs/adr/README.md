# Architecture Decision Records (설계 결정 기록)

이 프로젝트에서 "왜 이렇게 했는가" 를 남긴 문서들이다. 각 ADR 은 **문제 → 고려한 대안(장단점) →
결정 → 결과/한계** 순서로 쓰고, 뒤집힌 결정은 지우지 않고 "대체됨" 으로 남긴다. 코드 주석이
`ADR-000N` 으로 이 문서를 가리킨다.

| 번호 | 제목 | 한 줄 요약 |
|---|---|---|
| [0001](0001-virtualbox-vms-instead-of-physical-tsn-nics.md) | 물리 TSN NIC 대신 VirtualBox VM + netns 테스트베드 | 예산 0 으로 구조를 재현하고, 커널 메커니즘은 netns/CI 에서 검증 |
| [0002](0002-prio-instead-of-mqprio-etf-taprio.md) | mqprio/ETF/taprio 대신 소프트웨어 strict-priority qdisc | 1 TX 큐 virtio, SO_TXTIME 없는 talker, TAI/REALTIME 불일치 등 실패 기록 |
| [0003](0003-classify-at-host-nic-egress.md) | **TS 분류·마킹은 호스트 물리 NIC egress 에서** | `____dev_forward_skb()` 가 veth 통과 시 priority 를 0 으로 — Pod 안 설정은 무효 (실측 27,110/27,110) |
| [0004](0004-non-ts-priority-untouched.md) | 비-TS 패킷의 priority 는 건드리지 않는다 | 관찰자 원칙, 대조군 오염 방지 |
| [0005](0005-tcx-before-cilium.md) | Cilium(tcx) 앞에 BPF_F_BEFORE + TC_ACT_UNSPEC | tcx 프로그램이 OK 를 반환하면 legacy clsact 는 실행되지 않음 |
| [0006](0006-testbed-needs-contention.md) | 병목 링크 + 경쟁 트래픽이 있어야 우선순위 실험이다 | tbf/HTB 아래 조건 qdisc, 30 Mbit/s BE 홍수 |
| [0007](0007-dscp-marking-for-fabric-qos.md) | 호스트 밖 QoS 는 DSCP 로 | skb->priority 는 호스트 안에서 죽는다; EF 마킹 + 증분 체크섬 |
| [0008](0008-talker-resolve-once.md) | talker 는 이름을 한 번만 해석, CPU quota 없이 | 패킷마다 DNS 왕복이 latency 에 섞였던 5월 데이터 |
| [0009](0009-no-prebuilt-bpf-binaries.md) | BPF 바이너리 미커밋, CI 가 빌드·검증 | 소스와 어긋난 바이너리가 결과를 오염시켰던 이력 |
| [0010](0010-qdisc-conditions.md) | 비교 조건은 5개 | fifo / fq_codel / pfifo_fast(±분류기) / prio+분류기 로 인과 분리 |
| [0011](0011-priority-6-default-priomap.md) | priority 6 + 기본 priomap | 권한 경계(≤6), band 0, 커스텀 맵 취약성 |
| [0012](0012-clock-skew-and-same-host-testbed.md) | 두 VM 은 p1 정규화 상대 비교, 절대값은 같은 시계에서만 | 99 % 음수 latency, 22 ms 시계 스텝 |
| [0013](0013-configmap-scripts-via-kustomize.md) | ConfigMap 을 kustomize 가 .py 에서 생성 | 이미지 없는 VM, 인라인 사본 드리프트 |
| [0014](0014-udp-port-classification-and-trust-boundary.md) | UDP 포트 분류 기준과 신뢰 경계 | Pod 는 VLAN/AVTP 를 만들 수 없다; dport 는 테넌트가 정한다 |
| [0015](0015-statistics.md) | 선형 백분위 + 부트스트랩 CI + Mann-Whitney + Cliff's δ | 단일 run 점추정으로는 잡음과 신호를 못 가른다 |
| [0016](0016-results-provenance.md) | 5월 K8s 결과는 "메커니즘 미작동 데이터" 로 재분류·보존 | 틀린 숫자를 찾아낸 과정이 포트폴리오의 핵심 |

읽는 순서 추천: 0003 → 0005 → 0006 → 0010 → 0016 (핵심 서사), 나머지는 참고.

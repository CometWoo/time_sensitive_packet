#!/bin/bash
# =============================================================================
# deploy-experiment.sh — K8s(2-VM kubeadm + Cilium) 실험 러너
#
# "A Time-Sensitive Cloud-Native Network Based on eBPF" (Wen et al., CSCWD 2024) 재현.
# 이 스크립트는 talker Pod 가 뜨는 **control-plane(sender) 노드에서 sudo 로** 실행한다.
# qdisc 와 eBPF 분류기가 붙는 곳이 이 노드의 물리 NIC(PHYS_IF) egress 이기 때문이다.
#
# 설정: ./experiment.env (experiment.env.example 참고). 환경변수가 파일보다 우선한다.
#
# 명령:
#   build-ebpf                          step6-ebpf 빌드 (ts_classifier.bpf.o + tcx_attach)
#   deploy-k8s                          namespace + ConfigMap + listener + udp-sink 배포 후 Ready 대기
#   run <condition> [cpu%] [run-index]  실험 1회 → RESULTS_DIR/<condition>_cpu<N>_run<k>.csv + .meta.json
#   matrix <runs> [cpu%] [conditions..] run 을 조건 × 반복 으로 순회
#   status                              노드/NIC/qdisc/분류기/Pod 상태
#   attach-classifier | detach-classifier | show-counters   분류기 단독 조작
#   cleanup                             namespace, qdisc, clsact, 분류기(pin) 전부 제거
#
# 조건(condition) — testbed/run_testbed.sh 와 같은 이름을 써서 analysis/ 가 함께 묶는다:
#   fifo               HTB leaf = pfifo limit 1000        분류기 없음   "멍청한 단일 FIFO"
#   fq_codel           HTB leaf = fq_codel                분류기 없음   리눅스 기본, 흐름 격리   (alias: baseline)
#   pfifo_fast_noclsf  HTB leaf = pfifo_fast              분류기 없음   구 K8s 설계의 실제 상태
#   pfifo_fast_clsf    HTB leaf = pfifo_fast + ts_classifier
#   prio_clsf          HTB leaf = prio bands 3 + ts_classifier                              (alias: proposed)
#
# ── 왜 경쟁 트래픽과 셰이핑이 필요한가 ───────────────────────────────────────────
#   우선순위 qdisc 는 **큐에 backlog 가 있을 때만** 뭔가를 한다. 1 ms 간격 UDP 흐름 하나만
#   흘리면 어떤 qdisc 든 큐가 비어 있어 prio 와 fq_codel 이 같아 보인다. 그래서
#   (1) sender 노드에서 best-effort UDP 홍수(be-flood Job, FLOOD_MBPS) 를 같은 수신 노드로 보내고
#   (2) 그 두 흐름만 HTB class 1:10 (SHAPE_MBPS) 에 가두어 backlog 를 만든다.
#   제어 평면(API server, SSH, Cilium) 트래픽은 default class 1:1 (10gbit) 로 가서 영향이 없다.
#
# ── 패킷 경로와 우선순위가 작용하는 지점 (sender 노드, Cilium native routing) ─────────
#   talker Pod: sendto(), SO_PRIORITY=6 → skb->priority=6 (Pod netns 안에서만 유효)
#     │ veth 통과: ____dev_forward_skb() 가 skb->priority = 0 으로 리셋
#     │           (include/linux/netdevice.h v5.15 L4140 / v6.8 L4110, drivers/net/veth.c veth_forward_skb)
#     │           → Pod 안에서 무엇을 하든(SO_PRIORITY, Pod eth0 의 BPF) 호스트 qdisc 는 priority 0 만 본다
#     ▼
#   lxc* (호스트측 veth) ingress: Cilium cil_from_container → bpf_redirect(PHYS_IF)
#     │  __bpf_redirect() → __bpf_tx_skb() → dev_queue_xmit()   (net/core/filter.c)
#     ▼
#   __dev_queue_xmit(PHYS_IF)                                     (net/core/dev.c)
#     ├─ sch_handle_egress()
#     │    kernel >= 6.6: tcx_run() → [0] ts_classifier (BPF_F_BEFORE, tools/tcx_attach)
#     │                                    UDP dst TS_PORT → skb->priority = 6, DSCP = EF(46) → TC_ACT_UNSPEC(TCX_NEXT)
#     │                               → [1] cil_to_netdev (Cilium) → TC_ACT_OK
#     │      (분류기가 Cilium 뒤에 있거나 legacy clsact 라면 Cilium 의 TC_ACT_OK 에서 체인이 끝나 실행되지 않는다)
#     │    kernel <  6.6: legacy clsact tc_run() — 'tc filter ... bpf da pinned'
#     └─ __dev_xmit_skb() → q->enqueue = htb_enqueue()            (net/sched/sch_htb.c)
#          htb_classify(): skb->priority(6) 는 classid 가 아니므로 tcf_classify() 로 넘어가
#                          u32 'match ip dst <listener|udp-sink Pod IP>/32' → class 1:10 (rate/ceil SHAPE_MBPS)
#            └─ leaf qdisc 200: 의 enqueue
#                 prio_classify() / pfifo_fast: band = priomap[skb->priority & 15]  → 6 → band 0   ★ 우선순위가 작용하는 유일한 곳
#                 fq_codel: 5-tuple 흐름 해시 (priority 무시)      pfifo: 단일 FIFO (priority 무시)
#          (그 외 모든 트래픽) → default class 1:1 (rate 10gbit, leaf fq_codel) → 사실상 셰이핑 없음
#
#   즉 분류기는 HTB enqueue **직전**에 priority 를 세팅하고, HTB 는 u32(목적지 IP) 로 class 를 고르며,
#   class 1:10 안의 prio/pfifo_fast leaf 가 priority → band 로 TS 패킷을 먼저 dequeue 한다.
#   Cilium 의 bpf_redirect 도 결국 PHYS_IF 의 __dev_queue_xmit 를 지나므로 이 설계는 Cilium 과 무관하게 성립한다.
#
# ── 실행 순서 (run) ─────────────────────────────────────────────────────────────
#   listener Pod 재시작(빈 /data) → listener/udp-sink Pod IP 확보 → HTB + 조건 leaf + u32 (+분류기) 적용
#   → [cpu%>0] stress DaemonSet → be-flood Job 시작 → 2 s (큐가 찰 시간) → talker Job → 완료 대기
#   → listener CSV 수집(kubectl cp) → meta.json (커널, 조건, tc -s, 카운터, 타임스탬프) → flood/stress 제거
#   qdisc/분류기는 다음 run 이나 cleanup 까지 남겨 둔다.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EBPF_DIR="$SCRIPT_DIR/step6-ebpf"
BPF_BUILD="$EBPF_DIR/build"
K8S_DIR="$SCRIPT_DIR/step7-experiment/k8s"
BPFMAPS="$SCRIPT_DIR/testbed/bpfmaps.py"
TCX_ATTACH="$BPF_BUILD/tcx_attach"
CLSF_OBJ="$BPF_BUILD/ts_classifier.bpf.o"

# bpffs pin 배치 (cleanup 이 통째로 지운다)
PIN=/sys/fs/bpf/tsn
PIN_PROG=$PIN/clsf            # legacy: bpftool prog load ... 로 pin 한 프로그램
PIN_LINK=$PIN/clsf_link       # tcx:    tcx_attach 가 pin 한 bpf_link
PIN_MAPS=$PIN/clsf_maps       # 두 모드 모두: ts_config / ts_udp_ports / ts_counters

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date -u +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date -u +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date -u +%H:%M:%S) $*" >&2; }
die()       { log_error "$*"; exit 1; }

# =============================================================================
# 설정 로드 — ./experiment.env (KEY=VALUE, '#' 주석). 이미 환경에 있는 변수는 덮어쓰지 않는다.
# =============================================================================
ENV_FILE="${EXPERIMENT_ENV:-$SCRIPT_DIR/experiment.env}"
load_env_file() {
    local line key val
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        key="${line%%=*}"; val="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { log_warn "experiment.env: 무시 '$line'"; continue; }
        val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
        [ -n "${!key+x}" ] && continue          # 환경변수 우선
        [ -n "$val" ] || continue               # 빈 값(PHYS_IF= / KUBECONFIG=) 은 "기본값/자동 감지" — export 하지 않는다
        printf -v "$key" '%s' "$val"
        export "${key?}"
    done < "$ENV_FILE"
}
load_env_file

PHYS_IF="${PHYS_IF:-}"
NAMESPACE="${NAMESPACE:-tsn-experiment}"
TS_PORT="${TS_PORT:-6000}"
BE_PORT="${BE_PORT:-5001}"
TS_COUNT="${TS_COUNT:-10000}"
TS_INTERVAL_MS="${TS_INTERVAL_MS:-1}"
TS_SIZE="${TS_SIZE:-128}"
FLOOD_MBPS="${FLOOD_MBPS:-30}"
FLOOD_SIZE="${FLOOD_SIZE:-1400}"
SHAPE_MBPS="${SHAPE_MBPS:-20}"
MARK_DSCP="${MARK_DSCP:-1}"
TS_PRIORITY="${TS_PRIORITY:-6}"
TS_DSCP="${TS_DSCP:-46}"
STRESS_NODES="${STRESS_NODES:-receiver}"
STRESS_WORKERS="${STRESS_WORKERS:-2}"
LISTENER_CPU="${LISTENER_CPU:--1}"
TALKER_CPU="${TALKER_CPU:--1}"
TALKER_CPU_REQUEST="${TALKER_CPU_REQUEST:-1}"     # talker requests==limits (Guaranteed). 2 vCPU sender 에서 Pending 이면 500m
FLOOD_CPU_REQUEST="${FLOOD_CPU_REQUEST:-500m}"    # be-flood requests.cpu (limit 없음)
RESULTS_DIR="${RESULTS_DIR:-results/k8s}"
IMAGE_PY="${IMAGE_PY:-python:3.11-slim}"
IMAGE_STRESS="${IMAGE_STRESS:-alexeiled/stress-ng:latest}"
FORCE_NS_FINALIZE="${FORCE_NS_FINALIZE:-0}"
ALLOW_LEGACY_ON_TCX="${ALLOW_LEGACY_ON_TCX:-0}"   # kernel>=6.6 인데 tcx_attach 가 없을 때 legacy 강행
ALLOW_TUNNEL="${ALLOW_TUNNEL:-0}"                 # Cilium tunnel 모드에서 노드 IP 로 셰이핑 강행
case "$RESULTS_DIR" in /*) ;; *) RESULTS_DIR="$SCRIPT_DIR/$RESULTS_DIR" ;; esac

# =============================================================================
# 공통 유틸
# =============================================================================
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_num()  { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

kc() { kubectl -n "$NAMESPACE" "$@"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "root 필요 (tc/bpftool): sudo bash $0 $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 없음 — $2"; }

check_deps() {
    need_cmd kubectl "kubectl 설치/PATH 확인"
    need_cmd tc "iproute2"
    need_cmd ip "iproute2"
    need_cmd python3 "python3"
    need_cmd bpftool "linux-tools-\$(uname -r) 또는 ci/install-bpftool.sh"
    need_cmd git "git"
}

# 클러스터 접근 가능한지 (kubeconfig/권한 문제를 tc 를 만지기 전에 잡는다)
check_cluster() {
    local nodes
    nodes=$(kubectl get nodes -o name 2>&1) || die "kubectl 로 클러스터에 접근 불가 (KUBECONFIG=${KUBECONFIG:-~/.kube/config}): $nodes"
    [ "$(wc -l <<<"$nodes")" -ge 2 ] || log_warn "노드가 2개 미만 — talker(control-plane) 와 listener(worker) 가 다른 노드에 떠야 NIC egress 를 지난다"
}

PHYS_IF_SOURCE="env"    # env: experiment.env/환경변수로 지정됨, auto: default route 에서 감지, route: 목적지 경로로 교체됨
detect_phys_if() {
    if [ -z "$PHYS_IF" ]; then
        PHYS_IF=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
        PHYS_IF_SOURCE=auto
        [ -n "$PHYS_IF" ] || die "default route 인터페이스를 찾지 못함 — experiment.env 의 PHYS_IF 를 지정"
    fi
    [ -d "/sys/class/net/$PHYS_IF" ] || die "인터페이스 없음: $PHYS_IF"
}

# default route 장치 == 실험 트래픽이 나가는 장치인지 확인. VirtualBox NAT(default route) + host-only(클러스터)
# 처럼 두 NIC 가 있으면 default route 는 NAT 쪽이라 qdisc/분류기가 엉뚱한 NIC 에 붙고, 분류기 없는 조건은
# 아무 경고 없이 "그럴듯한" CSV 를 남긴다. 그래서 목적지(listener Pod IP / 수신 노드 IP) 로 'ip route get'.
ROUTE_DEV=""
check_phys_if_route() {   # <destination-ip>
    ROUTE_DEV=$(ip -o route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    if [ -z "$ROUTE_DEV" ]; then
        log_warn "ip route get $1 실패 — PHYS_IF=$PHYS_IF 가 실제 송신 NIC 인지 확인할 수 없다"; return 0
    fi
    if [ "$ROUTE_DEV" = "$PHYS_IF" ]; then
        log_info "경로 확인: $1 → dev $PHYS_IF (qdisc/분류기가 붙는 NIC 와 일치)"; return 0
    fi
    case "$ROUTE_DEV" in
        cilium_*|lxc*|veth*|docker*|br-*|cni*)
            log_warn "$1 의 경로가 가상 장치 $ROUTE_DEV 로 잡힘 (Cilium 내부 라우팅) — PHYS_IF=$PHYS_IF 를 유지. run 뒤 HTB 1:10 카운터로 확인"
            return 0 ;;
    esac
    if [ "$PHYS_IF_SOURCE" = auto ]; then
        [ -d "/sys/class/net/$ROUTE_DEV" ] || die "경로 장치 $ROUTE_DEV 가 /sys/class/net 에 없음"
        log_warn "default route 장치($PHYS_IF) ≠ $1 로 나가는 장치($ROUTE_DEV) (NAT + host-only 2-NIC?) → PHYS_IF=$ROUTE_DEV 로 교체"
        PHYS_IF=$ROUTE_DEV; PHYS_IF_SOURCE=route
    else
        die "PHYS_IF=$PHYS_IF 인데 $1 은 dev $ROUTE_DEV 로 나간다 — experiment.env 의 PHYS_IF 를 $ROUTE_DEV 로 바꾸거나 비워서 자동 감지"
    fi
}

# sudo 로 실행하면 HOME=/root 라 kubeconfig 가 없다 → SUDO_USER 의 것을 찾는다.
# 실패해도 exit 하지 않고 1 을 돌려준다 (cleanup/status 는 kubeconfig 없이도 tc/BPF 정리를 해야 한다);
# 치명적인 호출자(run/deploy-k8s)는 '|| exit 1' 로 멈춘다.
resolve_kubeconfig() {
    [ -n "${KUBECONFIG:-}" ] && { export KUBECONFIG; return 0; }
    [ "$(id -u)" -eq 0 ] || return 0                 # 일반 사용자: ~/.kube/config 기본
    local cand home_su=""
    if [ -n "${SUDO_USER:-}" ]; then
        home_su=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    fi
    for cand in /root/.kube/config "${home_su:+$home_su/.kube/config}" /etc/kubernetes/admin.conf; do
        [ -n "$cand" ] && [ -r "$cand" ] && { export KUBECONFIG="$cand"; return 0; }
    done
    log_error "kubeconfig 를 찾지 못함 — experiment.env 의 KUBECONFIG 를 지정 (예: /etc/kubernetes/admin.conf)"
    return 1
}

kernel_ge() {   # kernel_ge 6.6
    local have; have=$(uname -r | cut -d. -f1-2)
    [ "$(printf '%s\n' "$1" "$have" | sort -V | head -1)" = "$1" ]
}

# 분류기 attach 방식: kernel >= 6.6 이면 tcx(Cilium 앞), 아니면 legacy clsact.
# 분류기를 붙이는 명령(run *_clsf / attach-classifier)만 부른다 — detach 와 분류기 없는 조건은 필요 없다.
# 실패 시 exit 하지 않고 1 을 돌려준다 (호출자가 '|| exit 1').
ATTACH_MODE=legacy
decide_attach_mode() {
    if kernel_ge 6.6; then
        if [ -x "$TCX_ATTACH" ]; then
            ATTACH_MODE=tcx
        elif [ "$ALLOW_LEGACY_ON_TCX" = 1 ]; then
            ATTACH_MODE=legacy
            log_warn "kernel >= 6.6 인데 tcx_attach 없음 → legacy clsact 강행. Cilium(tcx) 이 TC_ACT_OK 를 반환하면 분류기는 실행되지 않는다"
        else
            log_error "kernel >= 6.6: 분류기는 tcx 로 Cilium 앞에 붙어야 한다. 'bash $0 build-ebpf' (make tools, libbpf >= 1.3) 후 재시도. (강행: ALLOW_LEGACY_ON_TCX=1)"
            return 1
        fi
    fi
}

normalize_condition() {
    case "$1" in
        baseline) echo fq_codel ;;
        proposed) echo prio_clsf ;;
        fifo|fq_codel|pfifo_fast_noclsf|pfifo_fast_clsf|prio_clsf) echo "$1" ;;
        *) return 1 ;;
    esac
}

# 템플릿의 __KEY__ 를 치환. 남은 플레이스홀더가 있으면 실패 (sed 가 조용히 빗나가는 일 방지).
render() {   # render <template> KEY=value ...
    local tpl=$1; shift
    local -a args=()
    local kv out left
    for kv in "$@"; do args+=(-e "s|__${kv%%=*}__|${kv#*=}|g"); done
    out=$(sed "${args[@]}" "$tpl")
    # 주석 줄(템플릿 헤더가 __KEY__ 를 설명한다)은 제외하고 남은 플레이스홀더를 찾는다
    left=$(grep -v '^[[:space:]]*#' <<<"$out" | grep -o '__[A-Z_]\{2,\}__' | sort -u | tr '\n' ' ' || true)
    [ -z "$left" ] || die "$(basename "$tpl"): 치환되지 않은 플레이스홀더: $left"
    printf '%s\n' "$out"
}

wait_pod_exists() {   # <label-selector> [timeout_s]   — kubectl wait 는 대상이 없으면 즉시 실패하므로 먼저 존재를 기다린다
    local sel=$1 t=${2:-60} i=0
    until [ -n "$(kc get pod -l "$sel" -o name 2>/dev/null)" ]; do
        i=$((i + 1)); [ "$i" -lt "$t" ] || return 1
        sleep 1
    done
}
wait_pod_ready() {    # <label-selector> [timeout_s]  — Deployment Pod 용 (listener / udp-sink)
    wait_pod_exists "$1" 60 || { log_error "Pod 생성 안 됨: -l $1"; return 1; }
    kc wait --for=condition=ready pod -l "$1" --timeout="${2:-180}s"
}
# Job Pod 용: 끝난(Succeeded/Failed) Pod 는 Ready=False 라 'kubectl wait --for=condition=ready' 가 타임아웃까지
# 막힌다 (짧은 TS_COUNT 면 존재 확인과 wait 사이에 이미 끝나 있을 수 있다). phase 가 Pending 을 벗어나면 통과.
wait_job_pod_started() {   # <label-selector> [timeout_s]
    local sel=$1 t=${2:-120} i=0 ph=""
    wait_pod_exists "$sel" 60 || { log_error "Pod 생성 안 됨: -l $sel"; return 1; }
    while :; do
        ph=$(kc get pod -l "$sel" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
        case "$ph" in Running|Succeeded|Failed) return 0 ;; esac
        i=$((i + 1)); [ "$i" -lt "$t" ] || { log_error "Pod 가 ${t}s 안에 시작하지 않음 (phase='${ph:-?}'): -l $sel"; return 1; }
        sleep 1
    done
}
wait_job() {          # <job> <timeout_s>  → 0 complete / 1 failed / 2 timeout
    local job=$1 t=$2 i=0 s f
    while :; do
        s=$(kc get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
        f=$(kc get job "$job" -o jsonpath='{.status.failed}' 2>/dev/null || true)
        [ "${s:-0}" -ge 1 ] 2>/dev/null && return 0
        [ "${f:-0}" -ge 1 ] 2>/dev/null && return 1
        i=$((i + 2)); [ "$i" -lt "$t" ] || return 2
        sleep 2
    done
}
pod_of() { kc get pod -l "$1" --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
job_pod_of() { kc get pod -l "$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }   # 끝난 Job Pod 도 찾는다 (로그/이미지 수집)
pod_ip_of() { kc get pod "$1" -o jsonpath='{.status.podIP}'; }
pod_node_of() { kc get pod "$1" -o jsonpath='{.spec.nodeName}'; }

cilium_routing_mode() {
    kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.routing-mode}' 2>/dev/null || true
}
cilium_image() {
    kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

# =============================================================================
# 분류기 (ts_classifier) attach / detach / 설정 / 카운터
# =============================================================================
classifier_attached() {
    if [ "$ATTACH_MODE" = tcx ]; then
        [ -e "$PIN_LINK" ] && "$TCX_ATTACH" query "$PHYS_IF" egress 2>/dev/null | grep -q ts_classifier
    else
        tc filter show dev "$PHYS_IF" egress 2>/dev/null | grep -q ts_classifier
    fi
}

# tcx_attach 는 오브젝트를 직접 로드하므로 map 이 pin 되지 않는다 → link → prog → map id 로 찾아 pin.
# 실패하면 카운터는 'bpftool map dump name ts_counters' (이름 조회) 로 읽는다.
pin_link_maps() {
    mkdir -p "$PIN_MAPS"
    python3 - "$PIN_LINK" "$PIN_MAPS" <<'PY'
import json, os, subprocess, sys
link, pin_dir = sys.argv[1], sys.argv[2]
def bj(*args):
    return json.loads(subprocess.check_output(["bpftool", "-j", *args], text=True))
info = bj("link", "show", "pinned", link)
if isinstance(info, list):
    info = info[0]
prog = bj("prog", "show", "id", str(info["prog_id"]))
if isinstance(prog, list):
    prog = prog[0]
for mid in prog.get("map_ids", []):
    m = bj("map", "show", "id", str(mid))
    if isinstance(m, list):
        m = m[0]
    name = m.get("name", "")
    if not name or name.startswith("."):
        continue
    dst = os.path.join(pin_dir, name)
    if os.path.lexists(dst):
        os.unlink(dst)
    subprocess.check_call(["bpftool", "map", "pin", "id", str(mid), dst])
    print(f"  pinned map {name} (id {mid}) -> {dst}")
PY
}

CLSF_CFG_APPLIED=0   # meta.json 에 기록: ts_config 를 실제로 썼는가 (0 이면 컴파일 타임 기본값으로 동작)
configure_classifier() {
    [ -f "$PIN_MAPS/ts_config" ] || { log_warn "ts_config pin 없음 — 분류기는 컴파일 타임 기본값(priority 6, DSCP 미마킹, 포트 6000)으로 동작"; return 0; }
    python3 "$BPFMAPS" set-ts-config "$PIN_MAPS/ts_config" "$TS_PRIORITY" "$TS_DSCP" "$MARK_DSCP"
    CLSF_CFG_APPLIED=1
    log_info "ts_config: priority=$TS_PRIORITY dscp=$TS_DSCP flags=$MARK_DSCP (bit0 = DSCP 마킹)"
    if [ "$TS_PORT" != 6000 ] && [ -f "$PIN_MAPS/ts_udp_ports" ]; then
        # ts_udp_ports: key = u16 호스트 바이트 오더(little-endian) → value u8 1
        bpftool map update pinned "$PIN_MAPS/ts_udp_ports" \
            key hex "$(printf '%02x' $((TS_PORT & 0xff)))" "$(printf '%02x' $((TS_PORT >> 8)))" value hex 01
        log_info "ts_udp_ports += $TS_PORT"
    fi
}

assert_classifier_first() {   # tcx 체인 [0] 이 ts_classifier 인지 (Cilium 재시작 뒤 순서가 바뀌었을 수 있다)
    local first
    first=$("$TCX_ATTACH" query "$PHYS_IF" egress 2>/dev/null | sed -n '2p')
    if ! grep -q ts_classifier <<<"$first"; then
        log_error "tcx egress 체인 맨 앞이 ts_classifier 가 아님:"
        "$TCX_ATTACH" query "$PHYS_IF" egress || true
        die "detach-classifier 후 attach-classifier 로 다시 붙이세요 (Cilium 이 TC_ACT_OK 를 먼저 반환하면 분류기가 실행되지 않는다)"
    fi
}

attach_classifier() {
    [ -f "$CLSF_OBJ" ] || die "$CLSF_OBJ 없음 — bash $0 build-ebpf"
    mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
    if classifier_attached; then
        log_info "분류기 이미 attach 됨 ($ATTACH_MODE, $PHYS_IF egress)"
        [ "$ATTACH_MODE" = tcx ] && assert_classifier_first
        configure_classifier
        return 0
    fi
    rm -rf "$PIN"; mkdir -p "$PIN"
    if [ "$ATTACH_MODE" = tcx ]; then
        # BPF_F_BEFORE: 체인 맨 앞. ts_classifier 는 TC_ACT_UNSPEC 을 반환해 Cilium 이 이어서 실행된다.
        "$TCX_ATTACH" attach "$PHYS_IF" "$CLSF_OBJ" "$PIN_LINK" egress before
        pin_link_maps || log_warn "map pin 실패 — 카운터는 'bpftool map dump name ts_counters' 로 읽으세요"
        assert_classifier_first
    else
        bpftool prog load "$CLSF_OBJ" "$PIN_PROG" pinmaps "$PIN_MAPS"
        tc qdisc show dev "$PHYS_IF" | grep -q '^qdisc clsact' || tc qdisc add dev "$PHYS_IF" clsact
        tc filter add dev "$PHYS_IF" egress pref 10 bpf da pinned "$PIN_PROG"
        if tc filter show dev "$PHYS_IF" egress | grep -q 'cil_'; then
            log_warn "Cilium legacy 필터가 같은 hook 에 있음 — Cilium 이 TC_ACT_OK 를 반환하면 pref 10 분류기는 실행되지 않는다. 카운터로 확인하세요"
        fi
    fi
    configure_classifier
    log_info "분류기 attach 완료 ($ATTACH_MODE, $PHYS_IF egress)"
}

detach_classifier() {
    if [ -e "$PIN_LINK" ] && [ -x "$TCX_ATTACH" ]; then
        "$TCX_ATTACH" detach "$PIN_LINK" || rm -f "$PIN_LINK"
    fi
    if tc filter show dev "$PHYS_IF" egress 2>/dev/null | grep -q ts_classifier; then
        tc filter del dev "$PHYS_IF" egress pref 10 2>/dev/null || true
    fi
    rm -rf "$PIN"
}

# 카운터 JSON 한 줄 (이름 붙은 카운터, per-CPU 합산).
#   1순위: pinned map ($PIN_MAPS/ts_counters, testbed/bpfmaps.py 와 같은 경로)
#   2순위: 이름 조회 'bpftool map dump name ts_counters' — pin 이 실패한 tcx 모드용. 같은 이름의 map 이
#          여럿이면(예: 테스트가 남긴 것) bpftool 은 첫 번째만 덤프하므로 개수를 stderr 에 경고한다.
#   둘 다 없으면 {} (분류기 미부착).
read_counters() {
    if [ -f "$PIN_MAPS/ts_counters" ]; then
        python3 "$BPFMAPS" counters "$PIN_MAPS/ts_counters" 2>/dev/null || echo '{}'
        return 0
    fi
    python3 - <<'PY' 2>/dev/null || echo '{}'
import json, subprocess, sys
NAMES = ["normal", "ts_avtp", "ts_pcp", "ts_udp", "dscp_marked", "parse_short"]
def bj(*a):
    return json.loads(subprocess.check_output(["bpftool", "-j", *a], text=True, stderr=subprocess.DEVNULL))
def to_int(v):
    if isinstance(v, int): return v
    if isinstance(v, list): return int.from_bytes(bytes(int(b, 16) for b in v), "little")
    return int(v)
maps = [m for m in bj("map", "show") if m.get("name") == "ts_counters"]
if not maps:
    print("{}"); sys.exit(0)
if len(maps) > 1:
    print(f"[WARN] ts_counters 이름의 map 이 {len(maps)}개 (id {[m['id'] for m in maps]}) — 가장 최근 id 를 읽음", file=sys.stderr)
raw = {}
for e in bj("map", "dump", "id", str(maps[-1]["id"])):
    src = e.get("formatted") or e
    vals = src.get("values") or [{"value": src.get("value", 0)}]
    raw[to_int(src["key"])] = sum(to_int(v["value"]) for v in vals)
print(json.dumps({n: raw.get(i, 0) for i, n in enumerate(NAMES)}))
PY
}

# 'tc -s class show' 의 class 별 Sent bytes/pkt 를 JSON 으로 (prio 200:1..3 = band 0..2, htb 1:1 / 1:10)
read_class_stats() {
    tc -s class show dev "$PHYS_IF" 2>/dev/null | python3 -c '
import json, re, sys
out, cur = {}, None
for line in sys.stdin:
    m = re.match(r"^class (\S+) (\S+)", line)
    if m:
        cur = f"{m.group(1)} {m.group(2)}"; continue
    m = re.match(r"^\s*Sent (\d+) bytes (\d+) pkt", line)
    if m and cur:
        out[cur] = {"bytes": int(m.group(1)), "pkts": int(m.group(2))}
print(json.dumps(out))' 2>/dev/null || echo '{}'
}

# =============================================================================
# qdisc 조건 적용 (헤더의 체인 설명 참고)
# =============================================================================
leaf_for() {
    case "$1" in
        fifo)                              echo "pfifo limit 1000" ;;
        fq_codel)                          echo "fq_codel" ;;
        pfifo_fast_noclsf|pfifo_fast_clsf) echo "pfifo_fast" ;;
        prio_clsf)                         echo "prio bands 3" ;;
        *) return 1 ;;
    esac
}

# root qdisc 제거. 배포판 기본 qdisc(fq_codel/pfifo_fast/mq) 는 handle 0: 이라 'tc qdisc del root' 가
# "Cannot delete qdisc with handle of zero" 로 실패한다 — 그 경우는 지울 것이 없으므로 건너뛴다.
# (우리가 붙인 htb 1: / 200: 등 handle 이 0 이 아닌 root 만 지운다. 실패는 숨기지 않는다.)
reset_root_qdisc() {
    local h
    h=$(tc qdisc show dev "$PHYS_IF" | awk '$1=="qdisc" && $4=="root" {print $3; exit}')
    case "$h" in
        ""|0:) ;;
        *) tc qdisc del dev "$PHYS_IF" root ;;
    esac
    if tc qdisc show dev "$PHYS_IF" | awk '$1=="qdisc" && $4=="root"' | grep -Eq '^qdisc (htb|prio|pfifo|tbf) '; then
        tc qdisc show dev "$PHYS_IF"; die "root qdisc 제거 실패: $PHYS_IF"
    fi
}

apply_condition() {   # apply_condition <condition> <shape-target-ip>...
    local cond=$1; shift
    local leaf ip
    leaf=$(leaf_for "$cond") || die "알 수 없는 조건: $cond"
    [ "$#" -ge 1 ] || die "apply_condition: 셰이핑 대상 IP 가 없다"
    reset_root_qdisc
    if [ "$SHAPE_MBPS" -gt 0 ]; then
        # root HTB: default 1 → 나머지 전부 class 1:1 (10gbit, 사실상 무제한)
        tc qdisc add dev "$PHYS_IF" root handle 1: htb default 1
        tc class add dev "$PHYS_IF" parent 1: classid 1:1 htb rate 10gbit ceil 10gbit quantum 60000
        tc qdisc add dev "$PHYS_IF" parent 1:1 handle 100: fq_codel
        # 실험 트래픽 class 1:10: rate = ceil = SHAPE_MBPS → 여기서 backlog 가 생긴다
        tc class add dev "$PHYS_IF" parent 1: classid 1:10 htb rate "${SHAPE_MBPS}mbit" ceil "${SHAPE_MBPS}mbit" quantum 15140
        # shellcheck disable=SC2086  # leaf 는 의도적으로 단어 분리 ("prio bands 3")
        tc qdisc add dev "$PHYS_IF" parent 1:10 handle 200: $leaf
        # u32: 목적지 IP(listener / udp-sink Pod) 로 class 1:10 선택 — HTB 분류는 skb->priority 가 아니라 이 필터
        for ip in "$@"; do
            tc filter add dev "$PHYS_IF" parent 1: protocol ip prio 1 u32 match ip dst "$ip/32" flowid 1:10
        done
        tc class show dev "$PHYS_IF" | grep -q 'class htb 1:10 ' || { tc class show dev "$PHYS_IF"; die "HTB class 1:10 확인 실패"; }
        [ "$(tc filter show dev "$PHYS_IF" parent 1: | grep -c 'flowid 1:10')" -ge "$#" ] \
            || { tc filter show dev "$PHYS_IF" parent 1:; die "u32 필터 확인 실패 (기대 $# 개 → 1:10)"; }
        log_info "HTB: 1:1 10gbit(fq_codel) | 1:10 ${SHAPE_MBPS}mbit → leaf '$leaf' | u32 dst {$*} → 1:10"
    else
        # shellcheck disable=SC2086
        tc qdisc add dev "$PHYS_IF" root handle 200: $leaf
        log_warn "SHAPE_MBPS=0: '$leaf' 를 root 에 직접 붙임 — 병목이 없어 큐가 비고, 조건 간 latency 차이가 나올 수 없다 (기능 검증 전용)"
    fi
    tc qdisc show dev "$PHYS_IF" | grep -q "^qdisc ${leaf%% *} 200:" \
        || { tc qdisc show dev "$PHYS_IF"; die "leaf qdisc 확인 실패: 기대 '${leaf%% *} 200:'"; }
    case "$cond" in
        *_clsf) attach_classifier ;;
        *)      detach_classifier; log_info "분류기 없음 (조건 $cond)" ;;
    esac
}

dump_tc() {   # 사람이 읽는 tc 상태 (meta.json 과 logs/*/qdisc.txt 에 저장)
    echo "### tc -s qdisc show dev $PHYS_IF"; tc -s qdisc show dev "$PHYS_IF" 2>&1 || true
    echo "### tc -s class show dev $PHYS_IF"; tc -s class show dev "$PHYS_IF" 2>&1 || true
    echo "### tc filter show dev $PHYS_IF parent 1:"; tc filter show dev "$PHYS_IF" parent 1: 2>&1 || true
    echo "### tc filter show dev $PHYS_IF egress"; tc filter show dev "$PHYS_IF" egress 2>&1 || true
    if [ -x "$TCX_ATTACH" ]; then
        echo "### tcx_attach query $PHYS_IF egress"; "$TCX_ATTACH" query "$PHYS_IF" egress 2>&1 || true
    fi
    if command -v bpftool >/dev/null 2>&1; then
        echo "### bpftool net show dev $PHYS_IF"; bpftool net show dev "$PHYS_IF" 2>&1 || true
    fi
}

# 시계 상태 (두 VM 의 one-way latency 는 시계 오프셋을 포함한다 — ADR-0012). 이 노드 것만 읽을 수 있다;
# 수신 노드는 ssh 접근이 없으므로 verify-experiment.sh 로 그쪽에서 따로 확인한다.
clock_status() {
    if command -v chronyc >/dev/null 2>&1; then
        chronyc tracking 2>&1 || echo "(chronyc tracking 실패)"
    else
        echo "(chronyc 없음)"; timedatectl show -p NTPSynchronized 2>/dev/null || true
    fi
}

# =============================================================================
# build-ebpf
# =============================================================================
build_ebpf() {
    need_cmd make "apt install make"
    command -v clang >/dev/null 2>&1 || die "clang 없음: sudo apt install clang llvm libbpf-dev linux-libc-dev (step6-ebpf/Makefile 참고)"
    log_info "=== eBPF 빌드: make -C step6-ebpf ==="
    make -C "$EBPF_DIR"
    log_info "=== tcx 로더 빌드: make -C step6-ebpf tools (libbpf >= 1.3) ==="
    if make -C "$EBPF_DIR" tools; then
        log_info "tools 빌드 완료: $TCX_ATTACH"
    else
        log_warn "tcx_attach 빌드 실패 (libbpf < 1.3?). kernel >= 6.6 에서는 tcx 가 필요하다 — libbpf-dev 를 올리거나 ALLOW_LEGACY_ON_TCX=1"
    fi
    log_info "빌드 산출물(커밋하지 않음):"; ls -la "$BPF_BUILD"
}

# =============================================================================
# deploy-k8s
# =============================================================================
deploy_k8s() {
    resolve_kubeconfig || exit 1; need_cmd kubectl "kubectl"; check_cluster
    log_info "=== K8s 배포 (namespace $NAMESPACE) ==="
    kubectl get nodes -o wide
    # Namespace 이름은 NAMESPACE 에서 렌더링. 매니페스트/kustomization 은 namespace 를 적지 않고
    # 'kubectl -n $NAMESPACE' 가 배치를 정한다 (그래야 NAMESPACE 가 진짜 설정값이다).
    render "$K8S_DIR/namespace.yaml" "NAMESPACE=$NAMESPACE" | kubectl apply -f -
    # ConfigMap 은 저장소의 .py 에서 생성 (kustomization.yaml). 파일이 디렉터리 밖에 있어 load restrictor 해제.
    kubectl kustomize --load-restrictor LoadRestrictionsNone "$K8S_DIR" | kc apply -f -
    # experiment.env 값 주입 (값이 같으면 변경 없음)
    kc set env deploy/listener TS_PORT="$TS_PORT" TS_INTERVAL_MS="$TS_INTERVAL_MS" LISTENER_CPU="$LISTENER_CPU"
    kc set env deploy/udp-sink BE_PORT="$BE_PORT"
    if [ "$IMAGE_PY" != "python:3.11-slim" ]; then
        kc set image deploy/listener listener="$IMAGE_PY"
        kc set image deploy/udp-sink udp-sink="$IMAGE_PY"
    fi
    # ConfigMap 내용이 바뀌어도 Pod 는 자동으로 다시 뜨지 않으므로 항상 재시작
    kc rollout restart deploy/listener deploy/udp-sink
    kc rollout status deploy/listener --timeout=300s || { kc describe pod -l app=listener | tail -30; die "listener 준비 실패"; }
    kc rollout status deploy/udp-sink --timeout=300s || { kc describe pod -l app=udp-sink | tail -30; die "udp-sink 준비 실패"; }
    kc get pods -o wide
    log_info "=== 배포 완료. 다음: sudo bash $0 run fq_codel 0 ==="
}

# =============================================================================
# run
# =============================================================================
next_run_index() {   # <condition> <cpu>
    local max=0 f k
    for f in "$RESULTS_DIR/${1}_cpu${2}_run"*.csv; do
        [ -e "$f" ] || continue
        k=${f##*_run}; k=${k%.csv}
        is_uint "$k" && [ "$k" -gt "$max" ] && max=$k
    done
    echo $((max + 1))
}

RUN_OK=0
run_abort_cleanup() {
    if [ "$RUN_OK" != 1 ]; then
        log_warn "run 중단 — flood/talker/stress 정리 (qdisc/분류기는 남김: 'bash $0 cleanup' 으로 제거)"
        kc delete job be-flood talker-run --ignore-not-found --wait=false >/dev/null 2>&1 || true
        kc delete ds cpu-stress --ignore-not-found --wait=false >/dev/null 2>&1 || true
        echo "RESULT status=aborted"
    fi
}

run_experiment() {
    local cond_in=${1:?condition} cpu=${2:-0} run=${3:-}
    local cond
    cond=$(normalize_condition "$cond_in") || die "알 수 없는 조건 '$cond_in' (fifo|fq_codel|pfifo_fast_noclsf|pfifo_fast_clsf|prio_clsf|baseline|proposed)"
    is_uint "$cpu" && [ "$cpu" -le 100 ] || die "cpu% 는 0..100 정수: '$cpu'"
    [ -z "$run" ] || is_uint "$run" || die "run-index 는 정수: '$run'"
    is_uint "$SHAPE_MBPS" || die "SHAPE_MBPS 정수 필요: '$SHAPE_MBPS'"
    is_num "$FLOOD_MBPS" && is_uint "$TS_COUNT" && is_num "$TS_INTERVAL_MS" || die "FLOOD_MBPS/TS_COUNT/TS_INTERVAL_MS 값 확인"
    case "$STRESS_NODES" in receiver|all) ;; *) die "STRESS_NODES 는 receiver|all: '$STRESS_NODES'" ;; esac

    require_root run "$@"; check_deps; resolve_kubeconfig || exit 1; check_cluster; detect_phys_if
    # attach 방식은 분류기를 붙이는 조건에서만 결정한다 — fifo/fq_codel/pfifo_fast_noclsf 는 eBPF 가 전혀 필요 없다
    case "$cond" in
        *_clsf) decide_attach_mode || exit 1
                [ -f "$CLSF_OBJ" ] || die "$CLSF_OBJ 없음 — bash $0 build-ebpf" ;;
        *)      ATTACH_MODE=none ;;
    esac

    mkdir -p "$RESULTS_DIR/logs"
    [ -n "$run" ] || run=$(next_run_index "$cond" "$cpu")
    local base="${cond}_cpu${cpu}_run${run}"
    local csv="$RESULTS_DIR/$base.csv" meta="$RESULTS_DIR/$base.meta.json" logdir="$RESULTS_DIR/logs/$base"
    [ -e "$csv" ] && die "이미 존재: $csv (run-index 를 바꾸세요)"
    mkdir -p "$logdir"
    exec > >(tee -a "$logdir/run.log") 2>&1
    trap run_abort_cleanup EXIT
    trap 'exit 130' INT TERM

    log_info "=== run: condition=$cond (입력 '$cond_in') cpu=${cpu}% run=$run → $base ==="
    log_info "kernel=$(uname -r) attach=$ATTACH_MODE PHYS_IF=$PHYS_IF shape=${SHAPE_MBPS}Mbit flood=${FLOOD_MBPS}Mbit ts=${TS_COUNT}x${TS_INTERVAL_MS}ms KUBECONFIG=${KUBECONFIG:-~/.kube/config}"
    if [ "$SHAPE_MBPS" -gt 0 ] && ! python3 -c "import sys; sys.exit(0 if float('$FLOOD_MBPS') > $SHAPE_MBPS else 1)"; then
        log_warn "FLOOD_MBPS($FLOOD_MBPS) <= SHAPE_MBPS($SHAPE_MBPS): 병목에 backlog 가 생기지 않아 조건 간 차이가 나올 수 없다"
    fi
    log_info "sender(control-plane) allocatable cpu: $(kubectl get node -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || echo '?') — talker $TALKER_CPU_REQUEST + be-flood $FLOOD_CPU_REQUEST 요청. 부족하면 Pending (experiment.env TALKER_CPU_REQUEST)"

    # Cilium 라우팅 모드: u32 는 목적지 Pod IP 로 매칭하므로 native routing 이어야 한다
    local routing; routing=$(cilium_routing_mode)
    local shape_by=pod
    if [ -n "$routing" ] && [ "$routing" != native ]; then
        [ "$ALLOW_TUNNEL" = 1 ] || die "Cilium routing-mode='$routing': 터널 모드에서는 NIC egress 에서 Pod IP/UDP 6000 이 캡슐화돼 u32/분류기가 보지 못한다. README 환경(native) 을 쓰거나 ALLOW_TUNNEL=1 (수신 노드 IP 로 셰이핑, 분류기 무효)"
        shape_by=node
        log_warn "터널 모드 강행: 수신 노드 IP 로 셰이핑, 분류기는 캡슐화된 패킷을 분류하지 못한다"
    fi

    # 0. 이전 run 잔여물
    kc delete job be-flood talker-run --ignore-not-found --wait=true --cascade=foreground --timeout=120s
    kc delete ds cpu-stress --ignore-not-found --wait=true --timeout=120s
    kc wait --for=delete pod -l app=talker --timeout=60s >/dev/null 2>&1 || true
    kc wait --for=delete pod -l app=be-flood --timeout=60s >/dev/null 2>&1 || true

    # 1. listener 재시작 (빈 /data, 새 결과 파일 보장)
    log_info "listener Pod 재시작..."
    kc delete pod -l app=listener --ignore-not-found --wait=true --timeout=90s
    wait_pod_ready app=listener 240 || { kc get pods -o wide; die "listener 준비 실패"; }
    local listener_pod listener_ip listener_node
    listener_pod=$(pod_of app=listener); listener_ip=$(pod_ip_of "$listener_pod"); listener_node=$(pod_node_of "$listener_pod")
    [ -n "$listener_ip" ] || die "listener Pod IP 없음"
    log_info "listener: $listener_pod ($listener_ip @ $listener_node)"

    # 2. udp-sink
    wait_pod_ready app=udp-sink 240 || { kc get pods -o wide; die "udp-sink 준비 실패 (deploy-k8s 를 먼저 실행했는가?)"; }
    local sink_pod sink_ip sink_node
    sink_pod=$(pod_of app=udp-sink); sink_ip=$(pod_ip_of "$sink_pod"); sink_node=$(pod_node_of "$sink_pod")
    log_info "udp-sink: $sink_pod ($sink_ip @ $sink_node)"
    [ "$sink_node" = "$listener_node" ] || log_warn "udp-sink 와 listener 가 다른 노드에 있음 — 경쟁이 같은 링크를 지나는지 확인"

    # 3. qdisc 조건 (+분류기). u32 대상: listener/sink Pod IP (터널 모드 강행 시 수신 노드 IP)
    local -a targets=("$listener_ip" "$sink_ip")
    if [ "$shape_by" = node ]; then
        mapfile -t targets < <(kubectl get node "$listener_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n')
    fi
    # PHYS_IF 가 실제로 목적지로 나가는 NIC 인지 (2-NIC VM 에서 default route ≠ 클러스터 NIC)
    check_phys_if_route "${targets[0]}"
    apply_condition "$cond" "${targets[@]}"
    local counters_before class_before
    counters_before=$(read_counters); class_before=$(read_class_stats)
    clock_status > "$logdir/chrony_before.txt"

    # 4. CPU 부하 (선택)
    local stress_key="node-role.kubernetes.io/control-plane" stress_op="DoesNotExist"
    if [ "$STRESS_NODES" = all ]; then stress_key="kubernetes.io/os"; stress_op="Exists"; fi
    local send_s flood_dur
    send_s=$(python3 -c "import math; print(int(math.ceil($TS_COUNT * $TS_INTERVAL_MS / 1000.0)))")
    flood_dur=$((send_s + 8))
    if [ "$cpu" -gt 0 ]; then
        log_info "stress DaemonSet: --cpu $STRESS_WORKERS --cpu-load $cpu (nodes=$STRESS_NODES)..."
        render "$K8S_DIR/stress-daemonset.yaml" "CPU_LOAD=$cpu" "STRESS_WORKERS=$STRESS_WORKERS" \
            "STRESS_TIMEOUT_S=$((flood_dur + 300))" "STRESS_AFFINITY_KEY=$stress_key" "STRESS_AFFINITY_OP=$stress_op" \
            "IMAGE_STRESS=$IMAGE_STRESS" | kc apply -f -
        kc rollout status ds/cpu-stress --timeout=180s || { kc describe ds cpu-stress | tail -20; die "stress 준비 실패"; }
        sleep 3   # 부하 안정화
    fi

    # 5. best-effort 홍수 시작 (talker 보다 2 s 먼저 → 큐가 찬 상태에서 TS 송신 시작)
    log_info "be-flood Job: → $sink_ip:$BE_PORT ${FLOOD_MBPS} Mbit/s, ${FLOOD_SIZE}B, ${flood_dur}s"
    render "$K8S_DIR/be-flood-job.yaml" "BE_TARGET=$sink_ip" "BE_PORT=$BE_PORT" "FLOOD_MBPS=$FLOOD_MBPS" \
        "FLOOD_SIZE=$FLOOD_SIZE" "FLOOD_DURATION_S=$flood_dur" "FLOOD_DEADLINE_S=$((flood_dur + 120))" \
        "FLOOD_CPU_REQUEST=$FLOOD_CPU_REQUEST" "IMAGE_PY=$IMAGE_PY" | kc apply -f -
    wait_job_pod_started app=be-flood 120 || { kc describe pod -l app=be-flood | tail -20; die "be-flood 시작 실패"; }
    sleep 2

    # 6. talker Job
    local t_start t_end
    t_start=$(date -u +%FT%TZ)
    log_info "talker Job: → $listener_ip:$TS_PORT ${TS_COUNT} pkts @ ${TS_INTERVAL_MS} ms (약 ${send_s}s)"
    render "$K8S_DIR/talker-job.yaml" "TS_TARGET=$listener_ip" "TS_PORT=$TS_PORT" "TS_INTERVAL_MS=$TS_INTERVAL_MS" \
        "TS_COUNT=$TS_COUNT" "TS_SIZE=$TS_SIZE" "TALKER_CPU=$TALKER_CPU" "TALKER_CPU_REQUEST=$TALKER_CPU_REQUEST" \
        "TALKER_DEADLINE_S=$((send_s + 120))" "IMAGE_PY=$IMAGE_PY" | kc apply -f -
    wait_job_pod_started app=talker 120 || { kc describe pod -l app=talker | tail -20; die "talker 시작 실패"; }
    local talker_pod; talker_pod=$(job_pod_of app=talker)
    local jrc=0
    wait_job talker-run $((send_s + 120)) || jrc=$?
    t_end=$(date -u +%FT%TZ)
    kc logs job/talker-run > "$logdir/talker.log" 2>&1 || true
    if [ "$jrc" != 0 ]; then
        tail -20 "$logdir/talker.log" || true
        die "talker Job 실패/타임아웃 (rc=$jrc) — 결과 CSV 를 남기지 않는다. 로그: $logdir/talker.log"
    fi
    [ "$(kc get pod -l app=talker -o name | wc -l)" -le 1 ] || die "talker Pod 가 2개 이상 — 재시도로 seq 가 섞였을 수 있다 (backoffLimit 0 인데?)"
    # stdout 에 실린 드리프트 로그 잘라내기 (Completed Pod 는 kubectl cp 불가)
    sed -n '/^### TALKER_LOG_BEGIN$/,/^### TALKER_LOG_END$/p' "$logdir/talker.log" | sed '1d;$d' > "$logdir/talker_drift.csv" || true
    grep -E "SO_PRIORITY|전송 완료|CPU affinity" "$logdir/talker.log" | sed 's/^/  talker: /' || true
    local talker_summary; talker_summary=$(grep -E "^전송 완료" "$logdir/talker.log" | tail -1 || true)
    grep -Eq "^전송 완료: ${TS_COUNT}/${TS_COUNT} " "$logdir/talker.log" \
        || log_warn "talker 가 ${TS_COUNT} 개를 다 보내지 못함: '$talker_summary'"

    # 7. listener CSV (마지막 패킷 후 --timeout 8 s 뒤에 생성)
    log_info "listener 결과 대기..."
    local i found=0
    for i in $(seq 1 45); do
        if kc exec "$listener_pod" -- test -f /data/results.csv 2>/dev/null; then found=1; break; fi
        sleep 2
    done
    kc logs "$listener_pod" > "$logdir/listener.log" 2>&1 || true
    [ "$found" = 1 ] || { tail -20 "$logdir/listener.log"; die "listener 가 results.csv 를 쓰지 않음 (패킷 미수신?)"; }
    kc cp "$listener_pod:/data/results.csv" "$logdir/results.csv.tmp" >/dev/null
    local rows; rows=$(($(wc -l < "$logdir/results.csv.tmp") - 1))
    head -1 "$logdir/results.csv.tmp" | grep -q '^seq,send_ns,recv_ns,latency_ms,jitter_us,pkt_size' || die "CSV 헤더가 예상과 다름"
    mv "$logdir/results.csv.tmp" "$csv"
    grep -E "Latency|Jitter|TOS|손실" "$logdir/listener.log" | sed 's/^/  listener: /' || true
    log_info "CSV: $csv ($rows 행 / 기대 $TS_COUNT)"

    # 8. flood 종료/통계, tc 상태, 카운터, meta
    wait_job be-flood 60 >/dev/null 2>&1 || true
    kc logs job/be-flood > "$logdir/flood.log" 2>&1 || true
    local flood_json; flood_json=$(sed -n '/^### FLOOD_STATS_BEGIN$/,/^### FLOOD_STATS_END$/p' "$logdir/flood.log" | sed '1d;$d' | tr -d '\n' || true)
    [ -n "$flood_json" ] || flood_json='{}'
    dump_tc > "$logdir/qdisc.txt"
    clock_status > "$logdir/chrony_after.txt"
    local counters_after class_after
    counters_after=$(read_counters); class_after=$(read_class_stats)
    local git_sha; git_sha=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
    local git_dirty=0; [ -z "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ] || git_dirty=1
    local image_listener image_talker
    image_listener=$(kc get pod "$listener_pod" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)
    image_talker=$(kc get pod "$talker_pod" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)

    META_COND="$cond" META_COND_IN="$cond_in" META_CPU="$cpu" META_RUN="$run" META_KERNEL="$(uname -r)" \
    META_ATTACH="$ATTACH_MODE" META_CLSF="$(case "$cond" in *_clsf) echo 1;; *) echo 0;; esac)" META_IF="$PHYS_IF" \
    META_IF_SOURCE="$PHYS_IF_SOURCE" META_ROUTE_DEV="$ROUTE_DEV" \
    META_CLSF_CFG="$CLSF_CFG_APPLIED" META_GIT_DIRTY="$git_dirty" META_IMG_LISTENER="$image_listener" META_IMG_TALKER="$image_talker" \
    META_TC_VER="$(tc -V 2>/dev/null || echo unknown)" META_BPFTOOL_VER="$(bpftool version 2>/dev/null | head -1 || echo unknown)" \
    META_CHRONY_BEFORE="$logdir/chrony_before.txt" META_CHRONY_AFTER="$logdir/chrony_after.txt" \
    META_CLASS_BEFORE="$class_before" META_CLASS_AFTER="$class_after" META_TALKER_SUMMARY="$talker_summary" \
    META_TALKER_LOG="$logdir/talker.log" META_LISTENER_LOG="$logdir/listener.log" META_FLOOD_LOG="$logdir/flood.log" \
    META_SHAPE="$SHAPE_MBPS" META_FLOOD="$FLOOD_MBPS" META_FLOOD_SIZE="$FLOOD_SIZE" META_COUNT="$TS_COUNT" \
    META_INTERVAL="$TS_INTERVAL_MS" META_SIZE="$TS_SIZE" META_TS_PORT="$TS_PORT" META_BE_PORT="$BE_PORT" \
    META_MARK_DSCP="$MARK_DSCP" META_TS_PRIORITY="$TS_PRIORITY" META_TS_DSCP="$TS_DSCP" \
    META_STRESS_NODES="$STRESS_NODES" META_STRESS_WORKERS="$STRESS_WORKERS" META_T0="$t_start" META_T1="$t_end" \
    META_LISTENER="$listener_pod@$listener_node/$listener_ip" META_SINK="$sink_pod@$sink_node/$sink_ip" \
    META_TARGETS="${targets[*]}" META_ROUTING="$routing" META_CILIUM="$(cilium_image)" META_GIT="$git_sha" \
    META_ROWS="$rows" META_QDISC_FILE="$logdir/qdisc.txt" META_OUT="$meta" \
    META_C_BEFORE="$counters_before" META_C_AFTER="$counters_after" META_FLOOD_JSON="$flood_json" \
    META_KUBECTL="$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo unknown)" \
    python3 - <<'PY'
import json, os
e = os.environ
def j(s, default):
    try:
        return json.loads(s) if s else default
    except Exception:
        return default
def read(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""
before, after = j(e["META_C_BEFORE"], {}), j(e["META_C_AFTER"], {})
delta = {k: after.get(k, 0) - before.get(k, 0) for k in after} if after else {}
cb, ca = j(e["META_CLASS_BEFORE"], {}), j(e["META_CLASS_AFTER"], {})
class_delta = {k: {f: ca[k].get(f, 0) - cb.get(k, {}).get(f, 0) for f in ("bytes", "pkts")} for k in ca}
# 'class prio 200:1' = band 0 (skb->priority 6 → priomap → band 0) … 200:3 = band 2 (prio_clsf 조건만 존재)
bands = {f"band{int(k.split(':')[1]) - 1}": v for k, v in class_delta.items() if k.startswith("prio 200:")}
meta = {
    "condition": e["META_COND"], "condition_input": e["META_COND_IN"],
    "cpu_load": int(e["META_CPU"]), "run": int(e["META_RUN"]),
    "kernel": e["META_KERNEL"], "git": e["META_GIT"], "git_dirty": bool(int(e["META_GIT_DIRTY"])),
    "kubectl": e["META_KUBECTL"], "tc": e["META_TC_VER"], "bpftool": e["META_BPFTOOL_VER"],
    "cilium_image": e["META_CILIUM"], "cilium_routing_mode": e["META_ROUTING"],
    "images": {"listener": e["META_IMG_LISTENER"], "talker": e["META_IMG_TALKER"]},
    "attach_mode": e["META_ATTACH"], "classifier": bool(int(e["META_CLSF"])), "phys_if": e["META_IF"],
    "phys_if_source": e["META_IF_SOURCE"], "route_dev": e["META_ROUTE_DEV"],
    "ts_config_applied": bool(int(e["META_CLSF_CFG"])),
    "shaper": "htb" if int(e["META_SHAPE"]) > 0 else "none",
    "link_rate_mbps": float(e["META_SHAPE"]), "flood_offered_mbps": float(e["META_FLOOD"]),
    "flood_size": int(e["META_FLOOD_SIZE"]),
    "ts_count": int(e["META_COUNT"]), "ts_interval_ms": float(e["META_INTERVAL"]), "ts_size": int(e["META_SIZE"]),
    "ts_port": int(e["META_TS_PORT"]), "be_port": int(e["META_BE_PORT"]),
    "ts_config": {"priority": int(e["META_TS_PRIORITY"]), "dscp": int(e["META_TS_DSCP"]), "mark_dscp": int(e["META_MARK_DSCP"])},
    "stress": {"nodes": e["META_STRESS_NODES"], "workers": int(e["META_STRESS_WORKERS"]), "cpu_load": int(e["META_CPU"])},
    "listener": e["META_LISTENER"], "udp_sink": e["META_SINK"], "shape_targets": e["META_TARGETS"].split(),
    "talker_start": e["META_T0"], "talker_end": e["META_T1"],
    "csv_rows": int(e["META_ROWS"]),
    "talker_summary": e["META_TALKER_SUMMARY"],
    "ts_counters": delta, "ts_counters_before": before, "ts_counters_after": after,
    "tc_class_delta": class_delta, "prio_bands": bands,
    "tc_class_before": cb, "tc_class_after": ca,
    "flood": j(e["META_FLOOD_JSON"], {}),
    "chrony_before": read(e["META_CHRONY_BEFORE"]), "chrony_after": read(e["META_CHRONY_AFTER"]),
    "logs": {"talker": e["META_TALKER_LOG"], "listener": e["META_LISTENER_LOG"], "flood": e["META_FLOOD_LOG"]},
    "tc_dump": read(e["META_QDISC_FILE"]),
}
with open(e["META_OUT"], "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=1, ensure_ascii=False)
print(f"  ts_counters (delta): {delta}")
print(f"  prio bands (delta): {bands}")
print(f"  flood: {meta['flood']}")
PY
    log_info "meta: $meta"
    # 분류기 조건인데 카운터가 안 움직였다 = 분류기가 실행되지 않았다 (tcx 순서/legacy+Cilium). 결과는 남기되 크게 경고.
    case "$cond" in *_clsf)
        if ! python3 - "$counters_before" "$counters_after" "$TS_COUNT" <<'PY'
import json, sys
b, a = (json.loads(x or "{}") for x in sys.argv[1:3])
sys.exit(0 if a.get("ts_udp", 0) - b.get("ts_udp", 0) >= 0.9 * int(sys.argv[3]) else 1)
PY
        then
            log_warn "ts_counters[ts_udp] 증가분이 TS_COUNT 의 90% 미만 — 분류기가 실행되지 않았거나(tcx 순서/legacy+Cilium) pin 을 못 읽었다. 'bash $0 status', verify-experiment.sh 로 확인"
        fi
    ;; esac
    # 모든 조건 공통: 실험 트래픽이 병목 class 1:10 을 실제로 지났는가. 분류기 없는 조건은 이것이 유일한 신호다
    # (PHYS_IF 가 엉뚱한 NIC 이거나 u32 dst 가 틀리면 HTB 1:10 카운터가 0 인 채 "그럴듯한" CSV 가 남는다).
    if [ "$SHAPE_MBPS" -gt 0 ]; then
        local htb_pkts
        htb_pkts=$(python3 - "$class_before" "$class_after" <<'PY'
import json, sys
b, a = (json.loads(x or "{}") for x in sys.argv[1:3])
print(a.get("htb 1:10", {}).get("pkts", 0) - b.get("htb 1:10", {}).get("pkts", 0))
PY
)
        if [ "${htb_pkts:-0}" -lt "$TS_COUNT" ]; then
            log_warn "HTB class 1:10 통과 패킷 증가분 ${htb_pkts:-0} < TS_COUNT($TS_COUNT) — 실험 트래픽이 병목을 지나지 않았다: PHYS_IF=$PHYS_IF 가 listener 로 나가는 NIC 인가 (route dev '${ROUTE_DEV:-?}'), u32 dst {${targets[*]}} 가 맞는가. verify-experiment.sh --offline 이 이 run 을 FAIL 로 잡는다"
        else
            log_info "HTB 1:10 통과 패킷 증가분 $htb_pkts (≥ TS_COUNT $TS_COUNT: 실험 트래픽이 병목을 지났다)"
        fi
    fi

    # 9. 정리 (qdisc/분류기는 남김)
    kc delete job be-flood talker-run --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc delete ds cpu-stress --ignore-not-found --wait=false >/dev/null 2>&1 || true
    RUN_OK=1; trap - EXIT
    echo "RESULT status=ok condition=$cond cpu=$cpu run=$run attach=$ATTACH_MODE classifier=$(case "$cond" in *_clsf) echo 1;; *) echo 0;; esac) csv_rows=$rows csv=$csv"
    log_info "=== 완료: $base (csv=$rows 행) — 로그: $logdir ==="
}

# matrix: run 을 조건 × 반복으로 순회. 바깥 루프가 반복(run k), 안쪽이 조건 → ABCDE ABCDE … (ABAB 인터리브).
# 한 조건을 N 번 연달아 돌리면 시간 드리프트(시계 slew, 노드 온도, 백그라운드 작업)가 조건 효과와 섞인다.
# 각 run 은 서브셸에서 돌아 하나가 실패해도 다음으로 넘어가고, 끝에 실패 목록을 모아 non-zero 로 끝난다.
run_matrix() {   # matrix <runs> [cpu%] [conditions...]
    local runs=${1:?runs} cpu=${2:-0}; shift; shift 2>/dev/null || true
    local -a conds=("$@")
    [ "${#conds[@]}" -gt 0 ] || conds=(fifo fq_codel pfifo_fast_noclsf pfifo_fast_clsf prio_clsf)
    is_uint "$runs" || die "runs 정수 필요"
    local r c failed="" n=0 t0
    for c in "${conds[@]}"; do normalize_condition "$c" >/dev/null || die "알 수 없는 조건: $c"; done
    t0=$(date +%s)
    for r in $(seq 1 "$runs"); do
        for c in "${conds[@]}"; do
            n=$((n + 1))
            log_info "##### matrix: run $r/$runs condition $c cpu $cpu  (${n}/$((runs * ${#conds[@]})), 경과 $(( $(date +%s) - t0 ))s)"
            ( run_experiment "$c" "$cpu" ) || { failed="$failed ${c}#$r"; log_warn "실패: $c run $r"; }
        done
    done
    echo "RESULT matrix runs=$runs cpu=$cpu conditions='${conds[*]}' failed='${failed# }' results=$RESULTS_DIR"
    [ -z "$failed" ] || die "실패한 run:$failed"
    log_info "matrix 완료 → $RESULTS_DIR  (요약: python3 compare_results.py $RESULTS_DIR / bash verify-experiment.sh --offline --results $RESULTS_DIR)"
}

# =============================================================================
# status / show-counters / cleanup
# =============================================================================
status() {
    resolve_kubeconfig 2>/dev/null || true
    detect_phys_if
    kernel_ge 6.6 && ATTACH_MODE=tcx
    echo "=== 노드 ==="; kubectl get nodes -o wide 2>/dev/null || echo "(kubectl 불가)"
    echo; echo "=== NIC $PHYS_IF: kernel $(uname -r), attach 모드 $ATTACH_MODE, TX queues $(find "/sys/class/net/$PHYS_IF/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)"
    ethtool -i "$PHYS_IF" 2>/dev/null | head -2 || true
    echo; echo "=== Cilium: image=$(cilium_image) routing-mode=$(cilium_routing_mode)"
    echo; dump_tc
    echo; echo "=== 분류기 pin ($PIN) ==="; ls -la "$PIN" "$PIN_MAPS" 2>/dev/null || echo "(없음)"
    if [ "$(id -u)" -eq 0 ]; then echo "counters: $(read_counters)"; else echo "(카운터는 root 로 실행 시 표시)"; fi
    echo; echo "=== Pod ($NAMESPACE) ==="; kc get pods -o wide 2>/dev/null || echo "(namespace 없음 — deploy-k8s)"
    echo; echo "=== 결과 ($RESULTS_DIR) ==="; ls -1 "$RESULTS_DIR"/*.csv 2>/dev/null || echo "(없음)"
}

show_counters() {
    require_root show-counters
    if [ -f "$PIN_MAPS/ts_counters" ]; then
        read_counters
    else
        log_warn "pinned ts_counters 없음 — 이름으로 조회 (같은 이름의 map 이 여럿이면 모두 표시)"
        bpftool map dump name ts_counters 2>/dev/null || echo "{}"
    fi
}

cleanup() {
    require_root cleanup; detect_phys_if
    kernel_ge 6.6 && [ -x "$TCX_ATTACH" ] && ATTACH_MODE=tcx
    log_info "=== cleanup ==="
    # kubeconfig/클러스터가 없어도(worker 노드, kubeadm reset 뒤) tc/BPF 정리는 반드시 진행한다
    if command -v kubectl >/dev/null 2>&1 && resolve_kubeconfig 2>/dev/null && kubectl get nodes >/dev/null 2>&1; then
        kc delete job --all --ignore-not-found --wait=false 2>/dev/null || true
        kc delete ds --all --ignore-not-found --wait=false 2>/dev/null || true
        if ! kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s; then
            log_warn "namespace $NAMESPACE 삭제 타임아웃 (Terminating)"
            if [ "$FORCE_NS_FINALIZE" = 1 ]; then
                log_warn "FORCE_NS_FINALIZE=1: finalizer 제거 (남은 리소스가 고아가 될 수 있음)"
                kubectl get namespace "$NAMESPACE" -o json \
                    | python3 -c 'import json,sys; o=json.load(sys.stdin); o["spec"]["finalizers"]=[]; json.dump(o,sys.stdout)' \
                    | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - >/dev/null || true
            else
                log_warn "원인: kubectl get ns $NAMESPACE -o yaml (status.conditions). 강제: FORCE_NS_FINALIZE=1 bash $0 cleanup"
            fi
        fi
    else
        log_warn "kubectl/kubeconfig/클러스터 접근 불가 — K8s 리소스는 건너뛰고 NIC 의 qdisc/분류기만 정리한다"
    fi
    [ -f "$SCRIPT_DIR/step8-measurement/hubble-monitor.sh" ] && bash "$SCRIPT_DIR/step8-measurement/hubble-monitor.sh" stop >/dev/null 2>&1 || true
    detach_classifier
    reset_root_qdisc
    # clsact 는 legacy 모드에서 우리가 만들었을 때만 지운다. Cilium(legacy tc) 이 쓰는 clsact 를 지우면 데이터패스가 끊긴다.
    if tc qdisc show dev "$PHYS_IF" | grep -q '^qdisc clsact'; then
        if tc filter show dev "$PHYS_IF" egress 2>/dev/null | grep -q 'cil_' || tc filter show dev "$PHYS_IF" ingress 2>/dev/null | grep -q 'cil_'; then
            log_warn "clsact 에 Cilium 필터가 있어 남겨 둠"
        else
            tc qdisc del dev "$PHYS_IF" clsact
        fi
    fi
    rm -rf "$PIN"
    log_info "qdisc/분류기 제거됨:"; tc qdisc show dev "$PHYS_IF"
    log_info "=== cleanup 완료 ==="
}

usage() {
    cat <<EOF
사용법: sudo bash $0 <command> [args]

  build-ebpf                          step6-ebpf 빌드 (clang/libbpf-dev/linux-libc-dev 필요)
  deploy-k8s                          namespace/ConfigMap/listener/udp-sink 배포 (sudo 불필요)
  run <condition> [cpu%] [run-index]  실험 1회 (root). condition: fifo | fq_codel | pfifo_fast_noclsf |
                                      pfifo_fast_clsf | prio_clsf  (alias baseline=fq_codel, proposed=prio_clsf)
  matrix <runs> [cpu%] [conditions..] 조건 × 반복 순회 (기본: 5개 조건 전부)
  status                              현재 상태
  attach-classifier / detach-classifier / show-counters
  cleanup                             전부 제거 (root)

설정: ./experiment.env (experiment.env.example 참고). 결과: $RESULTS_DIR/<condition>_cpu<N>_run<k>.csv (+ .meta.json)
예:
  bash $0 build-ebpf && bash $0 deploy-k8s
  sudo bash $0 matrix 3 0                 # 5 조건 × 3 회 (ABAB 인터리브), CPU 부하 없음
  sudo bash $0 run prio_clsf 50           # + 수신 노드 stress-ng 50%
  sudo bash verify-experiment.sh --condition prio_clsf   # 분류기 순서/카운터/band/CSV 검증
  python3 compare_results.py $RESULTS_DIR
  sudo bash $0 cleanup
EOF
}

# =============================================================================
# main
# =============================================================================
case "${1:-help}" in
    build-ebpf)        build_ebpf ;;
    deploy-k8s)        deploy_k8s ;;
    run)               shift; run_experiment "$@" ;;
    matrix)            shift; run_matrix "$@" ;;
    status)            status ;;
    attach-classifier) require_root attach-classifier; check_deps; detect_phys_if; decide_attach_mode || exit 1; attach_classifier ;;
    detach-classifier) require_root detach-classifier; detect_phys_if; detach_classifier; log_info "detach 완료" ;;   # detach 는 ATTACH_MODE 가 필요 없다 (pin / tc filter 로 판단)
    show-counters)     show_counters ;;
    cleanup)           cleanup ;;
    help|-h|--help)    usage ;;
    *)                 usage; exit 2 ;;
esac

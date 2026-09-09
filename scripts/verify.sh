#!/bin/bash
# =============================================================================
# scripts/verify.sh — 실험 상태 / 결과 검증 (scripts/experiment.sh 의 짝)
#
# 무엇을 검증하나
#   [live, root]  분류기가 tcx 체인 맨 앞(ts_classifier → cil_to_netdev)에 있는가 (legacy 면 tc filter),
#                 ts_counters (per-CPU 합산), HTB/leaf qdisc/u32 필터, prio band 별 tc -s class 카운터,
#                 isolcpus 와 Pod 의 Cpus_allowed_list, 클러스터/Pod Ready
#   [results]     CSV: 헤더, 행 수, seq 단조 증가/중복 없음, 송신 간격 중앙값 ±10 %,
#                 .meta.json 존재, meta 의 분류기 카운터(ts_udp ≥ 0.9·TS_COUNT) 와 band 0 카운터,
#                 DSCP 마킹(tos 컬럼) 이 도착했는가
#
# 사용법
#   sudo bash scripts/verify.sh [--condition <cond>] [--results DIR] [--quick]
#   bash scripts/verify.sh --offline [--results DIR ...]      # CI: 커밋된 CSV 만 (root 불필요)
#
#   --condition  기대 상태를 고정한다: *_clsf 면 분류기가 붙어 있어야, 아니면 없어야 하고 leaf 가 맞아야 한다.
#                생략하면 현재 상태를 보고만 한다 (모순 — pin 은 있는데 체인 맨 앞이 아님 — 만 실패).
#   --offline    live 검사를 건너뛴다. DIR 을 주지 않으면 results/k8s-2026-05 (2026-05, v1, meta 없음)
#                와 results/ (testbed, k8s) 아래를 재귀로 찾는다.
#   --quick      results 검사만 (live 는 [1]~[2] 만)
#
# 종료 코드: FAIL 이 하나라도 있으면 1. sudo 를 스스로 호출하지 않는다 (live 검사는 root 로 실행).
# 설정: ./experiment.env (scripts/experiment.sh 와 같은 파일/파서)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # 저장소 루트 (scripts/ 의 상위)
TCX_ATTACH="$ROOT_DIR/bpf/build/tcx_attach"
BPFMAPS="$ROOT_DIR/testbed/bpfmaps.py"
PIN=/sys/fs/bpf/tsn
PIN_LINK=$PIN/clsf_link
PIN_MAPS=$PIN/clsf_maps

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
N_OK=0; N_WARN=0; N_FAIL=0
ok()   { N_OK=$((N_OK + 1));     echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { N_WARN=$((N_WARN + 1)); echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { N_FAIL=$((N_FAIL + 1)); echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo "       $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 2; }

# ── experiment.env (scripts/experiment.sh 와 동일 규칙) ─────────────────────────
ENV_FILE="${EXPERIMENT_ENV:-$ROOT_DIR/experiment.env}"
load_env_file() {
    local line key val
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        key="${line%%=*}"; val="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
        [ -n "${!key+x}" ] && continue
        [ -n "$val" ] || continue
        printf -v "$key" '%s' "$val"
        export "${key?}"
    done < "$ENV_FILE"
}
load_env_file
PHYS_IF="${PHYS_IF:-}"
NAMESPACE="${NAMESPACE:-tsn-experiment}"
TS_PORT="${TS_PORT:-6000}"
TS_COUNT="${TS_COUNT:-10000}"
TS_INTERVAL_MS="${TS_INTERVAL_MS:-1}"
SHAPE_MBPS="${SHAPE_MBPS:-20}"
RESULTS_DIR="${RESULTS_DIR:-results/k8s}"
case "$RESULTS_DIR" in /*) ;; *) RESULTS_DIR="$ROOT_DIR/$RESULTS_DIR" ;; esac

# ── 인자 ────────────────────────────────────────────────────────────────────
OFFLINE=0; QUICK=0; CONDITION=""
declare -a RESULT_DIRS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --offline)   OFFLINE=1; shift ;;
        --quick)     QUICK=1; shift ;;
        --condition) CONDITION=${2:?}; shift 2 ;;
        --results)   RESULT_DIRS+=("${2:?}"); shift 2 ;;
        -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
        *) die "알 수 없는 인자: $1 (--help)" ;;
    esac
done
case "$CONDITION" in
    "") ;;
    baseline) CONDITION=fq_codel ;;
    proposed) CONDITION=prio_clsf ;;
    fifo|fq_codel|pfifo_fast_noclsf|pfifo_fast_clsf|prio_clsf) ;;
    *) die "알 수 없는 조건: $CONDITION" ;;
esac
EXPECT_CLSF=""; EXPECT_LEAF=""
case "$CONDITION" in
    fifo)              EXPECT_CLSF=0; EXPECT_LEAF=pfifo ;;
    fq_codel)          EXPECT_CLSF=0; EXPECT_LEAF=fq_codel ;;
    pfifo_fast_noclsf) EXPECT_CLSF=0; EXPECT_LEAF=pfifo_fast ;;
    pfifo_fast_clsf)   EXPECT_CLSF=1; EXPECT_LEAF=pfifo_fast ;;
    prio_clsf)         EXPECT_CLSF=1; EXPECT_LEAF=prio ;;
esac

echo "================================================================"
echo "  verify — $(date -u +%FT%TZ)  mode=$([ "$OFFLINE" = 1 ] && echo offline || echo live)${CONDITION:+  condition=$CONDITION}"
echo "================================================================"

kernel_ge() { local have; have=$(uname -r | cut -d. -f1-2); [ "$(printf '%s\n' "$1" "$have" | sort -V | head -1)" = "$1" ]; }

# kubeconfig (scripts/experiment.sh 와 같은 탐색, 실패해도 계속 — 클러스터 검사만 건너뛴다)
resolve_kubeconfig_soft() {
    [ -n "${KUBECONFIG:-}" ] && return 0
    [ -r "$HOME/.kube/config" ] && return 0
    local c home_su=""
    [ -n "${SUDO_USER:-}" ] && home_su=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    for c in /root/.kube/config "${home_su:+$home_su/.kube/config}" /etc/kubernetes/admin.conf; do
        [ -n "$c" ] && [ -r "$c" ] && { export KUBECONFIG="$c"; return 0; }
    done
    return 1
}
kube_ok() { command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; }

# ── 카운터 읽기 (pinned → 이름 조회) ────────────────────────────────────────
read_counters() {
    if [ -f "$PIN_MAPS/ts_counters" ]; then
        python3 "$BPFMAPS" counters "$PIN_MAPS/ts_counters" 2>/dev/null && return 0
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
raw = {}
for e in bj("map", "dump", "id", str(maps[-1]["id"])):
    src = e.get("formatted") or e
    vals = src.get("values") or [{"value": src.get("value", 0)}]
    raw[to_int(src["key"])] = sum(to_int(v["value"]) for v in vals)
out = {n: raw.get(i, 0) for i, n in enumerate(NAMES)}
out["_map_count"] = len(maps)
print(json.dumps(out))
PY
}

# =============================================================================
# live 검사
# =============================================================================
live_checks() {
    [ "$(id -u)" -eq 0 ] || die "live 검사는 root 필요 (tc/bpftool): sudo bash $0 ...   또는 --offline"
    local c; for c in tc ip bpftool python3; do command -v "$c" >/dev/null 2>&1 || die "$c 없음"; done
    resolve_kubeconfig_soft || true

    # [1] NIC / kernel / attach 모드
    echo; echo "[1] 노드"
    if [ -z "$PHYS_IF" ]; then
        PHYS_IF=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
        [ -n "$PHYS_IF" ] || die "default route 인터페이스를 찾지 못함 — experiment.env PHYS_IF"
    fi
    [ -d "/sys/class/net/$PHYS_IF" ] || die "인터페이스 없음: $PHYS_IF"
    local mode=legacy; kernel_ge 6.6 && mode=tcx
    local txq; txq=$(find "/sys/class/net/$PHYS_IF/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)
    ok "kernel $(uname -r), PHYS_IF=$PHYS_IF (TX queues $txq), attach 모드 $mode"
    if [ "$mode" = tcx ] && [ ! -x "$TCX_ATTACH" ]; then
        warn "$TCX_ATTACH 없음 — kernel >= 6.6 에서는 tcx 로 붙어야 한다 (bash scripts/experiment.sh build-ebpf)"
    fi

    # [2] 분류기 위치
    echo; echo "[2] ts_classifier 부착 (기대: $([ -n "$EXPECT_CLSF" ] && echo "$EXPECT_CLSF" || echo '?'))"
    local attached=0 first="" chain=""
    if [ "$mode" = tcx ] && [ -x "$TCX_ATTACH" ]; then
        chain=$("$TCX_ATTACH" query "$PHYS_IF" egress 2>&1 || true)
        sed 's/^/       /' <<<"$chain"
        first=$(sed -n '2p' <<<"$chain")
        grep -q ts_classifier <<<"$chain" && attached=1
        if [ "$attached" = 1 ]; then
            if grep -q ts_classifier <<<"$first"; then
                ok "ts_classifier 가 tcx egress 체인 [0] (Cilium 앞)"
                grep -q 'cil_' <<<"$chain" && info "Cilium 프로그램이 뒤에 있음 → TC_ACT_UNSPEC 으로 이어짐" \
                    || info "체인에 Cilium 프로그램 없음 (Cilium 이 이 NIC egress 에 붙지 않았거나 legacy tc)"
            else
                fail "ts_classifier 가 체인 맨 앞이 아님 — Cilium 이 TC_ACT_OK 를 먼저 반환하면 실행되지 않는다. detach-classifier → attach-classifier"
            fi
            [ -e "$PIN_LINK" ] || warn "링크 pin $PIN_LINK 없음 — scripts/experiment.sh 가 만든 링크가 아니다 (detach 는 pin 으로 한다)"
        elif [ -e "$PIN_LINK" ]; then
            fail "pin $PIN_LINK 은 있는데 체인에 ts_classifier 가 없음 (stale pin?) — rm -rf $PIN 후 다시 attach"
        fi
        if tc filter show dev "$PHYS_IF" egress 2>/dev/null | grep -q ts_classifier; then
            warn "legacy clsact 에도 ts_classifier 가 있음 — kernel >= 6.6 에서는 tcx 체인이 OK 를 반환하면 실행되지 않는다"
        fi
    else
        chain=$(tc filter show dev "$PHYS_IF" egress 2>&1 || true)
        sed 's/^/       /' <<<"$chain"
        grep -q ts_classifier <<<"$chain" && attached=1
        if [ "$attached" = 1 ]; then
            ok "legacy clsact egress 에 ts_classifier"
            grep -q 'cil_' <<<"$chain" && warn "같은 hook 에 Cilium 필터 — pref 가 더 낮은 Cilium 이 TC_ACT_OK 를 반환하면 분류기는 실행되지 않는다 (카운터로 확인)"
        fi
    fi
    if [ -n "$EXPECT_CLSF" ]; then
        if [ "$EXPECT_CLSF" = 1 ] && [ "$attached" = 0 ]; then fail "조건 $CONDITION 은 분류기가 필요한데 부착되지 않음"; fi
        if [ "$EXPECT_CLSF" = 0 ] && [ "$attached" = 1 ]; then fail "조건 $CONDITION 은 분류기가 없어야 하는데 부착됨 (priority 가 오염된다)"; fi
    elif [ "$attached" = 0 ]; then
        info "분류기 없음 (noclsf 조건이거나 attach 전)"
    fi

    # [3] 카운터
    echo; echo "[3] ts_counters (per-CPU 합산)"
    local counters; counters=$(read_counters)
    info "$counters"
    if [ "$attached" = 1 ]; then
        python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("ts_udp",0)>0 else 1)' "$counters" \
            && ok "ts_udp > 0: 분류기가 UDP:$TS_PORT 패킷을 봤다" \
            || warn "ts_udp == 0: attach 이후 TS 패킷이 없었거나 분류기가 실행되지 않음 (run 뒤에 다시 확인)"
        python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("_map_count",1)<=1 else 1)' "$counters" \
            || warn "ts_counters 이름의 map 이 여럿 — 가장 최근 것을 읽었다 (테스트 잔여물? bpftool map show)"
    fi
    [ "$QUICK" = 1 ] && return 0

    # [4] qdisc 체인
    echo; echo "[4] qdisc: HTB 1: → 1:10 (${SHAPE_MBPS}mbit) → leaf 200: $([ -n "$EXPECT_LEAF" ] && echo "(기대 $EXPECT_LEAF)")"
    local qd; qd=$(tc qdisc show dev "$PHYS_IF")
    sed 's/^/       /' <<<"$qd"
    local leaf_line; leaf_line=$(grep -E '^qdisc \S+ 200:' <<<"$qd" || true)
    if grep -q '^qdisc htb 1: root' <<<"$qd"; then
        ok "root htb 1:"
        tc class show dev "$PHYS_IF" | grep -q 'class htb 1:10 ' && ok "class htb 1:10 (실험 트래픽 병목)" || fail "class htb 1:10 없음"
        local nfilt; nfilt=$(tc filter show dev "$PHYS_IF" parent 1: 2>/dev/null | grep -c 'flowid 1:10' || true)
        [ "${nfilt:-0}" -ge 1 ] && ok "u32 dst → 1:10 필터 ${nfilt}개 (listener/udp-sink Pod IP)" || fail "u32 필터 없음 — 실험 트래픽이 default class 로 간다 (셰이핑 없음)"
    elif [ -n "$leaf_line" ]; then
        warn "HTB 없이 leaf 가 root (SHAPE_MBPS=0 기능 검증 모드): 경합이 없어 latency 비교 무의미"
    else
        [ -n "$CONDITION" ] && fail "실험 qdisc 가 없음 (apply 전이거나 cleanup 됨)" || info "실험 qdisc 없음 (배포판 기본 상태)"
    fi
    if [ -n "$leaf_line" ]; then
        local kind; kind=$(awk '{print $2}' <<<"$leaf_line")
        if [ -n "$EXPECT_LEAF" ]; then
            [ "$kind" = "$EXPECT_LEAF" ] && ok "leaf 200: = $kind" || fail "leaf 200: = $kind, 기대 $EXPECT_LEAF"
        else
            ok "leaf 200: = $kind"
        fi
    fi
    echo "       --- tc -s class show dev $PHYS_IF (prio 200:1 = band 0) ---"
    tc -s class show dev "$PHYS_IF" 2>/dev/null | grep -E '^class|Sent' | sed 's/^/       /' || true
    # PHYS_IF 가 실제로 listener 로 나가는 NIC 인가 (VirtualBox NAT + host-only: default route ≠ 클러스터 NIC).
    # 틀리면 HTB/분류기가 엉뚱한 NIC 에 있고 분류기 없는 조건은 경고 없이 CSV 를 남긴다.
    local lip=""
    kube_ok && lip=$(kubectl -n "$NAMESPACE" get pod -l app=listener -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
    if [ -n "$lip" ]; then
        local rdev; rdev=$(ip -o route get "$lip" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
        if [ -z "$rdev" ]; then
            warn "ip route get $lip 실패 — PHYS_IF=$PHYS_IF 가 송신 경로인지 확인 불가"
        elif [ "$rdev" = "$PHYS_IF" ]; then
            ok "listener $lip → dev $PHYS_IF (qdisc/분류기가 붙은 NIC 가 실제 송신 경로)"
        else
            case "$rdev" in
                cilium_*|lxc*|veth*|docker*|br-*|cni*) warn "listener $lip 경로가 가상 장치 $rdev (Cilium 내부 라우팅) — PHYS_IF=$PHYS_IF 는 HTB 1:10 카운터로 확인" ;;
                *) fail "listener $lip 은 dev $rdev 로 나가는데 qdisc/분류기는 $PHYS_IF 에 있음 (NAT + host-only 2-NIC?) — experiment.env PHYS_IF=$rdev" ;;
            esac
        fi
    else
        info "listener Pod IP 를 알 수 없어 송신 경로 검사 생략 (kubectl 접근 불가 / deploy-k8s 전)"
    fi

    # [5] CPU 격리 / Pod affinity (정보)
    echo; echo "[5] CPU"
    local iso; iso=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "")
    [ -n "$iso" ] && ok "isolcpus: $iso" || info "isolcpus 없음 (/sys/devices/system/cpu/isolated 비어 있음) — LISTENER_CPU/TALKER_CPU 고정은 격리를 뜻하지 않는다"
    # [6] 클러스터
    echo; echo "[6] 클러스터"
    if command -v kubectl >/dev/null 2>&1; then
        if kube_ok; then
            local notready; notready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready ' || true)
            [ "${notready:-0}" -eq 0 ] && ok "노드 모두 Ready" || warn "Ready 가 아닌 노드 ${notready}개"
            kubectl get nodes -o wide --no-headers 2>/dev/null | sed 's/^/       /'
            local p
            for p in listener udp-sink; do
                local ready; ready=$(kubectl -n "$NAMESPACE" get pod -l "app=$p" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
                [ "$ready" = true ] && ok "$p Pod Ready" || warn "$p Pod 가 Ready 가 아님 (deploy-k8s 전?)"
            done
            local lp; lp=$(kubectl -n "$NAMESPACE" get pod -l app=listener -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            [ -n "$lp" ] && info "listener Cpus_allowed_list: $(kubectl -n "$NAMESPACE" exec "$lp" -- grep Cpus_allowed_list /proc/1/status 2>/dev/null | awk '{print $2}' || echo '?')"
            info "cilium: $(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')  routing-mode=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.routing-mode}' 2>/dev/null || echo '?')"
        else
            warn "kubectl 로 클러스터 접근 불가 (KUBECONFIG?) — 클러스터 검사 생략"
        fi
    else
        info "kubectl 없음 — 클러스터 검사 생략"
    fi
    if command -v chronyc >/dev/null 2>&1; then
        info "chrony: $(chronyc tracking 2>/dev/null | grep -E 'System time|Last offset' | tr -s ' ' | paste -sd '|' || echo '?')  (두 VM one-way latency 는 오프셋을 포함한다, ADR-0012)"
    fi
}

# =============================================================================
# results 검사 (live/offline 공통)
# =============================================================================
results_checks() {
    echo; echo "[R] 결과 CSV / meta"
    local -a dirs=("${RESULT_DIRS[@]}")
    if [ "${#dirs[@]}" -eq 0 ]; then
        if [ "$OFFLINE" = 1 ]; then
            dirs=("$ROOT_DIR/results/k8s-2026-05" "$ROOT_DIR/results")
        else
            dirs=("$RESULTS_DIR")
        fi
    fi
    local out
    out=$(python3 - "$TS_COUNT" "$TS_INTERVAL_MS" "${dirs[@]}" <<'PY'
import csv, json, os, re, statistics, sys

ts_count_default, interval_default = int(sys.argv[1]), float(sys.argv[2])
dirs = sys.argv[3:]
HEADER = ["seq", "send_ns", "recv_ns", "latency_ms", "jitter_us", "pkt_size"]
NAME_RE = re.compile(r"(_run\d+|_cpu\d+)$")
n_ok = n_warn = n_fail = 0

def ok(m):
    global n_ok; n_ok += 1; print(f"[OK]   {m}")
def warn(m):
    global n_warn; n_warn += 1; print(f"[WARN] {m}")
def fail(m):
    global n_fail; n_fail += 1; print(f"[FAIL] {m}")

files = []
for d in dirs:
    if not os.path.isdir(d):
        warn(f"디렉터리 없음: {d}")
        continue
    for root, _dirs, names in os.walk(d):
        for n in sorted(names):
            stem, ext = os.path.splitext(n)
            if ext == ".csv" and NAME_RE.search(stem):
                files.append(os.path.join(root, n))
if not files:
    fail("검사할 결과 CSV 가 없음 (<cond>_cpu<N>_run<k>.csv / <cond>_run<k>.csv / <mode>_cpu<N>.csv): " + ", ".join(dirs))

for path in files:
    rel = os.path.relpath(path, os.getcwd())
    stem = os.path.splitext(path)[0]
    meta_path = stem + ".meta.json"
    meta = None
    if os.path.exists(meta_path):
        try:
            meta = json.load(open(meta_path, encoding="utf-8"))
        except (OSError, ValueError) as e:
            fail(f"{rel}: meta.json 파싱 실패: {e}")
    legacy_v1 = "results/k8s-2026-05/" in path.replace("\\", "/")   # 2026-05 v1 데이터 (meta 이전)
    with open(path, newline="", encoding="utf-8") as f:
        rdr = csv.reader(f)
        try:
            header = next(rdr)
        except StopIteration:
            fail(f"{rel}: 빈 파일"); continue
        rows = [r for r in rdr if r]
    if header[:6] != HEADER:
        fail(f"{rel}: 헤더 {header} != {HEADER}[,tos]"); continue
    has_tos = "tos" in header
    n = len(rows)
    if n == 0:
        fail(f"{rel}: 데이터 행 없음"); continue
    try:
        seq = [int(r[0]) for r in rows]
        send = [int(r[1]) for r in rows]
    except ValueError as e:
        fail(f"{rel}: 숫자 파싱 실패: {e}"); continue
    dup = n - len(set(seq))
    mono = all(b > a for a, b in zip(seq, seq[1:]))
    gaps = [b - a for a, b in zip(send, send[1:])]
    med_ms = statistics.median(gaps) / 1e6 if gaps else float("nan")
    expect_count = meta.get("ts_count", ts_count_default) if meta else ts_count_default
    expect_int = meta.get("ts_interval_ms", interval_default) if meta else interval_default
    summary = f"{rel}: rows={n}/{expect_count} seq[{seq[0]}..{seq[-1]}] send-interval median={med_ms:.3f} ms" + \
              (" tos" if has_tos else "") + (" meta" if meta else "")
    if dup:
        fail(f"{summary} — 중복 seq {dup}개 (talker 재시도?)")
    elif not mono:
        warn(f"{summary} — seq 가 단조 증가가 아님 (재정렬)")
    else:
        ok(summary)
    if n < expect_count:
        (warn if n >= 0.5 * expect_count else fail)(f"{rel}: 수신 {n} < 송신 {expect_count} (손실 {expect_count - n}; fifo/pfifo_fast 병목에서 tail-drop 은 정상)")
    if gaps and abs(med_ms - expect_int) > 0.10 * expect_int:
        msg = f"{rel}: 송신 간격 중앙값 {med_ms:.3f} ms, 기대 {expect_int} ms ±10 %"
        if meta:
            fail(msg + " — talker 페이싱 실패 (CFS throttling / CPU 기아?)")
        else:
            warn(msg + " (v1 데이터: per-packet DNS 해석으로 알려진 페이싱 결함, README 참고)")
    if meta is None:
        (warn if legacy_v1 else fail)(f"{rel}: {os.path.basename(meta_path)} 없음" + (" (2026-05 v1 데이터, meta 이전)" if legacy_v1 else ""))
        continue
    # ── meta 기반 검사 ──
    # k8s meta 는 "classifier": bool 을 쓰고, testbed(run.sh) meta 는 조건 이름(*_clsf) 으로만 안다
    clsf = meta.get("classifier")
    if clsf is None:
        clsf = str(meta.get("condition", "")).endswith("_clsf")
    if clsf:
        d = meta.get("ts_counters") or {}
        ts_udp = d.get("ts_udp", 0)
        if ts_udp >= 0.9 * expect_count:
            ok(f"{rel}: 분류기 ts_udp 증가분 {ts_udp} ≥ 0.9×{expect_count}")
        else:
            fail(f"{rel}: 분류기 조건인데 ts_udp 증가분 {ts_udp} < 0.9×{expect_count} — 분류기가 실행되지 않았다 (tcx 순서 / legacy+Cilium)")
        if meta.get("ts_config_applied") is False:
            warn(f"{rel}: ts_config 미적용 (컴파일 타임 기본값: priority 6, DSCP 마킹 없음)")
        bands = meta.get("prio_bands") or {}
        if meta.get("condition") == "prio_clsf" and bands:
            b0 = bands.get("band0", {}).get("pkts", 0)
            (ok if b0 >= 0.9 * expect_count else fail)(f"{rel}: prio band 0 pkts 증가분 {b0} (기대 ≥ 0.9×{expect_count}); bands={ {k: v.get('pkts') for k, v in bands.items()} }")
        mark = (meta.get("ts_config") or {}).get("mark_dscp", 0)
        if mark and has_tos and meta.get("ts_config_applied", True):
            want = (meta.get("ts_config") or {}).get("dscp", 46)
            ti = header.index("tos")
            hit = sum(1 for r in rows if r[ti] not in ("", "-1") and (int(r[ti]) >> 2) == want)
            if hit == n:
                ok(f"{rel}: 수신 tos DSCP {want} = {hit}/{n} (마킹이 와이어를 지나 도착)")
            elif hit == 0:
                fail(f"{rel}: DSCP {want} 마킹이 하나도 도착하지 않음 (MARK_DSCP=1 인데) — 분류기 미실행 또는 경로에서 재기록")
            else:
                warn(f"{rel}: DSCP {want} 도착 {hit}/{n} (일부만)")
    elif (meta.get("ts_counters") or {}).get("ts_udp", 0) > 0:
        fail(f"{rel}: 분류기 없는 조건인데 ts_udp 가 {meta['ts_counters']['ts_udp']} 증가 — 분류기가 붙어 있었다 (조건 오염)")
    # k8s meta: 실험 트래픽이 병목 class 1:10 을 실제로 지났는가 (분류기 없는 조건은 이것이 유일한 신호 —
    # PHYS_IF 가 엉뚱한 NIC 이거나 u32 dst 가 틀리면 HTB 카운터가 0 인 채 CSV 만 남는다)
    if meta.get("shaper") == "htb" and "tc_class_delta" in meta:
        htb = (meta.get("tc_class_delta") or {}).get("htb 1:10", {}).get("pkts")
        if htb is None:
            warn(f"{rel}: tc_class_delta 에 'htb 1:10' 이 없음 — HTB 통과 여부 확인 불가")
        elif htb >= expect_count:
            ok(f"{rel}: HTB 1:10 통과 pkts 증가분 {htb} ≥ TS_COUNT {expect_count}")
        else:
            fail(f"{rel}: HTB 1:10 통과 pkts 증가분 {htb} < TS_COUNT {expect_count} — 실험 트래픽이 병목을 지나지 않았다 (phys_if={meta.get('phys_if')}, route_dev={meta.get('route_dev')})")
    if meta.get("git_dirty"):
        warn(f"{rel}: 측정 당시 워킹트리가 dirty (git {meta.get('git')})")
    if meta.get("cilium_routing_mode") not in (None, "", "native"):
        warn(f"{rel}: Cilium routing-mode={meta['cilium_routing_mode']} (터널) — u32/분류기가 캡슐화된 패킷을 보지 못한다")
print(f"RESULTS_SUMMARY {n_ok} {n_warn} {n_fail}")
PY
    ) || true
    grep -v '^RESULTS_SUMMARY' <<<"$out" | sed -e "s/^\[OK\]/$(printf '%b' "${GREEN}[OK]${NC}")/" \
        -e "s/^\[WARN\]/$(printf '%b' "${YELLOW}[WARN]${NC}")/" -e "s/^\[FAIL\]/$(printf '%b' "${RED}[FAIL]${NC}")/"
    local s; s=$(grep '^RESULTS_SUMMARY' <<<"$out" || echo "RESULTS_SUMMARY 0 0 1")
    N_OK=$((N_OK + $(awk '{print $2}' <<<"$s")))
    N_WARN=$((N_WARN + $(awk '{print $3}' <<<"$s")))
    N_FAIL=$((N_FAIL + $(awk '{print $4}' <<<"$s")))
}

# =============================================================================
[ "$OFFLINE" = 1 ] || live_checks
results_checks

echo
echo "================================================================"
echo "  OK=$N_OK  WARN=$N_WARN  FAIL=$N_FAIL"
echo "================================================================"
[ "$N_FAIL" -eq 0 ] || exit 1

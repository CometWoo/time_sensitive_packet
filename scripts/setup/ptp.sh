#!/bin/bash
# Step 2-4: 두 VM 사이 시간 동기화 — chrony peer 모드 (control-plane = 시간 서버, worker = 클라이언트)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - scripts/experiment.sh 는 이 파일을 호출하지 않는다 (run 은 chronyc tracking 을 meta.json 에 기록만 한다).
#   - 커밋된 결과(2026-05)의 VM 은 각자 기본 chrony(pool) 로만 동기화됐고, 이 스크립트는 실행되지 않았다.
#   - 그 데이터에서 관측된 두 VM 시계 오프셋: **14–37 ms, 실행 중 22 ms 스텝** (docs/LIMITATIONS.md,
#     ADR-0012). 그래서 두 VM one-way latency 는 절대값이 아니라 조건 간 상대 비교로만 쓴다.
#   - virtio NIC 는 하드웨어 타임스탬프가 없어 ptp4l(-S 소프트웨어) 도 NTP 급 정확도밖에 못 낸다 → 제거.
#     이 스크립트는 chrony 만 쓴다 (LAN 직결 peer 로 sub-ms 를 노린다. 보장은 못 한다).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONF=/etc/chrony/conf.d/tsn-peer.conf

usage() {
    cat <<EOF
사용법:
  sudo bash $0 master <허용 서브넷>     # control-plane: 예 192.168.56.0/24
  sudo bash $0 worker <master-ip>       # worker: 예 192.168.56.10
  bash $0 status                        # chronyc tracking / sources
EOF
}

restart_chrony() {
    sudo systemctl enable chrony >/dev/null 2>&1 || true
    sudo systemctl restart chrony
    sleep 2
}

case "${1:-}" in
    master)
        SUBNET=${2:?허용 서브넷}
        # 상위(pool) 동기화는 그대로 두고, LAN 안에서 서버 역할만 추가한다.
        # local stratum 8: 인터넷이 끊겨도 worker 에 시간을 준다 (둘의 "상대" 오프셋이 중요하다).
        cat <<EOF | sudo tee "$CONF" >/dev/null
# time_sensitive_packet — control-plane 을 worker 의 시간 서버로
allow $SUBNET
local stratum 8
EOF
        restart_chrony
        echo "master 설정 완료 ($CONF). worker 에서: sudo bash $0 worker <이 노드 IP>"
        ;;
    worker)
        MASTER=${2:?master-ip}
        # minpoll 0 maxpoll 2: 1–4 s 마다 폴링. xleave: interleaved 모드 (타임스탬프 정밀도 향상).
        # prefer + trust: pool 보다 LAN 의 master 를 우선 — 두 노드의 **상대** 오프셋을 줄이는 것이 목표.
        cat <<EOF | sudo tee "$CONF" >/dev/null
# time_sensitive_packet — control-plane($MASTER) 을 우선 시간 서버로
server $MASTER iburst minpoll 0 maxpoll 2 xleave prefer trust
EOF
        restart_chrony
        sudo chronyc makestep >/dev/null 2>&1 || true
        echo "worker 설정 완료 ($CONF)."
        ;;
    status)
        echo "--- chronyc tracking ---"; chronyc tracking 2>&1 || true
        echo "--- chronyc sources -v ---"; chronyc sources -v 2>&1 || true
        cat <<'EOF'

 판독: 'System time ... slow/fast of NTP time' 이 두 노드 모두 1 ms 아래여야 one-way latency 의
 절대값을 믿을 수 있다. 5월 측정에서는 14–37 ms 였다 — 그 데이터의 latency 는 상대 비교용이다.
 scripts/experiment.sh run 은 sender 쪽 tracking 을 meta.json(chrony_before/after) 에 남긴다;
 receiver 쪽은 이 명령으로 따로 확인한다.
EOF
        exit 0
        ;;
    *) usage; exit 2 ;;
esac
echo "확인: bash $0 status"

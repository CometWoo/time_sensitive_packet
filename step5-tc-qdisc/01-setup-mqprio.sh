#!/bin/bash
# Step 5-1: mqprio — priority → traffic class → NIC TX 큐 매핑 (논문 §IV, 4-큐 NIC)
# ──────────────────────────────────────────────────────────────────────────────
# STATUS: reference-only (2026-09)
#   - deploy-experiment.sh 는 이 파일을 호출하지 않는다. 실험은 HTB + prio 를 쓴다 (ADR-0002).
#   - 커밋된 결과(2026-05)의 VM 은 TX 큐 1개 (virtio) 라 mqprio 가 붙지 않았다 (EINVAL: num_tc 3 > TXQ).
#   - 이전 버전의 "소프트웨어 mqprio: queues 1@0 1@0 1@0 hw 0" 분기는 삭제했다 — 겹치는 큐 범위는
#     커널(mqprio_parse_opt) 이 거부하므로 애초에 동작한 적이 없다. 하드웨어 분기는 TX 큐 >= 3 에서만 시도.
#   - 이 형태로 실행된 적은 없다 (multi-queue NIC 이 있는 물리 호스트/KVM 에서만 의미가 있다).
#   - map 은 common.sh 의 TS_PRIORITY(기본 6) 로 생성: 6→tc0, 5→tc1, 나머지→tc2.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
# shellcheck source=step5-tc-qdisc/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IFACE=$(step5_iface "${1:-}")
TXQ=$(tx_queue_count "$IFACE")
MAP=$(prio_map)

echo "=========================================="
echo " mqprio  dev=$IFACE  TX queues=$TXQ  TS_PRIORITY=$TS_PRIORITY"
echo " map (skb->priority 0..15 → tc): $MAP"
echo "=========================================="

if [ "$TXQ" -lt 3 ]; then
    cat <<EOF
TX 큐 $TXQ 개 < 3: mqprio num_tc 3 는 tc 마다 서로 다른 큐가 필요하다 → 붙일 수 없다.
  (VirtualBox virtio: 1 큐. KVM 이면 'ethtool -L $IFACE combined 4' 또는 <driver queues='4'/> 로 늘릴 수 있다.)
실험은 단일 큐에서도 동작하는 HTB + prio 를 쓴다 (deploy-experiment.sh). 중단.
EOF
    exit 1
fi

# queues: tc0 → 큐0 (1개), tc1 → 큐1 (1개), tc2 → 나머지 전부 (논문: 1@0 1@1 2@2 = 4 큐)
QUEUES="1@0 1@1 $((TXQ - 2))@2"

echo -e "\n[1/3] root qdisc 초기화..."
reset_root_qdisc "$IFACE"

echo -e "\n[2/3] mqprio 추가 (hw 1 mode dcb → 실패 시 hw 0 소프트웨어 매핑, 큐는 겹치지 않음)..."
# shellcheck disable=SC2086  # MAP/QUEUES 는 의도적 단어 분리
if sudo tc qdisc add dev "$IFACE" root handle 100: mqprio num_tc 3 map $MAP queues $QUEUES hw 1 mode dcb 2>/tmp/mqprio.err; then
    echo "  hw 1 (드라이버 오프로드, DCB)"
else
    echo "  hw 1 실패: $(cat /tmp/mqprio.err) → hw 0"
    # shellcheck disable=SC2086
    sudo tc qdisc add dev "$IFACE" root handle 100: mqprio num_tc 3 map $MAP queues $QUEUES hw 0
    echo "  hw 0 (커널이 tc → 큐 선택, 드라이버 오프로드 없음)"
fi
tc qdisc show dev "$IFACE" | grep -q '^qdisc mqprio 100: root' || { show_qdisc "$IFACE"; echo "mqprio 확인 실패"; exit 1; }

echo -e "\n[3/3] 확인..."
show_qdisc "$IFACE"

cat <<EOF

==========================================
 mqprio 완료. 각 tc 의 per-queue 클래스는 100:1 (tc0 = TXQ0), 100:2 (tc1 = TXQ1), 100:3.. (tc2)
 다음: 02-setup-etf.sh (tc0 큐에 ETF)  — 단, SO_TXTIME 없는 talker 패킷은 ETF 가 버린다 (그 파일 헤더 참고)
==========================================
EOF

#!/bin/bash
# Step 7: 실험 컨테이너 빌드 및 배포
#
# 사용법:
#   bash build-and-deploy.sh build      — Docker 이미지 빌드
#   bash build-and-deploy.sh deploy     — K8s에 배포
#   bash build-and-deploy.sh run-idle   — idle 부하(10%)로 실험 실행
#   bash build-and-deploy.sh run-heavy  — 고부하(99%)로 실험 실행
#   bash build-and-deploy.sh cleanup    — 정리
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="tsn-experiment"

build_images() {
    echo "=========================================="
    echo " 이미지 준비 (ConfigMap 방식 — 빌드 불필요)"
    echo "=========================================="

    echo "python:3.11-slim base image 확인..."
    if sudo ctr -n k8s.io images ls 2>/dev/null | grep -q "python.*3.11-slim"; then
        echo "python:3.11-slim 이미지 이미 존재"
    else
        echo "python:3.11-slim 이미지 pull..."
        sudo ctr -n k8s.io images pull docker.io/library/python:3.11-slim || {
            echo "WARNING: pull 실패 — Pod 생성 시 kubelet이 자동 pull합니다"
        }
    fi
    echo ""
    echo "talker/listener 스크립트는 ConfigMap으로 전달됩니다."
    echo "커스텀 Docker 이미지 빌드가 필요 없습니다."
}

deploy() {
    echo "=========================================="
    echo " K8s 리소스 배포"
    echo "=========================================="

    kubectl apply -f "$SCRIPT_DIR/k8s/namespace.yaml"
    kubectl apply -f "$SCRIPT_DIR/k8s/listener-deployment.yaml"

    echo "Listener 파드 대기..."
    kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l app=listener --timeout=120s

    LISTENER_POD=$(kubectl -n "$NAMESPACE" get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')
    LISTENER_IP=$(kubectl -n "$NAMESPACE" get pod "$LISTENER_POD" -o jsonpath='{.status.podIP}')
    echo "Listener 파드: $LISTENER_POD (IP: $LISTENER_IP)"
}

run_experiment() {
    local CPU_LOAD="${1:-10}"
    local LABEL="${2:-idle}"

    echo "=========================================="
    echo " 실험 실행: CPU $CPU_LOAD% 부하 ($LABEL)"
    echo "=========================================="

    # 기존 talker/stress job 정리
    kubectl -n "$NAMESPACE" delete job talker-run 2>/dev/null || true
    kubectl -n "$NAMESPACE" delete ds cpu-stress 2>/dev/null || true
    sleep 5

    # CPU 부하 생성 (10% 이상일 때만)
    if [ "$CPU_LOAD" -gt 10 ]; then
        echo "CPU 부하 생성: ${CPU_LOAD}%..."
        # stress DaemonSet의 cpu-load 값 수정
        sed "s/--cpu-load\"\$/--cpu-load\"/" "$SCRIPT_DIR/k8s/stress-daemonset.yaml" | \
        sed "s/\"99\"/\"$CPU_LOAD\"/" | \
        kubectl apply -f -
        sleep 10  # 부하 안정화 대기
        echo "CPU 부하 활성화 완료"
    fi

    # Talker Job 실행
    echo "Talker 시작..."
    kubectl apply -f "$SCRIPT_DIR/k8s/talker-job.yaml"

    # 완료 대기
    echo "실험 진행 중... (최대 5분 대기)"
    kubectl -n "$NAMESPACE" wait --for=condition=complete job/talker-run --timeout=300s || true

    # 결과 수집
    echo -e "\n결과 수집..."
    LISTENER_POD=$(kubectl -n "$NAMESPACE" get pod -l app=listener -o jsonpath='{.items[0].metadata.name}')
    kubectl -n "$NAMESPACE" cp "$LISTENER_POD:/data/results.csv" \
        "$SCRIPT_DIR/results-${LABEL}-cpu${CPU_LOAD}.csv" 2>/dev/null || \
        echo "  결과 파일 복사 실패 (listener가 아직 수신 중일 수 있음)"

    TALKER_POD=$(kubectl -n "$NAMESPACE" get pod -l job-name=talker-run -o jsonpath='{.items[0].metadata.name}')
    kubectl -n "$NAMESPACE" logs "$TALKER_POD" > "$SCRIPT_DIR/talker-log-${LABEL}.txt" 2>/dev/null || true

    echo "실험 완료: $LABEL (CPU ${CPU_LOAD}%)"
    echo "  결과: results-${LABEL}-cpu${CPU_LOAD}.csv"
}

cleanup() {
    echo "=========================================="
    echo " 정리"
    echo "=========================================="
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    echo "정리 완료"
}

case "${1:-help}" in
    build)     build_images ;;
    deploy)    deploy ;;
    run-idle)  run_experiment 10 "idle" ;;
    run-heavy) run_experiment 99 "heavy" ;;
    run-mid)   run_experiment 50 "mid" ;;
    cleanup)   cleanup ;;
    help)
        echo "사용법: $0 {build|deploy|run-idle|run-mid|run-heavy|cleanup}"
        echo ""
        echo "  build      Docker 이미지 빌드 + containerd import"
        echo "  deploy     Listener 배포"
        echo "  run-idle   10% CPU 부하 실험"
        echo "  run-mid    50% CPU 부하 실험"
        echo "  run-heavy  99% CPU 부하 실험"
        echo "  cleanup    네임스페이스 및 리소스 삭제"
        ;;
esac

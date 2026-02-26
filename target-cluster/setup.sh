#!/bin/bash

# =============================================================================
# Target Cluster Setup Script
# - apps: TC 기본 앱 컨테이너
# - monitoring: Prometheus/cAdvisor/Promtail (CJ 연동 브리지)
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF2
Usage: $0 [OPTIONS]

Target Cluster 설치 스크립트

OPTIONS:
    -h, --help            이 도움말 표시
    --no-pull             이미지 pull 건너뜀
    --apps-only           앱 컨테이너만 실행 (기본값)
    --prometheus-only     Prometheus + cAdvisor + Promtail 실행
    --all                 앱 + 모니터링 브리지 전체 실행

EXAMPLES:
    $0                    # 앱 컨테이너만 시작
    $0 --apps-only        # 앱만 실행
    $0 --prometheus-only  # 모니터링 브리지 실행
    $0 --all              # 전체 실행
EOF2
    exit 0
}

PULL_IMAGES=true
MODE="apps"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --no-pull)
            PULL_IMAGES=false
            shift
            ;;
        --apps-only)
            MODE="apps"
            shift
            ;;
        --prometheus-only)
            MODE="prometheus"
            shift
            ;;
        --all)
            MODE="all"
            shift
            ;;
        *)
            log_error "알 수 없는 옵션: $1"
            usage
            ;;
    esac
done

log_info "Target Cluster 설치를 시작합니다..."

if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker가 설치되어 있지 않습니다. 먼저 Docker를 설치해주세요."
    exit 1
fi
log_success "Docker 확인 완료"

if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose가 설치되어 있지 않습니다. 먼저 Docker Compose를 설치해주세요."
    exit 1
fi
log_success "Docker Compose 확인 완료"

port_in_use() {
    local port="$1"
    lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1
}

check_port() {
    local port="$1"
    if port_in_use "$port"; then
        log_warning "포트 $port가 이미 사용 중입니다."
        return 1
    fi
    return 0
}

candidate_ports() {
    local seed="${PROMETHEUS_PORT_CANDIDATES:-9091 19091 29091 39091}"
    local requested="${PROMETHEUS_HOST_PORT:-}"
    local seen=" "

    if [ -n "$requested" ]; then
        echo -n "$requested "
        seen="$seen$requested "
    fi

    for p in $seed; do
        if [[ "$seen" != *" $p "* ]]; then
            echo -n "$p "
            seen="$seen$p "
        fi
    done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
MONITOR_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.monitoring.yml"

if [ ! -f "$APP_COMPOSE_FILE" ]; then
    log_error "앱 compose 파일을 찾을 수 없습니다: $APP_COMPOSE_FILE"
    exit 1
fi

if { [ "$MODE" = "prometheus" ] || [ "$MODE" = "all" ]; } && [ ! -f "$MONITOR_COMPOSE_FILE" ]; then
    log_error "모니터링 compose 파일을 찾을 수 없습니다: $MONITOR_COMPOSE_FILE"
    exit 1
fi

COMPOSE_FILE_ARGS=()
if [ "$MODE" = "apps" ]; then
    COMPOSE_FILE_ARGS=(-f "$APP_COMPOSE_FILE")
elif [ "$MODE" = "prometheus" ]; then
    COMPOSE_FILE_ARGS=(-f "$MONITOR_COMPOSE_FILE")
else
    COMPOSE_FILE_ARGS=(-f "$APP_COMPOSE_FILE" -f "$MONITOR_COMPOSE_FILE")
fi

compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose "${COMPOSE_FILE_ARGS[@]}" "$@"
    else
        docker compose "${COMPOSE_FILE_ARGS[@]}" "$@"
    fi
}

compose_up() {
    compose_cmd up -d "$@"
}

compose_pull() {
    compose_cmd pull "$@"
}

start_with_prometheus_port_retry() {
    local services=("$@")
    local output=""
    local tried_any=false

    for port in $(candidate_ports); do
        tried_any=true

        if port_in_use "$port"; then
            log_warning "포트 $port가 이미 사용 중입니다. 다음 후보를 시도합니다."
            continue
        fi

        export PROMETHEUS_HOST_PORT="$port"
        log_info "Prometheus 호스트 포트 시도: $PROMETHEUS_HOST_PORT"

        if output=$(compose_up "${services[@]}" 2>&1); then
            [ -n "$output" ] && echo "$output"
            return 0
        fi

        echo "$output"
        if echo "$output" | grep -q "ports are not available"; then
            log_warning "포트 $port 바인딩 실패. 다음 후보를 시도합니다."
            continue
        fi

        log_error "컨테이너 시작 실패"
        return 1
    done

    if [ "$tried_any" = false ]; then
        log_error "Prometheus 포트 후보가 비어 있습니다. PROMETHEUS_PORT_CANDIDATES를 확인하세요."
    else
        log_error "사용 가능한 Prometheus 포트를 찾지 못했습니다."
    fi
    return 1
}

if [ "$MODE" = "apps" ]; then
    PORTS=(8081 8082)
elif [ "$MODE" = "prometheus" ]; then
    PORTS=(8080)
else
    PORTS=(8081 8082 8080)
fi

PORT_CONFLICT=false
for port in "${PORTS[@]}"; do
    if ! check_port "$port"; then
        PORT_CONFLICT=true
    fi
done

if [ "$PORT_CONFLICT" = true ]; then
    log_error "필수 포트 중 하나가 이미 사용 중입니다. 충돌하는 서비스를 먼저 중지해주세요."
    exit 1
fi
log_success "포트 충돌 체크 완료"

cd "$SCRIPT_DIR"
log_info "작업 디렉토리: $SCRIPT_DIR"

if [ -z "$DOCKER_CONFIG" ]; then
    DOCKER_CONFIG="$SCRIPT_DIR/.docker"
    export DOCKER_CONFIG
fi
mkdir -p "$DOCKER_CONFIG"
if [ ! -f "$DOCKER_CONFIG/config.json" ]; then
    printf "{}" > "$DOCKER_CONFIG/config.json"
fi

log_info "Docker 네트워크 생성 중..."
docker network create tc-network 2>/dev/null || log_warning "네트워크가 이미 존재합니다."
APP_CONTAINERS="internal-dummy-server llm-train-master llm-train-worker-01 hf-data-loader bpe-tokenizer-engine corpus-quality-filter synthetic-data-generator lora-adapter-trainer wandb-tracking-agent rag-embedding-cache text-embedding-server truth-checker-model model-checkpoint-zipper kube-karpenter-agent lustre-csi-driver eval-harness-runner finished-llama-tuning oom-hung-trainer s3-auth-failed-loader disk-full-saver orphaned-jupyter-lab v1-inference-endpoint gpu-pending-zombie s3-checkpoint-syncer daily-corpus-validator gpu-lock-sweeper inference-metrics-aggregator weekly-cache-evictor hf-model-syncer nvidia-smi-alerter midnight-rlhf-cron"

if [ "$PULL_IMAGES" = true ]; then
    log_info "Docker 이미지 다운로드 중..."
    if [ "$MODE" = "apps" ]; then
        compose_pull $APP_CONTAINERS || log_warning "이미지 pull 중 일부 오류 발생 (무시)"
    elif [ "$MODE" = "prometheus" ]; then
        compose_pull prometheus cadvisor promtail || log_warning "이미지 pull 중 일부 오류 발생 (무시)"
    else
        compose_pull || log_warning "이미지 pull 중 일부 오류 발생 (무시)"
    fi
    log_success "이미지 다운로드 완료"
fi

log_info "컨테이너 시작 중..."
if [ "$MODE" = "apps" ]; then
    compose_up -d $APP_CONTAINERS
elif [ "$MODE" = "prometheus" ]; then
    start_with_prometheus_port_retry prometheus cadvisor promtail
else
    compose_up -d $APP_CONTAINERS
    start_with_prometheus_port_retry prometheus cadvisor promtail
fi
log_success "컨테이너 시작 완료"

wait_for_container() {
    local container_name="$1"
    local max_wait=30
    local count=0

    log_info "$container_name 컨테이너가 실행될 때까지 대기 중..."
    while [ "$count" -lt "$max_wait" ]; do
        if docker ps --format '{{.Names}}' | grep -q "$container_name"; then
            log_success "$container_name 실행 중"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    log_error "$container_name가 실행되지 않았습니다."
    return 1
}

if [ "$MODE" != "apps" ]; then
    wait_for_container "target-prometheus"
    
    # Kind 네트워크에 연결 (CJ에서 접근 가능하도록)
    if docker network inspect kind &>/dev/null; then
        log_info "Kind 네트워크에 Prometheus 연결 중..."
        docker network connect kind target-prometheus 2>/dev/null || log_warning "Kind 네트워크 연결 실패 (무시)"
    fi
    wait_for_container "cadvisor"

    log_info "Prometheus 헬스 체크 중..."
    sleep 5

    MAX_PROM_CHECK=10
    PROM_CHECK_COUNT=0
    while [ "$PROM_CHECK_COUNT" -lt "$MAX_PROM_CHECK" ]; do
        if curl -s "http://localhost:${PROMETHEUS_HOST_PORT:-9091}/-/healthy" >/dev/null 2>&1; then
            log_success "Prometheus가 정상적으로 실행 중입니다."
            break
        fi
        sleep 2
        PROM_CHECK_COUNT=$((PROM_CHECK_COUNT + 1))
    done

    if [ "$PROM_CHECK_COUNT" -eq "$MAX_PROM_CHECK" ]; then
        log_warning "Prometheus 헬스 체크 실패 (나중에 확인 필요)"
    fi
fi

if [ "$MODE" = "apps" ]; then
    echo ""
    echo "=========================================="
    echo "Target 앱 컨테이너 설치 완료"
    echo "=========================================="
    echo ""
    echo "서비스:"
    echo "   - Active App:       http://localhost:8081"
    echo "   - Zombie Test App:  http://localhost:8082"
    echo ""
    echo "실행 중인 컨테이너:"
    docker ps --format "   - {{.Names}} ({{.Status}})" --filter "network=tc-network"
    echo ""
    echo "다음 명령어:"
    echo "   - 모니터링 브리지 시작: ./setup.sh --prometheus-only"
    echo ""
    exit 0
fi

if [ "$MODE" = "prometheus" ]; then
    echo ""
    echo "=========================================="
    echo "Target 모니터링 브리지 설치 완료"
    echo "=========================================="
    echo ""
    echo "서비스:"
    echo "   - Prometheus:       http://localhost:${PROMETHEUS_HOST_PORT:-9091}"
    echo "   - cAdvisor:         http://localhost:8080"
    echo "   - Promtail:         docker logs -f promtail"
    echo ""
    echo "실행 중인 컨테이너:"
    docker ps --format "   - {{.Names}} ({{.Status}})" --filter "network=tc-network"
    echo ""
    echo "다음 명령어:"
    echo "   - TC 연결 요청: ./setup-connection-to-cj.sh -a <CJ_HOST>"
    echo ""
    exit 0
fi

echo ""
echo "=========================================="
echo "Target 전체 설치 완료"
echo "=========================================="
echo ""
echo "서비스:"
echo "   - Prometheus:       http://localhost:${PROMETHEUS_HOST_PORT:-9091}"
echo "   - cAdvisor:         http://localhost:8080"
echo "   - Active App:       http://localhost:8081"
echo "   - Zombie Test App:  http://localhost:8082"
echo ""
echo "실행 중인 컨테이너:"
docker ps --format "   - {{.Names}} ({{.Status}})" --filter "network=tc-network"
echo ""

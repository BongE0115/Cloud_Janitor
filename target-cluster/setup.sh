#!/bin/bash

# =============================================================================
# Target Cluster Setup Script
# Prometheus + 더미 컨테이너로 구성된 Target Cluster 설치
# =============================================================================

set -e  # 에러 발생 시 즉시 종료

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
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

# 사용법 출력
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Target Cluster 설치 스크립트

OPTIONS:
    -h, --help      이 도움말을 표시
    --no-pull       이미지 pull 건너뜀
    --detach        백그라운드 모드로 실행 (기본값)
    --apps-only     앱 컨테이너만 실행
    --prometheus-only  Prometheus와 cAdvisor만 실행

EXAMPLES:
    $0                    # 기본 설치
    $0 --no-pull          # 이미지 pull 없이 설치
    $0 --apps-only        # 앱만 실행
    $0 --prometheus-only  # Prometheus만 실행
EOF
    exit 0
}

# 파라미터 파싱
PULL_IMAGES=true
DETACH=true
MODE="all"

for arg in "$@"; do
    case $arg in
        -h|--help)
            usage
            ;;
    --no-pull)
            PULL_IMAGES=false
            ;;
        --detach)
            DETACH=true
            ;;
    --apps-only)
        MODE="apps"
        ;;
    --prometheus-only)
        MODE="prometheus"
        ;;
        *)
            log_error "알 수 없는 옵션: $arg"
            usage
            ;;
    esac
done

# =============================================================================
# 사전 체크
# =============================================================================

log_info "Target Cluster 설치를 시작합니다..."

# Docker 체크
if ! command -v docker &> /dev/null; then
    log_error "Docker가 설치되어 있지 않습니다. 먼저 Docker를 설치해주세요."
    exit 1
fi

log_success "Docker 확인 완료"

# Docker Compose 체크
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    log_error "Docker Compose가 설치되어 있지 않습니다. 먼저 Docker Compose를 설치해주세요."
    exit 1
fi

log_success "Docker Compose 확인 완료"

# 포트 충돌 체크
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        log_warning "포트 $port가 이미 사용 중입니다."
        return 1
    fi
    return 0
}

if [ "$MODE" = "apps" ]; then
    PORTS=(8081 8082)
elif [ "$MODE" = "prometheus" ]; then
    PORTS=(9091 8080)
else
    PORTS=(9091 8081 8082 8080)
fi
PORT_CONFLICT=false

for port in "${PORTS[@]}"; do
    if ! check_port $port; then
        PORT_CONFLICT=true
    fi
done

if [ "$PORT_CONFLICT" = true ]; then
    log_error "필수 포트 중 하나가 이미 사용 중입니다. 충돌하는 서비스를 먼저 중지해주세요."
    exit 1
fi

log_success "포트 충돌 체크 완료"

# =============================================================================
# 설치 시작
# =============================================================================

# 스크립트 디렉토리로 이동
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Docker 네트워크 생성 (이미 존재하면 무시)
log_info "Docker 네트워크 생성 중..."
docker network create tc-network 2>/dev/null || log_warning "네트워크가 이미 존재합니다."

# 이미지 풀
if [ "$PULL_IMAGES" = true ]; then
    log_info "Docker 이미지 다운로드 중..."
    docker-compose pull || log_warning "이미지 pull 중 일부 오류 발생 (무시)"
    log_success "이미지 다운로드 완료"
fi

# 컨테이너 시작
log_info "컨테이너 시작 중..."
if [ "$MODE" = "apps" ]; then
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d promtail app-active app-zombie-sleeper app-zombie-completed app-zombie-test app-zombie-dev
    else
        docker compose up -d promtail app-active app-zombie-sleeper app-zombie-completed app-zombie-test app-zombie-dev
    fi
elif [ "$MODE" = "prometheus" ]; then
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d prometheus cadvisor promtail
    else
        docker compose up -d prometheus cadvisor promtail
    fi
else
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
fi

log_success "컨테이너 시작 완료"

# =============================================================================
# 설치 후 검증
# =============================================================================

log_info "컨테이너 상태 확인 중..."

# 대기 함수
wait_for_container() {
    local container_name=$1
    local max_wait=30
    local count=0

    log_info "$container_name 컨테이너가 실행될 때까지 대기 중..."

    while [ $count -lt $max_wait ]; do
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

MAX_PROM_CHECK=0
PROM_CHECK_COUNT=0

if [ "$MODE" != "apps" ]; then
    wait_for_container "target-prometheus"
    wait_for_container "cadvisor"

    log_info "Prometheus 헬스 체크 중..."
    sleep 5

    MAX_PROM_CHECK=10

    while [ $PROM_CHECK_COUNT -lt $MAX_PROM_CHECK ]; do
        if curl -s http://localhost:9091/-/healthy > /dev/null 2>&1; then
            log_success "Prometheus가 정상적으로 실행 중입니다."
            break
        fi
        sleep 2
        PROM_CHECK_COUNT=$((PROM_CHECK_COUNT + 1))
    done
    if [ $PROM_CHECK_COUNT -eq $MAX_PROM_CHECK ]; then
        log_warning "Prometheus 헬스 체크 실패 (나중에 확인 필요)"
    fi
fi

if [ "$MODE" = "apps" ]; then
    echo ""
    echo "=========================================="
    echo "🎉 Target 앱 컨테이너 설치 완료!"
    echo "=========================================="
    echo ""
    echo "📊 주요 서비스:"
    echo "   - Active App:       http://localhost:8081"
    echo "   - Zombie Test App:  http://localhost:8082"
    echo ""
    echo "📦 실행 중인 컨테이너:"
    docker ps --format "   - {{.Names}} ({{.Status}})" --filter "network=tc-network"
    echo ""
    echo "🧟 좀비 컨테이너 (Cloud Janitor 삭제 대상):"
    docker ps --format "   - {{.Names}} (zombie-type: {{.Labels}})" --filter "label=app-type=zombie" 2>/dev/null || log_warning "좀비 컨테이너를 찾을 수 없습니다."
    echo ""
    echo "🔧 유용한 명령어:"
    echo "   - 로그 확인:     docker-compose logs -f [container_name]"
    echo "   - 컨테이너 목록: docker-compose ps"
    echo "   - 전체 중지:     ./teardown.sh"
    echo "   - Prometheus 시작: ./setup.sh --prometheus-only"
    echo ""
    echo "➡️  다음 명령어:"
    echo "   ./setup.sh --prometheus-only"
    echo ""
    exit 0
fi

if [ "$MODE" = "prometheus" ]; then
    echo ""
    echo "=========================================="
    echo "🎉 Target Prometheus 설치 완료!"
    echo "=========================================="
    echo ""
    echo "📊 주요 서비스:"
    echo "   - Prometheus:       http://localhost:9091"
    echo "   - cAdvisor:        http://localhost:8080"
    echo ""
    echo "📦 실행 중인 컨테이너:"
    docker ps --format "   - {{.Names}} ({{.Status}})" --filter "network=tc-network"
    echo ""
    echo "🔧 유용한 명령어:"
    echo "   - 로그 확인:     docker-compose logs -f [container_name]"
    echo "   - 컨테이너 목록: docker-compose ps"
    echo "   - 전체 중지:     ./teardown.sh"
    echo ""
    echo "➡️  다음 명령어:"
    echo "   cj setup"
    echo ""
    exit 0
fi

# =============================================================================
# 설치 완료 요약
# =============================================================================

echo ""
echo "=========================================="
echo "🎉 Target Cluster 설치 완료!"
echo "=========================================="
echo ""
echo "📊 주요 서비스:"
echo "   - Prometheus:       http://localhost:9091"
echo "   - cAdvisor:        http://localhost:8080"
echo "   - Active App:       http://localhost:8081"
echo "   - Zombie Test App:  http://localhost:8082"
echo ""
echo "📦 실행 중인 컨테이너:"
docker ps --format "   - {{.Names}} ({{.Status}})" --filter "network=tc-network"
echo ""
echo "🧟 좀비 컨테이너 (Cloud Janitor 삭제 대상):"
docker ps --format "   - {{.Names}} (zombie-type: {{.Labels}})" --filter "label=app-type=zombie" 2>/dev/null || log_warning "좀비 컨테이너를 찾을 수 없습니다."
echo ""
echo "🔧 유용한 명령어:"
echo "   - 로그 확인:     docker-compose logs -f [container_name]"
echo "   - 컨테이너 목록: docker-compose ps"
echo "   - 전체 중지:     ./teardown.sh"
echo "   - Prometheus UI: http://localhost:9091"
echo ""
echo "📝 PromQL 쿼리 예시 (Cloud Janitor에서 사용):"
echo "   - CPU 낮은 컨테이너:"
echo "     rate(container_cpu_usage_seconds_total{name!=\"\"}[2m]) < 0.01"
echo ""
echo "   - 네트워크 낮은 컨테이너:"
echo "     rate(container_network_receive_bytes_total{name!=\"\"}[2m]) < 100"
echo ""

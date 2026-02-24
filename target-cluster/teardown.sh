#!/bin/bash

# =============================================================================
# Target Cluster Teardown Script
# Prometheus + 더미 컨테이너로 구성된 Target Cluster 삭제
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

Target Cluster 삭제 스크립트

OPTIONS:
    -h, --help      이 도움말을 표시
    --volumes       볼륨까지 모두 삭제 (데이터 손실 주의)
    --all           컨테이너, 네트워크, 볼륨 모두 삭제

EXAMPLES:
    $0                    # 컨테이너만 중지 및 삭제
    $0 --volumes          # 컨테이너 + 볼륨 삭제
    $0 --all              # 모든 리소스 삭제 (네트워크 포함)
EOF
    exit 0
}

# 파라미터 파싱
REMOVE_VOLUMES=false
REMOVE_ALL=false

for arg in "$@"; do
    case $arg in
        -h|--help)
            usage
            ;;
        --volumes)
            REMOVE_VOLUMES=true
            ;;
        --all)
            REMOVE_VOLUMES=true
            REMOVE_ALL=true
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

log_info "Target Cluster 삭제를 시작합니다..."

# Docker 체크
if ! command -v docker &> /dev/null; then
    log_error "Docker가 설치되어 있지 않습니다."
    exit 1
fi

# 스크립트 디렉토리로 이동
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log_info "작업 디렉토리: $SCRIPT_DIR"

APP_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
MONITOR_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.monitoring.yml"
COMPOSE_FILE_ARGS=()

if [ -f "$APP_COMPOSE_FILE" ]; then
    COMPOSE_FILE_ARGS+=(-f "$APP_COMPOSE_FILE")
fi
if [ -f "$MONITOR_COMPOSE_FILE" ]; then
    COMPOSE_FILE_ARGS+=(-f "$MONITOR_COMPOSE_FILE")
fi

if [ "${#COMPOSE_FILE_ARGS[@]}" -eq 0 ]; then
    log_error "Compose 파일을 찾을 수 없습니다."
    exit 1
fi

compose_down() {
    if command -v docker-compose &> /dev/null; then
        docker-compose "${COMPOSE_FILE_ARGS[@]}" down "$@"
    else
        docker compose "${COMPOSE_FILE_ARGS[@]}" down "$@"
    fi
}

# =============================================================================
# 컨테이너 삭제
# =============================================================================

log_info "실행 중인 컨테이너 목록 확인..."

# 컨테이너 개수 확인
CONTAINER_COUNT=$(docker ps -q --filter "network=tc-network" | wc -l)

if [ "$CONTAINER_COUNT" -eq 0 ]; then
    log_warning "삭제할 컨테이너가 없습니다."
else
    log_info "$CONTAINER_COUNT 개의 컨테이너가 실행 중입니다."

    # 컨테이너 중지
    log_info "컨테이너 중지 중..."
    compose_down

    log_success "컨테이너 중지 완료"
fi

# =============================================================================
# 볼륨 삭제 (옵션)
# =============================================================================

if [ "$REMOVE_VOLUMES" = true ]; then
    log_info "볼륨 삭제 중..."
    compose_down -v

    log_success "볼륨 삭제 완료"
else
    log_info "볼륨은 유지됩니다. (삭제하려면 --volumes 또는 --all 옵션 사용)"
fi

# =============================================================================
# 네트워크 삭제 (옵션)
# =============================================================================

if [ "$REMOVE_ALL" = true ]; then
    log_info "Docker 네트워크 삭제 중..."

    if docker network ls --format '{{.Name}}' | grep -q "tc-network"; then
        docker network rm tc-network
        log_success "네트워크 삭제 완료"
    else
        log_warning "네트워크를 찾을 수 없습니다."
    fi
else
    log_info "Docker 네트워크는 유지됩니다. (삭제하려면 --all 옵션 사용)"
fi

# =============================================================================
# 삭제 완료 요약
# =============================================================================

echo ""
echo "=========================================="
echo "🗑️  Target Cluster 삭제 완료!"
echo "=========================================="
echo ""

# 남은 리소스 확인
REMAINING_CONTAINERS=$(docker ps -q --filter "network=tc-network" | wc -l)
if [ "$REMAINING_CONTAINERS" -eq 0 ]; then
    log_success "모든 컨테이너가 삭제되었습니다."
else
    log_warning "$REMAINING_CONTAINERS 개의 컨테이너가 여전히 실행 중입니다."
    docker ps --filter "network=tc-network"
fi

if [ "$REMOVE_ALL" = false ]; then
    log_info "네트워크가 유지되었습니다. 완전히 삭제하려면:"
    echo "   $0 --all"
fi

echo ""
echo "🔧 유용한 명령어:"
echo "   - 다시 시작:     ./setup.sh"
echo "   - 컨테이너 목록: docker ps -a --filter \"network=tc-network\""
echo "   - 네트워크 확인: docker network ls | grep tc-network"
echo ""

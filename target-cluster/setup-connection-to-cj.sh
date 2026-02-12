#!/bin/bash

# =============================================================================
# TC → cj 연결 요청 스크립트
# Target Cluster(TC)에서 Cloud Janitor(cj)로 연결 요청 전송
# =============================================================================

set -e  # 에러 발생 시 즉시 종료

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_step() {
    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}==========================================${NC}"
}

# 사용법 출력
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

TC(Target Cluster) → cj(Cloud Janitor) 연결 요청 스크립트

OPTIONS:
    -h, --help              이 도움말을 표시
    -a, --cj-host HOST      cj(Cloud Janitor) 주소 (필수)
    -p, --cj-port PORT      cj API 포트 (기본값: 30800)
    -n, --name NAME         TC 이름 (기본값: tc-target)
    --prom-url URL          TC Prometheus URL (기본값: http://localhost:9091)
    --docker-url URL        TC Docker API URL (기본값: unix:///var/run/docker.sock)
    --labels KEY=VALUE      TC 라벨 (여러 개 가능)
    --check                연결 상태만 확인

EXAMPLES:
    $0 -a localhost                           # 로컬 cj에 연결
    $0 -a 192.168.1.100 -n production-tc   # 원격 cj에 연결
    $0 --check                               # 연결 상태 확인

DESCRIPTION:
    이 스크립트는 TC에서 실행하여 cj에 연결 요청을 전송합니다.
    cj가 요청을 받고 TC Prometheus를 모니터링 대상으로 등록합니다.

    연결 요청: TC → cj (이 스크립트 실행)
    모니터링: cj → TC (자동으로 시작됨)
      - cj가 TC Prometheus를 정기 폴링
      - cj가 TC Docker API로 좀비 컨테이너 삭제
      - cj가 cj MySQL에 삭제 기록 저장

    cj는 Terraform과 Ansible으로만 배포하면 됩니다.
    Cloud Janitor 앱이 자동으로 TC를 모니터링합니다.
EOF
    exit 0
}

# 파라미터 파싱
CJ_HOST=""
CJ_PORT="30800"
TC_NAME="tc-target"
TC_PROM_URL="http://localhost:9091"
TC_DOCKER_URL="unix:///var/run/docker.sock"
TC_LABELS=()
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -a|--cj-host)
            CJ_HOST="$2"
            shift 2
            ;;
        -p|--cj-port)
            CJ_PORT="$2"
            shift 2
            ;;
        -n|--name)
            TC_NAME="$2"
            shift 2
            ;;
        --prom-url)
            TC_PROM_URL="$2"
            shift 2
            ;;
        --docker-url)
            TC_DOCKER_URL="$2"
            shift 2
            ;;
        --labels)
            TC_LABELS+=("$2")
            shift 2
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        *)
            log_error "알 수 없는 옵션: $1"
            usage
            ;;
    esac
done

# =============================================================================
# 사전 체크
# =============================================================================

log_step "🔍 사전 체크"

# cj 주소 필수 확인
if [ -z "$CJ_HOST" ]; then
    log_error "cj 주소가 필요합니다. -a 또는 --cj-host 옵션을 사용하세요."
    usage
fi

log_success "cj 주소: $CJ_HOST:$CJ_PORT"

# TC Prometheus 실행 확인
log_info "TC Prometheus 실행 상태 확인..."

if curl -s "$TC_PROM_URL/-/healthy" > /dev/null 2>&1; then
    log_success "TC Prometheus가 실행 중입니다: $TC_PROM_URL"
else
    log_warning "TC Prometheus에 연결할 수 없습니다: $TC_PROM_URL"
    log_info "Prometheus가 실행 중인지 확인해주세요."
    read -p "계속 진행하시겠습니까? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# =============================================================================
# 연결 요청 데이터 준비
# =============================================================================

log_step "📤 연결 요청 데이터 준비"

# TC 정보 수집
TC_HOSTNAME=$(hostname)
TC_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
TC_OS=$(uname -s)
TC_ARCH=$(uname -m)

log_info "TC 정보:"
log_info "  - 이름:     $TC_NAME"
log_info "  - 호스트네임: $TC_HOSTNAME"
log_info "  - IP:       $TC_IP"
log_info "  - OS:       $TC_OS"
log_info "  - 아키텍처: $TC_ARCH"
log_info "  - Prometheus: $TC_PROM_URL"

# 라벨 포맷팅
LABELS_JSON="{}"
for label in "${TC_LABELS[@]}"; do
    key=$(echo "$label" | cut -d'=' -f1)
    value=$(echo "$label" | cut -d'=' -f2-)
    LABELS_JSON=$(echo "$LABELS_JSON" | sed "s/{}/{\"$key\":\"$value\",/g" | sed 's/,$//')
done

# JSON 요청 본문 생성
REQUEST_BODY=$(cat << EOF
{
  "tc_name": "$TC_NAME",
  "tc_hostname": "$TC_HOSTNAME",
  "tc_ip": "$TC_IP",
  "tc_os": "$TC_OS",
  "tc_arch": "$TC_ARCH",
  "prometheus_url": "$TC_PROM_URL",
  "docker_api_url": "$TC_DOCKER_URL",
  "labels": $LABELS_JSON,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

log_info "요청 본문:"
echo "$REQUEST_BODY" | python3 -m json.tool 2>/dev/null || echo "$REQUEST_BODY"

# =============================================================================
# 연결 상태 확인
# =============================================================================

check_connection() {
    log_step "🔍 연결 상태 확인"

    local cj_url="http://$CJ_HOST:$CJ_PORT"

    log_info "cj API에 연결 중: $cj_url"

    if curl -s "$cj_url/health" > /dev/null 2>&1; then
        log_success "cj API에 연결되었습니다."

        # 등록된 TC 목록 확인
        log_info "등록된 TC 목록 확인 중..."
        REGISTERED_TCS=$(curl -s "$cj_url/api/v1/targets" 2>/dev/null || echo "[]")

        echo ""
        echo "📋 등록된 TC 목록:"
        echo "$REGISTERED_TCS" | python3 -m json.tool 2>/dev/null || echo "$REGISTERED_TCS"
        echo ""

        # 현재 TC가 등록되었는지 확인
        if echo "$REGISTERED_TCS" | grep -q "\"tc_name\":\"$TC_NAME\""; then
            log_success "TC '$TC_NAME'가 cj에 등록되어 있습니다."
        else
            log_warning "TC '$TC_NAME'가 cj에 등록되어 있지 않습니다."
        fi

        return 0
    else
        log_error "cj API에 연결할 수 없습니다: $cj_url"
        log_info "다음을 확인해주세요:"
        echo "   1. cj가 실행 중인지 확인 (Terraform + Ansible으로 배포)"
        echo "   2. cj API 포트가 올바른지 확인: $CJ_PORT"
        echo "   3. 네트워크 연결을 확인"
        echo "   4. 방화벽 설정을 확인"
        echo ""
        return 1
    fi
}

if [ "$CHECK_ONLY" = true ]; then
    check_connection
    exit $?
fi

# =============================================================================
# cj에 연결 요청 전송
# =============================================================================

log_step "📡 cj에 연결 요청 전송"

CJ_URL="http://$CJ_HOST:$CJ_PORT/api/v1/register"

log_info "요청 전송 중: $CJ_URL"
log_info "TC: $TC_NAME → cj: $CJ_HOST:$CJ_PORT"

# 요청 전송
RESPONSE=$(curl -s -X POST "$CJ_URL" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY" \
    -w "\nHTTP_CODE:%{http_code}")

# HTTP 상태 코드 추출
HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d':' -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed 's/HTTP_CODE:[0-9]*//g')

# 응답 표시
log_info "cj 응답:"
echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"

# 성공 여부 확인
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    log_success "연결 요청이 성공했습니다! (HTTP $HTTP_CODE)"

    # 응답에서 메시지 추출
    SUCCESS_MSG=$(echo "$RESPONSE_BODY" | python3 -c "import sys, json; print(json.load(sys.stdin).get('message', 'No message'))" 2>/dev/null || echo "등록 완료")

    log_success "$SUCCESS_MSG"

    # =============================================================================
    # 연결 요청 완료 요약
    # =============================================================================

    log_step "🎉 연결 요청 완료!"

    echo ""
    echo "=========================================="
    echo "📊 TC → cj 연결 정보"
    echo "=========================================="
    echo ""
    echo "🎯 TC (Target Cluster):"
    echo "   - 이름:        $TC_NAME"
    echo "   - 호스트네임:   $TC_HOSTNAME"
    echo "   - IP:          $TC_IP"
    echo "   - Prometheus:   $TC_PROM_URL"
    echo "   - Docker API:  $TC_DOCKER_URL"
    echo ""
    echo "🎛️ cj (Cloud Janitor):"
    echo "   - 주소:        $CJ_HOST:$CJ_PORT"
    echo "   - 상태:        등록 완료"
    echo ""
    echo "📝 동작 방식:"
    echo "   1. TC가 cj에 연결 요청 전송 ✓ (이 스크립트)"
    echo "   2. cj가 TC를 모니터링 대상으로 등록 ✓"
    echo "   3. cj가 TC Prometheus를 정기 폴링 (자동)"
    echo "   4. cj가 TC Docker API로 좀비 컨테이너 삭제 (자동)"
    echo "   5. cj가 cj MySQL에 삭제 기록 저장 (자동)"
    echo ""
    echo "✨ cj 배포 방법:"
    echo "   cd .."
    echo "   ./scripts/deploy-all.sh --skip-target"
    echo ""
    echo "   cj는 Terraform + Ansible으로만 배포하면 됩니다."
    echo "   Cloud Janitor 앱이 자동으로 TC를 모니터링합니다."
    echo ""
    echo "🔧 유용한 명령어:"
    echo "   - 연결 상태:      $0 --check -a $CJ_HOST"
    echo "   - cj 로그:        kubectl logs -n default deployment/cloud-janitor"
    echo "   - TC Prom UI:     $TC_PROM_URL"
    echo ""
    echo "📊 PromQL 쿼리 (cj에서 사용):"
    echo "   - CPU 낮은 컨테이너:"
    echo "     rate(container_cpu_usage_seconds_total[2m]) < 0.01"
    echo ""
    echo "   - 네트워크 낮은 컨테이너:"
    echo "     rate(container_network_receive_bytes_total[2m]) < 100"
    echo ""

else
    log_error "연결 요청이 실패했습니다. (HTTP $HTTP_CODE)"

    # 오류 메시지 추출
    ERROR_MSG=$(echo "$RESPONSE_BODY" | python3 -c "import sys, json; print(json.load(sys.stdin).get('error', 'Unknown error'))" 2>/dev/null || echo "알 수 없는 오류")

    log_error "오류: $ERROR_MSG"

    echo ""
    log_info "다음을 확인해주세요:"
    echo "   1. cj가 실행 중인지 확인 (Terraform + Ansible으로 배포)"
    echo "   2. cj API 포트가 올바른지 확인: $CJ_PORT"
    echo "   3. cj가 TC 접속을 허용하는지 확인 (방화벽, 네트워크)"
    echo "   4. cj API 엔드포인트가 올바른지 확인: $CJ_URL"
    echo ""

    exit 1
fi

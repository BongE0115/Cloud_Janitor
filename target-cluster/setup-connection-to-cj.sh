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
    -p, --cj-port PORT      cj API 포트 (기본값: CJ_PORT 또는 30800)
    -n, --name NAME         TC 이름 (기본값: tc-target)
    --prom-url URL          TC Prometheus URL (미지정 시 실행 중인 compose 기준 자동 감지)
    --docker-url URL        TC Docker API URL (기본값: unix:///var/run/docker.sock)
    --loki-url URL          TC Promtail용 Loki Push URL 직접 지정
    --loki-port PORT        CJ Loki 포트 (기본값: CJ_LOKI_PORT 또는 31000)
    --whitelist NAMES       예외 컨테이너 목록 (쉼표 구분)
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC_ENV_FILE="$SCRIPT_DIR/.env"
MONITOR_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.monitoring.yml"

# Load TC-local .env if present (for defaults)
if [ -f "$TC_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$TC_ENV_FILE"
fi

CJ_HOST=""
CJ_PORT="${CJ_PORT:-30800}"
TC_NAME="tc-target"
TC_PROM_URL="${TC_PROM_URL:-}"
TC_DOCKER_URL="unix:///var/run/docker.sock"
TC_WHITELIST=""
TC_LABELS=()
CHECK_ONLY=false
LOKI_PUSH_URL="${LOKI_URL_OVERRIDE:-}"
CJ_LOKI_PORT="${CJ_LOKI_PORT:-31000}"

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
        --loki-url)
            LOKI_PUSH_URL="$2"
            shift 2
            ;;
        --loki-port)
            CJ_LOKI_PORT="$2"
            shift 2
            ;;
        --whitelist)
            TC_WHITELIST="$2"
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

detect_primary_ip() {
    # OS 분기 없이 공통 방식: UDP 소켓의 로컬 egress IP 사용
    python3 - << 'PY'
import socket

ip = ""
for target in ("1.1.1.1", "8.8.8.8"):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((target, 80))
        candidate = s.getsockname()[0]
        s.close()
        if candidate and not candidate.startswith("127."):
            ip = candidate
            break
    except Exception:
        pass

if not ip:
    try:
        candidate = socket.gethostbyname(socket.gethostname())
        if candidate and not candidate.startswith("127."):
            ip = candidate
    except Exception:
        pass

print(ip)
PY
}

detect_kind_host_gateway_ip() {
    docker exec cloud-janitor-cluster-control-plane sh -lc \
        "getent hosts host.docker.internal 2>/dev/null | awk '{print \$1}' | head -n1" 2>/dev/null || true
}

is_prometheus_healthy() {
    local url="$1"
    curl -s --max-time 2 "$url/-/healthy" >/dev/null 2>&1
}

extract_host_from_url() {
    local url="$1"
    python3 - "$url" << 'PY'
import sys
from urllib.parse import urlparse

u = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
try:
    parsed = urlparse(u)
    print(parsed.hostname or "")
except Exception:
    print("")
PY
}

extract_port_from_url() {
    local url="$1"
    local default_port="${2:-9091}"
    python3 - "$url" "$default_port" << 'PY'
import sys
from urllib.parse import urlparse

u = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
default_port = int(sys.argv[2]) if len(sys.argv) > 2 else 9091
try:
    parsed = urlparse(u)
    print(int(parsed.port or default_port))
except Exception:
    print(default_port)
PY
}

resolve_default_prom_url() {
    local mapped=""
    local detected=""
    local host_ip=""
    local kind_host_ip=""
    if [ "$CJ_HOST" = "localhost" ] || [ "$CJ_HOST" = "127.0.0.1" ]; then
        kind_host_ip="$(detect_kind_host_gateway_ip)"
    fi
    if [ -z "$kind_host_ip" ]; then
        host_ip="$(detect_primary_ip)"
    fi
    local port="9091"

    if [ -f "$MONITOR_COMPOSE_FILE" ] && docker compose version >/dev/null 2>&1; then
        mapped=$(docker compose -f "$MONITOR_COMPOSE_FILE" port prometheus 9090 2>/dev/null | tail -n1 || true)
    elif [ -f "$MONITOR_COMPOSE_FILE" ] && command -v docker-compose >/dev/null 2>&1; then
        mapped=$(docker-compose -f "$MONITOR_COMPOSE_FILE" port prometheus 9090 2>/dev/null | tail -n1 || true)
    fi

    if [ -n "$mapped" ]; then
        local mapped_port="${mapped##*:}"
        if [[ "$mapped_port" =~ ^[0-9]+$ ]]; then
            port="$mapped_port"
        fi
    fi

    # 로컬 CJ+kind면 kind에서 닿는 host gateway를 우선 사용
    if [ -n "$kind_host_ip" ]; then
        echo "http://$kind_host_ip:$port"
        return
    fi

    # 그 외에는 로컬에서 확인 가능한 URL을 우선 선택
    local candidates=()
    if [ -n "$host_ip" ]; then
        candidates+=("http://$host_ip:$port")
    fi
    candidates+=("http://localhost:$port" "http://127.0.0.1:$port")

    local candidate=""
    for candidate in "${candidates[@]}"; do
        if is_prometheus_healthy "$candidate"; then
            detected="$candidate"
            break
        fi
    done

    if [ -z "$detected" ]; then
        detected="${candidates[0]}"
    fi

    echo "$detected"
}

if [ -z "$TC_PROM_URL" ]; then
    TC_PROM_URL="$(resolve_default_prom_url)"
fi

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

LOCAL_CHECK_PORT="$(extract_port_from_url "$TC_PROM_URL" 9091)"
LOCAL_CHECK_URL="http://localhost:${LOCAL_CHECK_PORT}"

if is_prometheus_healthy "$TC_PROM_URL"; then
    log_success "TC Prometheus가 실행 중입니다: $TC_PROM_URL"
elif is_prometheus_healthy "$LOCAL_CHECK_URL"; then
    log_success "TC Prometheus가 실행 중입니다: $LOCAL_CHECK_URL (연결 URL: $TC_PROM_URL)"
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

BASE_WHITELIST="${CJ_CONTAINER_WHITELIST:-target-prometheus,promtail,cadvisor}"
CUSTOM_WHITELIST=""
CUSTOM_WHITELIST_FILE="$SCRIPT_DIR/.whitelist.custom"
if [ -f "$CUSTOM_WHITELIST_FILE" ]; then
    CUSTOM_WHITELIST=$(tr -d '\n' < "$CUSTOM_WHITELIST_FILE")
fi
# --whitelist가 전달되면 custom 화이트리스트를 1회 오버라이드
if [ -n "$TC_WHITELIST" ]; then
    CUSTOM_WHITELIST="$TC_WHITELIST"
fi
TC_WHITELIST=$(python3 -c '
import sys
base = [x.strip() for x in (sys.argv[1] or "").split(",") if x.strip()]
custom = [x.strip() for x in (sys.argv[2] or "").split(",") if x.strip()]
seen = set()
out = []
for x in base + custom:
    if x in seen:
        continue
    seen.add(x)
    out.append(x)
print(",".join(out))
' "$BASE_WHITELIST" "$CUSTOM_WHITELIST")

# TC 정보 수집
TC_HOSTNAME=$(hostname)
TC_URL_HOST="$(extract_host_from_url "$TC_PROM_URL")"
if [[ "$TC_URL_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [ "$TC_URL_HOST" != "127.0.0.1" ] && [ "$TC_URL_HOST" != "0.0.0.0" ]; then
    TC_IP="$TC_URL_HOST"
else
    TC_IP="$(detect_primary_ip)"
    if [ -z "$TC_IP" ]; then
        TC_IP="unknown"
    fi
fi
TC_OS=$(uname -s)
TC_ARCH=$(uname -m)

log_info "TC 정보:"
log_info "  - 이름:     $TC_NAME"
log_info "  - 호스트네임: $TC_HOSTNAME"
log_info "  - IP:       $TC_IP"
log_info "  - OS:       $TC_OS"
log_info "  - 아키텍처: $TC_ARCH"
log_info "  - Prometheus: $TC_PROM_URL"
log_info "  - WhiteList(base):   $BASE_WHITELIST"
log_info "  - WhiteList(custom): ${CUSTOM_WHITELIST:-<none>}"
log_info "  - WhiteList(send):   $TC_WHITELIST"

# 라벨 포맷팅
LABELS_JSON="{}"
for label in "${TC_LABELS[@]}"; do
    key=$(echo "$label" | cut -d'=' -f1)
    value=$(echo "$label" | cut -d'=' -f2-)
    LABELS_JSON=$(echo "$LABELS_JSON" | sed "s/{}/{\"$key\":\"$value\",/g" | sed 's/,$//')
done

# 컨테이너 ID -> 이름/역할 매핑 수집
# 우선순위:
# 1) docker compose ps (TC 앱 기준)
# 2) docker ps -a --filter network=tc-network (fallback)
CONTAINER_MAP_JSON="{}"
if command -v docker >/dev/null 2>&1; then
    collect_map_from_compose() {
        local include_mode="$1"
        shift
        if [ "$include_mode" = "all" ]; then
            "$@" ps --all --format json 2>/dev/null
        else
            "$@" ps --format json 2>/dev/null
        fi | python3 -c '
import json, sys, subprocess

def infer_type(name, service):
    text = (name or service or "").lower()
    if "zombie" in text:
        return "zombie"
    if "active" in text:
        return "active"
    return "unknown"

raw = sys.stdin.read().strip()
rows = []
if raw:
    # New compose: JSON array
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            rows = data
        elif isinstance(data, dict):
            rows = [data]
    except Exception:
        # Old compose: one JSON object per line
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                if isinstance(item, dict):
                    rows.append(item)
            except Exception:
                pass

out = {}
for row in rows:
    cid = str(row.get("ID") or row.get("Id") or row.get("id") or "")
    name = str(row.get("Name") or row.get("name") or "")
    service = str(row.get("Service") or row.get("service") or "")
    state = str(row.get("State") or row.get("state") or "").lower()
    if not cid:
        continue
    short = cid[:12]
    app_type = ""
    zombie_type = ""

    # Try to read labels directly from docker inspect for 정확한 type/zombie_type.
    try:
        inspect = subprocess.check_output(
            ["docker", "inspect", "-f", "{{json .Config.Labels}}", short],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        labels = json.loads(inspect) if inspect and inspect != "null" else {}
        app_type = str((labels or {}).get("app-type") or "")
        zombie_type = str((labels or {}).get("zombie-type") or "")
    except Exception:
        pass

    if not app_type:
        app_type = infer_type(name, service)

    out[short] = {
        "name": name or service or short,
        "type": app_type,
        "zombie_type": zombie_type,
        "state": state,
    }

print(json.dumps(out, ensure_ascii=False))
'
    }

    collect_map_from_docker_ps() {
        docker ps -a --filter "network=tc-network" \
            --format '{{.ID}}|{{.Names}}|{{.State}}|{{.Label "app-type"}}|{{.Label "zombie-type"}}' | \
            python3 -c '
import sys, json
m = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split("|")
    if len(parts) < 5:
        continue
    cid, name, state, app_type, zombie_type = parts[0], parts[1], parts[2], parts[3], parts[4]
    m[cid[:12]] = {
        "name": name,
        "state": state.lower() if state else "",
        "type": app_type or "unknown",
        "zombie_type": zombie_type or ""
    }
print(json.dumps(m, ensure_ascii=False))
'
    }

    if docker compose ps --all --format json >/dev/null 2>&1; then
        CONTAINER_MAP_JSON=$(collect_map_from_compose all docker compose || echo "{}")
    elif docker compose ps --format json >/dev/null 2>&1; then
        CONTAINER_MAP_JSON=$(collect_map_from_compose running docker compose || echo "{}")
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose ps --all --format json >/dev/null 2>&1; then
        CONTAINER_MAP_JSON=$(collect_map_from_compose all docker-compose || echo "{}")
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose ps --format json >/dev/null 2>&1; then
        CONTAINER_MAP_JSON=$(collect_map_from_compose running docker-compose || echo "{}")
    fi

    # compose 결과가 비었으면 네트워크 기준 fallback
    if [ -z "$CONTAINER_MAP_JSON" ] || [ "$CONTAINER_MAP_JSON" = "{}" ]; then
        CONTAINER_MAP_JSON=$(collect_map_from_docker_ps || echo "{}")
    fi
fi

# labels에 container_map / container_whitelist 병합
LABELS_JSON=$(python3 -c '
import json, sys
labels = json.loads(sys.argv[1]) if sys.argv[1] else {}
container_map = json.loads(sys.argv[2]) if sys.argv[2] else {}
whitelist = [x.strip() for x in (sys.argv[3] or "").split(",") if x.strip()]
labels["container_map"] = container_map
labels["container_whitelist"] = whitelist
print(json.dumps(labels, ensure_ascii=False))
' "$LABELS_JSON" "$CONTAINER_MAP_JSON" "$TC_WHITELIST")

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

        # 현재 TC가 등록되었는지 확인 (JSON 파싱 기반)
        if echo "$REGISTERED_TCS" | python3 -c '
import sys, json
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if isinstance(data, list) and any(str(item.get("tc_name")) == target for item in data if isinstance(item, dict)):
    raise SystemExit(0)
raise SystemExit(1)
' "$TC_NAME"; then
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

    # 응답에서 메시지/설정 추출
    SUCCESS_MSG=$(echo "$RESPONSE_BODY" | python3 -c "import sys, json; print(json.load(sys.stdin).get('message', 'No message'))" 2>/dev/null || echo "등록 완료")
    CJ_LOKI_PUSH_URL_FROM_API=$(echo "$RESPONSE_BODY" | python3 -c "import sys, json; print((json.load(sys.stdin).get('loki_push_url') or '').strip())" 2>/dev/null || echo "")

    log_success "$SUCCESS_MSG"

    # -----------------------------------------------------------------------------
    # TC Promtail -> CJ Loki 연결 자동 설정
    # -----------------------------------------------------------------------------
    if [ -n "$CJ_LOKI_PUSH_URL_FROM_API" ]; then
        LOKI_PUSH_URL="$CJ_LOKI_PUSH_URL_FROM_API"
        log_info "CJ 응답에서 Loki URL 수신: $LOKI_PUSH_URL"
    elif [ -z "$LOKI_PUSH_URL" ]; then
        local_loki_host="${CJ_LOKI_HOST:-}"
        if [ "$CJ_HOST" = "localhost" ] || [ "$CJ_HOST" = "127.0.0.1" ]; then
            # promtail 컨테이너 기준 localhost는 자기 자신이라 host gateway 사용
            local_loki_host="${local_loki_host:-host.docker.internal}"
        else
            local_loki_host="${local_loki_host:-$CJ_HOST}"
        fi
        LOKI_PUSH_URL="http://${local_loki_host}:${CJ_LOKI_PORT}"
    fi

    log_info "TC Promtail Loki URL 설정: $LOKI_PUSH_URL"
    if [ -f "$TC_ENV_FILE" ]; then
        if grep -q '^LOKI_URL=' "$TC_ENV_FILE"; then
            escaped_loki_url=$(printf '%s' "$LOKI_PUSH_URL" | sed 's/[&|]/\\&/g')
            sed -i.bak "s|^LOKI_URL=.*|LOKI_URL=$escaped_loki_url|" "$TC_ENV_FILE"
            rm -f "${TC_ENV_FILE}.bak"
        else
            echo "LOKI_URL=$LOKI_PUSH_URL" >> "$TC_ENV_FILE"
        fi
    else
        echo "LOKI_URL=$LOKI_PUSH_URL" > "$TC_ENV_FILE"
    fi

    # promtail 재시작으로 변경사항 반영 (실패해도 TC 등록 자체는 유지)
    if [ ! -f "$MONITOR_COMPOSE_FILE" ]; then
        log_warning "모니터링 compose 파일이 없어 Promtail 반영을 건너뜁니다: $MONITOR_COMPOSE_FILE"
    else
        promtail_restarted=false
        if command -v docker-compose >/dev/null 2>&1; then
            if (cd "$SCRIPT_DIR" && docker-compose -f "$MONITOR_COMPOSE_FILE" up -d promtail); then
                promtail_restarted=true
            else
                log_warning "Promtail 재시작 실패: tc pm start 상태를 확인하세요."
            fi
        else
            if (cd "$SCRIPT_DIR" && docker compose -f "$MONITOR_COMPOSE_FILE" up -d promtail); then
                promtail_restarted=true
            else
                log_warning "Promtail 재시작 실패: tc pm start 상태를 확인하세요."
            fi
        fi

        if [ "$promtail_restarted" = true ]; then
            log_success "TC Promtail 설정 반영 완료"
        fi
    fi

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

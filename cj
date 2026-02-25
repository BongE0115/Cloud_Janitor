#!/bin/bash

# =============================================================================
# Cloud Janitor CLI Tool
# 
# Cloud Janitor는 TC(Target Cluster)에 연결(attach)하여
# TC Prometheus를 기반으로 감지/정리 작업을 수행하는 시스템
#
# 사용법:
#   cj install           # cj CLI 시스템 PATH에 등록 (설치)
#   cj init              # 프로젝트 초기화
#   cj setup             # 전체 설정 (Mgmt Cluster 생성/준비)
#   cj start             # 서비스 시작
#   cj stop              # 서비스 중지
#   cj tunnel <cmd>      # SSH 터널 관리 (setup, stop, status)
#   cj tf <command>      # Terraform 명령어 (init, apply, destroy, plan)
#   cj status            # 상태 확인
#   cj logs <service>    # 로그 확인
#   cj grafana           # Grafana 접속
#   cj help              # 도움말
#
# 아키텍처:
#   - target-cluster: TC 측 Docker Compose 환경
#   - cj (Cloud Janitor): Management Cluster 운영 + TC 등록 관리
#   - Management Cluster: cj에서 생성하는 Kind K8s (Janitor, Grafana, Loki, MySQL)
# =============================================================================

set -e  # 에러 발생 시 즉시 종료

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
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

# =============================================================================
# 프로젝트 경로 설정
# =============================================================================

# CJ_HOME 환경변수가 설정되어 있으면 사용, 아니면 스크립트 위치 사용
CJ_HOME="${CJ_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# 경로 설정
TERRAFORM_DIR="$CJ_HOME/terraform"
ANSIBLE_DIR="$CJ_HOME/ansible"
SCRIPTS_DIR="$CJ_HOME/scripts"

# Target 주소 (터널 명령 fallback 용)
TARGET_HOST="${TARGET_HOST:-localhost}"

# =============================================================================
# 유틸리티 함수
# =============================================================================

# 프로젝트 경로 확인
check_cj_home() {
    if [ ! -d "$CJ_HOME" ]; then
        log_error "Cloud Janitor 프로젝트 디렉토리를 찾을 수 없습니다: $CJ_HOME"
        log_info "CJ_HOME 환경변수를 설정하거나 cj 스크립트가 있는 디렉토리에서 실행하세요."
        exit 1
    fi
}

# Docker 설치 확인
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker가 설치되어 있지 않습니다."
        exit 1
    fi
}

# Terraform 설치 확인
check_terraform() {
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform가 설치되어 있지 않습니다."
        exit 1
    fi
}

ensure_uv_sync() {
    if [ "${UV_SYNC_DONE:-false}" = "true" ]; then
        return 0
    fi
    log_info "uv sync 실행 중..."
    cd "$CJ_HOME"
    uv sync
    UV_SYNC_DONE=true
}

# kubectl 설치 확인
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl가 설치되어 있지 않습니다."
        exit 1
    fi
}

ensure_cloud_janitor_image() {
    check_docker

    if ! docker image inspect cloud-janitor:latest >/dev/null 2>&1; then
        log_info "Cloud Janitor 이미지 빌드 중..."
        docker build -t cloud-janitor:latest "$CJ_HOME"
    else
        log_info "Cloud Janitor 이미지가 이미 존재합니다."
    fi

    if command -v kind &> /dev/null; then
        if kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"; then
            log_info "kind 클러스터에 이미지 로드 중..."
            kind load docker-image cloud-janitor:latest --name cloud-janitor-cluster
        fi
    fi
}

# .env 파일 확인
check_env_file() {
    if [ ! -f "$CJ_HOME/.env" ]; then
        log_warning ".env 파일이 없습니다. .env.example을 복사합니다."
        cp "$CJ_HOME/.env.example" "$CJ_HOME/.env"
        log_warning ".env 파일을 설정해주세요. (특히 GRAFANA_PASSWORD)"
        return 1
    fi
    return 0
}

# SSH 터널 설정
setup_ssh_tunnel() {
    if [ -f "$CJ_HOME/.env" ]; then
        # shellcheck disable=SC1090
        source "$CJ_HOME/.env"
    fi

    # CLI 옵션이 있으면 우선 사용, 없으면 .env/기본값 사용
    USE_SSH_TUNNEL="${CLI_USE_SSH_TUNNEL:-${USE_SSH_TUNNEL:-true}}"
    TARGET_HOST="${CLI_TARGET_HOST:-${TARGET_HOST:-localhost}}"
    TARGET_SSH_USER="${CLI_TARGET_SSH_USER:-${TARGET_SSH_USER:-root}}"
    TARGET_SSH_PORT="${CLI_TARGET_SSH_PORT:-${TARGET_SSH_PORT:-22}}"
    TARGET_SSH_KEY="${CLI_TARGET_SSH_KEY:-${TARGET_SSH_KEY:-~/.ssh/id_rsa}}"
    PROMETHEUS_PORT="${CLI_PROMETHEUS_PORT:-${PROMETHEUS_PORT:-9091}}"
    LOCAL_PROMETHEUS_PORT="${CLI_LOCAL_PORT:-${LOCAL_PROMETHEUS_PORT:-9091}}"
    
    # 로컬이면 터널 필요 없음
    if [ "$TARGET_HOST" = "localhost" ]; then
        log_info "Target이 로컬입니다. SSH 터널을 설정하지 않습니다."
        return 0
    fi
    
    # SSH 터널 사용하지 않으면 무시
    if [ "$USE_SSH_TUNNEL" != "true" ]; then
        log_info "SSH 터널 사용 안 함"
        return 0
    fi
    
    # 이미 SSH 터널이 실행 중인지 확인
    SSH_TUNNEL_PID=$(pgrep -f "ssh.*localhost:${LOCAL_PROMETHEUS_PORT}:${TARGET_HOST}:${PROMETHEUS_PORT}" || true)
    if [ -n "$SSH_TUNNEL_PID" ]; then
        log_info "SSH 터널이 이미 실행 중입니다 (PID: $SSH_TUNNEL_PID)"
        return 0
    fi
    
    # SSH 터널 생성
    log_info "SSH 터널 생성 중: ${TARGET_HOST}:${PROMETHEUS_PORT} -> localhost:${LOCAL_PROMETHEUS_PORT}"
    log_info "SSH 사용자: ${TARGET_SSH_USER}@${TARGET_HOST}:${TARGET_SSH_PORT}"
    log_info "SSH 키: ${TARGET_SSH_KEY}"
    
    # SSH 키가 있는지 확인
    if [ ! -f "$TARGET_SSH_KEY" ]; then
        log_warning "SSH 키를 찾을 수 없습니다: ${TARGET_SSH_KEY}"
        log_warning "SSH 키 없이 비밀번호로 접속합니다 (비추천)"
    fi
    
    # SSH 터널 백그라운드 실행
    ssh -i "$TARGET_SSH_KEY" \
        -L "localhost:${LOCAL_PROMETHEUS_PORT}:${TARGET_HOST}:${PROMETHEUS_PORT}" \
        -N \
        -p "${TARGET_SSH_PORT}" \
        "${TARGET_SSH_USER}@${TARGET_HOST}" \
        &>/dev/null &
    
    SSH_TUNNEL_PID=$!
    
    # SSH 터널 시작 대기
    sleep 2
    
    # SSH 터널 확인
    if ps -p "$SSH_TUNNEL_PID" > /dev/null 2>&1; then
        log_success "SSH 터널 생성 성공 (PID: $SSH_TUNNEL_PID)"
    else
        log_error "SSH 터널 생성 실패"
        return 1
    fi
}

# SSH 터널 해제
teardown_ssh_tunnel() {
    if [ -f "$CJ_HOME/.env" ]; then
        # shellcheck disable=SC1090
        source "$CJ_HOME/.env"
    fi

    TARGET_HOST="${CLI_TARGET_HOST:-${TARGET_HOST:-localhost}}"
    PROMETHEUS_PORT="${CLI_PROMETHEUS_PORT:-${PROMETHEUS_PORT:-9091}}"
    LOCAL_PROMETHEUS_PORT="${CLI_LOCAL_PORT:-${LOCAL_PROMETHEUS_PORT:-9091}}"
    local tunnel_pattern="ssh.*localhost:${LOCAL_PROMETHEUS_PORT}:${TARGET_HOST}:${PROMETHEUS_PORT}"
    local pids
    pids=$(pgrep -f "$tunnel_pattern" || true)

    if [ -z "$pids" ]; then
        log_info "실행 중인 SSH 터널이 없습니다."
        return 0
    fi

    log_info "SSH 터널 종료 중..."
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    log_success "SSH 터널 종료 완료"
}

parse_tunnel_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --host)
                CLI_TARGET_HOST="$2"
                shift 2
                ;;
            --user)
                CLI_TARGET_SSH_USER="$2"
                shift 2
                ;;
            --port)
                CLI_TARGET_SSH_PORT="$2"
                shift 2
                ;;
            --key)
                CLI_TARGET_SSH_KEY="$2"
                shift 2
                ;;
            --remote-port)
                CLI_PROMETHEUS_PORT="$2"
                shift 2
                ;;
            --local-port)
                CLI_LOCAL_PORT="$2"
                shift 2
                ;;
            --enable|--use)
                CLI_USE_SSH_TUNNEL="true"
                shift
                ;;
            --disable|--no-use)
                CLI_USE_SSH_TUNNEL="false"
                shift
                ;;
            *)
                log_error "알 수 없는 tunnel 옵션: $1"
                echo "예시: cj tunnel setup --host 10.0.0.5 --user ubuntu --key ~/.ssh/id_rsa --remote-port 9091 --local-port 9091"
                exit 1
                ;;
        esac
    done
}

start_port_forward() {
    if command -v curl &> /dev/null; then
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:30800/health 2>/dev/null | grep -q "^200$"; then
            return 0
        fi
    fi

    if pgrep -f "port-forward.*service/cloud-janitor.*30800:8000" >/dev/null 2>&1; then
        return 0
    fi

    if ! kubectl get service cloud-janitor -n default &> /dev/null; then
        return 0
    fi

    pkill -f "port-forward.*service/cloud-janitor.*30800:8000" 2>/dev/null || true
    nohup kubectl port-forward -n default service/cloud-janitor 30800:8000 >/tmp/cj-port-forward.log 2>&1 &
    sleep 1
}

stop_port_forward() {
    pkill -f "port-forward.*service/cloud-janitor.*30800:8000" 2>/dev/null || true
}

start_loki_port_forward() {
    if command -v curl &> /dev/null; then
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:31000/ready 2>/dev/null | grep -q "^200$"; then
            return 0
        fi
    fi

    if pgrep -f "port-forward.*service/loki.*31000:3100" >/dev/null 2>&1; then
        return 0
    fi

    if ! kubectl get service loki -n monitoring &> /dev/null; then
        return 0
    fi

    # Kill any existing port-forward on same port
    pkill -f "port-forward.*loki.*31000" 2>/dev/null || true
    sleep 1

    nohup kubectl port-forward -n monitoring service/loki 31000:3100 >/tmp/cj-loki-port-forward.log 2>&1 &
    
    # Wait for port-forward to be ready
    sleep 3
    local retries=0
    while [ $retries -lt 10 ]; do
        if curl -s http://localhost:31000/ready > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        retries=$((retries + 1))
    done
    log_warning "Loki 포트포워드 연결 실패"
    return 1
}

stop_loki_port_forward() {
    pkill -f "port-forward.*service/loki.*31000:3100" 2>/dev/null || true
}

# 상태값은 파일에 저장하지 않고 런타임에서 계산
load_state() {
    return 0
}

# 상태값은 파일에 저장하지 않고 런타임에서 계산
save_state() {
    return 0
}

# =============================================================================
# 도움말
# =============================================================================

show_help() {
    echo -e "${BOLD}Cloud Janitor CLI Tool${NC}"
    echo ""
    echo -e "사용법: cj <command> [options]"
    echo ""
    echo -e "${BOLD}설치:${NC}"
    echo "  install           cj CLI 시스템 PATH에 등록 (설치)"
    echo ""
    echo -e "${BOLD}자동화:${NC}"
    echo "  bootstrap         전체 자동 설정 (install + init + setup + start)"
    echo ""
    echo -e "${BOLD}프로젝트 관리:${NC}"
    echo "  init              프로젝트 초기화 (.env 파일 생성, 의존성 설치 확인)"
    echo "  setup             전체 설정 (Mgmt Cluster 생성 + 앱 준비)"
    echo "  start             서비스 시작"
    echo "  stop              서비스 중지"
    echo "  clear             로컬 상태/파일 정리"
    echo ""
    echo -e "${BOLD}Terraform (Management Cluster):${NC}"
    echo "  tf init           Terraform 초기화"
    echo "  tf plan           Terraform 계획 확인"
    echo "  tf apply          Terraform 적용 (클러스터 생성)"
    echo "  tf destroy        Terraform 삭제 (클러스터 삭제)"
    echo "  tf clear          Terraform 로컬 상태 정리"
    echo "  tf output         Terraform 출력값 확인"
    echo "  tf shell          Terraform 쉘 실행 (terraform 명령어 직접 사용)"
    echo ""
    echo -e "${BOLD}상태 및 로그:${NC}"
    echo "  status            전체 시스템 상태 확인"
    echo "  logs <service>    로그 확인 (janitor, mysql, grafana, loki)"
    echo "  scan              Cloud Janitor 수동 1회 스캔 실행"
    echo ""
    echo -e "${BOLD}접속:${NC}"
    echo "  grafana           Grafana 접속"
    echo ""
    echo -e "${BOLD}기타:${NC}"
    echo "  env               .env 파일 편집"
    echo "  kubeconfig        kubeconfig 경로 출력"
    echo "  shell             Cloud Janitor 프로젝트 디렉토리로 이동"
    echo "  version           버전 정보"
    echo "  help              이 도움말 표시"
    echo ""
    echo -e "${BOLD}SSH 터널 (외부 Target 접근용):${NC}"
    echo "  tunnel setup      SSH 터널 생성 (옵션 우선, .env는 fallback)"
    echo "  tunnel stop       SSH 터널 종료"
    echo "  tunnel status     SSH 터널 상태 확인"
    echo ""
    echo -e "${BOLD}예시:${NC}"
    echo "  cj bootstrap               # 전체 자동 설정"
    echo "  cj install                 # cj CLI 설치"
    echo "  cj init                    # 프로젝트 초기화"
    echo "  cj setup                   # 전체 설정"
    echo "  cj status                  # 상태 확인"
    echo "  cj logs janitor            # Cloud Janitor 로그"
    echo "  cj stop                    # 서비스 중지"
    echo ""
    echo -e "${BOLD}환경 변수:${NC}"
    echo "  CJ_HOME         Cloud Janitor 프로젝트 경로 (기본값: cj 스크립트 위치)"
    echo "  TARGET_HOST     터널 명령 fallback 호스트 (권장: tunnel 옵션 사용)"
    echo ""
}

show_version() {
    cat << EOF
Cloud Janitor CLI Tool v1.0.0
Zombie Pod Detection and Auto-Cleanup System

Project Path: $CJ_HOME
EOF
}

# =============================================================================
# 초기화
# =============================================================================

cmd_init() {
    log_step "🚀 Cloud Janitor 초기화"

    check_cj_home

    log_info "기존 환경 정리 중..."
    set +e
    if command -v terraform &> /dev/null; then
        if [ -d "$CJ_HOME/terraform" ]; then
            (cd "$CJ_HOME/terraform" && terraform init -input=false >/dev/null 2>&1)
            if (cd "$CJ_HOME/terraform" && terraform destroy -auto-approve); then
                log_success "기존 Terraform 리소스 삭제 완료"
            else
                log_warning "Terraform 삭제가 실패했습니다. 상태를 정리합니다."
                if (cd "$CJ_HOME/terraform" && terraform state list >/dev/null 2>&1); then
                    while read -r resource; do
                        (cd "$CJ_HOME/terraform" && terraform state rm "$resource" >/dev/null 2>&1) || true
                    done < <(cd "$CJ_HOME/terraform" && terraform state list 2>/dev/null)
                    log_success "Terraform 상태 정리 완료"
                fi
            fi
        fi
    fi

    rm -f "$CJ_HOME/terraform/cloud-janitor-cluster-config"
    rm -f "$CJ_HOME/terraform/terraform.tfstate"
    rm -f "$CJ_HOME/terraform/terraform.tfstate.backup"
    rm -f "$CJ_HOME/terraform/terraform.tfstate.lock.info"
    rm -rf "$CJ_HOME/terraform/.terraform"
    teardown_ssh_tunnel || true

    if command -v kind &> /dev/null; then
        if kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"; then
            KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config" kind delete cluster --name cloud-janitor-cluster
            log_success "기존 kind 클러스터 삭제 완료"
        fi
    fi
    set -e

    # 디렉토리 구조 확인
    log_info "프로젝트 디렉토리 구조 확인 중..."
    
    for dir in terraform ansible; do
        if [ -d "$CJ_HOME/$dir" ]; then
            log_success "$dir/ ✓"
        else
            log_error "$dir/ ✗ (디렉토리를 찾을 수 없음)"
            exit 1
        fi
    done

    # 필수 파일 확인
    log_info "필수 파일 확인 중..."
    
    if [ -f "$CJ_HOME/.env.example" ]; then
        log_success ".env.example ✓"
    else
        log_error ".env.example ✗"
        exit 1
    fi

    # .env 파일 생성
    if [ ! -f "$CJ_HOME/.env" ]; then
        log_info ".env 파일 생성 중..."
        cp "$CJ_HOME/.env.example" "$CJ_HOME/.env"
        log_success ".env 파일 생성 완료"
        log_warning ".env 파일을 설정해주세요 (vim $CJ_HOME/.env)"
    else
        log_info ".env 파일이 이미 존재합니다."
    fi

    # 의존성 확인
    log_info "필수 도구 확인 중..."

    if command -v docker &> /dev/null; then
        log_success "Docker ✓"
    else
        log_warning "Docker ✗ (설치 필요 - TC 실행용)"
    fi

    if command -v terraform &> /dev/null; then
        log_success "Terraform ✓"
    else
        log_warning "Terraform ✗ (설치 필요)"
    fi

    if command -v uv &> /dev/null; then
        log_success "uv ✓"
    else
        log_warning "uv ✗ (설치 필요)"
    fi

    if command -v kubectl &> /dev/null; then
        log_success "kubectl ✓"
    else
        log_warning "kubectl ✗ (설치 필요)"
    fi

    # State 파일 초기화
    save_state

    log_step "✅ 초기화 완료"
    echo ""
    log_info "다음 명령어로 계속 진행하세요:"
    echo "   tc start              # Target 앱(좀비 포함) 시작"
    echo "   tc pm start           # Target Prometheus 시작"
    echo "   cj setup              # Management 설정"
    echo ""
    log_info "참고: Target Prometheus는 tc에서 별도 실행합니다."
    echo ""
    log_info "다음 명령어 추천:"
    echo "   tc start"
    echo ""
}

# =============================================================================
# cj CLI 설치
# =============================================================================

cmd_install() {
    log_step "📦 cj CLI 설치"

    # cj 스크립트 확인
    CJ_CLI="$CJ_HOME/cj"

    if [ ! -f "$CJ_CLI" ]; then
        log_error "cj CLI 스크립트를 찾을 수 없습니다: $CJ_CLI"
        exit 1
    fi

    # 실행 권한 확인
    if [ ! -x "$CJ_CLI" ]; then
        log_info "cj 스크립트에 실행 권한 부여 중..."
        chmod +x "$CJ_CLI"
        log_success "실행 권한 부여 완료"
    fi

    echo ""
    echo "=========================================="
    echo "  Cloud Janitor CLI 도구 설치"
    echo "=========================================="
    echo ""

    # 로그인 쉘 기준으로 RC 파일 선택
    local shell_name
    local rc_file
    local profile_file
    shell_name="$(basename "${SHELL:-bash}")"

    case "$shell_name" in
        zsh)
            rc_file="$HOME/.zshrc"
            profile_file="$HOME/.zprofile"
            log_info "감지된 쉘: zsh"
            ;;
        bash)
            rc_file="$HOME/.bashrc"
            profile_file="$HOME/.bash_profile"
            log_info "감지된 쉘: bash"
            ;;
        *)
            rc_file="$HOME/.profile"
            profile_file="$HOME/.profile"
            log_warning "쉘 타입을 감지할 수 없습니다. profile을 기본으로 사용합니다."
            ;;
    esac

    echo ""

    # 1) 시스템 PATH에 심볼릭 링크 생성 시도
    log_info "시스템 PATH에 심볼릭 링크 생성 중..."

    mkdir -p "$HOME/.local/bin"

    local link_locations=(
        "/opt/homebrew/bin/cj"
        "/usr/local/bin/cj"
        "$HOME/.local/bin/cj"
    )

    local link_success=false

    local link_path
    for link_path in "${link_locations[@]}"; do
        local link_dir
        link_dir=$(dirname "$link_path")

        if [ ! -d "$link_dir" ]; then
            continue
        fi

        if [ ! -w "$link_dir" ]; then
            continue
        fi

        if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
            continue
        fi

        rm -f "$link_path" 2>/dev/null || true
        ln -s "$CJ_CLI" "$link_path" || continue
        log_success "심볼릭 링크 생성: $link_path → $CJ_CLI"
        link_success=true
        break
    done

    if [ "$link_success" = false ]; then
        log_warning "시스템 PATH에 심볼릭 링크를 생성할 수 없습니다."
    fi

    echo ""

    # 2) RC 파일에 PATH 추가
    log_info "쉘 설정 파일에 CJ_HOME과 PATH 추가 중..."

    touch "$rc_file"
    touch "$profile_file"

    if ! grep -q "export CJ_HOME=" "$rc_file" 2>/dev/null; then
        cat >> "$rc_file" << EOF

# Cloud Janitor CLI
export CJ_HOME="$CJ_HOME"
export PATH="\$HOME/.local/bin:\$CJ_HOME:\$PATH"
EOF
        log_success "$rc_file에 추가 완료"
    else
        log_info "$rc_file에 이미 CJ_HOME 설정이 있습니다. (덮어쓰지 않음)"
    fi

    if [ "$profile_file" != "$rc_file" ] && ! grep -q "export CJ_HOME=" "$profile_file" 2>/dev/null; then
        cat >> "$profile_file" << EOF

# Cloud Janitor CLI
export CJ_HOME="$CJ_HOME"
export PATH="\$HOME/.local/bin:\$CJ_HOME:\$PATH"
EOF
        log_success "$profile_file에 추가 완료"
    elif [ "$profile_file" != "$rc_file" ]; then
        log_info "$profile_file에 이미 CJ_HOME 설정이 있습니다. (덮어쓰지 않음)"
    fi

    # 설치 완료 메시지
    echo "=========================================="
    echo "  설치 완료"
    echo "=========================================="
    echo ""
    log_success "이제 다음 명령어를 사용할 수 있습니다:"
    echo ""
    echo "  cj help              # 도움말"
    echo "  cj init             # 프로젝트 초기화"
    echo "  cj setup            # 전체 설정"
    echo "  cj status           # 상태 확인"
    echo ""
    log_info "다음 명령어 추천:"
    echo "  cj init"
    echo ""
}

# =============================================================================
# 전체 설정
# =============================================================================

cmd_setup() {
    log_step "🚀 Cloud Janitor 전체 설정"

    check_cj_home
    check_env_file || exit 1

    # 1. Terraform 초기화
    if [ ! -d "$CJ_HOME/terraform/.terraform" ]; then
        log_info "STEP 1/3: Terraform 초기화"
        cmd_tf init
    else
        log_info "STEP 1/3: Terraform 이미 초기화됨"
    fi

    # 2. Management Cluster 생성
    if ! (command -v kind &> /dev/null && kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"); then
        log_info "STEP 2/3: Management Cluster 생성"
        cmd_tf apply -auto-approve
        log_info "STEP 2.5/3: Cloud Janitor 이미지 빌드 및 kind 클러스터에 로드"
        ensure_cloud_janitor_image
    else
        log_info "STEP 2/3: Management Cluster 이미 생성됨"
        # 이미지가 존재하는지 확인 후 kind에 로드
        ensure_cloud_janitor_image
    fi

    # 3. 안내
    log_info "STEP 3/3: 서비스 준비 완료 (Target 연동은 tc connect로 진행)"
    log_info "다음 순서로 진행하세요:"
    echo "   cj start"
    echo "   tc connect -a <CJ_HOST>"

    log_step "🎉 전체 설정 완료"
    echo ""
    log_info "접속 정보:"
    echo "   📈 Grafana (Mgmt):     http://localhost:3000"
    echo "   🐍 CJ API:             http://localhost:30800 (cj start 이후)"
    echo ""
    log_info "상태 확인:"
    echo "   cj status"
    echo ""
    log_info "다음 명령어 추천:"
    echo "   cj start"
}

# =============================================================================
# 서비스 시작
# =============================================================================

cmd_start() {
    log_step "🚀 서비스 시작"

    check_cj_home

    log_info "Cloud Janitor 서비스를 시작합니다..."

    # kubeconfig 설정
    local kubeconfig_path="$CJ_HOME/terraform/cloud-janitor-cluster-config"
    if [ ! -f "$kubeconfig_path" ]; then
        log_warning "Management Cluster kubeconfig를 찾을 수 없습니다."
        log_info "먼저 다음을 실행하세요: cj setup"
        exit 1
    fi
    export KUBECONFIG="$kubeconfig_path"
    if ! kubectl get namespace default >/dev/null 2>&1; then
        log_warning "Management Cluster에 연결할 수 없습니다."
        log_info "먼저 다음을 실행하세요: cj setup"
        exit 1
    fi

    ensure_cloud_janitor_image

    cd "$CJ_HOME"
    export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
    export ANSIBLE_ROLES_PATH="$ANSIBLE_DIR/roles"
    export ANSIBLE_LOCAL_TMP="${ANSIBLE_LOCAL_TMP:-/tmp/ansible}"
    export ANSIBLE_REMOTE_TMP="${ANSIBLE_REMOTE_TMP:-/tmp/ansible}"
    mkdir -p "$ANSIBLE_LOCAL_TMP"
    ensure_uv_sync

    if kubectl get deployment cloud-janitor -n default &> /dev/null; then
        log_info "Cloud Janitor Deployment가 이미 존재합니다."
        log_info "최신 설정(ConfigMap/코드 주입) 적용 중..."
    else
        log_warning "Cloud Janitor Deployment를 찾을 수 없습니다."
        log_info "Ansible로 Cloud Janitor를 배포합니다..."
    fi

    uv run ansible-playbook "$ANSIBLE_DIR/playbooks/setup-cluster.yml"
    log_info "Deployment를 재시작합니다..."
    kubectl rollout restart deployment/cloud-janitor -n default
    log_info "Cloud Janitor Deployment 준비 대기 중..."
    kubectl rollout status deployment/cloud-janitor -n default --timeout=180s

    # 상태 확인
    log_info "Pod 상태 확인 중..."
    kubectl get pods -n default -l app=cloud-janitor

    start_port_forward
    log_info "cj API 포트포워드: http://localhost:30800"
    start_loki_port_forward
    log_info "Loki 포트포워드: http://localhost:31000"

    log_success "서비스 시작 완료"
    log_info "로그 확인: cj logs janitor"
    echo ""
    log_info "다음 명령어 추천:"
    echo "   cj status"
}

# =============================================================================
# 서비스 중지
# =============================================================================

cmd_stop() {
    log_step "🛑 서비스 중지"

    check_cj_home
    check_kubectl

    # kubeconfig 설정
    export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"

    log_info "Cloud Janitor 서비스를 중지합니다..."

    # Cloud Janitor Deployment 스케일링
    if kubectl get deployment cloud-janitor -n default &> /dev/null; then
        log_info "Cloud Janitor Deployment를 중지합니다..."
        kubectl scale deployment/cloud-janitor -n default --replicas=0
        log_success "Cloud Janitor 중지 완료"
    else
        log_warning "Cloud Janitor Deployment를 찾을 수 없습니다."
    fi

    stop_port_forward
    stop_loki_port_forward

    log_info "서비스가 중지되었습니다."
    log_info "다시 시작하려면: cj start"
    echo ""
    log_info "다음 명령어 추천:"
    echo "   cj start"
}

purge_terraform_artifacts() {
    rm -f "$CJ_HOME/terraform/cloud-janitor-cluster-config"
    rm -f "$CJ_HOME/terraform/terraform.tfstate"*
    rm -f "$CJ_HOME/terraform/.terraform.lock.hcl"
    rm -f "$CJ_HOME/terraform/terraform.tfstate.lock.info"
    rm -rf "$CJ_HOME/terraform/.terraform"
}

destroy_management_cluster() {
    if ! command -v terraform &> /dev/null; then
        log_warning "terraform가 없어 destroy를 건너뜁니다."
        return 0
    fi

    cd "$TERRAFORM_DIR"
    terraform init -input=false >/dev/null 2>&1 || true

    if terraform state list >/dev/null 2>&1; then
        log_info "Terraform destroy 실행 중..."
        terraform destroy -auto-approve || true
    fi

    if command -v kind &> /dev/null; then
        if kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"; then
            log_warning "kind 클러스터가 남아 있어 강제 삭제합니다..."
            kind delete cluster --name cloud-janitor-cluster || true
        fi
    fi
}

cmd_clear() {
    log_step "🧹 완전 정리"

    check_cj_home

    stop_port_forward
    stop_loki_port_forward
    teardown_ssh_tunnel || true
    destroy_management_cluster
    purge_terraform_artifacts
    TF_INITIALIZED=false
    MGMT_CLUSTER_CREATED=false
    CLOUD_JANITOR_DEPLOYED=false
    save_state

    log_success "로컬 상태 정리 완료"
    echo ""
    log_info "Management Cluster + 로컬 상태 정리 완료"
    log_info "다음 명령어 추천:"
    echo "   cj init"
}

# =============================================================================
# Terraform 명령어
# =============================================================================

cmd_tf() {
    local subcmd=$1
    shift || true

    check_terraform
    check_cj_home

    cd "$TERRAFORM_DIR"

    case $subcmd in
        init)
            log_step "🏗️  Terraform 초기화"
            terraform init
            TF_INITIALIZED=true
            save_state
            echo ""
            log_info "다음 명령어 추천:"
            echo "   cj tf apply"
            ;;
        plan)
            log_step "📋 Terraform 계획 확인"
            terraform plan
            ;;
        apply)
            log_step "🚀 Terraform 적용"
            log_info "Management Cluster를 생성합니다..."
            local apply_args=("$@")
            local auto_approve=false
            for arg in "${apply_args[@]}"; do
                if [ "$arg" = "-auto-approve" ]; then
                    auto_approve=true
                fi
            done

            local bootstrap_args=()
            if [ "$auto_approve" = true ]; then
                bootstrap_args+=("-auto-approve")
            fi

            local need_bootstrap=true
            local has_kind_state=false
            local kind_exists=false
            if terraform state list 2>/dev/null | grep -q "^kind_cluster.default$"; then
                has_kind_state=true
            fi
            if command -v kind &> /dev/null; then
                if kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"; then
                    kind_exists=true
                fi
            fi
            if [ "$has_kind_state" = false ] && [ "$kind_exists" = true ]; then
                log_warning "Terraform 상태에 없는 kind 클러스터가 존재합니다. 삭제합니다..."
                kind delete cluster --name cloud-janitor-cluster
                kind_exists=false
            fi
            if [ "$has_kind_state" = false ]; then
                need_bootstrap=true
            fi
            if [ "$kind_exists" = true ] && [ "$has_kind_state" = true ]; then
                need_bootstrap=false
            fi

            if [ "$need_bootstrap" = true ]; then
                log_info "kind 클러스터를 먼저 생성합니다..."
                if terraform state list 2>/dev/null | grep -q "^kubernetes_"; then
                    log_warning "기존 Kubernetes 리소스 상태를 정리합니다..."
                    while read -r resource; do
                        terraform state rm "$resource" >/dev/null 2>&1 || true
                    done < <(terraform state list 2>/dev/null | grep "^kubernetes_")
                    log_success "Kubernetes 상태 정리 완료"
                fi
                terraform apply -target kind_cluster.default "${bootstrap_args[@]}"
            fi

            terraform apply "${apply_args[@]}"
            MGMT_CLUSTER_CREATED=true
            save_state
            log_success "Management Cluster 생성 완료"
            log_info "kubeconfig: $CJ_HOME/terraform/cloud-janitor-cluster-config"
            echo ""
            log_info "다음 명령어 추천:"
            echo "   cj start"
            ;;
        destroy)
            log_step "🗑️  Terraform 삭제"
            log_warning "Management Cluster를 삭제합니다..."
            terraform init -input=false
            terraform destroy "$@"
            rm -f "$CJ_HOME/terraform/cloud-janitor-cluster-config"
            MGMT_CLUSTER_CREATED=false
            CLOUD_JANITOR_DEPLOYED=false
            save_state
            log_success "Management Cluster 삭제 완료"
            echo ""
            log_info "다음 명령어 추천:"
            echo "   cj init"
            ;;
        clear)
            log_step "🧹 Terraform 완전 정리"
            destroy_management_cluster
            purge_terraform_artifacts
            TF_INITIALIZED=false
            MGMT_CLUSTER_CREATED=false
            CLOUD_JANITOR_DEPLOYED=false
            save_state
            log_success "Terraform 완전 정리 완료"
            echo ""
            log_info "다음 명령어 추천:"
            echo "   cj init"
            ;;
        output)
            terraform output "$@"
            ;;
        shell)
            log_info "Terraform 쉘 시작 (exit로 종료)"
            bash
            ;;
        *)
            log_error "알 수 없는 Terraform 명령어: $subcmd"
            echo ""
            echo "사용 가능한 명령어:"
            echo "  cj tf init           Terraform 초기화"
            echo "  cj tf plan           Terraform 계획 확인"
            echo "  cj tf apply          Terraform 적용"
            echo "  cj tf destroy        Terraform 삭제"
            echo "  cj tf clear          Terraform 로컬 상태 정리"
            echo "  cj tf output         Terraform 출력값 확인"
            echo "  cj tf shell          Terraform 쉘"
            exit 1
            ;;
    esac
}

# =============================================================================
# 상태 확인
# =============================================================================

cmd_status() {
    log_step "📊 Cloud Janitor 상태"

    check_cj_home

    echo ""
    echo "🎯 Target Cluster 등록 상태:"
    if curl --max-time 3 -s -o /dev/null -w "%{http_code}" "http://localhost:30800/health" 2>/dev/null | grep -q "200"; then
        targets_json="$(curl -s http://localhost:30800/api/v1/targets 2>/dev/null || echo "[]")"
        target_count="$(echo "$targets_json" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
    print(len(data) if isinstance(data,list) else 0)
except Exception:
    print(0)
')"
        echo "   등록된 TC 수: $target_count"
        if [ "${target_count:-0}" -gt 0 ] 2>/dev/null; then
            echo "   등록 대상:"
            echo "$targets_json" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    data=[]
if isinstance(data,list):
    for item in data[:5]:
        if isinstance(item,dict):
            name=item.get("tc_name","unknown")
            prom=item.get("prometheus_url","")
            print(f"     - {name} ({prom})")
'
        fi
    else
        echo -e "   상태: ${YELLOW}CJ API 미연결${NC} (등록 대상 조회 불가)"
        echo "   확인: tc connect --check -a <CJ_HOST>"
    fi

    echo ""
    echo "🎛️  Management Cluster:"
    if [ -f "$CJ_HOME/terraform/cloud-janitor-cluster-config" ]; then
        export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"
        if kubectl get namespace default >/dev/null 2>&1; then
            echo -e "   상태: ${GREEN}생성됨${NC}"
            echo "   K8s Pods:"
            kubectl get pods -A --no-headers | head -5 | while read -r _ns rest; do
                echo "     - $rest"
            done
        else
            echo -e "   상태: ${YELLOW}kubeconfig 있음, 연결 실패${NC}"
        fi
    else
        echo -e "   상태: ${YELLOW}생성 안됨${NC}"
    fi
        
    echo ""
    echo "🐍 Cloud Janitor:"
    if [ -f "$CJ_HOME/terraform/cloud-janitor-cluster-config" ]; then
        export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"
        if kubectl get deployment cloud-janitor -n default >/dev/null 2>&1; then
            replicas=$(kubectl get deployment cloud-janitor -n default -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            replicas="${replicas:-0}"
            if [ "$replicas" -gt 0 ] 2>/dev/null; then
                echo -e "   상태: ${GREEN}실행 중${NC} (ready=$replicas)"
            else
                echo -e "   상태: ${YELLOW}배포됨(중지 상태)${NC}"
            fi
        else
            echo -e "   상태: ${YELLOW}배포 안됨${NC}"
        fi
    else
        echo -e "   상태: ${YELLOW}배포 안됨${NC}"
    fi

    echo ""
    echo "🔧 환경 변수:"
    echo "   CJ_HOME: $CJ_HOME"
    echo "   KUBECONFIG: ${KUBECONFIG:-설정 안됨}"
}

# =============================================================================
# 로그 확인
# =============================================================================

cmd_logs() {
    check_kubectl
    check_cj_home

    export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"

    local service=$1

    case $service in
        janitor)
            log_info "Cloud Janitor 로그"
            kubectl logs -n default deployment/cloud-janitor -f
            ;;
        mysql)
            log_info "MySQL 로그"
            kubectl logs -n default statefulset/mysql -f
            ;;
        grafana)
            log_info "Grafana 로그"
            kubectl logs -n monitoring deployment/grafana -f
            ;;
        loki)
            log_info "Loki 로그"
            kubectl logs -n monitoring statefulset/loki -f
            ;;
        *)
            log_error "알 수 없는 서비스: $service"
            echo ""
            echo "사용 가능한 서비스:"
            echo "   cj logs janitor   # Cloud Janitor"
            echo "   cj logs mysql     # MySQL"
            echo "   cj logs grafana   # Grafana"
            echo "   cj logs loki      # Loki"
            exit 1
            ;;
    esac
}

# =============================================================================
# 수동 스캔
# =============================================================================

cmd_scan() {
    check_kubectl
    check_cj_home

    export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"

    if ! kubectl get deployment cloud-janitor -n default >/dev/null 2>&1; then
        log_error "cloud-janitor Deployment를 찾을 수 없습니다. 먼저 cj start를 실행하세요."
        exit 1
    fi

    local pod
    local retries=0
    while [ $retries -lt 30 ]; do
        pod=$(kubectl get pods -n default -l app=cloud-janitor -o go-template='{{range .items}}{{if and (eq .status.phase "Running") (not .metadata.deletionTimestamp)}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | tail -n1)
        if [ -n "$pod" ]; then
            break
        fi
        sleep 2
        retries=$((retries + 1))
    done
    if [ -z "$pod" ]; then
        log_error "실행 중인 cloud-janitor Pod가 없습니다. cj start 후 다시 시도하세요."
        exit 1
    fi

    log_info "수동 스캔 실행: $pod"
    kubectl exec -n default "$pod" -- python main.py scan
}

# =============================================================================
# 접속
# =============================================================================

cmd_grafana() {
    log_info "Grafana 접속: http://localhost:3000"
    
    # .env 파일 로드
    if [ -f "$CJ_HOME/.env" ]; then
        source "$CJ_HOME/.env"
        log_info "ID: admin, Password: ${GRAFANA_PASSWORD:-changeme}"
    else
        log_info "ID: admin, Password: changeme (.env 파일에서 GRAFANA_PASSWORD 설정)"
    fi

    if command -v xdg-open &> /dev/null; then
        xdg-open http://localhost:3000
    elif command -v open &> /dev/null; then
        open http://localhost:3000
    else
        log_info "브라우저를 직접 열어주세요: http://localhost:3000"
    fi
}

# =============================================================================
# 기타 명령어
# =============================================================================

cmd_env() {
    log_info ".env 파일 편집"
    
    if [ ! -f "$CJ_HOME/.env" ]; then
        log_warning ".env 파일이 없습니다. 생성합니다..."
        cp "$CJ_HOME/.env.example" "$CJ_HOME/.env"
    fi

    ${EDITOR:-vim} "$CJ_HOME/.env"
}

cmd_kubeconfig() {
    check_cj_home
    
    local kubeconfig="$CJ_HOME/terraform/cloud-janitor-cluster-config"
    
    if [ -f "$kubeconfig" ]; then
        echo "$kubeconfig"
        log_info "사용법: export KUBECONFIG=\"$kubeconfig\""
    else
        log_error "kubeconfig 파일을 찾을 수 없습니다."
        exit 1
    fi
}

cmd_shell() {
    check_cj_home
    log_info "Cloud Janitor 프로젝트 디렉토리로 이동 (exit로 종료)"
    cd "$CJ_HOME"
    bash
}

# =============================================================================
# Bootstrap (전체 자동화)
# =============================================================================

cmd_bootstrap() {
    log_step "🚀 Cloud Janitor 전체 자동 설정"
    echo ""
    log_info "이 명령어는 다음을 자동으로 실행합니다:"
    echo "   1. cj install   - CLI 설치"
    echo "   2. cj init      - 프로젝트 초기화"
    echo "   3. cj setup     - Kind 클러스터 생성 + Loki + MySQL + Grafana"
    echo "   4. cj start     - Cloud Janitor 배포"
    echo ""
    
    # 1. CLI 설치
    log_step "📦 STEP 1/4: CLI 설치"
    cmd_install
    
    # 2. 프로젝트 초기화
    log_step "🔧 STEP 2/4: 프로젝트 초기화"
    cmd_init
    
    # 3. 전체 설정
    log_step "🏗️  STEP 3/4: 클러스터 설정"
    cmd_setup
    
    # 4. 서비스 시작
    log_step "🎯 STEP 4/4: 서비스 시작"
    cmd_start
    
    log_step "✅ Cloud Janitor Bootstrap 완료!"
    echo ""
    echo "=========================================="
    echo "  🎉 서비스 접속 정보"
    echo "=========================================="
    echo ""
    echo "  📈 Grafana:      http://localhost:3000"
    echo "     ID: admin"
    echo "     PW: changeme (또는 .env에서 설정한 값)"
    echo ""
    echo "  📊 Loki API:     http://localhost:31000"
    echo "  🐍 CJ API:       http://localhost:30800"
    echo ""
    echo "=========================================="
    echo "  📝 다음 단계 (TC에서 실행)"
    echo "=========================================="
    echo ""
    echo "  TC 서버에서 다음 명령어를 실행하세요:"
    echo ""
    echo "  tc bootstrap -a <CJ_IP>"
    echo ""
    echo "  예시 (로컬호스트):"
    echo "  tc bootstrap -a localhost"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================

main() {
    local command=$1
    shift || true

    case $command in
        install)
            cmd_install
            ;;
        init)
            cmd_init
            ;;
        setup)
            cmd_setup
            ;;
        start)
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        clear)
            cmd_clear
            ;;
        tunnel)
            local subcmd=$1
            shift || true
            parse_tunnel_options "$@"
            case $subcmd in
                setup)
                    setup_ssh_tunnel
                    ;;
                teardown|stop)
                    teardown_ssh_tunnel
                    ;;
                status)
                    if [ -f "$CJ_HOME/.env" ]; then
                        # shellcheck disable=SC1090
                        source "$CJ_HOME/.env"
                    fi
                    TARGET_HOST="${CLI_TARGET_HOST:-${TARGET_HOST:-localhost}}"
                    PROMETHEUS_PORT="${CLI_PROMETHEUS_PORT:-${PROMETHEUS_PORT:-9091}}"
                    LOCAL_PROMETHEUS_PORT="${CLI_LOCAL_PORT:-${LOCAL_PROMETHEUS_PORT:-9091}}"
                    SSH_TUNNEL_PID=$(pgrep -f "ssh.*localhost:${LOCAL_PROMETHEUS_PORT}:${TARGET_HOST}:${PROMETHEUS_PORT}" || true)
                    if [ -n "$SSH_TUNNEL_PID" ]; then
                        log_success "SSH 터널 실행 중 (PID: $SSH_TUNNEL_PID)"
                    else
                        log_warning "SSH 터널이 실행 중이지 않습니다."
                    fi
                    ;;
                *)
                    log_error "알 수 없는 터널 명령어: $subcmd"
                    echo ""
                    echo "사용 가능한 명령어:"
                    echo "  cj tunnel setup [--host H --user U --port P --key K --remote-port RP --local-port LP]"
                    echo "  cj tunnel stop  [--host H --remote-port RP --local-port LP]"
                    echo "  cj tunnel status [--host H --remote-port RP --local-port LP]"
                    exit 1
                    ;;
            esac
            ;;
        tf)
            cmd_tf "$@"
            ;;
        status)
            cmd_status
            ;;
        logs)
            cmd_logs "$@"
            ;;
        scan)
            cmd_scan
            ;;
        grafana)
            cmd_grafana
            ;;
        env)
            cmd_env
            ;;
        kubeconfig)
            cmd_kubeconfig
            ;;
        shell)
            cmd_shell
            ;;
        bootstrap)
            cmd_bootstrap
            ;;
        version|--version|-v)
            show_version
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            log_error "알 수 없는 명령어: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}


main "$@"

#!/bin/bash

# =============================================================================
# Cloud Janitor CLI Tool
# 
# Cloud Janitor는 기존의 target-cluster에 연결(attach)하여
# target 내부에 Prometheus를 설치하고 모니터링하는 시스템
#
# 사용법:
#   cj install           # cj CLI 시스템 PATH에 등록 (설치)
#   cj init              # 프로젝트 초기화
#   cj setup             # 전체 설정 (target Prometheus 설치 + Mgmt Cluster 생성)
#   cj start             # 서비스 시작
#   cj stop              # 서비스 중지
#   cj tunnel <cmd>      # SSH 터널 관리 (setup, stop, status)
#   cj tf <command>      # Terraform 명령어 (init, apply, destroy, plan)
#   cj ans <playbook>    # Ansible playbook 실행
#   cj status            # 상태 확인
#   cj logs <service>    # 로그 확인
#   cj grafana           # Grafana 접속
#   cj help              # 도움말
#
# 아키텍처:
#   - target-cluster: 외부 서버에서 실행되는 Docker Compose 환경
#   - cj (Cloud Janitor): target에 SSH 터널을 통한 안전한 접근
#   - Management Cluster: cj에서 생성하는 Kind K8s (Grafana, Loki)
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

# 상태 파일
STATE_FILE="$CJ_HOME/.cj_state"

# Target 주소 (현재는 localhost, 실제로는 다른 서버)
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

# Ansible 설치 확인
check_ansible() {
    if ! command -v uv &> /dev/null; then
        log_error "uv가 설치되어 있지 않습니다."
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

# .env 파일 확인
check_env_file() {
    if [ ! -f "$CJ_HOME/.env" ]; then
        log_warning ".env 파일이 없습니다. .env.example을 복사합니다."
        cp "$CJ_HOME/.env.example" "$CJ_HOME/.env"
        log_warning ".env 파일을 설정해주세요. (특히 GRAFANA_PASSWORD, TARGET_HOST)"
        return 1
    fi
    return 0
}

# SSH 터널 설정
setup_ssh_tunnel() {
    check_env_file
    source "$CJ_HOME/.env"
    
    # SSH 터널 설정 확인
    USE_SSH_TUNNEL="${USE_SSH_TUNNEL:-true}"
    TARGET_HOST="${TARGET_HOST:-localhost}"
    TARGET_SSH_USER="${TARGET_SSH_USER:-root}"
    TARGET_SSH_PORT="${TARGET_SSH_PORT:-22}"
    TARGET_SSH_KEY="${TARGET_SSH_KEY:-~/.ssh/id_rsa}"
    PROMETHEUS_PORT="${PROMETHEUS_PORT:-9091}"
    
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
    SSH_TUNNEL_PID=$(pgrep -f "ssh.*${TARGET_HOST}.*${PROMETHEUS_PORT}" || true)
    if [ -n "$SSH_TUNNEL_PID" ]; then
        log_info "SSH 터널이 이미 실행 중입니다 (PID: $SSH_TUNNEL_PID)"
        return 0
    fi
    
    # SSH 터널 생성
    log_info "SSH 터널 생성 중: ${TARGET_HOST}:${PROMETHEUS_PORT} -> localhost:${PROMETHEUS_PORT}"
    log_info "SSH 사용자: ${TARGET_SSH_USER}@${TARGET_HOST}:${TARGET_SSH_PORT}"
    log_info "SSH 키: ${TARGET_SSH_KEY}"
    
    # SSH 키가 있는지 확인
    if [ ! -f "$TARGET_SSH_KEY" ]; then
        log_warning "SSH 키를 찾을 수 없습니다: ${TARGET_SSH_KEY}"
        log_warning "SSH 키 없이 비밀번호로 접속합니다 (비추천)"
    fi
    
    # SSH 터널 백그라운드 실행
    ssh -i "$TARGET_SSH_KEY" \
        -L "localhost:${PROMETHEUS_PORT}:${TARGET_HOST}:${PROMETHEUS_PORT}" \
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
        echo "$SSH_TUNNEL_PID" > "$CJ_HOME/.ssh_tunnel_pid"
    else
        log_error "SSH 터널 생성 실패"
        return 1
    fi
}

# SSH 터널 해제
teardown_ssh_tunnel() {
    SSH_TUNNEL_PID_FILE="$CJ_HOME/.ssh_tunnel_pid"
    
    if [ ! -f "$SSH_TUNNEL_PID_FILE" ]; then
        log_info "SSH 터널 PID 파일을 찾을 수 없습니다."
        return 0
    fi
    
    SSH_TUNNEL_PID=$(cat "$SSH_TUNNEL_PID_FILE")
    
    if ps -p "$SSH_TUNNEL_PID" > /dev/null 2>&1; then
        log_info "SSH 터널 종료 중 (PID: $SSH_TUNNEL_PID)..."
        kill "$SSH_TUNNEL_PID"
        log_success "SSH 터널 종료 완료"
    else
        log_info "SSH 터널이 이미 종료되었습니다."
    fi
    
    rm -f "$SSH_TUNNEL_PID_FILE"
}

# SSH 연결 확인
check_ssh_connection() {
    check_env_file
    source "$CJ_HOME/.env"
    
    TARGET_HOST="${TARGET_HOST:-localhost}"
    TARGET_SSH_USER="${TARGET_SSH_USER:-root}"
    TARGET_SSH_PORT="${TARGET_SSH_PORT:-22}"
    TARGET_SSH_KEY="${TARGET_SSH_KEY:-~/.ssh/id_rsa}"
    
    # 로컬이면 무시
    if [ "$TARGET_HOST" = "localhost" ]; then
        return 0
    fi
    
    log_info "SSH 연결 확인 중: ${TARGET_SSH_USER}@${TARGET_HOST}:${TARGET_SSH_PORT}"
    
    if ssh -i "$TARGET_SSH_KEY" \
        -p "${TARGET_SSH_PORT}" \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        "${TARGET_SSH_USER}@${TARGET_HOST}" \
        exit 2>/dev/null; then
        log_success "SSH 연결 성공"
        return 0
    else
        log_error "SSH 연결 실패"
        log_info "  - SSH 키 확인: $TARGET_SSH_KEY"
        log_info "  - 호스트 확인: $TARGET_HOST:$TARGET_SSH_PORT"
        log_info "  - 사용자 확인: $TARGET_SSH_USER"
        return 1
    fi
}

# State 파일 로드
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    fi
}

# State 파일 저장
save_state() {
    cat > "$STATE_FILE" << EOF
CJ_HOME="$CJ_HOME"
TF_INITIALIZED="${TF_INITIALIZED:-false}"
MGMT_CLUSTER_CREATED="${MGMT_CLUSTER_CREATED:-false}"
TARGET_PROMETHEUS_INSTALLED="${TARGET_PROMETHEUS_INSTALLED:-false}"
CLOUD_JANITOR_DEPLOYED="${CLOUD_JANITOR_DEPLOYED:-false}"
EOF
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
    echo -e "${BOLD}프로젝트 관리:${NC}"
    echo "  init              프로젝트 초기화 (.env 파일 생성, 의존성 설치 확인)"
    echo "  setup             전체 설정 (Target Prometheus 확인 + Mgmt Cluster 생성)"
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
    echo -e "${BOLD}Ansible (Target Prometheus 확인):${NC}"
    echo "  ans install       Target Prometheus 접속 확인"
    echo "  ans configure     Prometheus 설정 및 Grafana 연동"
    echo "  ans shell         Ansible playbook 실행 쉘"
    echo ""
    echo -e "${BOLD}상태 및 로그:${NC}"
    echo "  status            전체 시스템 상태 확인"
    echo "  logs [service]    로그 확인 (janitor, mysql, grafana, loki)"
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
    echo "  tunnel setup      SSH 터널 생성 (localhost:9091 → TARGET_HOST:9091)"
    echo "  tunnel stop       SSH 터널 종료"
    echo "  tunnel status     SSH 터널 상태 확인"
    echo ""
    echo -e "${BOLD}예시:${NC}"
    echo "  cj install                   # cj CLI 설치"
    echo "  cj init                      # 프로젝트 초기화"
    echo "  cj setup                     # 전체 설정"
    echo "  cj status                    # 상태 확인"
    echo "  cj logs janitor              # Cloud Janitor 로그"
    echo "  cj stop                      # 서비스 중지"
    echo ""
    echo -e "${BOLD}환경 변수:${NC}"
    echo "  CJ_HOME         Cloud Janitor 프로젝트 경로 (기본값: cj 스크립트 위치)"
    echo "  TARGET_HOST     Target 서버 주소 (기본값: localhost)"
    echo ""
}

show_version() {
    cat << EOF
Cloud Janitor CLI Tool v1.0.0
Zombie Pod Detection and Auto-Cleanup System

Project Path: $CJ_HOME
Target Host: $TARGET_HOST
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
    rm -f "$STATE_FILE"
    rm -f "$CJ_HOME/.ssh_tunnel_pid"

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
        log_warning "특히 TARGET_HOST를 설정하세요 (기본값: localhost)"
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

    # 쉘 타입 자동 감지
    SHELL_TYPE=""
    RC_FILE=""

    if [ -n "$ZSH_VERSION" ]; then
        SHELL_TYPE="zsh"
        RC_FILE="$HOME/.zshrc"
        log_info "감지된 쉘: zsh"
    elif [ -n "$BASH_VERSION" ]; then
        SHELL_TYPE="bash"
        RC_FILE="$HOME/.bashrc"
        log_info "감지된 쉘: bash"
    else
        SHELL_TYPE="bash"
        RC_FILE="$HOME/.bashrc"
        log_warning "쉘 타입을 감지할 수 없습니다. bash를 기본으로 사용합니다."
    fi

    echo ""

    # 1) 시스템 PATH에 심볼릭 링크 생성 시도
    log_info "시스템 PATH에 심볼릭 링크 생성 중..."

    LINK_LOCATIONS=(
        "/usr/local/bin/cj"
        "$HOME/.local/bin/cj"
    )

    LINK_SUCCESS=false

    for link_path in "${LINK_LOCATIONS[@]}"; do
        link_dir=$(dirname "$link_path")

        if [ ! -d "$link_dir" ]; then
            continue
        fi

        if [ ! -w "$link_dir" ]; then
            continue
        fi

        if [ -e "$link_path" ]; then
            rm -f "$link_path"
        fi

        ln -s "$CJ_CLI" "$link_path"
        log_success "심볼릭 링크 생성: $link_path → $CJ_CLI"
        LINK_SUCCESS=true
        break
    done

    if [ "$LINK_SUCCESS" = false ]; then
        log_warning "시스템 PATH에 심볼릭 링크를 생성할 수 없습니다."
    fi

    echo ""

    # 2) RC 파일에 PATH 추가
    log_info "$RC_FILE에 CJ_HOME과 PATH 추가 중..."

    if [ ! -f "$RC_FILE" ]; then
        log_warning "$RC_FILE 파일이 없습니다. 생성합니다."
        touch "$RC_FILE"
    fi

    # Cloud Janitor CLI 추가 (이미 있으면 무시)
    if ! grep -q "Cloud Janitor CLI" "$RC_FILE" 2>/dev/null; then
        cat >> "$RC_FILE" << EOF

# Cloud Janitor CLI
export CJ_HOME="$CJ_HOME"
export PATH="\$PATH:\$CJ_HOME"
EOF
        log_success "$RC_FILE에 추가 완료"
    else
        log_info "$RC_FILE에 이미 Cloud Janitor CLI 설정이 있습니다. (덮어쓰지 않음)"
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

    # .env 파일 로드
    source "$CJ_HOME/.env"

    # TARGET_HOST 설정 확인
    if [ -z "$TARGET_HOST" ]; then
        TARGET_HOST="localhost"
        log_warning "TARGET_HOST가 설정되지 않아 기본값(localhost)을 사용합니다."
        log_info ".env 파일에서 TARGET_HOST를 설정하세요."
    fi

    log_info "Target Host: $TARGET_HOST"
    echo ""

    # SSH 터널 설정 (외부 Target일 경우)
    if [ "$TARGET_HOST" != "localhost" ]; then
        log_info "외부 Target Cluster 감지됨. SSH 터널을 설정합니다."
        
        # SSH 연결 확인
        if ! check_ssh_connection; then
            log_error "SSH 연결 실패. 설정을 확인하세요."
            exit 1
        fi
        
        # SSH 터널 설정
        setup_ssh_tunnel || exit 1
    fi

    # 스크립트 종료 시 SSH 터널 해제
    trap teardown_ssh_tunnel EXIT

    # 1. Target Prometheus 확인
    log_info "STEP 1/4: Target Prometheus 확인"
    cmd_ans install

    # 2. Terraform 초기화
    if [ "$TF_INITIALIZED" != "true" ]; then
        log_info "STEP 2/4: Terraform 초기화"
        cmd_tf init
    else
        log_info "STEP 2/4: Terraform 이미 초기화됨"
    fi

    # 3. Management Cluster 생성
    if [ "$MGMT_CLUSTER_CREATED" != "true" ]; then
        log_info "STEP 3/4: Management Cluster 생성"
        cmd_tf apply -auto-approve
    else
        log_info "STEP 3/4: Management Cluster 이미 생성됨"
    fi

    # 4. Prometheus 설정 및 Grafana 연동
    log_info "STEP 4/4: Prometheus 설정 및 Grafana 연동"
    cmd_ans configure
    if [ "$TARGET_PROMETHEUS_INSTALLED" != "true" ]; then
        log_warning "Target Prometheus가 아직 실행되지 않았습니다."
        log_info "다음 순서로 진행하세요:"
        echo "   tc pm start"
        echo "   cj ans configure"
    fi

    # SSH 터널 유지 안내
    if [ "$TARGET_HOST" != "localhost" ]; then
        log_step "🔐 SSH 터널 유지"
        log_warning "SSH 터널이 백그라운드에서 실행 중입니다."
        log_warning "종료하려면: Ctrl+C 또는 cj tunnel stop"
        log_info "SSH 터널 확인: cj tunnel status"
    fi

    log_step "🎉 전체 설정 완료"
    echo ""
    log_info "접속 정보:"
    echo "   📊 Target Prometheus:  http://$TARGET_HOST:9091"
    echo "   📈 Grafana (Mgmt):     http://localhost:3000"
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
    load_state

    log_info "Cloud Janitor 서비스를 시작합니다..."

    # Management Cluster가 생성되어 있는지 확인
    if [ "$MGMT_CLUSTER_CREATED" != "true" ]; then
        log_warning "Management Cluster가 생성되지 않았습니다."
        log_info "먼저 다음을 실행하세요: cj setup"
        exit 1
    fi

    # kubeconfig 설정
    export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"

    # Cloud Janitor Pod가 실행 중인지 확인
    if kubectl get deployment cloud-janitor -n default &> /dev/null; then
        log_info "Cloud Janitor Deployment가 이미 존재합니다."
        log_info "Deployment를 재시작합니다..."
        kubectl rollout restart deployment/cloud-janitor -n default
    else
        log_warning "Cloud Janitor Deployment를 찾을 수 없습니다."
        log_info "Ansible로 Cloud Janitor를 배포합니다..."
        cd "$CJ_HOME"
        export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
        export ANSIBLE_ROLES_PATH="$ANSIBLE_DIR/roles"
        export ANSIBLE_LOCAL_TMP="${ANSIBLE_LOCAL_TMP:-/tmp/ansible}"
        export ANSIBLE_REMOTE_TMP="${ANSIBLE_REMOTE_TMP:-/tmp/ansible}"
        mkdir -p "$ANSIBLE_LOCAL_TMP"
        ensure_uv_sync
        uv run ansible-playbook "$ANSIBLE_DIR/playbooks/setup-cluster.yml"
    fi

    # 상태 확인
    log_info "Pod 상태 확인 중..."
    kubectl get pods -n default -l app=cloud-janitor

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

    log_info "서비스가 중지되었습니다."
    log_info "다시 시작하려면: cj start"
    echo ""
    log_info "다음 명령어 추천:"
    echo "   cj start"
}

cmd_clear() {
    log_step "🧹 로컬 정리"

    check_cj_home

    rm -f "$CJ_HOME/.ssh_tunnel_pid"
    rm -f "$CJ_HOME/terraform/cloud-janitor-cluster-config"
    rm -f "$CJ_HOME/terraform/terraform.tfstate"
    rm -f "$CJ_HOME/terraform/terraform.tfstate.backup"
    rm -f "$CJ_HOME/terraform/terraform.tfstate.lock.info"
    rm -f "$CJ_HOME/terraform/.terraform.lock.hcl"
    rm -rf "$CJ_HOME/terraform/.terraform"

    TF_INITIALIZED=false
    MGMT_CLUSTER_CREATED=false
    TARGET_PROMETHEUS_INSTALLED=false
    CLOUD_JANITOR_DEPLOYED=false
    save_state

    if command -v kind &> /dev/null; then
        if kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"; then
            log_warning "kind 클러스터는 남아있습니다. 필요하면 cj tf destroy를 실행하세요."
        fi
    fi

    log_success "로컬 상태 정리 완료"
    echo ""
    log_info "다음 명령어 추천:"
    echo "   cj tf init"
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
            echo "   cj ans configure"
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
            log_step "🧹 Terraform 로컬 상태 정리"
            rm -f "$CJ_HOME/terraform/cloud-janitor-cluster-config"
            rm -f "$CJ_HOME/terraform/terraform.tfstate"
            rm -f "$CJ_HOME/terraform/terraform.tfstate.backup"
            rm -f "$CJ_HOME/terraform/terraform.tfstate.lock.info"
            rm -f "$CJ_HOME/terraform/.terraform.lock.hcl"
            rm -rf "$CJ_HOME/terraform/.terraform"
            TF_INITIALIZED=false
            MGMT_CLUSTER_CREATED=false
            CLOUD_JANITOR_DEPLOYED=false
            save_state
            if command -v kind &> /dev/null; then
                if kind get clusters 2>/dev/null | grep -q "^cloud-janitor-cluster$"; then
                    log_warning "kind 클러스터는 남아있습니다. 필요하면 cj tf destroy를 실행하세요."
                fi
            fi
            log_success "Terraform 로컬 상태 정리 완료"
            echo ""
            log_info "다음 명령어 추천:"
            echo "   cj tf init"
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
# Ansible 명령어
# =============================================================================

cmd_ans() {
    local subcmd=$1
    shift || true

    check_ansible
    check_docker
    check_cj_home
    ensure_uv_sync

    export DOCKER_CONFIG="$CJ_HOME/.docker"

    # .env 파일 로드
    source "$CJ_HOME/.env"

    # TARGET_HOST 설정
    TARGET_HOST="${TARGET_HOST:-localhost}"

    export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
    export ANSIBLE_ROLES_PATH="$ANSIBLE_DIR/roles"
    export ANSIBLE_LOCAL_TMP="${ANSIBLE_LOCAL_TMP:-/tmp/ansible}"
    export ANSIBLE_REMOTE_TMP="${ANSIBLE_REMOTE_TMP:-/tmp/ansible}"
    mkdir -p "$ANSIBLE_LOCAL_TMP"

    cd "$CJ_HOME"

    case $subcmd in
        install)
            log_step "📦 Target Prometheus 확인"
            log_info "Target 서버: $TARGET_HOST"
            PROMETHEUS_URL="http://$TARGET_HOST:9091"

            if curl -s -o /dev/null -w "%{http_code}" "$PROMETHEUS_URL/-/healthy" | grep -q "200"; then
                TARGET_PROMETHEUS_INSTALLED=true
                save_state
                log_success "Target Prometheus 접속 성공"
            else
                TARGET_PROMETHEUS_INSTALLED=false
                save_state
                log_warning "Target Prometheus 접속 실패"
                log_info "먼저 실행하세요: tc pm start"
            fi
            echo ""
            log_info "다음 명령어 추천:"
            if [ "$TARGET_PROMETHEUS_INSTALLED" = "true" ]; then
                echo "   cj ans configure"
            else
                echo "   tc pm start"
            fi
            ;;
            
        configure)
            log_step "🔧 Prometheus 설정 및 Grafana 연동"
            
            # kubeconfig 설정
            export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"
            
            # Prometheus URL 확인
            PROMETHEUS_URL="http://$TARGET_HOST:9091"
            
            log_info "Prometheus URL: $PROMETHEUS_URL"
            
            # Prometheus 접속 확인
            if curl -s -o /dev/null -w "%{http_code}" "$PROMETHEUS_URL/-/healthy" | grep -q "200"; then
                log_success "Target Prometheus 접속 성공"
            else
                log_warning "Target Prometheus 접속 실패"
                log_info "먼저 실행하세요: tc pm start"
                echo ""
                log_info "다음 명령어 추천:"
                echo "   tc pm start"
                return 0
            fi
            
            # Grafana에 Target Prometheus 데이터소스 추가
            log_info "Grafana에 Target Prometheus 데이터소스 추가 중..."
            
            if [ -f "$CJ_HOME/ansible/playbooks/setup-target.yml" ]; then
                uv run ansible-playbook "$ANSIBLE_DIR/playbooks/setup-target.yml" \
                    -e "target_prometheus_url=$PROMETHEUS_URL"
                
                log_success "Prometheus 설정 및 Grafana 연동 완료"
            else
                log_warning "setup-target.yml를 찾을 수 없습니다."
                log_info "수동으로 Grafana에서 Target Prometheus를 데이터소스로 추가하세요."
                log_info "  URL: $PROMETHEUS_URL"
            fi
            echo ""
            log_info "다음 명령어 추천:"
            echo "   cj start"
            ;;
            
        shell)
            log_info "Ansible 쉘 시작 (exit로 종료)"
            bash
            ;;
            
        *)
            log_error "알 수 없는 Ansible 명령어: $subcmd"
            echo ""
            echo "사용 가능한 명령어:"
            echo "  cj ans install       Target Prometheus 접속 확인"
            echo "  cj ans configure     Prometheus 설정 및 Grafana 연동"
            echo "  cj ans shell          Ansible 쉘"
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
    load_state

    # .env 파일 로드
    if [ -f "$CJ_HOME/.env" ]; then
        source "$CJ_HOME/.env"
    fi
    TARGET_HOST="${TARGET_HOST:-localhost}"

    echo ""
    echo "🎯 Target Cluster (외부 서버):"
    echo "   Host: $TARGET_HOST"
    
    # Target Prometheus 확인
    PROMETHEUS_URL="http://$TARGET_HOST:9091"
    if curl -s -o /dev/null -w "%{http_code}" "$PROMETHEUS_URL/-/healthy" 2>/dev/null | grep -q "200"; then
        echo -e "   Prometheus: ${GREEN}실행 중${NC} ($PROMETHEUS_URL)"
    else
        echo -e "   Prometheus: ${RED}중지${NC} ($PROMETHEUS_URL)"
    fi

    echo ""
    echo "🎛️  Management Cluster:"
    if [ "$MGMT_CLUSTER_CREATED" = "true" ]; then
        echo -e "   상태: ${GREEN}생성됨${NC}"
        
        # kubeconfig 확인
        if [ -f "$CJ_HOME/terraform/cloud-janitor-cluster-config" ]; then
            export KUBECONFIG="$CJ_HOME/terraform/cloud-janitor-cluster-config"
            echo "   K8s Pods:"
            kubectl get pods -A --no-headers | head -5 | while read ns rest; do
                echo "     - $rest"
            done
        fi
    else
        echo -e "   상태: ${YELLOW}생성 안됨${NC}"
    fi

    echo ""
    echo "🐍 Cloud Janitor:"
    if [ "$CLOUD_JANITOR_DEPLOYED" = "true" ]; then
        echo -e "   상태: ${GREEN}배포됨${NC}"
    else
        echo -e "   상태: ${YELLOW}배포 안됨${NC}"
    fi

    echo ""
    echo "🔧 환경 변수:"
    echo "   CJ_HOME: $CJ_HOME"
    echo "   TARGET_HOST: $TARGET_HOST"
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
            case $subcmd in
                setup)
                    setup_ssh_tunnel
                    ;;
                teardown|stop)
                    teardown_ssh_tunnel
                    ;;
                status)
                    if [ -f "$CJ_HOME/.ssh_tunnel_pid" ]; then
                        SSH_TUNNEL_PID=$(cat "$CJ_HOME/.ssh_tunnel_pid")
                        if ps -p "$SSH_TUNNEL_PID" > /dev/null 2>&1; then
                            log_success "SSH 터널 실행 중 (PID: $SSH_TUNNEL_PID)"
                        else
                            log_warning "SSH 터널 PID 파일은 있지만 프로세스가 없습니다."
                        fi
                    else
                        log_warning "SSH 터널이 실행 중이지 않습니다."
                    fi
                    ;;
                *)
                    log_error "알 수 없는 터널 명령어: $subcmd"
                    echo ""
                    echo "사용 가능한 명령어:"
                    echo "  cj tunnel setup    SSH 터널 생성"
                    echo "  cj tunnel stop     SSH 터널 종료"
                    echo "  cj tunnel status  SSH 터널 상태 확인"
                    exit 1
                    ;;
            esac
            ;;
        tf)
            cmd_tf "$@"
            ;;
        ans)
            cmd_ans "$@"
            ;;
        status)
            cmd_status
            ;;
        logs)
            cmd_logs "$@"
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

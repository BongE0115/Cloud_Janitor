#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CUSTOM_FILE="$SCRIPT_DIR/.whitelist.custom"
DEFAULT_WHITELIST="target-prometheus,promtail,cadvisor"

CJ_HOST="${CJ_HOST:-localhost}"
CJ_PORT="${CJ_PORT:-30800}"
TC_NAME="${TC_NAME:-tc-target}"
SYNC=true

usage() {
    cat << EOF
Usage: $0 <command> [options]

commands:
  list                    tc-network 컨테이너 목록 표시
  show                    base/custom/effective 화이트리스트 표시
  set "<csv>"             사용자(custom) 화이트리스트 전체 교체
  add "<csv>"             사용자(custom) 화이트리스트 추가
  remove "<csv>"          사용자(custom) 화이트리스트 제거
  pick                    컨테이너 목록에서 번호 선택해 custom 저장
  sync                    base+custom 묶어서 CJ로 즉시 반영

options:
  -a, --cj-host HOST      CJ API 호스트 (기본: localhost)
  -p, --cj-port PORT      CJ API 포트 (기본: 30800)
  -n, --tc-name NAME      TC 이름 (기본: tc-target)
  --no-sync               custom 파일만 수정 (CJ 즉시 반영 안 함)
  -h, --help              도움말

examples:
  $0 list
  $0 pick -a localhost -n tc-target
  $0 set "app-active,app-zombie-dev"
EOF
}

get_containers() {
    docker ps --filter "network=tc-network" --format '{{.Names}}' | sort -u
}

read_base_whitelist() {
    if [ -f "$ENV_FILE" ]; then
        local line
        line=$(grep -E '^CJ_CONTAINER_WHITELIST=' "$ENV_FILE" || true)
        if [ -n "$line" ]; then
            echo "${line#CJ_CONTAINER_WHITELIST=}"
            return
        fi
    fi
    echo "$DEFAULT_WHITELIST"
}

read_custom_whitelist() {
    if [ -f "$CUSTOM_FILE" ]; then
        local raw
        raw=$(tr -d '\n' < "$CUSTOM_FILE")
        echo "$raw"
        return
    fi
    echo ""
}

normalize_csv() {
    python3 - "$1" << 'PY'
import sys
items = [x.strip() for x in (sys.argv[1] or "").split(",")]
seen = set()
out = []
for x in items:
    if not x or x in seen:
        continue
    seen.add(x)
    out.append(x)
print(",".join(out))
PY
}

merge_csv() {
    normalize_csv "$1,$2"
}

read_effective_whitelist() {
    merge_csv "$(read_base_whitelist)" "$(read_custom_whitelist)"
}

write_custom_whitelist() {
    local csv="$1"
    csv="$(normalize_csv "$csv")"
    if [ -n "$csv" ]; then
        echo "$csv" > "$CUSTOM_FILE"
    else
        rm -f "$CUSTOM_FILE"
    fi
    if [ -n "$csv" ]; then
        log_success "custom 저장 완료: $csv"
    else
        log_success "custom 화이트리스트 제거 완료"
    fi
    log_info ".env(base)는 변경하지 않습니다."
}

sync_to_cj() {
    local csv="$1"
    [ "$SYNC" = false ] && return 0
    local json_list
    json_list=$(python3 - "$csv" << 'PY'
import json,sys
vals=[x.strip() for x in (sys.argv[1] or "").split(",") if x.strip()]
print(json.dumps({"container_whitelist": vals}, ensure_ascii=False))
PY
)
    local url="http://${CJ_HOST}:${CJ_PORT}/api/v1/targets/${TC_NAME}/whitelist"
    log_info "CJ 실시간 반영 요청: $url"
    if curl -fsS -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$json_list" >/dev/null 2>&1; then
        log_success "CJ 화이트리스트 실시간 반영 완료"
    else
        log_warning "CJ 실시간 반영 실패 (TC 등록/주소 확인 필요). custom 파일 값은 저장됨"
    fi
}

command="${1:-}"
[ -z "$command" ] && { usage; exit 1; }
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--cj-host) CJ_HOST="$2"; shift 2 ;;
        -p|--cj-port) CJ_PORT="$2"; shift 2 ;;
        -n|--tc-name) TC_NAME="$2"; shift 2 ;;
        --no-sync) SYNC=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) break ;;
    esac
done

case "$command" in
    list)
        get_containers
        ;;
    show)
        echo "BASE      : $(read_base_whitelist)"
        echo "CUSTOM    : $(read_custom_whitelist)"
        echo "EFFECTIVE : $(read_effective_whitelist)"
        ;;
    set)
        [ -z "${1:-}" ] && { log_error "set 값이 필요합니다"; exit 1; }
        custom="$(normalize_csv "$1")"
        write_custom_whitelist "$custom"
        sync_to_cj "$(read_effective_whitelist)"
        ;;
    add)
        [ -z "${1:-}" ] && { log_error "add 값이 필요합니다"; exit 1; }
        custom="$(merge_csv "$(read_custom_whitelist)" "$1")"
        write_custom_whitelist "$custom"
        sync_to_cj "$(read_effective_whitelist)"
        ;;
    remove)
        [ -z "${1:-}" ] && { log_error "remove 값이 필요합니다"; exit 1; }
        custom=$(python3 - "$(read_custom_whitelist)" "$1" << 'PY'
import sys
cur=[x.strip() for x in sys.argv[1].split(",") if x.strip()]
rm={x.strip() for x in sys.argv[2].split(",") if x.strip()}
print(",".join([x for x in cur if x not in rm]))
PY
)
        write_custom_whitelist "$custom"
        sync_to_cj "$(read_effective_whitelist)"
        ;;
    pick)
        mapfile -t arr < <(get_containers)
        if [ "${#arr[@]}" -eq 0 ]; then
            log_error "tc-network에서 컨테이너를 찾지 못했습니다."
            exit 1
        fi
        echo "번호를 쉼표로 입력하세요. 예: 1,3,4"
        for i in "${!arr[@]}"; do
            printf "  %d) %s\n" "$((i+1))" "${arr[$i]}"
        done
        printf "선택: "
        read -r pick
        custom=$(python3 - "$pick" "$(read_base_whitelist)" "${arr[@]}" << 'PY'
import sys
sel=[x.strip() for x in (sys.argv[1] or "").split(",") if x.strip()]
base={x.strip() for x in sys.argv[2].split(",") if x.strip()}
arr=sys.argv[3:]
out=[]
seen=set()
for s in sel:
    if not s.isdigit():
        continue
    idx=int(s)-1
    if idx<0 or idx>=len(arr):
        continue
    v=arr[idx]
    if v in seen:
        continue
    if v in base:
        # base whitelist는 custom에 중복 저장하지 않음
        continue
    seen.add(v)
    out.append(v)
print(",".join(out))
PY
)
        write_custom_whitelist "$custom"
        sync_to_cj "$(read_effective_whitelist)"
        ;;
    sync)
        sync_to_cj "$(read_effective_whitelist)"
        ;;
    *)
        usage
        exit 1
        ;;
esac

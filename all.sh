# 1. CLI 설치 (선택사항, 이미 설치되어 있으면 생략)
./cj install
./tc install

# ========================================
# 🛠️ 수동 실행
# ========================================

# 2. 초기화
cj init

# 3. TC 앱 시작
tc start

# 4. TC Prometheus + Promtail 시작
tc pm start

# 5. cj 설정 (Grafana/Loki/MySQL 준비)
cj setup

# 6. cj 서비스 시작
cj start

# 7. TC → cj 연결 요청
tc connect -a localhost

# (선택) TC에서 화이트리스트 직접 설정
#  - base(고정): target-cluster/.env 의 CJ_CONTAINER_WHITELIST
#    (whitelist 명령으로 수정되지 않음)
#  - custom(사용자): tc whitelist set/add/remove/pick
#    (target-cluster/.whitelist.custom 에 저장)
#  - 전송 방식: tc connect 시 base+custom을 합쳐 labels.container_whitelist로 동봉 전송
#  - 실시간 반영: tc whitelist ... -a localhost -n tc-target
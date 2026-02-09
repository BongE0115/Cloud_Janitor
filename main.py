import logging
import sys
import os

# [시스템 경로 설정] 
# py_Logic 폴더 안에 있는 config, janitor_logic 등을 불러오기 위해 경로를 등록합니다.
sys.path.append(os.path.join(os.path.dirname(__file__), 'py_Logic'))

try:
    from py_Logic import config
    from py_Logic.janitor_logic import run_janitor_process
except ImportError as e:
    print(f"❌ 모듈 로드 실패: {e}")
    print("💡 py_Logic 폴더와 그 안의 파일들이 정확한 위치에 있는지 확인하세요.")
    sys.exit(1)

# =================================================================
# [사용자 설정 구역] - 여기서 청소 기준과 환경을 제어합니다.
# =================================================================

# --- 1. 좀비 파드 판정 수치 기준 ---
# CPU 사용량이 이 수치보다 낮으면 '일 안 하는 파드'로 간주합니다. (단위: m = milliCPU)
config.LIMIT_CPU_M = 10.0           
# CPU를 감시할 시간 범위입니다. (예: "2m"은 최근 2분간의 평균치를 확인)
config.TIME_WINDOW_CPU = "2m"       

# 네트워크 수신량이 이 수치보다 낮으면 '통신이 없는 파드'로 간주합니다. (단위: Bytes)
config.LIMIT_NET_B = 100.0          
# 네트워크 활동을 감시할 시간 범위입니다.
config.TIME_WINDOW_NET = "2m"

# --- 2. 비용 계산 및 실행 모드 설정 ---
# 1개 코어(1000m)를 1시간 동안 사용했을 때 발생하는 비용 (US 달러 기준)
config.COST_PER_CORE_HOUR = 0.1     
# 파드 설정에 CPU 요청량(Request)이 없을 경우, 비용 계산을 위해 적용할 기본값 (0.2 = 200m)
config.DEFAULT_CPU_REQ = 0.2        
# [중요] DRY_RUN 설정
# True: 삭제는 하지 않고 어떤 파드가 좀비인지 목록만 출력 (테스트용)
# False: 좀비 파드를 발견 즉시 삭제하고 DB에 기록 (실전용)
config.DRY_RUN = True             

# --- 3. 대상 네임스페이스(구역) 설정 ---
# 절대 건드리지 말아야 할 안전 구역 (보통 시스템 인프라 관련 네임스페이스)
config.WHITE_LIST_NS = [
    'kube-system', 
    'prometheus', 
    'local-path-storage', 
    'monitoring'
]
# 좀비 파드를 찾아내서 청소할 대상 구역
config.TARGET_NAMESPACES = [
    'default', 
    'zombie-zone', 
    'target-workloads'
]

# --- 4. 외부 시스템 연결 정보 ---
# 지표를 가져올 프로메테우스 서버 주소 (포트 포워딩 상태여야 함)
config.PROMETHEUS_URL = "http://localhost:9090"

# 청소 내역(Billing Log)을 저장할 MySQL 데이터베이스 정보
config.DB_CONFIG = {
    "host": "127.0.0.1",              # DB 서버 주소
    "user": "root",                   # 접속 계정
    "password": "1234",               # 비밀번호
    "database": "janitor_db",         # 데이터베이스 이름
    "auth_plugin": "mysql_native_password"
}
# =================================================================

if __name__ == "__main__":
    # 로그 출력 형식 설정 (시간 [로그레벨] 메시지)
    logging.basicConfig(
        level=logging.INFO, 
        format='%(asctime)s [%(levelname)s] %(message)s'
    )
    
    # 설정된 모든 값을 가지고 실제 소탕 로직(janitor_logic)을 실행합니다.
    run_janitor_process()
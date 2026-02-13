import os
import sys
from dotenv import load_dotenv  # .env 파일에 정의된 환경 변수를 로드하기 위한 라이브러리


# 프로젝트의 로직 폴더(py_Logic)를 파이썬 경로에 등록하여 임포트 가능하게 함
sys.path.append(os.path.join(os.path.dirname(__file__), 'py_Logic'))


# .env 파일의 내용을 환경 변수로 불러옴 (파일이 없어도 에러 없이 통과됨)
load_dotenv()

try:
    # 메인 소탕 로직이 담긴 함수를 임포트
    from py_Logic.janitor_logic import run_janitor
except ImportError as e:
    # 파일이 없거나 경로가 틀렸을 경우 에러 메시지 출력 후 종료
    print(f"❌ 로직 파일을 로드할 수 없습니다: {e}")
    sys.exit(1)

def main():
    # os.getenv('환경변수명', '기본값')을 사용하여 설정값을 가져옴
    # 환경변수(.env 포함)가 설정되어 있지 않으면 우측의 기본값을 자동으로 사용함 (하드코딩 방지)
    config = {
        # --- [판정 기준] ---
        "LIMIT_CPU_M": float(os.getenv('LIMIT_CPU_M', 10.0)),       # CPU 사용량 10m 미만 시 좀비 후보
        "TIME_WINDOW_CPU": os.getenv('TIME_WINDOW_CPU', '2m'),      # CPU 평균 계산 시간 (2분 간격)
        "LIMIT_NET_B": float(os.getenv('LIMIT_NET_B', 100.0)),     # 네트워크 100바이트 미만 시 좀비 후보
        "TIME_WINDOW_NET": os.getenv('TIME_WINDOW_NET', '2m'),      # 네트워크 감시 시간 (2분 간격)
        "LIMIT_MEM_MI": float(os.getenv('LIMIT_MEM_MI', 1.0)),      # 메모리 1MiB 미만 (로그 출력 및 참고용)
        
        # --- [유예 기간 설정] ---
        "GRACE_PERIOD_MINUTES": int(os.getenv('GRACE_PERIOD_MINUTES', 3)), # 좀비 탐지 후 삭제까지 대기할 유예 기간 (분 단위)
        #  "GRACE_PERIOD_DAYS": int(os.getenv('GRACE_PERIOD_DAYS', 3)), 좀비 탐지 후 삭제까지 대기할 유예 기간 (일 단위)
        # --- [비용 계산] ---
        "COST_PER_CORE_HOUR": float(os.getenv('COST_PER_CORE_HOUR', 0.1)), # 시간당 1코어 사용 시 발생하는 비용 ($)
        "DEFAULT_CPU_REQ": float(os.getenv('DEFAULT_CPU_REQ', 0.2)),       # 파드에 CPU 설정이 없을 때 적용할 기본값

        # --- [데이터베이스 접속] ---
        "DB_CONFIG": {
            "host": os.getenv('DB_HOST', '127.0.0.1'),             # 데이터베이스 서버 주소
            "user": os.getenv('DB_USER', 'root'),                  # 접속 계정 아이디
            "password": os.getenv('DB_PASSWORD', 'rootpassword'),  # 접속 계정 비밀번호
            "database": os.getenv('DB_NAME', 'janitor_db'),        # 사용할 데이터베이스 이름
            "auth_plugin": "mysql_native_password"                 # MySQL 8.0 이상 호환을 위한 플러그인 설정
        },

        # --- [인프라 제어] ---
        "PROMETHEUS_URL": os.getenv('PROMETHEUS_URL', 'http://localhost:9090'), # 프로메테우스 접속 API 주소
        "DRY_RUN": os.getenv('DRY_RUN', 'False') == 'True',        # True일 경우 실제 DB 등록 없이 목록만 확인
        "WHITE_LIST_NS": ['kube-system', 'prometheus', 'local-path-storage', 'monitoring'], # 삭제 방지 보호 네임스페이스
        "TARGET_NAMESPACES": ['default', 'zombie-zone']              # 좀비를 탐색할 대상 네임스페이스
    }

    # 취합된 모든 설정 정보(config)를 로직 실행 함수로 전달
    run_janitor(config)

if __name__ == "__main__":
    # 프로그램 실행 시 가장 먼저 main 함수 호출
    main()
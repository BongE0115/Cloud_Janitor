import os
import sys
from dotenv import load_dotenv  # .env 파일에 정의된 환경 변수를 로드하기 위한 라이브러리


# 프로젝트의 로직 폴더(py_Logic)를 파이썬 경로에 등록하여 임포트 가능하게 함
sys.path.append(os.path.join(os.path.dirname(__file__), 'py_Logic'))


# .env 파일의 내용을 환경 변수로 불러옴 (파일이 없어도 에러 없이 통과됨)
load_dotenv()

try:
    # 실제 삭제 및 빌링 기록 로직이 담긴 함수를 임포트
    from py_Logic.janitor_logic import run_cleanup
except ImportError as e:
    # 파일이 없거나 경로가 틀렸을 경우 에러 메시지 출력 후 종료
    print(f"❌ 로직 파일을 로드할 수 없습니다: {e}")
    sys.exit(1)

def main():
    # os.getenv('환경변수명', '기본값')을 사용하여 설정값을 가져옴
    # Phase 2(삭제) 단계에서는 비용 계산과 DB 접속 정보가 핵심입니다.
    config = {
        # --- [비용 계산] ---
        "COST_PER_CORE_HOUR": float(os.getenv('COST_PER_CORE_HOUR', 0.1)), # 시간당 1코어 사용 시 발생하는 비용 ($)
        "DEFAULT_CPU_REQ": float(os.getenv('DEFAULT_CPU_REQ', 0.2)),       # 파드에 CPU 설정이 없을 때 적용할 기본값

        # --- [데이터베이스 접속] ---
        "DB_CONFIG": {
            "host": os.getenv('DB_HOST', '127.0.0.1'),             # 데이터베이스 서버 주소
            "user": os.getenv('DB_USER', 'root'),                  # 접속 계정 아이디
            "password": os.getenv('DB_PASSWORD', 'rootpassword'),  # 접속 계정 비밀번호
            "database": os.getenv('DB_NAME', 'cloud_janitor'),     # 사용할 데이터베이스 이름
            "auth_plugin": "mysql_native_password"                 # MySQL 8.0 이상 호환을 위한 플러그인 설정
        },

        # --- [인프라 제어] ---
        # 실제 파드를 삭제하기 위해 K8s 인증이 필요하므로 관련 설정을 포함합니다.
        "PROMETHEUS_URL": os.getenv('PROMETHEUS_URL', 'http://localhost:9090'),
    }

    # 대기열을 확인하여 유예 기간이 지난 파드를 실제로 소탕하는 함수 호출
    print("🧹 [Phase 2] 삭제 대기열 만료 파드 실제 소탕 및 빌링 기록을 시작합니다.")
    run_cleanup(config)

if __name__ == "__main__":
    # 프로그램 실행 시 가장 먼저 main 함수 호출
    main()
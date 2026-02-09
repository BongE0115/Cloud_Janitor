import os
import requests
from kubernetes import client, config as k8s_config

def get_k8s_client():
    try:
        # 로컬 인증 파일 경로 설정 (~/.kube/config)
        kube_config_path = os.path.expanduser("~/.kube/config")
        
        if os.path.exists(kube_config_path):
            # 🏠 파일이 있는 경우: 로컬(내 컴퓨터/VM) 환경
            k8s_config.load_kube_config(config_file=kube_config_path)
            print(">>> [AUTH] 🏠 로컬 환경 인증 파일(.kube/config)을 사용합니다.") # 접속 위치 출력
        else:
            # ☸️ 파일이 없는 경우: 쿠버네티스 파드 내부 환경
            k8s_config.load_incluster_config()
            print(">>> [AUTH] ☸️ 클러스터 내부 서비스 어카운트(SA) 토큰을 사용합니다.") # 접속 위치 출력
            
        return client.CoreV1Api()
    except Exception as e:
        # 인증 오류 발생 시 메시지 출력
        print(f">>> [AUTH] ❌ 인증 실패: {str(e)}")
        return None


def get_prom_val(url, query):
    """
    프로메테우스 서버에 PromQL 쿼리를 날려 결과값(숫자)을 가져옵니다.
    """
    try:
        # HTTP 요청을 보냄 (3초 타임아웃 설정으로 무한 대기 방지)
        res = requests.get(f"{url}/api/v1/query", params={'query': query}, timeout=3).json()
        result = res.get('data', {}).get('result', [])
        
        # 결과 리스트에 데이터가 있으면 숫자 값만 추출해서 반환
        return float(result[0]['value'][1]) if result else 0.0
    except Exception:
        # 네트워크 오류 등으로 실패 시 0.0 반환
        return 0.0
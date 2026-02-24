import time
import requests

target_url = "http://nginx-server"

while True:
    # 1. 1분간 폭풍 통신
    print(f"[{time.strftime('%H:%M:%S')}] 특작 모드: Nginx로 집중 부하 생성!")
    end_time = time.time() + 60
    while time.time() < end_time:
        try:
            # 쉼 없이 요청을 보내서 네트워크 지표를 끌어올림
            requests.get(target_url, timeout=1)
        except:
            pass
    
    # 2. 1분간 휴식 (가짜 좀비 상태)
    print(f"[{time.strftime('%H:%M:%S')}] 특작 모드: 통신 중단 및 휴식 중...")
    time.sleep(60)
import time
import requests

# 내부 서비스 이름으로 주소 설정
target_url = "http://nginx-server" 

print(f"정상 네트워크 파드 시작: {target_url}로 내부 통신을 시작합니다.")

while True:
    try:
        # 내부 Nginx로 요청 발송
        response = requests.get(target_url, timeout=2)
        print(f"[정상] Nginx 응답 완료 (코드: {response.status_code})")
        
        # CPU 부하를 위한 미세 연산
        _ = [x**2 for x in range(500)]
        
        # 내부 통신이므로 속도를 더 높여도 안전합니다 (0.1초 대기)
        time.sleep(0.1)
    except Exception as e:
        print(f"[오류] Nginx 연결 실패. 서버가 떠 있는지 확인하세요: {e}")
        time.sleep(2)
import time
import sys

def draw_ram(percent):
    # 메모리 칩 모양 아스키 아트
    ram_art = [
        "  _________________  ",
        " [ ### RAM CHIP ### ] ",
        f" [ Usage: {percent}%   ] ",
        " [_________________] ",
        "  || || || || || ||  "
    ]
    for line in ram_art:
        print(line)

print("--- [정상] 메모리 부하 생성기 시작 ---")
dummy_storage = []

while True:
    # 데이터 추가 (메모리 점유)
    if len(dummy_storage) < 50: # 로컬 환경 보호를 위해 약 500MB~1GB 내외 유지
        dummy_storage.append("M" * (10**7)) # 약 10MB씩 추가
    
    # 출력
    print("\033[H\033[J", end="") # 화면 클리어 (선택 사항)
    current_usage = len(dummy_storage) * 2 # 대략적인 퍼센트 표시
    draw_ram(min(current_usage, 99))
    print(f"\n현재 메모리 블록 점유 중... (Count: {len(dummy_storage)})")
    print("상태: 정상 작동 중 (KEEP ALIVE)")
    
    time.sleep(2) # 메모리는 한 번 점유하면 유지되므로 천천히 루프
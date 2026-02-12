import time
import random
import os

# OS에 따라 화면 클리어 설정
clear_cmd = 'cls' if os.name == 'nt' else 'clear'

def draw_forge(is_working, elapsed):
    if is_working:
        # 일할 때: 불꽃과 망치질 애니메이션 (CPU 부하 유도)
        sparks = ["*", ".", "o", "O", "🔥", "✨"]
        print("="*30)
        print(f" [상태: 제련 중!!] 경과: {int(elapsed)}초")
        print("="*30)
        for _ in range(5):
            line = "".join(random.choice(sparks) if i in range(5, 15) else " " for i in range(20))
            print(f"      {line}")
        print("     [  ⚒️  ]  <-- 망치질 중!")
        print("      |  |")
    else:
        # 쉴 때: 화로가 식은 상태 (CPU/IOPS ≈ 0)
        print("="*30)
        print(f" [상태: 휴식 중...] 다음 제련까지 대기")
        print("="*30)
        for _ in range(5):
            print(" ")
        print("     [  💤  ]  <-- 가짜 좀비 상태")
        print("      |  |")

# 무한 루프 시작
while True:
    # 1. 1분간 열일 모드 (CPU 부하 가동)
    start_time = time.time()
    while time.time() - start_time < 60:
        elapsed = time.time() - start_time
        
        # [부하 추가] 의미 없는 수학 연산으로 CPU 사용량 상승
        for _ in range(1000000):
            _ = 123 * 456
            
        # os.system(clear_cmd) # 로그를 깔끔하게 보려면 주석 해제
        draw_forge(True, elapsed)
        time.sleep(0.1)

    # 2. 1분간 휴식 모드 (좀비로 오해받기 딱 좋은 시간)
    print("\n" + "!"*30)
    print("제련 완료! 1분간 휴식합니다.")
    print("!"*30)
    
    # 1분 동안 아무것도 안 함 (이때 main.py가 얘를 죽일지 말지 결정하게 됨)
    time.sleep(60)
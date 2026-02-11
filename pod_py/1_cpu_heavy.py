import time
import random

def draw_engine(frame):
    # 피스톤이 움직이는 듯한 애니메이션
    frames = [
        "    |--|  \n    |  |  \n   /    \\ ",
        "    ____  \n    |--|  \n    |  |  ",
        "    ____  \n   /    \\ \n    |--|  "
    ]
    print("--- [정상] CPU 엔진 가동 중 ---")
    print(frames[frame % 3])
    print("   [POWER: MAX]   ")

print("무한 연산 시작...")
counter = 0

while True:
    # [CPU 부하] 미친 듯한 연산
    for _ in range(1000000):
        _ = 999 * 999
    
    # 애니메이션 출력
    # os.system('clear') 대신 줄바꿈으로 로그에 남김
    print("-" * 20)
    draw_engine(counter)
    counter += 1
    
    # 너무 많이 쌓이지 않게 조절
    time.sleep(0.5)
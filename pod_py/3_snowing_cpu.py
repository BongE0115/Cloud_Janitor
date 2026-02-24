import time
import random
import os

# OS에 따라 화면을 깔끔하게 유지하기 위한 설정
clear_cmd = 'cls' if os.name == 'nt' else 'clear'

def draw_snow_tree(elapsed_time):
    snow_chars = [" ", " ", ".", "*", " "]
    # 1. 눈 내리는 풍경 출력
    for i in range(10):
        line = "".join(random.choice(snow_chars) for _ in range(20))
        print(f"\033[37m{line}\033[0m") # 하얀색 눈 효과
    
    # 2. 트리 밑동 출력
    print("      V      \n     [ ]     ") 
    
    # 3. 경과 시간 출력 (이 부분이 추가되었습니다)
    print(f"\n[상태: 작동 중] 축제 시작 후 {int(elapsed_time)}초 경과... (60초 후 종료)")

# 1. 처음 1분간은 눈이 내리며 일함 (정상 상태)
print("크리스마스 축제 시작!")
start_time = time.time()

while True:
    current_time = time.time()
    elapsed = current_time - start_time
    
    if elapsed < 60:
        # 화면을 깨끗하게 지우고 다시 그리기 (실시간 효과)
        # 로그로 볼 때는 지저분할 수 있으니 필요 없으면 os.system 줄을 주석 처리하세요.
        # os.system(clear_cmd) 
        
        draw_snow_tree(elapsed)
        
        # CPU 부하를 위한 연산
        _ = [i**2 for i in range(2000)]
        time.sleep(0.5) # 초당 2번 정도 업데이트
    else:
        break

# 2. 1분 뒤 축제 종료 (좀비 상태로 진입)
print("\n" + "="*30)
print("축제가 끝났습니다. 모두 잠듭니다... (좀비화)")
print("현재 상태: IDLE (CPU/IOPS ≈ 0)")
print("="*30)

while True:
    # 좀비 상태가 된 후에도 로그에서 확인 가능하도록 1시간마다 한 줄씩만 출력
    time.sleep(3600)
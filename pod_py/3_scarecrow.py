import time
import sys

def print_progress_bar(iteration, total, length=30):
    percent = ("{0:.1f}").format(100 * (iteration / float(total)))
    filled_length = int(length * iteration // total)
    bar = '█' * filled_length + '-' * (length - filled_length)
    # \r을 사용해 한 줄에서 숫자가 올라가게 함
    sys.stdout.write(f'\r작업 진행 중: |{bar}| {percent}% 완료')
    sys.stdout.flush()

# 1. 실제 작업 수행 (약 1분간 진행 바 출력)
print("--- [MISSION: DATA ANALYSIS] ---")
total_steps = 600
for i in range(total_steps):
    # CPU 부하 연산
    _ = [x**2 for x in range(2500)]
    
    # 0.1초마다 진행 바 업데이트
    if i % 10 == 0:
        print_progress_bar(i + 1, total_steps)
    time.sleep(0.1)

print_progress_bar(total_steps, total_steps)
print("\n\n[SUCCESS] 모든 데이터 분석이 완료되었습니다!")
print("상태: 결과 보고 대기 중... (하지만 담당자가 퇴근함)")

# 2. 작업 완료 후 허수아비 좀비 등장
scarecrow = [
    "      _  _      ",
    "     (o)(o)     <-- 눈만 멀뚱멀뚱",
    "    /  __  \\    ",
    "   /|      |\\   ",
    "    |  ||  |    ",
    "    |  ||  |    ",
    "    /      \\    ",
    "   ~~~~~~~~~~   ",
    "   Z O M B I E  "
]

print("\n" + "!"*30)
for line in scarecrow:
    print(line)
    time.sleep(0.2)
print("!"*30)
print("현재 상태: IDLE (사용량 0, 삭제 대기 중)")

# 3. 무한 잠자기 (좀비화)
while True:
    time.sleep(3600)
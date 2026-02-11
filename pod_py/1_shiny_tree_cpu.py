import time
import random
import os

# OS에 따라 화면 클리어
clear_cmd = 'cls' if os.name == 'nt' else 'clear'

color_format = ['\033[31m', '\033[32m', '\033[33m','\033[34m', '\033[35m','\033[36m', '\033[37m', '\033[0m']

tree = [
    "      * ",
    "     *** ",
    "    ***** ",
    "   ******* ",
    "  ********* ",
    " *********** ",
    "*************",
    "      |      ",
    "      |      "
]

while True:
    # [부하 추가] 트리를 그리기 전에 엄청난 연산을 수행합니다.
    # 이 부분이 그라파나의 CPU 그래프를 치솟게 만듭니다.
    for _ in range(500000):
        _ = 100 * 100 

    os.system(clear_cmd)
    for line in tree:
        colored_line = ''.join(f"{random.choice(color_format)}{char}" if char == '*' \
                               else f"{color_format[-1]}{char}" for char in line)
        print(colored_line)
    
    # sleep을 아주 짧게 주거나 없애면 CPU 부하가 더 커집니다.
    time.sleep(0.05)
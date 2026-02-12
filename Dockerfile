# 1. 베이스 이미지: 가볍고 빠른 3.12-slim
FROM python:3.12-slim

# 2. 작업 디렉토리 설정
WORKDIR /app

# 3. 환경 변수 설정
# - 파이썬 로그가 버퍼링 없이 즉시 출력되도록 설정 (K8s 로그 확인용)
ENV PYTHONUNBUFFERED=1

# 4. 의존성 설치
# (캐싱을 위해 소스 코드 복사보다 먼저 수행)
COPY pyproject.toml .
# pyproject.toml이 없다면 아래 줄 주석 해제 후 사용:
# RUN pip install --no-cache-dir kubernetes requests mysql-connector-python
RUN pip install --no-cache-dir kubernetes requests mysql-connector-python

# 5. 소스 코드 전체 복사
COPY . .

# 6. 실행
CMD ["python", "main.py"]
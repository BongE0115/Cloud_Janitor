# TC (Target Cluster)

Target Cluster(TC)는 Cloud Janitor의 모니터링 대상인 오래된 시스템입니다.

## 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│  TC (Target Cluster) - 오래된 시스템                │
│  - Docker Compose로 구성                                  │
│  - Prometheus + 기존 프로세스들                        │
│  - cj에 연결 요청 전송                                    │
└─────────────────────────────────────────────────────────────┘
```

## 구조

```
target-cluster/
├── docker-compose.yml    # Docker Compose 설정
├── prometheus.yml       # Prometheus 설정
├── setup.sh           # TC 시작 스크립트
├── teardown.sh        # TC 중지 스크립트
└── README.md          # 이 파일
```

## 사용법

### TC 시작

```bash
# 기본 시작
./setup.sh

# 이미지 pull 없이 시작
./setup.sh --no-pull
```

### TC 중지

```bash
# 컨테이너만 중지
./teardown.sh

# 볼륨까지 삭제
./teardown.sh --volumes

# 전체 삭제 (컨테이너 + 네트워크 + 볼륨)
./teardown.sh --all
```

### 서비스

| 서비스 | URL | 설명 |
|--------|------|------|
| Prometheus | http://localhost:9091 | 메트릭 수집 |
| cAdvisor | http://localhost:8080 | 컨테이너 메트릭 |
| Active App | http://localhost:8081 | 정상 동작 앱 |
| Zombie Test App | http://localhost:8082 | 좀비 테스트 앱 |

## 연결 요청 (TC → cj)

TC가 cj(Cloud Janitor)에 연결 요청을 전송하려면:

```bash
# cj 배포 후
cd ..

# TC → cj 연결 요청 전송
./target-cluster/setup-connection-to-cj.sh -a localhost
```

## 문제 해결

### 포트 충돌

```bash
# 사용 중인 포트 확인
lsof -i :9091
lsof -i :8080
lsof -i :8081
lsof -i :8082
```

### 컨테이너 로그 확인

```bash
# Prometheus 로그
docker logs -f target-prometheus

# cAdvisor 로그
docker logs -f cadvisor

# 특정 컨테이너 로그
docker logs -f <container_name>
```

### 네트워크 확인

```bash
# Docker 네트워크 확인
docker network ls | grep tc-network

# 네트워크 상세 정보
docker network inspect tc-network
```

## 좀비 컨테이너

TC에는 테스트용 좀비 컨테이너가 포함되어 있습니다:

| 컨테이너 | 설명 |
|-----------|------|
| app-zombie-sleeper | CPU/네트워크 미사용 |
| app-zombie-completed | 작업 완료 후 대기 |
| app-zombie-test | 테스트 환경 방치 |
| app-zombie-dev | 개발 환경 방치 |

Cloud Janitor(cj)가 이 컨테이너들을 자동으로 감지하고 삭제합니다.

# TC (Target Cluster)

Target Cluster(TC)는 Cloud Janitor의 모니터링 대상인 오래된 시스템입니다.

## 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│  TC (Target Cluster)                                       │
│  - docker-compose.yml: TC 앱 컨테이너 전용                │
│  - docker-compose.monitoring.yml: CJ 연동 브리지 전용     │
│  - tc connect: CJ 등록 API 호출                            │
└─────────────────────────────────────────────────────────────┘
```

## 구조

```
target-cluster/
├── docker-compose.yml              # TC 앱 컨테이너 전용
├── docker-compose.monitoring.yml   # Prometheus/cAdvisor/Promtail
├── prometheus.yml                  # Prometheus 설정
├── promtail-config.yaml            # Promtail 설정
├── setup.sh                        # TC 시작 스크립트
├── setup-connection-to-cj.sh       # TC -> CJ 연결 요청
├── teardown.sh                     # TC 중지 스크립트
└── tc                              # TC CLI
```

## 사용법

### 1) TC 앱 시작 (CJ와 무관)

```bash
# 기본값: 앱 컨테이너만 실행
./setup.sh

# 또는
./setup.sh --apps-only
# 또는
./tc start
```

### 2) 연동 브리지 시작 (Prometheus/cAdvisor/Promtail)

```bash
./setup.sh --prometheus-only
# 또는
./tc pm start
```

### 3) TC -> CJ 연결 요청

```bash
./setup-connection-to-cj.sh -a <CJ_HOST>
# 또는
./tc connect -a <CJ_HOST>
```

## 중지/정리

```bash
# 컨테이너 중지
./teardown.sh

# 볼륨까지 삭제
./teardown.sh --volumes

# 전체 삭제 (컨테이너 + 네트워크 + 볼륨)
./teardown.sh --all
```

## 서비스

### 앱 스택

| 서비스 | URL |
|--------|-----|
| Active App | http://localhost:8081 |
| Zombie Test App | http://localhost:8082 |

### 연동 브리지 스택

| 서비스 | URL |
|--------|-----|
| Prometheus | http://localhost:9091 |
| cAdvisor | http://localhost:8080 |
| Promtail | (로그 전송용, 별도 UI 없음) |

## 문제 해결

### 포트 충돌

```bash
lsof -i :9091
lsof -i :8080
lsof -i :8081
lsof -i :8082
```

### 컨테이너 로그

```bash
# 전체
./tc logs

# 특정 서비스
./tc logs promtail
./tc logs prometheus
./tc logs app-active
```

### 네트워크 확인

```bash
docker network ls | grep tc-network
docker network inspect tc-network
```

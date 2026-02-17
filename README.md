# Cloud Janitor

KT Cloud Tech Up 2기 클라우드 인프라 과정 기본 프로젝트 2조(내 이름은 코난, 탐정 2조)

**Zombie Pod 감지 및 자동 정리 시스템**

## 아키텍처 R&R

### TC (Target Cluster - 적용 시스템)
- **Prometheus**: 컨테이너 메트릭 수집
  - cAdvisor를 통해 Docker 컨테이너 메트릭(CPU, 메모리, 네트워크) 수집
  - Cloud Janitor가 PromQL 쿼리로 폴링하여 좀비 파드 감지
- **Promtail**: TC 컨테이너 로그 수집
  - TC의 모든 컨테이너 로그를 CJ의 Loki로 전송
  - 로그 라벨: `{job="tc-docker"}`

### CJ (Cloud Janitor - 모니터링 시스템)
- **Loki**: 중앙 로그 저장소
  - TC Promtail 로그 수신 (TC 컨테이너 로그)
  - CJ Promtail 로그 수신 (Cloud Janitor/Scanner 활동 로그)
- **Promtail (CJ)**: CJ Pod 로그 수집
  - `cloud-janitor`, `cloud-janitor-scanner` 로그를 Loki로 전송
- **Grafana**: 데이터 시각화
  - Loki 로그 기반 대시보드 (좀비 파드 감지 기록)
  - Prometheus 메트릭 기반 대시보드 (네트워크 트래픽 등)
- **Cloud Janitor**: 좀비 파드 감지 및 삭제 서비스
  - TC Prometheus 폴링 → 좀비 파드 감지 → 삭제 → 로그 기록
  - 감지 결과를 로그로 남겨 Loki에 저장
- **MySQL**: 좀비 파드 삭제 기록 DB

## Team Members
- 신봉근 : 팀장, 인프라
- 문경호 : 부팀장, 인프라
- 이우열 : 서기, 백엔드
- 김건 : 백엔드
- 조승연 : 시각화

## Index
1. [🏗️ Project Architecture](#🏗️-project-architecture)
2. [🛠 Tech Stack](#🛠-tech-stack)
3. [🚀 Quick Start](#🚀-quick-start)
4. [📊 운영 확인 가이드](#📊-운영-확인-가이드)

## 🏗️ Project Architecture

Cloud Janitor는 **TC(Target Cluster, 적용 시스템)**와 **CJ(Cloud Janitor, 모니터링 시스템)**로 분리된 아키텍처입니다.

```mermaid
flowchart TB
    %% 스타일 정의
    classDef default fill:#ffffff,stroke:#333333,stroke-width:1px,color:#000000;
    classDef highlight fill:#fff59d,stroke:#fbc02d,stroke-width:3px,color:#000000,font-weight:bold;
    classDef tc fill:#fff3e0,stroke:#ff9800,stroke-width:2px,color:#000000;
    classDef cj fill:#e3f2fd,stroke:#1976d2,stroke-width:2px,color:#000000;

    %% TC (적용 시스템)
    subgraph TC_Cluster["🎯 TC (Target Cluster - 적용 시스템)"]
        direction TB
        style TC_Cluster fill:#fff3e0,stroke:#ff9800,stroke-width:2px,color:#000000

        TC_Prometheus["📊 Prometheus<br/>메트릭 수집"]
        TC_Promtail["📤 Promtail<br/>로그 전송"]
        TC_Apps["📦 컨테이너들<br/>(더미 앱, 좀비 포함)"]
    end

    %% cj (모니터링 시스템)
    subgraph CJ_Cluster["🎛️ cj (Cloud Janitor - 모니터링 시스템)"]
        direction TB
        style CJ_Cluster fill:#e3f2fd,stroke:#1976d2,stroke-width:2px,color:#000000

        CJ_Janitor["🐍 Cloud Janitor<br/>[Deployment]<br/>좀비 Pod 감지<br/>로그 기록"]:::highlight
        CJ_Promtail["📤 Promtail (CJ)<br/>[Helm]<br/>CJ Pod 로그 수집"]
        CJ_Loki["📝 Loki<br/>[Helm]<br/>중앙 로그 저장소<br/>{app=~'cloud-janitor|cloud-janitor-scanner'}"]
        CJ_MySQL["🗄️ MySQL<br/>[Deployment]<br/>삭제 기록 저장"]
        CJ_Grafana["📈 Grafana<br/>[Deployment]<br/>시각화 대시보드"]
    end

    %% 데이터 흐름 - TC 내부
    TC_Apps -->|CPU/메모리/네트워크| TC_Prometheus
    TC_Apps -->|컨테이너 로그| TC_Promtail

    %% TC → cj 연결
    TC_Promtail -->|로그 전송| CJ_Loki
    CJ_Janitor -.->|PromQL 폴링<br/>(CPU/네트워크)| TC_Prometheus
    CJ_Janitor -.->|Docker API<br/>(좀비 삭제)| TC_Apps

    %% cj 내부 데이터 흐름
    CJ_Janitor -->|Pod stdout 로그| CJ_Promtail
    CJ_Promtail -->|로그 전송| CJ_Loki
    CJ_Janitor -->|삭제 기록| CJ_MySQL

    %% 데이터 소스
    CJ_Loki -->|Cloud Janitor 로그<br/>(좀비 감지 기록)| CJ_Grafana
    TC_Prometheus -.->|메트릭<br/>(네트워크 등)| CJ_Grafana
```

### 핵심 설계 원칙

1. **TC (적용 시스템)**: Prometheus + Promtail (메트릭/로그 수집)
2. **CJ (모니터링 시스템)**: Promtail(CJ 로그 수집), Loki (로그 저장), Grafana (시각화), Cloud Janitor (감지/삭제), MySQL (기록 저장)
3. **데이터 흐름**: 
   - TC Prometheus → Cloud Janitor 폴링 → 좀비 감지
   - TC Promtail → CJ Loki (TC 컨테이너 로그)
   - Cloud Janitor/Scanner 로그 → CJ Promtail → CJ Loki
   - Cloud Janitor 로그 → Grafana 대시보드 (좀비 감지/삭제 기록)
   - TC Prometheus → Grafana 대시보드 (네트워크 트래픽 등)
4. **연결 방식**: TC Promtail과 CJ Promtail이 각각 Loki로 로그를 전송, Cloud Janitor가 TC Prometheus를 폴링

### 연결 방식

TC에서 Prometheus와 앱을 실행하고, cj에서 설정/시작하여 연결합니다.

### Janitor 로그 소스 구분

| app 라벨 | 실행 주체 | 용도 |
|----------|-----------|------|
| `cloud-janitor` | Deployment (API 서버) | 등록 API, 수동 스캔 실행 로그, 서비스 상태 로그 |
| `cloud-janitor-scanner` | CronJob (주기 스캔) | 자동 주기 스캔 결과 로그 (`SCAN_CYCLE_*`, `SCAN_CONTAINER`) |

## 🛠 Tech Stack

| Category | Technology | Version | Description |
|----------|------------|---------|-------------|
| Language | Python | 3.12.12 | Main programming language |
| Package Manager | uv | latest | Fast Python package installer & resolver |
| IaC | Terraform | 1.14.4 | Infrastructure as Code |
| IaC | Ansible | 2.20.2 | Configuration Management |
| Container | Docker | latest | Container Runtime |
| Container | Kind | TBA | Kubernetes in Docker |
| Container Orchestration | Kubernetes (kubectl) | | Container Orchestration |
| Package Manager | Helm | | Kubernetes Package Manager |
| Database | MySQL | | Relational Database |
| Monitoring | Prometheus | | Metrics Collection |
| Visualization | Grafana | | Data Visualization |
| Logging | Loki | | Log Aggregation System |

버전 관리는 `pyproject.toml` 및 본 표를 기준으로 합니다.

## 🚀 Quick Start

### 사전 요구사항

- Docker & Docker Compose
- Terraform >= 1.14.4
- Ansible >= 2.20.2
- kubectl
- Helm
- **target-cluster 앱과 Prometheus는 별도 실행**

### TC CLI 위치

- TC CLI 본체: `target-cluster/tc`
- 루트 `tc`는 `target-cluster/tc`를 호출하는 래퍼입니다.
- 설치는 기존처럼 `./tc install` 또는 `target-cluster/tc install` 둘 다 가능합니다.

### 실행 프로세스

```bash
# 1. CLI 설치 (선택사항, 이미 설치되어 있으면 생략)
./cj install
./tc install

# ========================================
# 🛠️ 수동 실행
# ========================================

# 2. 초기화
cj init

# 3. TC 앱 시작
tc start

# 4. TC Prometheus + Promtail 시작
tc pm start

# 5. cj 설정 (Grafana/Loki/MySQL 준비)
cj setup

# 6. cj 서비스 시작
cj start

# 7. TC → cj 연결 요청
tc connect -a localhost

# (선택) TC에서 화이트리스트 직접 설정
#  - base(고정): target-cluster/.env 의 CJ_CONTAINER_WHITELIST
#    (whitelist 명령으로 수정되지 않음)
#  - custom(사용자): tc whitelist set/add/remove/pick
#    (target-cluster/.whitelist.custom 에 저장)
#  - 전송 방식: tc connect 시 base+custom을 합쳐 labels.container_whitelist로 동봉 전송
#  - 실시간 반영: tc whitelist ... -a localhost -n tc-target
```

### 외부 TC 서버 시나리오

#### CJ 서버에서 TC Prometheus로 SSH 터널 생성 (`-L`)

```bash
# 1) CJ 서버에서 TC Prometheus(원격 9091)로 SSH 터널 생성
#    - 로컬 9091 -> 원격 9091
cj tunnel setup \
  --host <TC_PUBLIC_IP_OR_HOST> \
  --user <SSH_USER> \
  --port 22 \
  --key ~/.ssh/<KEY_FILE> \
  --remote-port 9091 \
  --local-port 9091

# 2) 터널 상태 확인
cj tunnel status --host <TC_PUBLIC_IP_OR_HOST> --remote-port 9091 --local-port 9091

# 3) TC 등록 (CJ API 기준)
#    - tc는 TC 서버에서 실행하거나, TC 환경 접근 가능한 위치에서 실행
tc connect -a <CJ_PUBLIC_IP_OR_HOST> --prom-url http://localhost:9091 -n tc-target

# 4) 필요 시 수동 스캔
cj scan

# 5) 종료 시 터널 해제
cj tunnel stop --host <TC_PUBLIC_IP_OR_HOST> --remote-port 9091 --local-port 9091
```

### 외부 TC 서버 시나리오 (SSH 역터널: TC -> CJ, `-R`)

TC에서 CJ로 SSH 접속 가능한 환경(NAT/방화벽으로 CJ -> TC 인바운드가 어려운 경우)에 권장합니다.

```bash
# 1) TC 서버에서 CJ로 역터널 생성
#    - CJ의 19091 포트를 통해 TC localhost:9091(Prometheus)에 접근 가능
tc tunnel setup \
  --cj-host <CJ_PUBLIC_IP_OR_HOST> \
  --cj-user <CJ_SSH_USER> \
  --cj-port 22 \
  --key ~/.ssh/<TC_PRIVATE_KEY> \
  --remote-port 19091 \
  --local-port 9091

# 2) 상태 확인
tc tunnel status --cj-host <CJ_PUBLIC_IP_OR_HOST> --cj-user <CJ_SSH_USER> --remote-port 19091 --local-port 9091

# 3) CJ에 TC 등록 (Prometheus URL은 CJ에서 열리는 포트 기준)
tc connect -a <CJ_PUBLIC_IP_OR_HOST> --prom-url http://localhost:19091 -n tc-target

# 4) 필요 시 수동 스캔
cj scan

# 5) 종료 시 역터널 해제
tc tunnel stop --cj-host <CJ_PUBLIC_IP_OR_HOST> --cj-user <CJ_SSH_USER> --remote-port 19091 --local-port 9091
```

## 📊 운영 확인 가이드

### 빠른 점검 순서

```bash
# 1) TC/CJ 상태
tc status
cj status

# 2) TC -> CJ 연결 상태 점검
tc connect --check -a localhost

# 3) 수동 1회 스캔
cj scan

# 4) 로그 확인
cj logs janitor
tc logs promtail
```

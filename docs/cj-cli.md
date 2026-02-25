# CJ CLI 명령어 가이드

`cj`는 Cloud Janitor(모니터링 시스템) 관리용 CLI입니다.

## 기본 형식

```bash
cj <command> [options]
```

## 주요 명령어

| 명령어 | 설명 |
|---|---|
| `cj install` | `cj`를 PATH에 등록하고 `CJ_HOME` 환경변수를 설정 |
| `cj init` | 프로젝트 초기화 (`.env` 생성, 필수 도구/구조 점검) |
| `cj setup` | Management Cluster 준비 (Terraform 적용 등) |
| `cj start` | Cloud Janitor 서비스 배포/재시작, API/Loki 포트포워드 준비 |
| `cj stop` | Cloud Janitor 서비스 중지 |
| `cj clear` | 로컬 상태 정리 (포트포워드/터널/클러스터/terraform 산출물 정리) |
| `cj bootstrap` | `install -> init -> setup -> start` 순서 자동 실행 |
| `cj status` | TC 등록 상태, 클러스터/배포 상태 확인 |
| `cj logs <service>` | 서비스 로그 조회 (`janitor`, `mysql`, `grafana`, `loki`) |
| `cj scan` | Cloud Janitor 수동 1회 스캔 실행 |
| `cj grafana` | Grafana 접속 URL/계정 정보 출력 및 브라우저 오픈 시도 |
| `cj env` | `.env` 편집 |
| `cj kubeconfig` | Management Cluster kubeconfig 경로 출력 |
| `cj shell` | `CJ_HOME` 기준 쉘 실행 |
| `cj version` | 버전/프로젝트 경로 출력 |
| `cj help` | 도움말 출력 |

## Terraform 하위 명령어

```bash
cj tf <subcommand> [terraform options]
```

| 하위 명령어 | 설명 |
|---|---|
| `init` | Terraform 초기화 |
| `plan` | 변경 계획 확인 |
| `apply` | 클러스터 생성/적용 |
| `destroy` | 클러스터 삭제 |
| `clear` | Terraform 로컬 상태 완전 정리 |
| `output` | Terraform 출력값 조회 |
| `shell` | Terraform 작업용 쉘 실행 |

## SSH 터널 하위 명령어

외부 TC Prometheus에 접근해야 할 때 사용합니다.

```bash
cj tunnel <setup|stop|status> [options]
```

옵션:

- `--host <HOST>`: TC SSH 호스트
- `--user <USER>`: SSH 사용자
- `--port <PORT>`: SSH 포트
- `--key <PATH>`: SSH 키 파일 경로
- `--remote-port <PORT>`: 원격 Prometheus 포트 (기본 `9091`)
- `--local-port <PORT>`: 로컬 포워드 포트 (기본 `9091`)
- `--enable`, `--use`: 터널 사용 강제
- `--disable`, `--no-use`: 터널 사용 비활성화

예시:

```bash
cj tunnel setup --host 10.0.0.5 --user ubuntu --key ~/.ssh/id_rsa --remote-port 9091 --local-port 9091
cj tunnel status --host 10.0.0.5 --remote-port 9091 --local-port 9091
cj tunnel stop --host 10.0.0.5 --remote-port 9091 --local-port 9091
```

## 운영 흐름 예시

```bash
# 로컬 기본 흐름
cj init
cj setup
cj start
cj status

# 문제 확인
cj logs janitor
cj scan
```

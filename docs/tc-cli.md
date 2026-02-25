# TC CLI 명령어 가이드

`tc`는 Target Cluster(적용 시스템) 관리용 CLI입니다.

루트의 `./tc`는 `target-cluster/tc`를 호출하는 래퍼입니다.

## 기본 형식

```bash
tc <command> [options]
```

## 주요 명령어

| 명령어 | 설명 |
|---|---|
| `tc install` | `tc`를 PATH에 등록하고 `TC_HOME` 설정 |
| `tc init` | 기본 앱 컨테이너만 시작 (`setup.sh --apps-only`) |
| `tc start` | TC 앱 컨테이너 시작 |
| `tc stop` | TC 앱/모니터링 중지 (`teardown.sh`) |
| `tc clear` | TC 전체 정리 (`teardown.sh --all`) |
| `tc pm start` | Prometheus + cAdvisor + Promtail 시작 |
| `tc pm stop` | Prometheus + cAdvisor + Promtail 중지 |
| `tc pm status` | 모니터링 스택 상태 확인 |
| `tc status` | TC 컨테이너 상태/Prometheus 헬스 확인 |
| `tc logs [service]` | TC 컨테이너 로그 조회 |
| `tc connect ...` | TC를 CJ에 등록 (연결 요청 전송) |
| `tc tunnel ...` | TC -> CJ SSH 역터널 관리 |
| `tc whitelist ...` | 컨테이너 화이트리스트 관리 |
| `tc bootstrap -a <CJ_HOST>` | `install -> start -> pm start -> connect` 자동 실행 |
| `tc help` | 도움말 출력 |

## `tc connect` 옵션

`tc connect`는 `target-cluster/setup-connection-to-cj.sh`를 그대로 호출합니다.

```bash
tc connect -a <CJ_HOST> [options]
```

주요 옵션:

- `-a, --cj-host <HOST>`: CJ 주소 (필수)
- `-p, --cj-port <PORT>`: CJ API 포트 (기본 `30800`)
- `-n, --name <NAME>`: TC 이름 (기본 `tc-target`)
- `--prom-url <URL>`: TC Prometheus URL (미지정 시 자동 감지)
- `--docker-url <URL>`: TC Docker API URL (기본 `unix:///var/run/docker.sock`)
- `--loki-url <URL>`: TC Promtail용 Loki Push URL 직접 지정
- `--loki-port <PORT>`: CJ Loki 포트 (기본 `31000`)
- `--whitelist "<csv>"`: 예외 컨테이너 목록
- `--labels KEY=VALUE`: TC 라벨 (여러 번 전달 가능)
- `--check`: 연결 상태만 점검

예시:

```bash
tc connect -a localhost -n tc-target
tc connect -a 192.168.1.100 --prom-url http://localhost:9091 --check
```

## `tc tunnel` 하위 명령어

NAT/방화벽 등으로 CJ에서 TC로 직접 접근이 어려울 때 사용합니다.

```bash
tc tunnel <setup|stop|status> [options]
```

옵션:

- `--cj-host <HOST>`: CJ SSH 호스트 (필수)
- `--cj-user <USER>`: CJ SSH 사용자 (기본 `root`)
- `--cj-port <PORT>`: CJ SSH 포트 (기본 `22`)
- `--key <PATH>`: SSH 키 파일
- `--remote-port <PORT>`: CJ 쪽 포트 (기본 `19091`)
- `--local-port <PORT>`: TC Prometheus 포트 (기본 `9091`)

예시:

```bash
tc tunnel setup --cj-host 10.0.0.10 --cj-user ubuntu --key ~/.ssh/cj_tunnel --remote-port 19091 --local-port 9091
tc tunnel status --cj-host 10.0.0.10 --cj-user ubuntu --remote-port 19091 --local-port 9091
tc tunnel stop --cj-host 10.0.0.10 --cj-user ubuntu --remote-port 19091 --local-port 9091
```

## `tc whitelist` 하위 명령어

`target-cluster/whitelist.sh`를 호출하여 base/custom/effective 화이트리스트를 관리합니다.

```bash
tc whitelist <command> [options]
```

하위 명령어:

- `list`: `tc-network` 컨테이너 목록 표시
- `show`: base/custom/effective 화이트리스트 표시
- `set "<csv>"`: custom 화이트리스트 전체 교체
- `add "<csv>"`: custom 화이트리스트 추가
- `remove "<csv>"`: custom 화이트리스트 제거
- `pick`: 컨테이너 목록 번호 선택 방식으로 custom 저장
- `sync`: base+custom을 CJ로 즉시 반영

공통 옵션:

- `-a, --cj-host <HOST>` (기본 `localhost`)
- `-p, --cj-port <PORT>` (기본 `30800`)
- `-n, --tc-name <NAME>` (기본 `tc-target`)
- `--no-sync` (custom 파일만 수정)

## 운영 흐름 예시

```bash
# TC 앱 시작
tc start

# 모니터링 브리지 시작
tc pm start

# CJ 등록
tc connect -a <CJ_HOST>

# 상태 확인
tc status
```

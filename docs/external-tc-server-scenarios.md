# 외부 TC 서버 시나리오 (SSH 터널)

이 문서는 **외부 서버에 있는 TC**를 CJ에 연결할 때 사용하는 터널 시나리오를 정리합니다.

## 1) CJ 서버에서 TC Prometheus로 포워드 (`-L`)

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

## 2) TC 서버에서 CJ로 역포워드 (`-R`)

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

## 선택 기준

- `-L` 포워드: CJ가 TC로 직접 접근 가능한 경우
- `-R` 역포워드: CJ -> TC 인바운드 접근이 제한된 경우

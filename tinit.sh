#!/bin/bash

# 완전 클린 설치기 때문에 단순 실행을 원한다면 # 3. Terraform init + apply 부분부터 실행하세요.
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$ROOT_DIR/terraform"
ANSIBLE_DIR="$ROOT_DIR/ansible"

echo "========================================="
echo " Cloud Janitor — 클린 설치"
echo "========================================="

# 1. 기존 환경 제거
echo "[1/5] 기존 환경 제거..."
cd "$TF_DIR"
terraform destroy -auto-approve 2>/dev/null || true
kind delete cluster --name cloud-janitor-cluster 2>/dev/null || true
rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup cloud-janitor-cluster-config

# 2. .env 확인
echo "[2/5] .env 파일 확인..."
if [ ! -f "$ROOT_DIR/.env" ]; then
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  echo "  .env.example → .env 복사됨. GRAFANA_PASSWORD를 수정하세요."
  echo "  수정 후 다시 실행해주세요."
  exit 1
fi

# 3. Terraform init + apply
echo "[3/5] Terraform init..."
cd "$TF_DIR"
terraform init

echo "[4/5] Terraform apply..."
terraform apply -auto-approve

# 4. Ansible
echo "[5/5] Ansible playbook 실행..."
cd "$ANSIBLE_DIR"
uv run ansible-playbook playbooks/setup-cluster.yml

echo ""
echo "========================================="
echo " 완료!"
echo " Grafana  : http://localhost:3000"
echo " Prometheus: http://localhost:9090"
echo "========================================="

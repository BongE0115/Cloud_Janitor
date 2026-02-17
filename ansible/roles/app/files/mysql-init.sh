#!/usr/bin/env bash
set -euo pipefail

until mysql -h"$MYSQL_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; do
  echo "Waiting for MySQL..."
  sleep 3
done

mysql -h"$MYSQL_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < /opt/mysql-init/mysql-init.sql
echo "MySQL initialization completed successfully"

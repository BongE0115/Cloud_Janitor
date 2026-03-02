# =============================================================================
# .env 파일에서 직접 변수 로드 (source/export 불필요)
# =============================================================================

locals {
  env_file = { for line in compact(split("\n", file("${path.module}/../.env"))) :
    trimspace(split("=", line)[0]) => trimspace(join("=", slice(split("=", line), 1, length(split("=", line)))))
    if !startswith(trimspace(line), "#") && length(trimspace(line)) > 0 && length(regexall("=", line)) > 0
  }

  grafana_password  = local.env_file["GRAFANA_PASSWORD"]
  smtp_password     = local.env_file["SMTP_PASSWORD"]
  grafana_host_port = try(tonumber(local.env_file["GRAFANA_HOST_PORT"]), 3000)
  mysql_host_port   = try(tonumber(local.env_file["MYSQL_HOST_PORT"]), 3306)
}

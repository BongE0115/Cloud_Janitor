# =============================================================================
# .env 파일에서 직접 변수 로드 (source/export 불필요)
# =============================================================================

locals {
  env_file = { for line in compact(split("\n", file("${path.module}/../.env"))) :
    trimspace(split("=", line)[0]) => trimspace(join("=", slice(split("=", line), 1, length(split("=", line)))))
    if !startswith(trimspace(line), "#") && length(trimspace(line)) > 0 && length(regexall("=", line)) > 0
  }

  grafana_password = local.env_file["GRAFANA_PASSWORD"]
}

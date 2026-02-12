# =============================================================================
# Outputs
# =============================================================================

output "kubeconfig_path" {
  description = "kubeconfig 파일 경로"
  value       = kind_cluster.default.kubeconfig_path
}

output "grafana_url" {
  description = "Grafana 접속 주소"
  value       = "http://localhost:3000"
}

output "prometheus_url" {
  description = "Prometheus 접속 주소"
  value       = "http://localhost:9090"
}

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

output "zombie_namespace" {
  description = "좀비 파드가 배포된 네임스페이스"
  value       = kubernetes_namespace.target_workloads.metadata[0].name
}

output "zombie_pods_count" {
  description = "생성된 좀비 파드 수"
  value       = "7 pods (3 sleeper + 2 completed + 1 forgotten + 1 old-dev)"
}

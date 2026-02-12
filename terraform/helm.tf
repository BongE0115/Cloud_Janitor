# =============================================================================
# Helm Releases — 인프라 레이어
# Prometheus는 Target Cluster에서 별도로 실행되므로
# Management Cluster에서는 Loki만 설치/관리
# Grafana와 Cloud Janitor는 Ansible에서 배포
# =============================================================================

# NOTE: Prometheus는 제거됨
# Target Cluster의 Prometheus API를 Cloud Janitor가 직접 호출하므로
# Management Cluster에는 Prometheus가 필요 없음

# ---------- Loki Stack (로그 수집) ------------------------------------------

resource "helm_release" "loki_stack" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  version    = "2.9.11"

  set {
    name  = "loki.image.tag"
    value = "2.9.10"
  }

  wait            = true
  cleanup_on_fail = true

  depends_on = [kubernetes_namespace.monitoring]
}

# =============================================================================
# Helm Releases — 인프라 레이어
# Prometheus + Grafana, Loki 모두 Terraform에서 설치/관리
# =============================================================================

# ---------- Prometheus + Grafana (kube-prometheus-stack) ---------------------

resource "helm_release" "prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout         = 900 # 15분
  wait            = true
  cleanup_on_fail = true

  # Grafana 관리자 비밀번호 (TF_VAR_grafana_password 환경변수로 전달)
  set_sensitive {
    name  = "grafana.adminPassword"
    value = local.grafana_password
  }

  # Grafana NodePort (localhost:3000)
  set {
    name  = "grafana.service.type"
    value = "NodePort"
  }
  set {
    name  = "grafana.service.nodePort"
    value = "30080"
  }

  # sidecar datasource 완전 비활성화 → Ansible에서 직접 관리
  set {
    name  = "grafana.sidecar.datasources.enabled"
    value = "false"
  }

  # Prometheus NodePort (localhost:9090)
  set {
    name  = "prometheus.service.type"
    value = "NodePort"
  }
  set {
    name  = "prometheus.service.nodePort"
    value = "30090"
  }

  depends_on = [kubernetes_namespace.monitoring]
}

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

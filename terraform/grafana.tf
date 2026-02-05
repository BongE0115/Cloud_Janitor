provider "grafana" {
  url  = "http://localhost:3000"
  auth = "admin:${var.grafana_password}"
}

resource "grafana_data_source" "loki" {
  type = "loki"
  name = "Loki"
  url  = "http://loki.logging.svc.cluster.local:3100"

  is_default = true

  json_data_encoded = jsonencode({
    maxLines = 1000
  })

  depends_on = [kind_cluster.default]
}

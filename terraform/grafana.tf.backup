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

resource "grafana_dashboard" "example_monitor" {
  config_json = jsonencode({
    title = "loki monitor"
    uid = "loki-monitor-001"
    refresh = "10s"
    schemaVersion = 39

    # 상단 드롭다운 변수 설정
    templating = {
      list = [
        {
          name = "selected_pod"
          type = "query"
          label = "대상 파드 선택"
          datasource = { type = "loki", uid = grafana_data_source.loki.uid }
          
          definition = "label_values({namespace=~\".+\"}, pod)"
          query      = "label_values({namespace=~\".+\"}, pod)"

          refresh = 2
          includeAll = true
          allValue = ".+"
          multi = false

          # loki-0으로 되도록 설정 
          current = {
            selected = true
            text = "loki-0"
            value = "loki-0"
          }
        }
      ]
    }

    # 로그 출력 패널
    panels = [
      {
        type = "logs"
        title = "실시간 로그: $selected_pod"
        gridPos = { h=20, w=24, x=0, y=0 }
        datasource = { 
          type = "loki", 
          uid = "${grafana_data_source.loki.uid}"
        }
        targets = [
          {
            # 선택한 파드 라벨로 고정
            expr = "{pod=~\"$selected_pod\"}"
          }
        ]
      }
    ]
  })
}

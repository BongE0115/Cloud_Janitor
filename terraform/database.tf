# =============================================================================
# MySQL Database (StatefulSet + Service + ConfigMap)
# =============================================================================

resource "kubernetes_config_map" "mysql_init" {
  metadata {
    name      = "mysql-init"
    namespace = "default"
  }

  data = {
    "init.sql" = "CREATE DATABASE IF NOT EXISTS cloud_janitor;"
  }

  depends_on = [kind_cluster.default]
}

resource "kubernetes_stateful_set" "mysql" {
  metadata {
    name      = "mysql"
    namespace = "default"
  }

  spec {
    service_name = "mysql"
    replicas     = 1

    selector {
      match_labels = {
        app = "mysql"
      }
    }

    template {
      metadata {
        labels = {
          app = "mysql"
        }
      }

      spec {
        container {
          name  = "mysql"
          image = "mysql:8.0"

          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = "rootpassword"
          }
          env {
            name  = "MYSQL_DATABASE"
            value = "cloud_janitor"
          }

          port {
            container_port = 3306
            name           = "mysql"
          }

          volume_mount {
            name       = "mysql-data"
            mount_path = "/var/lib/mysql"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "mysql-data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "1Gi"
          }
        }
      }
    }
  }

  depends_on = [kind_cluster.default]
}

resource "kubernetes_service" "mysql" {
  metadata {
    name      = "mysql"
    namespace = "default"
  }

  spec {
    type = "NodePort"

    selector = {
      app = "mysql"
    }

    port {
      port        = 3306
      target_port = 3306
      node_port   = 30306
      name        = "mysql"
    }
  }

  depends_on = [kind_cluster.default]
}

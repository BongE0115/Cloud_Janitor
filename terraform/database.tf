# =============================================================================
# MySQL Deployment — Cloud Janitor에서 직접 관리
# Management Cluster(cj)에 MySQL 데이터베이스 설치
# - 좀비 Pod 삭제 기록 저장
# =============================================================================

# MySQL Namespace
resource "kubernetes_namespace" "mysql" {
  metadata {
    name = "mysql"
  }

  depends_on = [kind_cluster.default]
}

# MySQL Secret (Root Password)
resource "kubernetes_secret" "mysql" {
  metadata {
    name      = "mysql-secret"
    namespace = kubernetes_namespace.mysql.metadata[0].name
  }

  type = "Opaque"

  data = {
    mysql-root-password = "rootpassword"
    mysql-password      = "rootpassword"
  }

  depends_on = [kubernetes_namespace.mysql]
}

# MySQL Deployment
resource "kubernetes_deployment" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.mysql.metadata[0].name
    labels = {
      app = "mysql"
    }
  }

  spec {
    replicas = 1

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

          port {
            container_port = 3306
          }

          env {
            name = "MYSQL_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mysql.metadata[0].name
                key  = "mysql-root-password"
              }
            }
          }

          env {
            name  = "MYSQL_DATABASE"
            value = "janitor_db"
          }

          volume_mount {
            name       = "mysql-storage"
            mount_path = "/var/lib/mysql"
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -uroot -p$MYSQL_ROOT_PASSWORD"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "mysql -h 127.0.0.1 -uroot -p$MYSQL_ROOT_PASSWORD -e 'SELECT 1'"]
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "mysql-storage"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [kubernetes_secret.mysql]
}

# MySQL Service (ClusterIP)
resource "kubernetes_service" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.mysql.metadata[0].name
  }

  spec {
    selector = {
      app = "mysql"
    }

    port {
      port        = 3306
      target_port = 3306
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.mysql]
}

# MySQL Service (NodePort for external access)
resource "kubernetes_service" "mysql_nodeport" {
  metadata {
    name      = "mysql-nodeport"
    namespace = kubernetes_namespace.mysql.metadata[0].name
  }

  spec {
    selector = {
      app = "mysql"
    }

    port {
      port        = 3306
      target_port = 3306
      node_port   = 30306
    }

    type = "NodePort"
  }

  depends_on = [kubernetes_deployment.mysql]
}

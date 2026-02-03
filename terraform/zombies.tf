# =============================================================================
# Zombie Pods for Cloud Janitor Testing
# These pods simulate low-usage workloads that Cloud Janitor should detect
# =============================================================================

# Target namespace for zombie pods (simulating customer environment)
resource "kubernetes_namespace" "target_workloads" {
  metadata {
    name = "target-workloads"
    labels = {
      purpose = "cloud-janitor-target"
      managed-by = "terraform"
    }
  }

  depends_on = [kind_cluster.default]
}

# -----------------------------------------------------------------------------
# Zombie Deployment 1: Sleeping forever, doing nothing
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "zombie_sleeper" {
  metadata {
    name      = "zombie-sleeper"
    namespace = kubernetes_namespace.target_workloads.metadata[0].name
    labels = {
      app         = "zombie-sleeper"
      zombie-type = "idle"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "zombie-sleeper"
      }
    }

    template {
      metadata {
        labels = {
          app         = "zombie-sleeper"
          zombie-type = "idle"
        }
      }

      spec {
        container {
          name    = "sleeper"
          image   = "busybox:latest"
          command = ["sleep", "infinity"]

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.target_workloads]
}

# -----------------------------------------------------------------------------
# Zombie Deployment 2: Completed job that never gets cleaned up
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "zombie_completed" {
  metadata {
    name      = "zombie-completed"
    namespace = kubernetes_namespace.target_workloads.metadata[0].name
    labels = {
      app         = "zombie-completed"
      zombie-type = "completed"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "zombie-completed"
      }
    }

    template {
      metadata {
        labels = {
          app         = "zombie-completed"
          zombie-type = "completed"
        }
      }

      spec {
        container {
          name    = "done"
          image   = "busybox:latest"
          command = ["sh", "-c", "echo 'I finished my job but nobody cleaned me up' && sleep infinity"]

          resources {
            requests = {
              cpu    = "5m"
              memory = "8Mi"
            }
            limits = {
              cpu    = "20m"
              memory = "32Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.target_workloads]
}

# -----------------------------------------------------------------------------
# Zombie Pod 3: Forgotten test pod
# -----------------------------------------------------------------------------
resource "kubernetes_pod" "zombie_forgotten_test" {
  metadata {
    name      = "zombie-forgotten-test"
    namespace = kubernetes_namespace.target_workloads.metadata[0].name
    labels = {
      app         = "zombie-forgotten"
      zombie-type = "forgotten"
      environment = "test"
    }
  }

  spec {
    container {
      name  = "forgotten"
      image = "nginx:alpine"

      resources {
        requests = {
          cpu    = "10m"
          memory = "32Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "128Mi"
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.target_workloads]
}

# -----------------------------------------------------------------------------
# Zombie Pod 4: Old development pod
# -----------------------------------------------------------------------------
resource "kubernetes_pod" "zombie_old_dev" {
  metadata {
    name      = "zombie-old-dev"
    namespace = kubernetes_namespace.target_workloads.metadata[0].name
    labels = {
      app         = "zombie-old-dev"
      zombie-type = "stale"
      environment = "dev"
    }
  }

  spec {
    container {
      name    = "old-app"
      image   = "alpine:latest"
      command = ["sh", "-c", "echo 'Old dev environment nobody uses' && sleep infinity"]

      resources {
        requests = {
          cpu    = "5m"
          memory = "16Mi"
        }
        limits = {
          cpu    = "50m"
          memory = "64Mi"
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.target_workloads]
}

# -----------------------------------------------------------------------------
# Output: Zombie namespace info
# -----------------------------------------------------------------------------
output "zombie_namespace" {
  description = "Target workloads namespace for zombie pods"
  value       = kubernetes_namespace.target_workloads.metadata[0].name
}

output "zombie_pods_count" {
  description = "Total number of zombie pods created"
  value       = "7 pods (3 sleeper + 2 completed + 1 forgotten + 1 old-dev)"
}

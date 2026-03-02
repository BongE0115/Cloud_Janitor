terraform {
  required_version = ">= 1.0.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

# =============================================================================
# Providers
# =============================================================================

provider "kind" {}

provider "kubernetes" {
  config_path = kind_cluster.default.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = kind_cluster.default.kubeconfig_path
  }
}

# =============================================================================
# Kind Cluster (Docker 기반 K8s)
# =============================================================================
# NOTE: 클러스터가 이미 존재하면 Terraform이 멱등하게 관리합니다.
#       수동 삭제가 필요하면: kind delete cluster --name cloud-janitor-cluster

resource "kind_cluster" "default" {
  name           = "cloud-janitor-cluster"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Grafana (3000), MySQL (3306) 포트 노출
      # Prometheus는 Target Cluster에서 별도로 실행되므로 포트 매핑 제거
      extra_port_mappings {
        container_port = 30080 # Grafana NodePort
        host_port      = local.grafana_host_port
      }

      extra_port_mappings {
        container_port = 30306 # MySQL NodePort
        host_port      = local.mysql_host_port
      }

      extra_port_mappings {
        container_port = 30800 # Cloud Janitor NodePort
        host_port      = 30800 # localhost:30800
      }

      extra_port_mappings {
        container_port = 31000 # Loki NodePort
        host_port      = 31000 # localhost:31000
      }

      # Cloud Janitor scanner/cleanup에서 호스트 Docker daemon에 접근할 수 있도록 소켓 전달
      extra_mounts {
        host_path      = "/var/run/docker.sock"
        container_path = "/var/run/docker.sock"
      }
    }
  }
}

# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [kind_cluster.default]
}

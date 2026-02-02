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
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "kind" {}

provider "kubernetes" {
  config_path = kind_cluster.default.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = kind_cluster.default.kubeconfig_path
  }
}

provider "docker" {}

# Kind 클러스터 생성 (Docker 컨테이너 기반 K8s)
resource "kind_cluster" "default" {
  name = "cloud-janitor-cluster"
  wait_for_ready = true
}

# 네임스페이스 생성 예시
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [kind_cluster.default]
}

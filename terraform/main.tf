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
    #grafana = {
     # source = "grafana/grafana"
      #version = "3.7.0"
    #}
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

# Ensure any existing kind cluster with the same name is removed before creating a new one
resource "null_resource" "pre_delete_kind" {
  # change on every run so the provisioner runs each apply
  triggers = {
    force = timestamp()
  }

  provisioner "local-exec" {
    command = "kind delete cluster --name cloud-janitor-cluster || true"
  }
}

resource "kind_cluster" "default" {
  depends_on = [null_resource.pre_delete_kind]
  name = "cloud-janitor-cluster"
  wait_for_ready = true
  
  # Host와 클러스터 간 포트 매핑 (자동으로 포트포워딩)
  kind_config {
    kind = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    
    node {
      role = "control-plane"
      
      # Grafana (3000), Prometheus (9090), MySQL (3306) 포트 노출
      #extra_port_mappings {
       # container_port = 30080  # Grafana NodePort
       # host_port      = 3000   # localhost:3000으로 접속
      #}
      
      extra_port_mappings {
        container_port = 30090  # Prometheus NodePort
        host_port      = 9090   # localhost:9090으로 접속
      }
      
      extra_port_mappings {
        container_port = 30306  # MySQL NodePort
        host_port      = 3306   # localhost:3306으로 접속
      }
    }
  }
}

# 네임스페이스 생성 예시
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [kind_cluster.default]
}

# Cloud Janitor

KT Cloud Tech Up 2기 클라우드 인프라 과정 기본 프로젝트 2조(내 이름은 코난, 탐정 2조)

## Team Members
- 신봉근 : 팀장, 인프라
- 문경호 : 부팀장, 인프라
- 이우열 : 서기, 백엔드
- 김건 : 백엔드
- 조승연 : 시각화

## Index
1. [🏗️ Project Architecture](#🏗️-project-architecture)
2. [🛠 Tech Stack](#🛠-tech-stack)
3. [🔄 Workflow](#🔄-workflow)

## 🏗️ Project Architecture

```mermaid
flowchart TB
    %% ==========================================
    %% 스타일 정의 (가독성 개선)
    %% ==========================================
    %% 기본 노드: 흰색 배경 + 검정 글씨 + 진한 테두리
    classDef default fill:#ffffff,stroke:#333333,stroke-width:1px,color:#000000;
    
    %% 강조 노드 (Cloud Janitor): 노란색 배경 + 굵은 테두리
    classDef highlight fill:#fff59d,stroke:#fbc02d,stroke-width:3px,color:#000000,font-weight:bold;
    
    %% 외부 도구 (Terraform/Ansible): 회색 톤
    classDef tool fill:#f5f5f5,stroke:#616161,stroke-width:1px,color:#000000;

    %% ==========================================
    %% 1. 관리 영역 (내 컴퓨터 / CI 서버)
    %% ==========================================
    subgraph Manager["💻 Management Station (Dev / CI Server)"]
        direction LR
        style Manager fill:#eeeeee,stroke:#bdbdbd,stroke-width:2px,color:#000000
        
        Terraform["🏗️ Terraform<br/>(Infrastructure Provisioner)"]:::tool
        Ansible["🔧 Ansible<br/>(Configuration Manager)"]:::tool
    end

    %% ==========================================
    %% 2. 타겟 인프라 (Kubernetes Cluster)
    %% ==========================================
    subgraph K8sCluster["☸️ Target Kubernetes Cluster"]
        style K8sCluster fill:#e8eaf6,stroke:#3f51b5,stroke-width:2px,color:#000000

        %% 2-1. 시스템/노드 레벨
        subgraph Nodes["📦 Worker Nodes (DaemonSet & System)"]
            style Nodes fill:#e0f2f1,stroke:#009688,stroke-dasharray: 5 5,color:#000000
            
            cAdvisor["📉 cAdvisor<br/>[Built-in Kubelet]"]
            Promtail["📤 Promtail<br/>[DaemonSet Pod]<br/>모든 노드에 1개씩"]
        end

        %% 2-2. 모니터링 네임스페이스
        subgraph NS_Mon["📂 namespace: monitoring"]
            style NS_Mon fill:#f3e5f5,stroke:#9c27b0,stroke-width:1px,color:#000000
            
            Prometheus["📊 Prometheus<br/>[StatefulSet Pod]<br/>데이터 수집/저장"]
            Loki["📝 Loki<br/>[StatefulSet Pod]<br/>로그 저장소"]
            Grafana["📈 Grafana<br/>[Deployment Pod]<br/>시각화 웹"]
            KSM["📈 kube-state-metrics<br/>[Deployment Pod]"]
        end

        %% 2-3. 애플리케이션 네임스페이스
        subgraph NS_App["📂 namespace: default"]
            style NS_App fill:#fff3e0,stroke:#ff9800,stroke-width:1px,color:#000000
            
            CloudJanitor["🐍 Cloud Janitor<br/>[Deployment Pod]<br/>Core Logic"]:::highlight
            MySQL["🗄️ MySQL<br/>[StatefulSet Pod]<br/>DB"]
        end
    end

    %% ==========================================
    %% 흐름 정의 (Flow)
    %% ==========================================

    %% 1. 인프라 생성 (Provisioning)
    Terraform ==>|1. K8s 클러스터 생성| K8sCluster
    
    %% 2. 앱 배포 (Deployment)
    Ansible ==>|2. Helm 차트 배포| Prometheus
    Ansible ==>|2. Helm 차트 배포| Loki
    Ansible ==>|2. Helm 차트 배포| Grafana
    Ansible ==>|2. Manifest 배포| CloudJanitor

    %% 3. 데이터 수집 (Collection)
    cAdvisor -->|Metrics| Prometheus
    KSM -->|Metrics| Prometheus
    Promtail -->|Logs| Loki

    %% 4. 핵심 로직 (Logic)
    Prometheus -->|"3. 조회 (PromQL)"| CloudJanitor
    CloudJanitor -->|4. 삭제 이력| MySQL

    %% 5. 시각화 (Viz)
    Prometheus -.-> Grafana
    Loki -.-> Grafana
    MySQL -.-> Grafana
```

## 🛠 Tech Stack

| Category | Technology | Version | Description |
|----------|------------|---------|-------------|
| Language | Python | 3.12.12 | Main programming language |
| Package Manager | uv | latest | Fast Python package installer & resolver |
| IaC | Terraform | 1.14.3 | Infrastructure as Code |
| IaC | Ansible | 2.20.2 | Configuration Management |
| Container | Docker | latest | Container Runtime |
| Container | Kind | TBA | Kubernetes in Docker |
| Container Orchestration | Kubernetes (kubectl) | | Container Orchestration |
| Package Manager | Helm | | Kubernetes Package Manager |
| Database | MySQL | | Relational Database |
| Monitoring | Prometheus | | Metrics Collection |
| Visualization | Grafana | | Data Visualization |
| Logging | Loki | | Log Aggregation System |

버전 관리는 `pyproject.toml` 및 본 표를 기준으로 합니다.

## 🔄 Workflow

```mermaid
flowchart TB
    subgraph Input["📝 STEP 0: 사용자 입력"]
        Config["targets.yml<br/>- K8s: kubeconfig<br/>- VM: IP 주소"]
    end
    
    subgraph Terraform["🏗️ STEP 1: Terraform"]
        TF_Apply["terraform apply"]
        subgraph TF_Resources["생성되는 리소스"]
            VPC["VPC/Network"]
            EC2["EC2 (Optional)"]
            EKS["EKS (Optional)"]
            RDS["RDS (MySQL)"]
        end
        TF_Apply --> TF_Resources
        TF_Output["Output:<br/>prometheus_url<br/>loki_url<br/>grafana_url"]
        TF_Resources --> TF_Output
    end
    
    subgraph Ansible1["🔧 STEP 2: Ansible - 우리 서비스"]
        A1_Play["setup-cloud-janitor.yml"]
        subgraph OurStack["Cloud Janitor 스택"]
            Prometheus["Prometheus<br/>:9090"]
            Loki["Loki<br/>:3100"]
            Grafana["Grafana<br/>:3000"]
            MySQL["MySQL<br/>:3306"]
            CJ["Cloud Janitor<br/>Python App"]
        end
        A1_Play --> OurStack
    end
    
    subgraph Ansible2["🎯 STEP 3: Ansible - Target 설치"]
        A2_Play["setup-targets.yml"]
        
        subgraph K8sTarget["Target K8s"]
            KSM["✅ kube-state-metrics"]
            Promtail_K8s["✅ Promtail DaemonSet"]
            RBAC["✅ ServiceAccount/RBAC"]
        end
        
        subgraph VMTarget["Target VM"]
            NodeExp["✅ node_exporter"]
            Promtail_VM["✅ Promtail"]
            Firewall["✅ 방화벽 설정"]
        end
        
        A2_Play --> K8sTarget
        A2_Play --> VMTarget
    end
    
    subgraph Complete["✅ STEP 4: 완료"]
        Running["Cloud Janitor 실행 중!<br/>- 메트릭 수집<br/>- 저사용 Pod 감지<br/>- 자동 최적화"]
    end
    
    Config --> Terraform
    Terraform --> Ansible1
    Ansible1 --> Ansible2
    Ansible2 --> Complete
    
    K8sTarget -.->|metrics| Prometheus
    K8sTarget -.->|logs| Loki
    VMTarget -.->|metrics| Prometheus
    VMTarget -.->|logs| Loki
```

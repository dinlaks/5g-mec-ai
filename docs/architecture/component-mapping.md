# Component Mapping — Near Edge vs Far Edge
# 5G MEC Content Intelligence — Intelligent Pre-positioning & Adaptive Streaming

---

## Near Edge — OpenShift 4.21 + RHOAI 3.3 (GPU Cluster)

### Phase 01 — Foundation (Infrastructure & Operators)

| Component | Namespace | Role |
|---|---|---|
| cert-manager | cert-manager-operator | TLS for RHOAI, LlamaStack, Langfuse |
| Node Feature Discovery (NFD) | openshift-nfd | Labels GPU node for GPU Operator |
| NVIDIA GPU Operator | gpu-operator | GPU drivers + device plugin for vLLM |
| OpenShift GitOps (ArgoCD) | openshift-gitops | GitOps deployment engine |
| RHOAI 3.3 Operator | redhat-ods-operator | Manages vLLM, KServe, Kubeflow Pipelines |
| AMQ Streams 3.1 Operator | amq-streams | Manages Kafka cluster |
| AAP 2.5 Operator | aap | Manages AutomationController + EDAController |
| ACM 2.15 Operator | open-cluster-management | Multi-cluster management hub |

### Phase 02 — Data Pipeline

| Component | Namespace | Role |
|---|---|---|
| Kafka Cluster (KRaft, no ZooKeeper) | mec-ai-data | Event bus between far edge and near edge |
| Kafka Topics (8 topics) | mec-ai-data | Full data flow — telemetry, predictions, decisions, outcomes |
| MinIO | mec-ai-data | Object storage for vLLM + KServe model weights |
| Langfuse | mec-ai-obs | LLM observability — traces every agent decision |
| ClickHouse | mec-ai-obs | Langfuse analytics backend (LLM trace store) |
| Redis | mec-ai-obs | Langfuse queue backend (async trace ingestion) |
| PostgreSQL | mec-ai-obs | Langfuse metadata backend (projects, API keys) |

### Phase 03 — AI Core

| Component | Namespace | Role |
|---|---|---|
| RHOAI DataScienceCluster | redhat-ods-operator | Enables KServe, Kubeflow Pipelines, Dashboard |
| vLLM InferenceService (Llama 3.1 8B, GPU) | redhat-ods-applications | GPU LLM inference engine |
| LlamaStack 0.3.5 | mec-content-ai | Unified LLM API — tool calling, memory, provider abstraction |

### Phase 04 — Automation

| Component | Namespace | Role |
|---|---|---|
| AAP AutomationController | aap | Executes Ansible playbooks (prefetch, QoS, ABR, rollback, alert) |
| AAP EDAController | aap | Kafka-triggered automation bridge |
| EDA Rulebook | aap | Listens on `demand.predictions` — auto-triggers pre-warm at confidence > 0.95 |
| ACM MultiClusterHub | open-cluster-management | Governs all far-edge MEC clusters |
| ACM Placement (near-edge) | openshift-gitops | Targets near-edge cluster for ArgoCD apps |
| ACM Placement (far-edge) | openshift-gitops | Targets all far-edge MEC clusters for ApplicationSet |
| ACM GitOpsCluster | openshift-gitops | Links ACM Placements → ArgoCD |
| AAP Playbooks (5) | aap | prefetch-content, set-qos-policy, push-abr-policy, rollback-cache, alert-noc |

### Phase 05 — Agent & MCP Servers

| Component | Namespace | Role |
|---|---|---|
| ContentIntelligenceAgent (LangGraph) | mec-content-ai | 8-node agentic workflow — demand_reader → kubeflow_trigger |
| mcp-network-intel | mec-content-ai | Wraps 5G network APIs (capacity, cache inventory, event schedule, subscriber context) |
| mcp-kafka | mec-content-ai | Wraps AMQ Streams (read/publish all 8 Kafka topics) |
| mcp-aap | mec-content-ai | Wraps AAP REST API (trigger playbooks, poll job status) |
| mcp-slack | mec-content-ai | Wraps Slack Bolt API (human-in-loop approvals, notifications, reports) |
| mcp-kubeflow | mec-content-ai | Wraps Kubeflow Pipelines + MLflow (trigger retraining, register model) |
| mcp-openshift | mec-content-ai | Wraps OpenShift/K8s API (pod health, InferenceService status, node resources) |

### Phase 07 — Dashboard

| Component | Namespace | Role |
|---|---|---|
| EdgeStream IQ Backend (FastAPI + WebSocket) | mec-content-ai | Kafka consumers, Langfuse API, AAP REST, LangGraph state relay |
| EdgeStream IQ Frontend (React + Nginx) | mec-content-ai | 7-panel live operator dashboard |

---

## Far Edge — OpenShift SNO on MEC Node (CPU Only)

**Phase 06 — deployed to all MEC nodes via ACM ApplicationSet**
Namespace: `far-edge-mec`

| Component | Type | Role |
|---|---|---|
| OpenShift SNO | Single-node OpenShift cluster | Full OpenShift runtime — runs all far-edge pods |
| ACM Klusterlet | DaemonSet | Reports health to ACM Hub, enforces policies, detects drift |
| Telemetry Collector | Kafka Producer Pod | Taps UPF → publishes `content.requests.live`, `ue.density.live`, `network.capacity.live` |
| KServe LSTM (Demand Model) | KServe InferenceService (CPU, ~15 MB) | Predicts content demand spike → publishes `demand.predictions` |
| ABR Policy Engine | KServe InferenceService (CPU) | Enforces per-UE streaming quality (4K / 1080p / 720p) → publishes `qoe.metrics` |
| Cache Manager | Nginx + NVMe Pod | Stores pre-fetched video content → publishes `cache.state` |
| EDA Receiver | EDA Runner Pod | Executes AAP playbook jobs locally. Auto-pre-warms cache when confidence > 0.95 |

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│                        NEAR EDGE                                    │
│              OpenShift 4.21 + RHOAI 3.3 (GPU Cluster)              │
│                                                                     │
│  Phase 01: cert-manager · NFD · GPU Op · ArgoCD · RHOAI · Kafka   │
│            AMQ Streams · AAP · ACM                                  │
│                                                                     │
│  Phase 02: Kafka Cluster + 8 Topics · MinIO                        │
│            Langfuse (ClickHouse + Redis + PostgreSQL)               │
│                                                                     │
│  Phase 03: vLLM (Llama 3.1 8B, GPU) · LlamaStack                  │
│                                                                     │
│  Phase 04: AAP Controller + EDA + Playbooks · ACM Hub              │
│                                                                     │
│  Phase 05: LangGraph Agent · 6 MCP Servers                         │
│            (network-intel, kafka, aap, slack,                       │
│             kubeflow, openshift)                                    │
│                                                                     │
│  Phase 07: EdgeStream IQ (FastAPI backend + React frontend)         │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
           Kafka TLS  │  ACM  │  AAP API
                            │
┌───────────────────────────▼─────────────────────────────────────────┐
│                        FAR EDGE                                     │
│              OpenShift SNO on MEC Node (CPU Only)                   │
│                                                                     │
│  Phase 06: SNO · ACM Klusterlet                                     │
│            Telemetry Collector (Kafka Producer)                     │
│            KServe LSTM (~15 MB demand model)                        │
│            KServe ABR Policy Engine                                 │
│            Cache Manager (Nginx + NVMe)                             │
│            EDA Receiver                                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Rule of Thumb

| If it... | It lives on... |
|---|---|
| Needs GPU / LLM reasoning | Near Edge |
| Needs Kafka broker / centralized storage | Near Edge |
| Needs high availability across multiple sites | Near Edge |
| Runs in < 100ms using only local data | Far Edge |
| Is CPU-only, lightweight model (< 50 MB) | Far Edge |
| Touches raw UPF telemetry per cell sector | Far Edge |
| Enforces policy on the live streaming path | Far Edge |

---

## Managed By

| Layer | Near Edge | Far Edge |
|---|---|---|
| Application deployment | ArgoCD (GitOps) | ACM ApplicationSet |
| OS + device config | — | Machine Config Operator (MCO) |
| Cluster governance | ACM Hub | ACM Klusterlet (spoke) |
| Model delivery | Kubeflow Pipelines + MLflow | MinIO + KServe initContainer |
| Human-in-loop | Slack + EdgeStream IQ dashboard | — |

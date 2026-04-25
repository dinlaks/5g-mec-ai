# 5G MEC Content Intelligence — Intelligent Pre-positioning & Adaptive Streaming

> AI-Driven MEC Content Pre-positioning powered by Red Hat OpenShift AI

[![OpenShift](https://img.shields.io/badge/OpenShift-4.21-red)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![RHOAI](https://img.shields.io/badge/OpenShift%20AI-3.3-red)](https://www.redhat.com/en/technologies/cloud-computing/openshift/openshift-ai)
[![Kafka](https://img.shields.io/badge/AMQ%20Streams-3.1-orange)](https://www.redhat.com/en/resources/amq-streams-datasheet)
[![AAP](https://img.shields.io/badge/AAP-2.5-red)](https://www.redhat.com/en/technologies/management/ansible)
[![ACM](https://img.shields.io/badge/ACM-2.15-red)](https://www.redhat.com/en/technologies/management/advanced-cluster-management)
[![LangGraph](https://img.shields.io/badge/LangGraph-1.0-blue)](https://langchain-ai.github.io/langgraph/)
[![LlamaStack](https://img.shields.io/badge/LlamaStack-0.3.5-purple)](https://llama-stack.readthedocs.io)
[![Langfuse](https://img.shields.io/badge/Langfuse-3.x-green)](https://langfuse.com)

---

## Overview

An agentic AI system that predicts video content demand at 5G MEC edge nodes, pre-positions
content proactively before demand spikes, and dynamically adjusts per-subscriber ABR streaming
quality — reducing backhaul costs, improving QoE, and enabling new CDN revenue streams for US
telco operators (AT&T, Verizon, T-Mobile).

### Key Capabilities

| Capability | Technology | Result |
|---|---|---|
| Real-time demand prediction | KServe LSTM (far edge, CPU) | 30–60 min ahead |
| Agentic pre-positioning | LangGraph + LlamaStack + vLLM | < 2s decision cycle |
| MCP tool abstraction | FastMCP 3.0.2 (6 MCP servers) | Clean agent-to-system interface |
| AAP execution | AAP 2.5 + EDA | Prefetch, QoS, ABR policy push |
| Human-in-the-loop | LangGraph suspend + Slack | Approval gate for low-confidence runs |
| Full observability | Langfuse 3.x | Every LLM call and node traced |
| Live operator dashboard | EdgeStream IQ (React + FastAPI) | MEC map, agent graph, KPIs |
| Multi-cluster management | ACM 2.15 | Hub governs far edge MEC fleet |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  NEAR EDGE — OpenShift 4.21 + RHOAI 3.3                        │
│  GPU node (NVIDIA A10G or L40S)                                 │
│                                                                  │
│  RHOAI 3.3 · LlamaStack 0.3.5 · vLLM · Llama 3.1 8B           │
│  AMQ Streams 3.1 · AAP 2.5 + EDA · ACM 2.15 Hub               │
│  Langfuse 3.x · MinIO · FastMCP 3.0.2                          │
│  LangGraph 1.0 Agent · EdgeStream IQ Dashboard                  │
└──────────────────────────┬──────────────────────────────────────┘
                           │ Kafka TLS + ACM + AAP API
┌──────────────────────────▼──────────────────────────────────────┐
│  FAR EDGE — OpenShift SNO (each MEC node, CPU only)            │
│                                                                  │
│  KServe: LSTM demand prediction (~15 MB)                        │
│  KServe: ABR policy engine                                      │
│  Kafka Producer (telemetry → near edge)                         │
│  Nginx + NVMe: cache manager                                    │
│  ACM Klusterlet · EDA Receiver                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Full architecture:** [`5g-edge-usecase-content/uc-option-d-architecture.md`](../5g-edge-usecase-content/uc-option-d-architecture.md)

---

## Prerequisites

### Required Clusters
- [ ] Near Edge: OpenShift 4.21 with GPU node (NVIDIA A10G / L40S recommended)
- [ ] Far Edge: MicroShift node (CPU only, NVMe storage)

### Required Access
- [ ] Near Edge: `oc login <near-edge-api> --token=<token>`
- [ ] Far Edge: `oc login <far-edge-api> --token=<token>` (or SSH)
- [ ] Slack bot token for human-in-loop notifications
- [ ] Red Hat pull secret

### Required Subscriptions
- [ ] Red Hat OpenShift 4.21
- [ ] Red Hat OpenShift AI 3.3
- [ ] Red Hat ACM 2.15
- [ ] Red Hat AMQ Streams 3.1
- [ ] Red Hat Ansible Automation Platform 2.5

### Workstation Tools
```bash
oc          # OpenShift CLI 4.21+
helm        # Helm 3.x
git         # Git
python3     # Python 3.11+
kubectl     # Optional
```

---

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/dinlaks/5g-mec-ai.git
cd 5g-mec-ai

# 2. Configure environment
cp configs/near-edge/env.sh.example configs/near-edge/env.sh
cp configs/far-edge/env.sh.example configs/far-edge/env.sh
# Edit both files with your cluster details

# 3. Source near-edge environment
source configs/near-edge/env.sh

# 4. Run pre-flight checks
./scripts/phase-01-deploy.sh --validate

# 5. Follow implementation phases in order
# See: docs/deployment/START-HERE.md
```

---

## Implementation Phases

| Phase | Name | Key Deliverable |
|---|---|---|
| [01](implementation/phase-01-foundation/) | Foundation | All operators running, GPU node, namespaces |
| [02](implementation/phase-02-data-pipeline/) | Data Pipeline | Kafka + Langfuse + MinIO running |
| [03](implementation/phase-03-ai-core/) | AI Core | Llama 3.1 8B serving via RHOAI + LlamaStack |
| [04](implementation/phase-04-automation/) | Automation | AAP + EDA + ACM connected |
| [05](implementation/phase-05-agent-mcp/) | Agent & MCP | LangGraph agent + all 6 MCP servers |
| [06](implementation/phase-06-far-edge/) | Far Edge | KServe LSTM + ABR + cache at MEC node |
| [07](implementation/phase-07-dashboard/) | Dashboard | EdgeStream IQ live and connected |
| [08](implementation/phase-08-validation/) | Validation | Full NFL demand spike demo passing |

**Deployment order:** [`docs/deployment/START-HERE.md`](docs/deployment/START-HERE.md)

---

## Red Hat Products

| Product | Version | Role |
|---|---|---|
| OpenShift Container Platform | 4.21 | Container runtime (near + far edge) |
| Red Hat OpenShift AI | 3.3 | MLOps, model serving (vLLM + KServe) |
| Red Hat ACM | 2.15 | Multi-cluster management |
| Red Hat AMQ Streams | 3.1 | Event streaming (KRaft, no ZooKeeper) |
| Red Hat AAP | 2.5 | Automated remediation + prefetch execution |
| Event-Driven Ansible | 2.5 | Kafka-triggered automation |

## Open Source Stack

| Component | Version | Role |
|---|---|---|
| Llama 3.1 8B Instruct | Latest quantized | LLM reasoning engine |
| LlamaStack | 0.3.5 | Unified LLM API over vLLM |
| LangGraph | 1.0 | Agentic workflow (8 nodes) |
| Langfuse | 3.x | LLM observability (self-hosted) |
| FastMCP | 3.0.2 | MCP server framework |
| MinIO | Latest | Object storage (model artifacts) |

---

## Command Log

Every command run during implementation is logged in [`logs/COMMANDS-LOG.md`](logs/COMMANDS-LOG.md).

Format: `Phase | Command | Why | Expected Output | Actual Output | Status`

---

*5G MEC Content Intelligence · Telco Edge AI · April 2026*

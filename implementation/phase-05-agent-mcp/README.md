# Phase 05 — Agent & MCP Servers

## Goal
Deploy the ContentIntelligenceAgent (LangGraph) and all 7 MCP servers.
This is the core agentic intelligence of the system.

## LangGraph Agent — ContentIntelligenceAgent
> **LangGraph lives here** — it is the agent orchestration framework.
> `agent.py` contains the full 8-node StateGraph.
> LangGraph is a Python library inside the agent container — not a separate deployment.

```
agent/
├── agent.py          ← 8-node LangGraph StateGraph (full implementation)
├── state.py          ← ContentIntelligenceState TypedDict (separate file)
├── requirements.txt  ← langgraph, llamastack, langfuse, fastapi, confluent-kafka, fastmcp
├── Dockerfile
├── buildconfig.yaml  ← OpenShift BuildConfig (Git → ImageStream → Deployment)
└── deployment.yaml   ← Deployment + Service
                         Exposes:
                           GET  /health
                           GET  /agent/state/{run_id}    ← EdgeStream IQ polls this
                           POST /agent/resume/{run_id}   ← human approval relay
```

### 8-Node Flow
```
[Kafka: demand.predictions]
         ↓
demand_reader_node        ← mcp-kafka
         ↓
context_enricher_node     ← mcp-network-intel + mcp-kafka + mcp-openshift
         ↓
strategy_reasoner_node    ← LlamaStack → vLLM  [Langfuse traces here]
         ↓
confidence_gate_node      ← pure routing (no MCP calls)
    ↙              ↘
≥ 0.85           < 0.85
aap_executor     human_approver_node  ← mcp-slack → Slack OR dashboard /resume
    ↓                    ↓
outcome_verifier_node ←──┘   ← mcp-kafka + mcp-openshift
         ↓
kubeflow_trigger_node    ← mcp-kubeflow + mcp-slack
```

## Slack — Human-in-Loop
> **Slack lives here** — via `mcp-slack`.
> `human_approver_node` suspends the graph and posts an approval card to `#mec-ai-ops`.
> Operator approves/rejects from **Slack** OR from the **EdgeStream IQ dashboard** (Panel C).
> Both paths call `POST /agent/resume/{run_id}` on the agent API.

---

## MCP Servers — All 7

All built with **FastMCP 3.0.2**. Each server = its own folder with `server.py`, `Dockerfile`, `requirements.txt`. All deployed via `mcp-servers-deployment.yaml`. There are 6 MCP servers.

| # | Server | Wraps | Used By Nodes |
|---|---|---|---|
| 1 | `mcp-network-intel` | 5G network APIs | context_enricher, strategy_reasoner |
| 2 | `mcp-kafka` | AMQ Streams | demand_reader, context_enricher, aap_executor, outcome_verifier |
| 3 | `mcp-aap` | AAP REST API | aap_executor |
| 4 | `mcp-slack` | Slack Bolt API | human_approver, aap_executor, outcome_verifier, kubeflow_trigger |
| 5 | `mcp-kubeflow` | Kubeflow Pipelines + MLflow | kubeflow_trigger |
| 6 | `mcp-openshift` | OpenShift / K8s API | context_enricher, outcome_verifier |

### mcp-openshift — Tool Inventory
```python
get_pod_health(namespace, label_selector)
    # Checks far-edge cache manager + ABR engine pod status
    # Used by: context_enricher (before deciding to pre-cache)
    #          outcome_verifier (after AAP playbook executes)

get_inferenceservice_status(name, namespace)
    # Checks KServe LSTM model status on far-edge MEC node
    # Used by: context_enricher (is far-edge model healthy?)

get_deployment_status(name, namespace)
    # Checks near-edge agent + MCP server health
    # Used by: outcome_verifier (system self-check)

get_node_resources(node_name)
    # CPU/memory/GPU utilization on GPU node
    # Used by: context_enricher (is near-edge at capacity?)
```

## Folder Structure

```
phase-05-agent-mcp/
├── README.md
├── COMMANDS.md
├── agent/
│   ├── agent.py
│   ├── state.py
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── buildconfig.yaml
│   └── deployment.yaml
└── mcp-servers/
    ├── mcp-network-intel/
    │   ├── server.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── mcp-kafka/
    │   ├── server.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── mcp-aap/
    │   ├── server.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── mcp-slack/
    │   ├── server.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── mcp-kubeflow/
    │   ├── server.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── mcp-openshift/
    │   ├── server.py
    │   ├── requirements.txt
    │   └── Dockerfile
    └── mcp-servers-deployment.yaml   ← all 6 MCP servers in one YAML
```

## Dependencies
- Phase 02 — Kafka + Langfuse running
- Phase 03 — LlamaStack running (agent calls it for LLM reasoning)
- Phase 04 — AAP running (mcp-aap); ACM hub ready (mcp-openshift needs cluster access)
- Slack bot token in Secret
- Langfuse API key in Secret

## GitOps
Managed by ArgoCD Application: `mec-agent-mcp` (auto-sync)

## Validation
```bash
# All 7 MCP servers + agent running
oc get pods -n mec-content-ai | grep -E "mcp|agent"

# Agent health
curl http://$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}')/health

# MCP status
curl http://$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}')/mcp/status | jq

# Synthetic demand spike → watch Langfuse for traces
./scripts/validate-demo.sh synthetic
echo "Langfuse: $LANGFUSE_HOST"
```

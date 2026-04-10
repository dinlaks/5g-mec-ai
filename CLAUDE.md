# CLAUDE.md — 5G MEC Content Intelligence
# Auto-loaded by Claude Code (CLI + Cursor extension) on every session.
# Keep this up to date as the project progresses.

---

## What This Project Is

**Use Case:** Intelligent 5G MEC Content Pre-positioning & Adaptive Streaming
**Goal:** Agentic AI system that predicts video content demand at 5G MEC edge nodes,
pre-caches content proactively, and adjusts ABR streaming quality per subscriber —
reducing backhaul costs, improving QoE, enabling CDN revenue for US telco operators.
**Purpose:** Demo / PoC on Red Hat OpenShift AI stack.

---

## Tech Stack (Locked In)

| Layer | Technology | Version |
|---|---|---|
| Container platform | Red Hat OpenShift | 4.21 |
| AI/ML platform | RHOAI | 3.3 |
| LLM inference | vLLM (via RHOAI KServe) | — |
| Model | Llama 3.1 8B Instruct (quantized) | — |
| LLM API layer | LlamaStack (via RHOAI CRD) | 0.4.2 (RHOAI 3.3 ships with 0.4.2.1+rhai0) |
| Agent framework | LangGraph | 1.0 |
| MCP framework | FastMCP | 3.0.2 |
| LLM observability | Langfuse (self-hosted) | 3.x |
| Event streaming | AMQ Streams (Kafka KRaft) | 3.1 |
| Automation | AAP + EDA | 2.5 |
| Multi-cluster mgmt | ACM | 2.15 |
| GitOps | OpenShift GitOps (ArgoCD) | — |
| Dashboard | EdgeStream IQ (React + FastAPI) | — |
| Human-in-loop | Slack (via mcp-slack) | — |

---

## Architecture — Two Tiers

**Near Edge** (OpenShift 4.21 + RHOAI 3.3, GPU):
Kafka broker · MinIO · Langfuse · vLLM · LlamaStack · AAP+EDA · ACM Hub · LangGraph agent · 7 MCP servers · EdgeStream IQ dashboard

**Far Edge** (OpenShift SNO on MEC node, CPU only):
Telemetry Collector · KServe LSTM (~15MB) · ABR Policy Engine · Cache Manager (Nginx+NVMe) · EDA Receiver · ACM Klusterlet

Full map: `docs/architecture/component-mapping.md`
Full architecture: `../5g-edge-usecase-content/uc-option-d-architecture.md`

---

## Phase Mapping — What Lives Where

| Phase | Name | Key Components | Cluster |
|---|---|---|---|
| 01 | Foundation | Operators (wave-0/wave-1), namespaces, GitOps bootstrap | Near Edge |
| 02 | Data Pipeline | Kafka + 8 topics, MinIO, **Langfuse** (ClickHouse+Redis+PG) | Near Edge |
| 03 | AI Core | vLLM InferenceService, **LlamaStack** | Near Edge |
| 04 | Automation | AAP + EDA + playbooks, ACM hub | Near Edge |
| 05 | Agent & MCP | **LangGraph** agent, 6 MCP servers, **Slack** via mcp-slack | Near Edge |
| 06 | Far Edge | KServe LSTM, ABR engine, cache manager, telemetry collector | Far Edge |
| 07 | Dashboard | EdgeStream IQ backend (FastAPI) + frontend (React) | Near Edge |
| 08 | Validation | test-scenarios.sh, demand-spike-cronjob.yaml | Both |

**Key rule:** LlamaStack=Ph03, LangGraph=Ph05, Langfuse=Ph02, Slack=Ph05 via mcp-slack

---

## LangGraph Agent — 8 Nodes

```
demand_reader → context_enricher → strategy_reasoner → confidence_gate
    → [≥0.85] aap_executor → outcome_verifier → kubeflow_trigger
    → [<0.85] human_approver (Slack OR EdgeStream IQ) → aap_executor
```

---

## 7 MCP Servers (Phase 05)

| Server | Wraps |
|---|---|
| mcp-network-intel | 5G network APIs (capacity, cache inventory, event schedule) |
| mcp-kafka | AMQ Streams (read/publish all 8 topics) |
| mcp-aap | AAP REST API (trigger playbooks, poll jobs) |
| mcp-slack | Slack Bolt API (approvals, notifications) |
| mcp-kubeflow | Kubeflow Pipelines + MLflow |
| mcp-openshift | OpenShift/K8s API (pod health, InferenceService status) |

---

## GitOps Model

```
Phase 01: Manual oc apply (operators + bootstrap only)
    └── ArgoCD + ACM take over from Phase 02 onwards
            ├── Near edge: 5 ArgoCD Applications (auto/manual sync per phase)
            └── Far edge: 1 ACM ApplicationSet → all MEC nodes
```

Bootstrap: `gitops/bootstrap/`
ACM resources: `gitops/acm/`
ArgoCD apps: `gitops/apps/near-edge/` + `gitops/apps/far-edge/`

---

## Kafka Topics (8)

`content.requests.live` · `ue.density.live` · `network.capacity.live` ·
`cache.state` · `qoe.metrics` · `demand.predictions` · `agent.decisions` · `remediation.outcomes`

---

## Current Build Status

| Phase | Status | Notes |
|---|---|---|
| 01 Foundation | ✅ Complete | Operators, namespaces, COMMANDS.md all written |
| 02 Data Pipeline | 📄 YAMLs + COMMANDS.md written | Kafka + MinIO + Langfuse (ClickHouse+Redis+PG) — Langfuse API key step in COMMANDS.md Step 7 |
| 03 AI Core | 📄 YAMLs + COMMANDS.md written | vLLM ServingRuntime + InferenceService + LlamaStackDistribution CRD (v0.4.2, RHOAI-managed) — model via RHOAI catalog |
| 04 Automation | 📄 README only | AAP + EDA + playbooks not yet written |
| 05 Agent & MCP | 📄 README only | agent.py + 7 MCP server stubs not yet written |
| 06 Far Edge | 📄 README only | KServe + ABR + cache YAMLs not yet written |
| 07 Dashboard | 📄 README only | FastAPI backend + React frontend not yet written |
| 08 Validation | 📄 README only | test-scenarios.sh not yet written |

Live status: `logs/PROGRESS-TRACKER.md`

---

## Verification Rule (IMPORTANT)

All content built so far is **planned/designed state — not verified on a live cluster**.
When implementing on actual OpenShift 4.21:
- Verify EVERY step before proceeding to the next
- Use `COMMANDS.md` per phase as the verification checklist
- Update `logs/PROGRESS-TRACKER.md` and `logs/COMMANDS-LOG.md` with actual outputs
- Do NOT assume a resource works — confirm with `oc get` / `curl` / logs
- If something fails: diagnose root cause, do not skip

---

## Key File Paths

| File | Purpose |
|---|---|
| `docs/deployment/START-HERE.md` | First doc to read before any deployment |
| `docs/architecture/component-mapping.md` | Full near/far edge component map |
| `logs/PROGRESS-TRACKER.md` | Live phase-by-phase status |
| `logs/COMMANDS-LOG.md` | Every command run with output |
| `RECOVERY-CHECKLIST.md` | Redeploy safety checklist |
| `configs/near-edge/env.sh.example` | Near-edge cluster env vars template |
| `configs/far-edge/env.sh.example` | Far-edge MEC node env vars template |
| `../5g-edge-usecase-content/uc-option-d-architecture.md` | Source of truth for architecture |

---

## Reference Repo

`msugur/auto-darknoc` on GitHub — mirror its full structure and patterns.
Repurpose ALL sections: scripts, configs, deploy, docs, logs, gitops, playbooks, implementation.
Key file to study: `implementation/phase-05-agent-mcp/agent/agent.py` (31KB LangGraph reference)

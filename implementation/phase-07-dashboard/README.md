# Phase 07 — EdgeStream IQ Dashboard

## What This Phase Does

Deploys the **EdgeStream IQ** live operator dashboard — a two-component application
(FastAPI backend + React frontend) that gives engineers real-time visibility into
the entire 5G MEC Content Intelligence system.

## Architecture

```
Browser (operator)
      │ WebSocket + REST
      ▼
EdgeStream IQ Frontend (React + Vite, served by Nginx)
      │ /api/* HTTP calls
      ▼
EdgeStream IQ Backend (FastAPI + WebSocket)
      ├── Kafka consumers (8 topics)   ← real-time data from near + far edge
      ├── Langfuse API                 ← agent trace data + LLM metrics
      ├── AAP REST API                 ← playbook job status
      └── Agent API                   ← LangGraph run state + node progress
```

## 7 Dashboard Panels

| Panel | Data Source | What It Shows |
|---|---|---|
| **A — MEC Site Map** | Kafka: `ue.density.live`, `cache.state` | Per-site UE count, cache hit rate, site health |
| **B — AI Prediction Feed** | Kafka: `demand.predictions` | Incoming LSTM predictions, confidence scores, content IDs |
| **C — Agent Decision Center** | Agent API `/agent/state/{run_id}` | LangGraph 8-node flow with live node highlighting, human approval queue |
| **D — Cache Intelligence** | Kafka: `cache.state` | Cache hit rate over time, pre-fetched content inventory |
| **E — QoE Live View** | Kafka: `qoe.metrics` | Buffering rate, QoE score, quality tier distribution |
| **F — Business KPIs** | Kafka: `remediation.outcomes` | Backhaul saved (Mbps), $ saved counter, events handled |
| **G — AI Health** | Langfuse API | LLM trace count, avg latency, confidence trend, Langfuse link |

## Files

```
phase-07-dashboard/
├── README.md
├── COMMANDS.md
├── backend/
│   ├── app.py                 ← FastAPI server: WebSocket hub + REST endpoints
│   ├── kafka_consumer.py      ← Kafka consumer threads for all 8 topics
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── buildconfig.yaml
│   └── deployment.yaml        ← Deployment + Service + Route
└── frontend/
    ├── src/
    │   ├── App.jsx             ← Root app: layout + WebSocket connection
    │   ├── main.jsx
    │   ├── index.css
    │   └── components/
    │       ├── MecSiteMap.jsx
    │       ├── AIPredictionFeed.jsx
    │       ├── AgentDecisionCenter.jsx
    │       ├── CacheIntelligence.jsx
    │       ├── QoELiveView.jsx
    │       ├── BusinessKPIs.jsx
    │       └── AIHealth.jsx
    ├── package.json
    ├── vite.config.js
    ├── index.html
    ├── nginx.conf
    ├── Dockerfile
    ├── buildconfig.yaml
    └── deployment.yaml        ← Deployment + Service + Route
```

## Key Demo Features

- **Live LangGraph node highlighting** — Panel C shows the 8-node graph with the
  current active node highlighted in real-time as the agent processes an event
- **Human approval queue** — Panel C shows pending approvals with Approve/Reject
  buttons that call `POST /agent/resume/{run_id}` on the agent API
- **Cache hit rate jump** — Panel D shows the dramatic jump from ~12% → ~87%
  after a pre-cache event — this is the headline demo metric
- **$ saved counter** — Panel F accumulates backhaul cost saved per event

## GitOps

Managed by ArgoCD Application `mec-dashboard` (auto-sync).
Both backend and frontend are built via OpenShift BuildConfig (Git → ImageStream).

## Dependencies

- Phase 02: Kafka + Langfuse running
- Phase 04: AAP running (for job status polling)
- Phase 05: Agent API running (for LangGraph state)
- Phase 06: Far-edge pods publishing to Kafka topics

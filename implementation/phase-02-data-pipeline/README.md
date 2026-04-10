# Phase 02 — Data Pipeline

## Goal
Deploy the full data infrastructure: Kafka event bus, MinIO object storage, and Langfuse
observability stack. Everything the agent and far-edge modules write to and read from.

## What Gets Deployed

### Kafka (AMQ Streams 3.1 — KRaft mode, no ZooKeeper)
- Kafka cluster in `mec-ai-data` namespace
- 8 topics covering the full data flow between far edge and near edge

### MinIO
- Object storage for model artifacts (vLLM + KServe model weights)
- Bucket: `mec-models`
- Deployed in `mec-ai-data` namespace

### Langfuse (self-hosted)
> **Langfuse lives here** — it is observability infrastructure, deployed before the agent.
> The agent (Phase 05) and LlamaStack (Phase 03) write traces to Langfuse.
> Langfuse must be running before Phase 03 and Phase 05.

Langfuse requires 3 backends:

| Backend | Why |
|---|---|
| **ClickHouse** | Analytics store — all LLM traces and spans |
| **Redis** | Queue — async trace ingestion |
| **PostgreSQL** | Metadata store — projects, API keys, users |

All deployed in `mec-ai-obs` namespace.

## Kafka Topics

| Topic | Producer | Consumer(s) | Payload |
|---|---|---|---|
| `content.requests.live` | Far Edge: Telemetry Collector | Far Edge: Demand Detection | Per-title request rate |
| `ue.density.live` | Far Edge: Telemetry Collector | Far Edge: Demand Detection | UE count per sector |
| `network.capacity.live` | Far Edge: Telemetry Collector | Near Edge: mcp-kafka, EdgeStream IQ | PRB utilization, throughput |
| `cache.state` | Far Edge: Cache Manager | Near Edge: mcp-kafka, EdgeStream IQ | Hit rate, inventory, storage |
| `qoe.metrics` | Far Edge: ABR Policy Engine | Near Edge: mcp-kafka, EdgeStream IQ | Buffering ratio, resolution |
| `demand.predictions` | Far Edge: Demand Detection | Near Edge: agent + EDA, EdgeStream IQ | Spike prediction, confidence |
| `agent.decisions` | Near Edge: aap_executor node | Near Edge: EDA, EdgeStream IQ | Action decided by agent |
| `remediation.outcomes` | Near Edge: outcome_verifier node | Near Edge: kubeflow_trigger, EdgeStream IQ | QoE result, cache hit after |

## Folder Structure

```
phase-02-data-pipeline/
├── README.md
├── COMMANDS.md
├── kafka/
│   ├── kafka-cluster.yaml            ← AMQ Streams KRaft cluster
│   └── kafka-topics.yaml             ← all 8 topic definitions
├── minio/
│   └── minio-deployment.yaml
└── langfuse/
    ├── langfuse-values.yaml          ← Helm values (connects to backends)
    ├── langfuse-secrets.yaml         ← API keys, passwords (templated)
    ├── langfuse-route.yaml           ← OpenShift Route (HTTPS)
    ├── clickhouse-deployment.yaml    ← ClickHouse analytics store
    ├── redis-deployment.yaml         ← Redis queue
    └── postgresql-deployment.yaml    ← PostgreSQL metadata store
```

## Dependencies
- Phase 01 complete — AMQ Streams operator running, namespaces created
- ArgoCD Application `mec-data-pipeline` syncing from Git

## GitOps
Managed by ArgoCD Application: `mec-data-pipeline` (auto-sync)
Commit files here → ArgoCD syncs automatically.

## Validation
```bash
oc get kafka -n mec-ai-data
oc get kafkatopics -n mec-ai-data
oc get pods -n mec-ai-data | grep minio
oc get pods -n mec-ai-obs
echo "Langfuse: https://$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}')"
```

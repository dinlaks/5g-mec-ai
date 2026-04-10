# Phase 02 — Data Pipeline — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Update "Actual Output" and "Status" as you run each command.
Status: ✅ Success | ❌ Failed | ⬜ Not yet run | 🔄 In progress

> **Note:** After Phase 01, ArgoCD Application `mec-data-pipeline` manages this phase.
> Changes committed to Git are auto-synced. Manual `oc apply` only needed for secrets
> and one-time steps (Langfuse API key generation).

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `source configs/near-edge/env.sh` | Load environment variables | No output (silent) | | ⬜ |
| `oc get namespace mec-ai-data` | Namespace exists from Phase 01 | `Active` | | ⬜ |
| `oc get namespace mec-ai-obs` | Namespace exists from Phase 01 | `Active` | | ⬜ |
| `oc get csv -n amq-streams` | AMQ Streams operator ready | `Succeeded` | | ⬜ |

---

## Step 1 — Apply Secrets (manual — not GitOps managed)

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `./scripts/apply-secrets.sh --validate` | Check all Phase 02 env vars are set | `All required variables are set` | | ⬜ |
| `./scripts/apply-secrets.sh --phase 02` | Create all Phase 02 secrets | 4 secrets applied | | ⬜ |
| `oc get secrets -n mec-ai-obs` | Verify Langfuse secrets created | `langfuse-db-secret`, `langfuse-clickhouse-secret`, `langfuse-app-secret` listed | | ⬜ |
| `oc get secrets -n mec-ai-data` | Verify MinIO secret created | `minio-secret` listed | | ⬜ |

---

## Step 2 — Kafka Cluster

> GitOps: ArgoCD `mec-data-pipeline` app syncs these from Git automatically.
> Manual apply only if ArgoCD is not yet set up.

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-02-data-pipeline/kafka/kafka-cluster.yaml` | Deploy Kafka KRaft cluster | `kafkanodepool + kafka created` | | ⬜ |
| `oc get kafka -n mec-ai-data` | Kafka cluster ready | `kafka-cluster` with `Ready` condition | | ⬜ |
| `oc get kafkanodepool -n mec-ai-data` | Node pools ready | `controller` and `broker` both `Ready` | | ⬜ |
| `oc get pods -n mec-ai-data \| grep kafka` | All Kafka pods running | 6 pods Running (3 controller + 3 broker) | | ⬜ |
| `oc wait kafka/kafka-cluster --for=condition=Ready --timeout=300s -n mec-ai-data` | Wait for cluster ready | `kafka.kafka.strimzi.io/kafka-cluster condition met` | | ⬜ |

---

## Step 3 — Kafka Topics

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-02-data-pipeline/kafka/kafka-topics.yaml` | Create all 8 topics | 8 `kafkatopic` resources created | | ⬜ |
| `oc get kafkatopics -n mec-ai-data` | Verify all topics created | 8 topics listed, all `Ready` | | ⬜ |
| `oc get kafkatopic demand-predictions -n mec-ai-data -o jsonpath='{.status.conditions[0].type}'` | demand.predictions topic ready | `Ready` | | ⬜ |

### Quick Kafka connectivity test
```bash
# Produce a test message
oc run kafka-producer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions
# Type: {"site_id":"test","confidence":0.91} then Ctrl+C

# Consume to verify
oc run kafka-consumer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions \
  --from-beginning \
  --max-messages 1
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Kafka produce/consume test (above) | Verify Kafka is working end-to-end | Message consumed successfully | | ⬜ |

---

## Step 4 — MinIO

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-02-data-pipeline/minio/minio-deployment.yaml` | Deploy MinIO | Deployment + Service + Route created | | ⬜ |
| `oc get pods -n mec-ai-data \| grep minio` | MinIO pod running | `Running` | | ⬜ |
| `oc get route minio-console -n mec-ai-data` | Get MinIO console URL | Route URL | | ⬜ |
| `curl -s http://minio.mec-ai-data.svc.cluster.local:9000/minio/health/ready` | MinIO health check | HTTP 200 | | ⬜ |

### Create MinIO bucket
```bash
# Port-forward to access MinIO locally
oc port-forward svc/minio 9000:9000 -n mec-ai-data &

# Create bucket using mc (MinIO client)
mc alias set mec-minio http://localhost:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc mb mec-minio/mec-models
mc ls mec-minio
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| MinIO bucket creation (above) | Create `mec-models` bucket for model storage | `mec-models` bucket listed | | ⬜ |

---

## Step 5 — Langfuse Backends (PostgreSQL + ClickHouse + Redis)

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-02-data-pipeline/langfuse/postgresql-deployment.yaml` | Deploy PostgreSQL | Deployment + Service created | | ⬜ |
| `oc apply -f implementation/phase-02-data-pipeline/langfuse/clickhouse-deployment.yaml` | Deploy ClickHouse | Deployment + Service created | | ⬜ |
| `oc apply -f implementation/phase-02-data-pipeline/langfuse/redis-deployment.yaml` | Deploy Redis | Deployment + Service created | | ⬜ |
| `oc get pods -n mec-ai-obs` | All backend pods running | `postgresql`, `clickhouse`, `redis` all `Running` | | ⬜ |
| `oc wait deployment/postgresql --for=condition=Available --timeout=120s -n mec-ai-obs` | PostgreSQL ready | `deployment.apps/postgresql condition met` | | ⬜ |
| `oc wait deployment/clickhouse --for=condition=Available --timeout=120s -n mec-ai-obs` | ClickHouse ready | `deployment.apps/clickhouse condition met` | | ⬜ |
| `oc wait deployment/redis --for=condition=Available --timeout=60s -n mec-ai-obs` | Redis ready | `deployment.apps/redis condition met` | | ⬜ |

---

## Step 6 — Langfuse (Helm install)

```bash
# Add Langfuse Helm repo
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update

# Install Langfuse (uses values from langfuse-values.yaml)
# Update the nextauth.url in langfuse-values.yaml with your cluster domain first
helm upgrade --install langfuse langfuse/langfuse \
  --namespace mec-ai-obs \
  --values implementation/phase-02-data-pipeline/langfuse/langfuse-values.yaml \
  --wait \
  --timeout 5m
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `helm repo add langfuse https://langfuse.github.io/langfuse-k8s` | Add Helm repo | `"langfuse" has been added` | | ⬜ |
| `helm upgrade --install langfuse ... (above)` | Deploy Langfuse | `Release "langfuse" has been deployed` | | ⬜ |
| `oc apply -f implementation/phase-02-data-pipeline/langfuse/langfuse-route.yaml` | Expose Langfuse via Route | `route.route.openshift.io/langfuse created` | | ⬜ |
| `oc get pods -n mec-ai-obs \| grep langfuse` | Langfuse pods running | `langfuse-web` and `langfuse-worker` both `Running` | | ⬜ |
| `oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}'` | Get Langfuse URL | `langfuse.apps.<cluster>` | | ⬜ |
| `curl -s https://$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}')/api/public/health` | Langfuse API health | `{"status":"ok"}` | | ⬜ |

---

## Step 7 — Generate Langfuse API Keys ⚠️ REQUIRED before Phase 05

> This step is **mandatory**. The agent (Phase 05) and EdgeStream IQ dashboard (Phase 07)
> need Langfuse API keys to send traces. Generate them now and save to `env.sh`.

### 7a — Create Langfuse account + project

```bash
# Open Langfuse UI in browser
echo "Langfuse URL: https://$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}')"
```

1. Open the URL in your browser
2. Click **Sign up** → create an admin account
3. Create a new **Organization**: `mec-content-ai`
4. Create a new **Project**: `5g-mec-intelligence`

### 7b — Generate API Keys

1. In Langfuse UI → go to **Settings** (top right) → **API Keys**
2. Click **Create new API key**
3. Copy both keys — you will only see the secret key **once**

### 7c — Save keys to env.sh

```bash
# Edit configs/near-edge/env.sh and update these two lines:
export LANGFUSE_PUBLIC_KEY="pk-lf-<paste-your-public-key>"
export LANGFUSE_SECRET_KEY="sk-lf-<paste-your-secret-key>"

# Also update LANGFUSE_HOST with your actual Route URL
export LANGFUSE_HOST="https://$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}')"
```

### 7d — Apply Phase 05 secrets (now that keys are available)

```bash
source configs/near-edge/env.sh

# Validate Phase 05 vars now include Langfuse keys
./scripts/apply-secrets.sh --validate

# Apply Phase 05 secrets (can be done now, ready for when Phase 05 deploys)
./scripts/apply-secrets.sh --phase 05
```

| Step | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Langfuse UI accessible in browser | Verify Langfuse is working | Login page loads | | ⬜ |
| Created organization + project | Required for API keys | `mec-content-ai` org, `5g-mec-intelligence` project | | ⬜ |
| API key generated | Agent + dashboard need this | Public key `pk-lf-...` + Secret key `sk-lf-...` | | ⬜ |
| Keys saved to `configs/near-edge/env.sh` | Single source of truth | `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` set | | ⬜ |
| `./scripts/apply-secrets.sh --phase 05` | Pre-create Phase 05 secrets | 5 secrets applied in `mec-content-ai` | | ⬜ |

---

## Phase 02 Complete ✅

When all rows above are ✅, Phase 02 is done.

### Quick validation
```bash
# All pods running
oc get pods -n mec-ai-data
oc get pods -n mec-ai-obs

# All 8 Kafka topics exist
oc get kafkatopics -n mec-ai-data

# Langfuse healthy
curl -s https://$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}')/api/public/health

# MinIO bucket exists
mc ls mec-minio/
```

**Next:** Phase 03 — AI Core (vLLM + LlamaStack).
Langfuse API keys are now in `env.sh` and Phase 05 secrets are pre-created — Phase 03 can instrument traces from day one.

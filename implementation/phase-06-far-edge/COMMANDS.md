# Phase 06 — Far Edge — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Update "Actual Output" and "Status" as you run each command.
Status: ✅ Success | ❌ Failed | ⬜ Not yet run | 🔄 In progress

> **Note:** Phase 06 deploys to far-edge SNO clusters via ACM ApplicationSet.
> All YAMLs are applied by ArgoCD on each SNO cluster automatically once
> the ApplicationSet is synced. Manual steps here cover:
> - MEC kubeconfig setup
> - LSTM model upload to MinIO
> - End-to-end telemetry → prediction → Kafka test

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `source configs/near-edge/env.sh` | Load env vars | Silent | | ⬜ |
| `oc get managedcluster mec-stadium-01` | SNO node 1 registered with ACM | `Available=True` | | ⬜ |
| `oc get managedcluster mec-stadium-02` | SNO node 2 registered with ACM | `Available=True` | | ⬜ |
| `oc get applicationset far-edge-mec-workloads -n openshift-gitops` | ApplicationSet exists | Listed | | ⬜ |
| `oc get kafkatopic cache.state -n mec-ai-data` | cache.state topic exists (Phase 02) | `Ready` | | ⬜ |
| `oc get kafkatopic demand.predictions -n mec-ai-data` | demand.predictions topic exists | `Ready` | | ⬜ |

---

## Step 1 — Set MEC Kubeconfig Variables

> The MEC kubeconfigs were saved during setup-infra.sh.
> Export them so subsequent steps can target far-edge clusters directly.

```bash
export MEC_01_KUBECONFIG="${HOME}/mec-rhdp/mec-stadium-01-kubeconfig"
export MEC_02_KUBECONFIG="${HOME}/mec-rhdp/mec-stadium-02-kubeconfig"

# Verify both SNO clusters are reachable
KUBECONFIG=${MEC_01_KUBECONFIG} oc get nodes
KUBECONFIG=${MEC_02_KUBECONFIG} oc get nodes
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `KUBECONFIG=${MEC_01_KUBECONFIG} oc get nodes` | mec-stadium-01 reachable | 1 node `Ready` | | ⬜ |
| `KUBECONFIG=${MEC_02_KUBECONFIG} oc get nodes` | mec-stadium-02 reachable | 1 node `Ready` | | ⬜ |

---

## Step 2 — Upload LSTM Model to MinIO

> The LSTM demand predictor downloads the model from MinIO at pod startup.
> For demo: upload a minimal placeholder ONNX model.
> For production: replace with a properly trained model from Kubeflow Pipelines.

```bash
# Port-forward MinIO
oc port-forward svc/minio 9000:9000 -n mec-ai-data &

# Create demo LSTM model (minimal ONNX file — correct shape for demo)
python3 - << 'EOF'
import numpy as np

# Create a minimal ONNX model for demo purposes
# Input: [batch=1, sequence=10, features=5] → Output: [predicted_viewers, confidence, peak_mins/60]
try:
    from skl2onnx import to_onnx
    from sklearn.linear_model import LinearRegression
    import onnx

    # Train a trivial model on dummy data
    X = np.random.rand(100, 50).astype(np.float32)   # 10 timesteps × 5 features = 50
    y = np.random.rand(100, 3).astype(np.float32)     # 3 outputs
    model = LinearRegression().fit(X, y)
    onnx_model = to_onnx(model, X[:1], target_opset=12)
    with open("/tmp/model.onnx", "wb") as f:
        f.write(onnx_model.SerializeToString())
    print("Demo ONNX model created: /tmp/model.onnx")
except ImportError:
    # Fallback: create minimal valid ONNX manually
    import struct
    # Write a minimal ONNX file (the server falls back to rules-based if model is invalid)
    with open("/tmp/model.onnx", "wb") as f:
        f.write(b"")
    print("Placeholder model created — server will use rules-based fallback")
EOF

# Upload to MinIO
mc alias set mec-minio http://localhost:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
mc mb mec-minio/mec-models --ignore-existing
mc cp /tmp/model.onnx mec-minio/mec-models/lstm-demand/latest/model.onnx

# Verify upload
mc ls mec-minio/mec-models/lstm-demand/latest/
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `mc ls mec-minio/mec-models/lstm-demand/latest/` | Model uploaded to MinIO | `model.onnx` listed | | ⬜ |

---

## Step 3 — Verify ACM ApplicationSet Synced to SNO Nodes

> ArgoCD ApplicationSet `far-edge-mec-workloads` deploys Phase 06 YAMLs
> to all MEC clusters matching the far-edge Placement.
> This happens automatically when the clusters are registered with ACM.

```bash
# Check ArgoCD Applications created for each MEC site
oc get applications -n openshift-gitops | grep far-edge

# Check sync status for both
oc get application far-edge-mec-stadium-01 -n openshift-gitops \
  -o jsonpath='{.status.sync.status}'
oc get application far-edge-mec-stadium-02 -n openshift-gitops \
  -o jsonpath='{.status.sync.status}'
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get applications -n openshift-gitops \| grep far-edge` | ApplicationSet created apps for both sites | `far-edge-mec-stadium-01` and `far-edge-mec-stadium-02` listed | | ⬜ |
| Application `far-edge-mec-stadium-01` sync status | Phase 06 YAMLs deployed to SNO-01 | `Synced` | | ⬜ |
| Application `far-edge-mec-stadium-02` sync status | Phase 06 YAMLs deployed to SNO-02 | `Synced` | | ⬜ |

---

## Step 4 — Verify All Pods Running on SNO Nodes

```bash
# Check mec-stadium-01
KUBECONFIG=${MEC_01_KUBECONFIG} oc get pods -n far-edge-mec

# Check mec-stadium-02
KUBECONFIG=${MEC_02_KUBECONFIG} oc get pods -n far-edge-mec
```

| Pod | Why | Expected | Actual | Status (SNO-01) | Status (SNO-02) |
|---|---|---|---|---|---|
| `telemetry-collector-*` | Raw telemetry publisher | `Running` | | ⬜ | ⬜ |
| `demand-predictor-*` | LSTM caller + demand.predictions publisher | `Running` | | ⬜ | ⬜ |
| `lstm-demand-predictor-*` | Model server (FastAPI + ONNX) | `Running` | | ⬜ | ⬜ |
| `abr-policy-engine-*` | Quality decision server (FastAPI) | `Running` | | ⬜ | ⬜ |
| `cache-manager-*` | Nginx cache + cache-reporter sidecar | `Running` | | ⬜ | ⬜ |
| `eda-receiver-*` | Ultra-high confidence fast-path trigger | `Running` | | ⬜ | ⬜ |

### Wait for all pods
```bash
KUBECONFIG=${MEC_01_KUBECONFIG} oc wait deployment \
  telemetry-collector demand-predictor lstm-demand-predictor \
  abr-policy-engine cache-manager eda-receiver \
  --for=condition=Available --timeout=300s -n far-edge-mec
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc wait deployment ... --for=condition=Available` (above) | All deployments available on SNO-01 | All `condition met` | | ⬜ |

---

## Step 5 — Health Checks

```bash
# Port-forward cache-manager on SNO-01 to verify locally
KUBECONFIG=${MEC_01_KUBECONFIG} \
  oc port-forward svc/cache-manager 8081:8080 -n far-edge-mec &

# Check cache manager health
curl -s http://localhost:8081/health | jq
# Expected: {"status":"ok","service":"cache-manager"}

# Check cache inventory (empty before any prefetch)
curl -s http://localhost:8081/cache-status | jq
# Expected: empty directory listing

# Check LSTM model server health
KUBECONFIG=${MEC_01_KUBECONFIG} \
  oc port-forward svc/lstm-demand-predictor 8082:8080 -n far-edge-mec &
curl -s http://localhost:8082/v1/models/lstm-demand | jq
# Expected: {"name":"lstm-demand","ready":true,"backend":"onnx"} or "rules-based"

# Check ABR policy engine health
KUBECONFIG=${MEC_01_KUBECONFIG} \
  oc port-forward svc/abr-policy-engine 8083:8080 -n far-edge-mec &
curl -s http://localhost:8083/v1/models/abr-policy | jq
# Expected: {"name":"abr-policy","ready":true,...}
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `curl http://localhost:8081/health` | Cache manager healthy | `{"status":"ok"}` | | ⬜ |
| `curl http://localhost:8082/v1/models/lstm-demand` | LSTM server healthy | `{"ready":true}` | | ⬜ |
| `curl http://localhost:8083/v1/models/abr-policy` | ABR server healthy | `{"ready":true}` | | ⬜ |

---

## Step 6 — Test ABR Quality Decision

```bash
# Send a test subscriber request to ABR policy engine
curl -s -X POST http://localhost:8083/v1/models/abr-policy:predict \
  -H "Content-Type: application/json" \
  -d '{
    "subscriber_id": "ue-test-001",
    "subscriber_tier": "premium",
    "signal_strength_dbm": -75,
    "timestamp": "2026-04-09T10:00:00Z"
  }' | jq
# Expected: {"model_name":"abr-policy","outputs":[{"name":"quality_tier","data":["4K"]}]}

# Test with weak signal — should cap at 360p regardless of tier
curl -s -X POST http://localhost:8083/v1/models/abr-policy:predict \
  -H "Content-Type: application/json" \
  -d '{
    "subscriber_id": "ue-test-002",
    "subscriber_tier": "premium",
    "signal_strength_dbm": -105,
    "timestamp": "2026-04-09T10:00:00Z"
  }' | jq
# Expected: quality_tier = "360p" (weak signal override)
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| ABR predict — premium, strong signal | Default policy: premium gets 4K | `4K` | | ⬜ |
| ABR predict — premium, weak signal (-105dBm) | Weak signal override: 360p | `360p` | | ⬜ |

---

## Step 7 — Verify Telemetry Publishing to Kafka

```bash
# Consume from content.requests.live — should see telemetry from both SNO nodes
oc run telemetry-consumer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic content.requests.live \
  --max-messages 2 \
  --timeout-ms 60000
# Expected: 2 JSON messages from mec-stadium-01 and mec-stadium-02
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Consume `content.requests.live` | Both SNO nodes publishing telemetry | 2 JSON messages with `mec_site_id` | | ⬜ |
| Consume `ue.density.live` | UE density data flowing | Messages with `active_ues` field | | ⬜ |
| Consume `network.capacity.live` | Backhaul capacity data flowing | Messages with `backhaul_capacity_mbps` | | ⬜ |

---

## Step 8 — Verify demand.predictions Publishing

> Wait 30–60 seconds after telemetry starts for demand-predictor to
> accumulate enough samples and publish its first prediction.

```bash
oc run prediction-consumer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions \
  --max-messages 1 \
  --timeout-ms 120000
# Expected: JSON with mec_site_id, content_id, predicted_viewers, confidence
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Consume `demand.predictions` | demand-predictor publishing predictions | JSON with `confidence >= 0.75` | | ⬜ |

---

## Phase 06 Complete ✅

When all rows above are ✅, Phase 06 is done.

### Quick validation summary
```bash
# Both SNO clusters reachable
KUBECONFIG=${MEC_01_KUBECONFIG} oc get pods -n far-edge-mec
KUBECONFIG=${MEC_02_KUBECONFIG} oc get pods -n far-edge-mec

# Telemetry flowing
oc run check --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions --max-messages 1 --timeout-ms 60000
```

**Next:** Phase 07 — EdgeStream IQ Dashboard (FastAPI backend + React frontend).

### Prerequisites before Phase 07
- All 3 Kafka topics publishing: `content.requests.live`, `ue.density.live`, `demand.predictions`
- Agent (Phase 05) responding to demand events from SNO nodes
- Langfuse traces appearing for agent runs

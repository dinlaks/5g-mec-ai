# Phase 03 — AI Core — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Status: ✅ Success | ❌ Failed | ⬜ Not yet run | 🔄 In progress

> **Note:** `mec-ai-core` ArgoCD Application is MANUAL sync — model changes
> are high-impact and require deliberate promotion. Run `argocd app sync mec-ai-core`
> only after review. Secrets in this phase are applied manually via oc commands.

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `source configs/near-edge/env.sh` | Load environment | Silent | | ⬜ |
| `oc get datasciencecluster` | RHOAI DSC ready from Phase 01 | `Ready` | | ⬜ |
| `oc get pods -n redhat-ods-applications` | RHOAI pods running | All `Running` | | ⬜ |
| `oc get nodes -l nvidia.com/gpu.present=true` | GPU node available | GPU node listed | | ⬜ |
| `oc get pods -n mec-ai-data \| grep minio` | MinIO running from Phase 02 | `Running` | | ⬜ |

---

## Step 1 — Apply Data Connection Secret (MinIO → RHOAI)

> This Secret tells KServe where to pull model weights from (MinIO bucket).
> Applied manually — contains credentials from env.sh.

```bash
source configs/near-edge/env.sh

oc create secret generic aws-connection-mec-models \
  -n mec-content-ai \
  --from-literal=AWS_ACCESS_KEY_ID=$MINIO_ACCESS_KEY \
  --from-literal=AWS_SECRET_ACCESS_KEY=$MINIO_SECRET_KEY \
  --from-literal=AWS_S3_ENDPOINT=http://minio.mec-ai-data.svc.cluster.local:9000 \
  --from-literal=AWS_DEFAULT_REGION=us-east-1 \
  --from-literal=AWS_S3_BUCKET=mec-models \
  --from-literal=AWS_S3_USE_PATH_STYLE=true \
  --dry-run=client -o yaml | oc apply -f -
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc create secret generic aws-connection-mec-models ... (above)` | MinIO S3 connection for RHOAI | `secret/aws-connection-mec-models configured` | | ⬜ |
| `oc get secret aws-connection-mec-models -n mec-content-ai` | Verify secret exists | Secret listed | | ⬜ |

---

## Step 2 — Apply vLLM ServingRuntime

```bash
oc apply -f implementation/phase-03-ai-core/vllm/vllm-servingruntime.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-03-ai-core/vllm/vllm-servingruntime.yaml` | Register custom vLLM runtime | `servingruntime.serving.kserve.io/vllm-runtime-mec created` | | ⬜ |
| `oc get servingruntime vllm-runtime-mec -n mec-content-ai` | Verify runtime registered | Runtime listed | | ⬜ |

---

## Step 3 — Deploy Model via RHOAI Model Catalog (Recommended)

> RHOAI 3.3 has a built-in Model Catalog with `RedHatAI/Llama-3.1-8B-Instruct`.
> This is the recommended approach — no manual model download Job needed.
> See: `model-download/model-catalog-notes.md` for full details.

### 3a — Get RHOAI Dashboard URL
```bash
echo "RHOAI Dashboard: https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')"
```

### 3b — Create HuggingFace token secret (needed to pull model from catalog)
```bash
# Get HuggingFace token from: https://huggingface.co/settings/tokens
# Accept model license at: https://huggingface.co/RedHatAI/Llama-3.1-8B-Instruct
oc create secret generic hf-token-secret \
  -n mec-content-ai \
  --from-literal=token=hf_<your-hf-token> \
  --dry-run=client -o yaml | oc apply -f -
```

### 3c — Deploy via Dashboard OR apply InferenceService directly

**Option A — Dashboard (recommended):**
1. Open RHOAI Dashboard URL (from 3a)
2. Models → Model Catalog → search "Llama 3.1 8B"
3. Select `Llama-3.1-8B-Instruct` (RedHatAI)
4. Click Deploy → select runtime `vllm-runtime-mec` → data connection `aws-connection-mec-models`
5. Set GPU: 1 × NVIDIA GPU → Deploy

**Option B — Direct InferenceService (GitOps):**
```bash
oc apply -f implementation/phase-03-ai-core/vllm/vllm-inferenceservice.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| HuggingFace token secret created | Pull model from catalog | `secret configured` | | ⬜ |
| Model deployed (dashboard or YAML) | InferenceService created | `inferenceservice.serving.kserve.io/llama-3-1-8b-instruct` | | ⬜ |
| `oc get inferenceservice -n mec-content-ai -w` | Watch until Ready | `READY: True` | | ⬜ |

> ⏱️ **Allow 10–20 minutes** for the model to be pulled and loaded on the GPU node.

### 3d — Get vLLM URL (needed for LlamaStack config)
```bash
export VLLM_URL=$(oc get inferenceservice llama-3-1-8b-instruct \
  -n mec-content-ai \
  -o jsonpath='{.status.url}')
echo "vLLM URL: $VLLM_URL"
# Save this URL to configs/near-edge/env.sh as VLLM_URL
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get inferenceservice llama-3-1-8b-instruct -n mec-content-ai -o jsonpath='{.status.url}'` | Get vLLM URL for LlamaStack | `https://llama-3-1-8b-instruct-predictor-...` | | ⬜ |
| `curl -s $VLLM_URL/health` | vLLM health check | `{"status":"ok"}` or HTTP 200 | | ⬜ |
| Quick inference test (below) | Verify model responds | JSON response with content | | ⬜ |

```bash
# Quick inference test
curl -s -X POST $VLLM_URL/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3-1-8b-instruct",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 50
  }' | jq '.choices[0].message.content'
```

---

## Step 4 — Update LlamaStack Config with vLLM URL

> Before deploying LlamaStack, update the vLLM URL and Langfuse URL
> in the LlamaStackDistribution YAML.

```bash
# Get your cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# Update llamastack-distribution.yaml — replace placeholder URLs
# Edit: implementation/phase-03-ai-core/llamastack/llamastack-distribution.yaml
# Set: VLLM_URL → $VLLM_URL from Step 3d
# Set: OTEL_EXPORTER_OTLP_ENDPOINT → Langfuse OTLP URL from env.sh
echo "Cluster domain: $CLUSTER_DOMAIN"
echo "vLLM URL: $VLLM_URL"
echo "Langfuse host: $LANGFUSE_HOST"
```

| Action | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Update `VLLM_URL` in `llamastack-distribution.yaml` | LlamaStack needs to know vLLM endpoint | URL updated in file | | ⬜ |
| Update `OTEL_EXPORTER_OTLP_ENDPOINT` in `llamastack-distribution.yaml` | LlamaStack sends traces to Langfuse | OTLP URL updated | | ⬜ |

---

## Step 5 — Deploy LlamaStack (LlamaStackDistribution CRD)

> RHOAI 3.3 ships with the `llama-stack-k8s-operator` — no separate install needed.
> The `LlamaStackDistribution` CRD is managed by the RHOAI operator.

```bash
oc apply -f implementation/phase-03-ai-core/llamastack/llamastack-distribution.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-03-ai-core/llamastack/llamastack-distribution.yaml` | Create LlamaStack via CRD | `llamastackdistribution.llamastack.io/mec-llamastack created` | | ⬜ |
| `oc get llamastackdistribution -n mec-content-ai` | LlamaStack distribution exists | `mec-llamastack` listed | | ⬜ |
| `oc get pods -n mec-content-ai \| grep llamastack` | LlamaStack pod running | Pod `Running` | | ⬜ |
| `oc wait llamastackdistribution/mec-llamastack --for=condition=Ready --timeout=120s -n mec-content-ai` | Wait for Ready | Condition met | | ⬜ |

---

## Step 6 — Verify LlamaStack

```bash
# Get LlamaStack service URL
LLAMASTACK_URL="http://$(oc get svc -n mec-content-ai | grep llamastack | awk '{print $3}'):8321"

# Check registered models
curl -s $LLAMASTACK_URL/v1/models | jq '.data[].model_id'
# Expected: "llama-3-1-8b-instruct"

# Test tool calling (simple)
curl -s -X POST $LLAMASTACK_URL/v1/inference/chat_completion \
  -H "Content-Type: application/json" \
  -d '{
    "model_id": "llama-3-1-8b-instruct",
    "messages": [{"role": "user", "content": "What is 2+2?"}]
  }' | jq '.completion_message.content'

# Check Langfuse — traces should appear within 30s
echo "Check Langfuse traces: $LANGFUSE_HOST"
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `curl $LLAMASTACK_URL/v1/models` | Model registered in LlamaStack | `llama-3-1-8b-instruct` | | ⬜ |
| LlamaStack inference test | End-to-end LLM response | Valid text response | | ⬜ |
| Langfuse trace appears | LlamaStack → Langfuse OTLP working | Trace visible in Langfuse UI | | ⬜ |

---

## Phase 03 Complete ✅

When all rows above are ✅, Phase 03 is done.
Save `VLLM_URL` and `LLAMASTACK_URL` to `configs/near-edge/env.sh` before proceeding.

**Next:** Phase 04 — Automation (AAP + EDA + ACM policies).

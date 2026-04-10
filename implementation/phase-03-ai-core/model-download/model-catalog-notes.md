# Model Deployment — RHOAI 3.3 Model Catalog

## Overview

RHOAI 3.3 has a built-in **Model Catalog** that includes Red Hat validated models.
Llama 3.1 8B Instruct is available as `RedHatAI/Llama-3.1-8B-Instruct` — Red Hat's
own optimized version on HuggingFace.

**No manual Kubernetes Job needed.** The RHOAI dashboard guides you through the
model deployment workflow including pulling weights to MinIO/S3 storage.

---

## Workflow via RHOAI Dashboard

### Step 1 — Access Model Catalog
1. Open RHOAI Dashboard: `https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')`
2. Navigate to **Models** → **Model Catalog**
3. Browse available models — filter by provider: **Red Hat** or **Meta**

### Step 2 — Select Llama 3.1 8B Instruct
1. Find **Llama-3.1-8B-Instruct** (from RedHatAI)
2. Click **Deploy** — the dashboard guides you through:
   - Selecting a ServingRuntime (choose `vllm-runtime-mec`)
   - Selecting the Data Connection (choose `aws-connection-mec-models` — MinIO)
   - Setting GPU resource limits
3. The dashboard pulls the model to MinIO and creates the InferenceService automatically

### Step 3 — Alternative: Manual InferenceService (if not using dashboard)
If you prefer GitOps-driven deployment or the dashboard flow doesn't fit:

```bash
# 1. Create HuggingFace token secret (needed to pull model)
oc create secret generic hf-token-secret \
  -n redhat-ods-applications \
  --from-literal=token=hf_<your-huggingface-token>

# 2. Apply the InferenceService (RHOAI will pull model from HF via token)
oc apply -f implementation/phase-03-ai-core/vllm/vllm-inferenceservice.yaml

# 3. Watch InferenceService status
oc get inferenceservice llama-3-1-8b-instruct -n redhat-ods-applications -w
```

---

## HuggingFace Access Requirements

To use `RedHatAI/Llama-3.1-8B-Instruct`:
1. Go to https://huggingface.co/RedHatAI/Llama-3.1-8B-Instruct
2. Accept the model license agreement
3. Generate an access token: HuggingFace → Settings → Access Tokens

---

## Notes

- Model size: ~16 GB (BF16) or ~8 GB (AWQ quantized)
- Recommended GPU: NVIDIA A10G (24GB VRAM) with AWQ, or L40S (48GB VRAM) with BF16
- The `vllm-servingruntime.yaml` in this phase is applied regardless of whether
  you use the dashboard or manual InferenceService approach
- After model is serving, get the URL for LlamaStack config:
  ```bash
  oc get inferenceservice llama-3-1-8b-instruct \
    -n redhat-ods-applications \
    -o jsonpath='{.status.url}'
  ```

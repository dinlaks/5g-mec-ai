# Phase 03 — AI Core

## Goal
Deploy the full LLM serving stack: RHOAI vLLM + LlamaStack.
This is the reasoning engine the LangGraph agent (Phase 05) calls through LlamaStack.

## What Gets Deployed

### vLLM (via RHOAI 3.3 KServe)
- Model: **Llama 3.1 8B Instruct** (quantized — fits A10G / L40S GPU)
- Served as a KServe InferenceService in `mec-content-ai`
- Exposes OpenAI-compatible `/v1/chat/completions` API
- GPU node required (labelled by NFD + GPU Operator from Phase 01)

### LlamaStack 0.3.5
> **LlamaStack lives here** — it is the unified LLM API layer on top of vLLM.
> It provides: tool calling, agent memory, structured output, provider abstraction.
> The LangGraph agent (Phase 05) calls LlamaStack, NOT vLLM directly.

```
LangGraph Agent (Phase 05)
        │
        ▼
  LlamaStack 0.3.5          ← tool calling, memory, provider abstraction
        │
        ▼
  vLLM (RHOAI KServe)       ← GPU inference
        │
        ▼
  Llama 3.1 8B Instruct     ← model weights (in MinIO from Phase 02)
```

### Why LlamaStack Between LangGraph and vLLM?
- Handles **MCP tool calling protocol** — the 7 MCP servers register their tools here
- **Provider abstraction** — swap vLLM for another backend without changing agent code
- **Agent memory** — conversation history across LangGraph node invocations
- **Langfuse middleware** — auto-instruments every LLM call with traces and spans

## Folder Structure

```
phase-03-ai-core/
├── README.md
├── COMMANDS.md
├── vllm/
│   ├── vllm-inferenceservice.tmpl.yaml   ← template (${VLLM_MODEL}, ${GPU_NODE_LABEL})
│   ├── vllm-inferenceservice.yaml        ← rendered actual
│   └── vllm-servingruntime.yaml          ← vLLM ServingRuntime for RHOAI
└── llamastack/
    ├── llamastack-distribution.tmpl.yaml ← template
    ├── llamastack-distribution.yaml      ← rendered actual
    └── llamastack-distribution.yaml      ← LlamaStackDistribution CRD (port 8321, rh-dev)
```

## Dependencies
- Phase 01 complete — RHOAI operator + GPU node running
- Phase 02 complete — MinIO running with model weights in `mec-models` bucket
- Langfuse running (Phase 02) — LlamaStack sends traces on startup

## GitOps Sync Policy
> **`mec-ai-core` ArgoCD Application is MANUAL sync.**
> Model changes are high-impact — require deliberate promotion.
> `argocd app sync mec-ai-core` after review.

## Validation
```bash
oc get inferenceservice -n mec-content-ai
curl https://$VLLM_URL/health
curl -s $LLAMASTACK_URL/v1/models | jq '.data[].id'
```

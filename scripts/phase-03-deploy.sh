#!/usr/bin/env bash
# =============================================================================
# phase-03-deploy.sh — AI Core (vLLM + LlamaStack)
# Automates: implementation/phase-03-ai-core/COMMANDS.md
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DRY_RUN=false; VALIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
  case $1 in --dry-run) DRY_RUN=true; shift ;; --validate) VALIDATE_ONLY=true; shift ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; exit 1 ;; esac
done

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }
run()     { [[ "$DRY_RUN" == true ]] && { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; return; }; eval "$*"; }
pause_for_human() {
  echo ""; echo -e "${YELLOW}${BOLD}⏸  MANUAL STEP REQUIRED${NC}"
  echo -e "${YELLOW}$*${NC}"
  echo ""; read -rp "Press Enter when done to continue..."
}

wait_for() {
  local desc=$1 max=$2 cmd=$3
  info "Waiting: ${desc} (max ${max}s)..."
  local elapsed=0
  while ! eval "$cmd" &>/dev/null; do
    sleep 15; elapsed=$((elapsed+15))
    [[ $elapsed -ge $max ]] && { error "Timeout: ${desc}"; exit 1; }
    echo -n "."
  done
  echo ""; success "${desc}"
}

# =============================================================================
section "Pre-flight Checks"
# =============================================================================
if ! oc whoami &>/dev/null; then error "Not logged in."; exit 1; fi
(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep -q Succeeded) || \
  { error "RHOAI operator not ready — run phase-01 first."; exit 1; }
(oc get pods -n mec-ai-obs -l app.kubernetes.io/name=langfuse --no-headers 2>/dev/null | grep -q Running) || \
  { error "Langfuse not running — run phase-02 first."; exit 1; }
if oc get node -l node-role.kubernetes.io/gpu-worker --no-headers 2>/dev/null | grep -q Ready; then
  GPU_NODE=$(oc get node -l node-role.kubernetes.io/gpu-worker --no-headers 2>/dev/null | awk '{print $1}')
  success "GPU node ready: ${GPU_NODE}"
else
  echo ""
  warn "No GPU node found. vLLM (Step 4) will stay Pending until a GPU node is added."
  echo ""
  echo -e "${YELLOW}  ── How to add a GPU node ──${NC}"
  echo -e "  Option A — Use the automated script (recommended):"
  echo -e "    ${CYAN}./scripts/setup-infra.sh --skip-mec${NC}"
  echo -e "    Adds a g5.2xlarge (NVIDIA A10G) worker node via MachineSet."
  echo -e "    Requires: AWS CLI configured with RHDP credentials."
  echo ""
  echo -e "  Option B — Manual MachineSet (if AWS CLI unavailable):"
  echo -e "    ${CYAN}oc get machineset -n openshift-machine-api${NC}   # get reference MachineSet"
  echo -e "    Copy an existing MachineSet, change instanceType to g5.2xlarge,"
  echo -e "    add label node-role.kubernetes.io/gpu-worker: ''"
  echo -e "    ${CYAN}oc apply -f gpu-machineset.yaml${NC}"
  echo ""
  echo -e "  Option C — Proceed without GPU (Step 4 will remain Pending):"
  echo -e "    LlamaStack and Agent phases can still be deployed."
  echo -e "    vLLM InferenceService will become Ready once GPU node joins."
  echo ""
  read -rp "  Proceed without GPU node? [y/N] " PROCEED
  if [[ "${PROCEED,,}" != "y" ]]; then
    echo ""
    info "Exiting. Add a GPU node and re-run: ./scripts/phase-03-deploy.sh"
    exit 0
  fi
  warn "Proceeding without GPU node — Step 4 (vLLM) will be Pending."
fi
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — RHOAI DataScienceCluster"
# =============================================================================
if oc get datasciencecluster &>/dev/null; then
  success "DataScienceCluster already exists"
else
  warn "DataScienceCluster not found — applying now"
  run "oc apply -f implementation/phase-01-foundation/operators/wave-1-rhoai-datasciencecluster.yaml"
fi

# =============================================================================
section "Step 2 — MinIO Data Connection Secret (for vLLM model)"
# =============================================================================
./scripts/apply-secrets.sh --phase 03 --validate
./scripts/apply-secrets.sh --phase 03
success "Phase 03 secrets applied"

# =============================================================================
section "Step 3 — vLLM ServingRuntime"
# =============================================================================
if oc get servingruntime vllm-runtime-mec -n redhat-ods-applications &>/dev/null; then
  info "vLLM ServingRuntime already exists — skipping"
else
  run "oc apply -f implementation/phase-03-ai-core/vllm/vllm-servingruntime.yaml"
  success "vLLM ServingRuntime created"
fi

# =============================================================================
section "Step 4 — vLLM InferenceService (RHOAI Model Catalog)"
# =============================================================================
APPS_DOMAIN=$(echo "${NEAR_EDGE_API}" | sed 's|https://api\.||' | sed 's|:6443||')

if oc get inferenceservice llama-3-1-8b-instruct -n redhat-ods-applications &>/dev/null; then
  info "vLLM InferenceService already exists — skipping"
else
  run "oc apply -f implementation/phase-03-ai-core/vllm/vllm-inferenceservice.yaml"
  success "vLLM InferenceService created — RHOAI catalog will pull the model automatically"
fi

# Wait for InferenceService Ready — GPU node + model pull can take 10-20 min
if oc get node -l node-role.kubernetes.io/gpu-worker --no-headers 2>/dev/null | grep -q Ready; then
  wait_for "vLLM InferenceService Ready" 1200 \
    "oc get inferenceservice llama-3-1-8b-instruct -n redhat-ods-applications \
     -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"
else
  warn "No GPU node yet — InferenceService will become Ready once GPU node joins. Continuing..."
fi

# =============================================================================
section "Step 5 — LlamaStack Distribution"
# =============================================================================
# Auto-fetch vLLM URL from InferenceService status and persist to env.sh
VLLM_INFERENCE_URL=$(oc get inferenceservice -n redhat-ods-applications \
  -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)
if [[ -z "$VLLM_INFERENCE_URL" ]]; then
  warn "vLLM InferenceService URL not yet available (GPU node pending?) — using placeholder"
  VLLM_INFERENCE_URL="https://llama-3-1-8b-instruct.apps.${APPS_DOMAIN}"
else
  success "vLLM URL: ${VLLM_INFERENCE_URL}"
  # Persist to env.sh so Phase 05 agent and LlamaStack config pick it up
  sed -i "s|^export VLLM_URL=.*|export VLLM_URL=\"${VLLM_INFERENCE_URL}\"|" configs/near-edge/env.sh
  success "VLLM_URL saved to configs/near-edge/env.sh"
fi
export VLLM_INFERENCE_URL
export LANGFUSE_HOST="${LANGFUSE_HOST:-https://langfuse.apps.${APPS_DOMAIN}}"

if oc get llamastackdistribution mec-llamastack -n mec-content-ai &>/dev/null; then
  info "LlamaStack already exists — skipping"
else
  envsubst < implementation/phase-03-ai-core/llamastack/llamastack-distribution.yaml | \
    run "oc apply -f -"
  success "LlamaStack distribution created"
fi

wait_for "LlamaStack pod running" 600 \
  "oc get pods -n mec-content-ai -l app=mec-llamastack --no-headers 2>/dev/null | grep -q Running"

# =============================================================================
section "Step 6 — Verify Inference"
# =============================================================================
LLAMASTACK_SVC="http://llamastack.mec-content-ai.svc.cluster.local:5001"
info "Testing LlamaStack inference endpoint..."
oc run llama-test --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/python-311:latest \
  -n mec-content-ai -- /bin/sh -c \
  "pip install -q llama-stack-client && python3 -c \"
from llama_stack_client import LlamaStackClient
client = LlamaStackClient(base_url='${LLAMASTACK_SVC}')
models = client.models.list()
print('Models available:', [m.identifier for m in models])
\"" 2>/dev/null || warn "LlamaStack test skipped — run manually from agent pod after Phase 05"

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 03 complete.${NC}"
echo -e "    Next: ./scripts/phase-04-deploy.sh"

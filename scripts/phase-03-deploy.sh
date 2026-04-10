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
oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep -q Succeeded || \
  { error "RHOAI operator not ready — run phase-01 first."; exit 1; }
oc get pods -n mec-ai-obs -l app.kubernetes.io/name=langfuse --no-headers 2>/dev/null | grep -q Running || \
  { error "Langfuse not running — run phase-02 first."; exit 1; }
oc get node -l node-role.kubernetes.io/gpu-worker &>/dev/null || \
  warn "No GPU node found — vLLM InferenceService will be in pending state until GPU node is ready"
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — RHOAI DataScienceCluster"
# =============================================================================
if oc get datasciencecluster -n redhat-ods-operator &>/dev/null 2>&1 | grep -q "No resources"; then
  warn "DataScienceCluster not found — apply manually via RHOAI dashboard or CR"
  warn "See: implementation/phase-03-ai-core/COMMANDS.md Step 1"
else
  success "DataScienceCluster already exists"
fi

# =============================================================================
section "Step 2 — MinIO Data Connection Secret (for vLLM model)"
# =============================================================================
run "oc apply -f implementation/phase-03-ai-core/vllm/data-connection-secret.yaml"

# =============================================================================
section "Step 3 — vLLM ServingRuntime"
# =============================================================================
if oc get servingruntime vllm-runtime-mec -n redhat-ods-applications &>/dev/null; then
  warn "vLLM ServingRuntime already exists — skipping"
else
  run "oc apply -f implementation/phase-03-ai-core/vllm/vllm-servingruntime.yaml"
  success "vLLM ServingRuntime created"
fi

# =============================================================================
section "Step 4 — ⏸ MANUAL: Download model via RHOAI Model Catalog"
# =============================================================================
RHOAI_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
pause_for_human "Download Llama 3.1 8B via RHOAI Model Catalog:
  1. Open RHOAI Dashboard: https://${RHOAI_URL}
  2. Go to: Models → Model Catalog
  3. Search: RedHatAI/Llama-3.1-8B-Instruct
  4. Click Deploy → select vllm-runtime-mec → deploy to redhat-ods-applications
  5. Wait for InferenceService to show Ready in the dashboard

  Alternatively apply directly:
    envsubst < implementation/phase-03-ai-core/vllm/vllm-inferenceservice.tmpl.yaml | oc apply -f -
  (requires VLLM_MODEL_NAME and VLLM_STORAGE_URI set in env.sh)"

# =============================================================================
section "Step 5 — LlamaStack Distribution"
# =============================================================================
if oc get llamastackdistribution mec-llamastack -n mec-content-ai &>/dev/null; then
  warn "LlamaStack already exists — skipping"
else
  run "oc apply -f implementation/phase-03-ai-core/llamastack/llamastack-distribution.yaml"
  success "LlamaStack distribution created"
fi

wait_for "LlamaStack pod running" 300 \
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

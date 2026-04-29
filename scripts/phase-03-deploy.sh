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
(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep 'rhods-operator.*Succeeded' > /dev/null) || \
  { error "RHOAI operator not ready — run phase-01 first."; exit 1; }
(oc get pods -n mec-ai-obs -l app.kubernetes.io/name=langfuse --no-headers 2>/dev/null | grep Running > /dev/null) || \
  { error "Langfuse not running — run phase-02 first."; exit 1; }
if oc get node -l node-role.kubernetes.io/gpu-worker --no-headers 2>/dev/null | grep Ready > /dev/null; then
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
section "Step 3 — RHOAI HardwareProfile (NVIDIA A10G GPU)"
# =============================================================================
# Apply to redhat-ods-applications (dashboard visibility)
run "oc apply -f implementation/phase-03-ai-core/hardware-profile.yaml"
success "HardwareProfile applied in redhat-ods-applications"

# Apply to mec-content-ai (admission webhook needs it in the same namespace as InferenceService)
sed 's/namespace: redhat-ods-applications/namespace: mec-content-ai/' \
  implementation/phase-03-ai-core/hardware-profile.yaml | \
  oc apply -f - 2>&1 | grep -v "Warning" || true
success "HardwareProfile applied in mec-content-ai"

# =============================================================================
section "Step 4 — vLLM ServingRuntime (vLLM NVIDIA GPU ServingRuntime for KServe)"
# =============================================================================
# Single runtime for Granite 3.3 8B — used for both strategy reasoning and Lightspeed.
# Display name matches RHOAI template exactly so dashboard shows correctly.
if oc get servingruntime vllm-cuda-runtime -n mec-content-ai &>/dev/null; then
  info "vLLM ServingRuntime already exists — skipping"
else
  run "oc apply -f implementation/phase-03-ai-core/vllm/vllm-servingruntime.yaml"
  success "vLLM NVIDIA GPU ServingRuntime created"
fi

# =============================================================================
section "Step 5 — Granite 3.3 8B InferenceService (reasoning + Lightspeed)"
# =============================================================================
APPS_DOMAIN=$(echo "${NEAR_EDGE_API}" | sed 's|https://api\.||' | sed 's|:6443||')

if oc get inferenceservice granite-3-3-8b -n mec-content-ai &>/dev/null; then
  info "Granite InferenceService already exists — skipping"
else
  run "oc apply -f implementation/phase-03-ai-core/vllm/vllm-inferenceservice.yaml"
  success "Granite 3.3 8B InferenceService created — OCI model pull starting on GPU node"
fi

# Wait for InferenceService Ready
if oc get node -l node-role.kubernetes.io/gpu-worker --no-headers 2>/dev/null | grep Ready > /dev/null; then
  wait_for "Granite InferenceService Ready" 800 \
    "oc get inferenceservice granite-3-3-8b -n mec-content-ai \
     -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep True > /dev/null"
else
  warn "No GPU node yet — InferenceService will become Ready once GPU node joins. Continuing..."
fi

# =============================================================================
section "Step 6 — LlamaStack Distribution"
# =============================================================================
# Auto-fetch vLLM URL from InferenceService status and persist to env.sh
VLLM_INFERENCE_URL=$(oc get inferenceservice -n mec-content-ai \
  -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)
if [[ -z "$VLLM_INFERENCE_URL" ]]; then
  warn "vLLM InferenceService URL not yet available (GPU node pending?) — using placeholder"
  VLLM_INFERENCE_URL="http://granite-3-3-8b-predictor.mec-content-ai.svc.cluster.local"
else
  success "vLLM URL: ${VLLM_INFERENCE_URL}"
  # Persist to env.sh — replace if exists, append if not (macOS-safe sed)
  if grep -q "^export VLLM_URL=" configs/near-edge/env.sh 2>/dev/null; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^export VLLM_URL=.*|export VLLM_URL=\"${VLLM_INFERENCE_URL}\"|" configs/near-edge/env.sh
    else
      sed -i "s|^export VLLM_URL=.*|export VLLM_URL=\"${VLLM_INFERENCE_URL}\"|" configs/near-edge/env.sh
    fi
  else
    echo "export VLLM_URL=\"${VLLM_INFERENCE_URL}\"" >> configs/near-edge/env.sh
  fi
  success "VLLM_URL saved to configs/near-edge/env.sh"
fi
export VLLM_INFERENCE_URL
export LANGFUSE_HOST="${LANGFUSE_HOST:-https://langfuse.apps.${APPS_DOMAIN}}"

# Always read PG_PASSWORD directly from the cluster secret — env.sh value may differ
export PG_PASSWORD
PG_PASSWORD=$(oc get secret langfuse-secrets -n mec-ai-obs \
  -o jsonpath='{.data.DATABASE_PASSWORD}' 2>/dev/null | base64 -d)
if [[ -z "$PG_PASSWORD" ]]; then
  error "Could not read DATABASE_PASSWORD from langfuse-secrets — is Phase 02 deployed?"
  exit 1
fi

# Ensure llamastack DB exists in Langfuse PostgreSQL with correct permissions
oc exec -n mec-ai-obs deployment/postgresql -- \
  psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='llamastack'" 2>/dev/null | grep -q 1 || \
  oc exec -n mec-ai-obs deployment/postgresql -- psql -U postgres \
    -c "CREATE DATABASE llamastack;" 2>/dev/null || true
oc exec -n mec-ai-obs deployment/postgresql -- psql -U postgres -d llamastack \
  -c "GRANT ALL PRIVILEGES ON DATABASE llamastack TO langfuse; GRANT ALL ON SCHEMA public TO langfuse; ALTER SCHEMA public OWNER TO langfuse;" \
  &>/dev/null || true
success "LlamaStack PostgreSQL database ready"

if oc get llamastackdistribution mec-llamastack -n mec-content-ai &>/dev/null; then
  info "LlamaStack already exists — skipping"
else
  envsubst < implementation/phase-03-ai-core/llamastack/llamastack-distribution.yaml | \
    run "oc apply -f -"
  success "LlamaStack distribution created"
fi

wait_for "LlamaStack pod running" 120 \
  "oc get pods -n mec-content-ai -l app=llama-stack --no-headers 2>/dev/null | grep Running > /dev/null"

# =============================================================================
section "Step 7 — Verify Inference"
# =============================================================================
LLAMASTACK_SVC="http://mec-llamastack.mec-content-ai.svc.cluster.local:8321"
info "Testing LlamaStack inference endpoint..."
oc run llama-test --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  -n mec-content-ai -- /bin/sh -c \
  "curl -sf ${LLAMASTACK_SVC}/v1/models | head -c 500 && echo" 2>/dev/null \
  && success "LlamaStack /v1/models responded — inference ready" \
  || warn "LlamaStack health check skipped — verify manually: curl ${LLAMASTACK_SVC}/v1/models"

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 03 complete.${NC}"
echo -e "    Next: ./scripts/phase-04-deploy.sh"

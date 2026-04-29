#!/usr/bin/env bash
# =============================================================================
# phase-04-deploy.sh — Automation (AAP + EDA + Playbooks)
# Automates: implementation/phase-04-automation/COMMANDS.md
# =============================================================================
set -euo pipefail

# Source env.sh for credentials/vars.
# Keep env.sh KUBECONFIG if it works (user ran oc login with it);
# restore original only if env.sh KUBECONFIG fails authentication.
_KUBE_BEFORE="${KUBECONFIG:-}"
[[ -f "configs/near-edge/env.sh" ]] && source "configs/near-edge/env.sh"
if ! oc whoami --request-timeout=5s &>/dev/null 2>&1; then
  # env.sh KUBECONFIG is stale — restore original
  if [[ -n "${_KUBE_BEFORE}" ]]; then
    export KUBECONFIG="${_KUBE_BEFORE}"
  else
    unset KUBECONFIG
  fi
fi

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

aap_api() {
  # Helper: call AAP REST API
  local method=$1 path=$2 data=${3:-}
  local url="${AAP_HOST}/api/v2${path}"
  if [[ -n "$data" ]]; then
    curl -s -X "${method}" "${url}" \
      -H "Authorization: Bearer ${AAP_TOKEN}" \
      -H "Content-Type: application/json" \
      --insecure -d "${data}"
  else
    curl -s -X "${method}" "${url}" \
      -H "Authorization: Bearer ${AAP_TOKEN}" \
      --insecure
  fi
}

# =============================================================================
section "Pre-flight Checks"
# =============================================================================
if ! oc whoami --request-timeout=10s &>/dev/null; then error "Not logged in."; exit 1; fi
success "Logged in as: $(oc whoami --request-timeout=10s 2>/dev/null)"
# Verify AAP was installed by phase-01 (namespace is the simplest reliable check)
oc get namespace aap --request-timeout=15s &>/dev/null || \
  { error "AAP namespace not found — run phase-01 first."; exit 1; }
success "AAP namespace exists"
[[ -z "${AAP_ADMIN_PASSWORD:-}" ]] && \
  { error "AAP_ADMIN_PASSWORD not set in env.sh"; exit 1; }
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Apply Phase 04 Secrets"
# =============================================================================
./scripts/apply-secrets.sh --phase 04
success "aap-admin-secret created"

# =============================================================================
section "Step 2 — Deploy AAP Platform + Controllers"
# =============================================================================
run "oc apply -f implementation/phase-04-automation/aap/aap-platform.yaml"

wait_for "AutomationController CRD registered" 300 \
  "oc get crd automationcontrollers.automationcontroller.ansible.com &>/dev/null"
run "oc apply -f implementation/phase-04-automation/aap/automation-controller.yaml"

wait_for "EDA CRD registered" 300 \
  "oc get crd edas.eda.ansible.com &>/dev/null"
run "oc apply -f implementation/phase-04-automation/aap/eda-controller.yaml"

info "Waiting for AAP components (5–10 minutes)..."
wait_for "AutomationController web pod running" 600 \
  "oc get pods -n aap --no-headers 2>/dev/null | awk '{print \$1,\$3}' | grep '^controller-web' | grep -q Running"
wait_for "EDA API pod running" 600 \
  "oc get pods -n aap --no-headers 2>/dev/null | awk '{print \$1,\$3}' | grep '^eda-api\|^eda-controller-api' | grep -q Running"

AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null)
EDA_URL=$(oc get route eda -n aap -o jsonpath='{.spec.host}' 2>/dev/null || \
          oc get route eda-controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null)
success "AAP Controller: https://${AAP_URL}"
success "EDA Controller: https://${EDA_URL}"

# =============================================================================
section "Step 3 — ⏸ MANUAL: Get AAP API Token"
# =============================================================================
pause_for_human "Complete these steps before continuing:

  ── 1. Activate AAP Subscription ──────────────────────────────────────
  If not already activated (you will see the subscription screen on first login):

  a) Get your subscription manifest:
     → Go to: https://access.redhat.com/management/subscription_allocations
     → Create or select an allocation that includes Ansible Automation Platform
     → Click 'Export Manifest' → download the .zip file

  b) Activate in AAP UI: https://${AAP_URL}
     → On the subscription screen, select 'Subscription manifest'
     → Upload the downloaded .zip file → Next → Submit

  ── 2. Get AAP API Token ───────────────────────────────────────────────
  Option A (UI): https://${AAP_URL}
    → User icon (top right) → My Profile → Tokens → Add
    → Description: mcp-aap | Scope: Write → Save → Copy token

  Option B (API — run in your terminal):
    curl -s -X POST 'https://${AAP_URL}/api/v2/tokens/' \\
      -H 'Content-Type: application/json' \\
      -u 'admin:\${AAP_ADMIN_PASSWORD}' \\
      -d '{\"description\":\"mcp-aap token\",\"scope\":\"write\"}' \\
      --insecure | jq '.token'

  ── 3. Save to env.sh ─────────────────────────────────────────────────
  Add to configs/near-edge/env.sh:
    export AAP_TOKEN='<paste-token>'
    export AAP_HOST='https://${AAP_URL}'
  Then run:
    source configs/near-edge/env.sh
    ./scripts/apply-secrets.sh --phase 05"

[[ -z "${AAP_TOKEN:-}" ]] && { error "AAP_TOKEN not set. Set it in env.sh and re-source."; exit 1; }

# =============================================================================
section "Step 4 — Create Lightspeed Job Template in AAP"
# =============================================================================
# All-Lightspeed architecture: Granite 3.3 8B generates every playbook dynamically.
# Predefined playbooks in playbooks/examples/ are used as few-shot prompts for Granite.
# Only one AAP job template is needed: lightspeed-generate-and-run.
[[ -z "${GIT_REPO_URL:-}" ]] && { error "GIT_REPO_URL not set in env.sh"; exit 1; }

info "Getting AAP organization..."
# AAP 2.5: orgs cannot be created via controller API — must use platform gateway.
# Use 'MEC Content Intelligence' if it exists, otherwise fall back to 'Default'.
ORG_ID=$(aap_api GET "/organizations/?name=MEC+Content+Intelligence" | jq -r '.results[0].id // empty')
[[ -z "$ORG_ID" ]] && \
  ORG_ID=$(aap_api GET "/organizations/?name=Default" | jq -r '.results[0].id // empty')
[[ -z "$ORG_ID" ]] && \
  ORG_ID=$(aap_api GET "/organizations/" | jq -r '.results[0].id // empty')
[[ -z "$ORG_ID" ]] && { error "No AAP organization found — check AAP_TOKEN and AAP_HOST"; exit 1; }
success "Organization ID: ${ORG_ID}"

info "Creating AAP project (pointing to Git repo)..."
PROJ_ID=$(aap_api POST "/projects/" \
  "{\"name\":\"mec-content-playbooks\",\"organization\":${ORG_ID},\"scm_type\":\"git\",\"scm_url\":\"${GIT_REPO_URL}\",\"scm_branch\":\"main\",\"scm_update_on_launch\":true}" \
  | jq -r '.id // empty')
[[ -z "$PROJ_ID" ]] && \
  PROJ_ID=$(aap_api GET "/projects/?name=mec-content-playbooks" | jq -r '.results[0].id')
success "Project ID: ${PROJ_ID}"

wait_for "AAP project sync complete" 120 \
  "aap_api GET '/projects/${PROJ_ID}/' | jq -r '.status' | grep -q successful"

info "Creating inventory..."
INV_ID=$(aap_api POST "/inventories/" \
  "{\"name\":\"mec-sites\",\"organization\":${ORG_ID}}" | jq -r '.id // empty')
[[ -z "$INV_ID" ]] && \
  INV_ID=$(aap_api GET "/inventories/?name=mec-sites" | jq -r '.results[0].id')
success "Inventory ID: ${INV_ID}"

# Create the single Lightspeed job template (receives Granite-generated YAML)
EXISTING=$(aap_api GET "/job_templates/?name=lightspeed-generate-and-run" | jq -r '.count')
if [[ "$EXISTING" == "0" ]]; then
  aap_api POST "/job_templates/" \
    "{\"name\":\"lightspeed-generate-and-run\",\"description\":\"Executes Granite-generated Ansible playbooks from the LangGraph agent\",\"organization\":${ORG_ID},\"project\":${PROJ_ID},\"playbook\":\"implementation/phase-04-automation/playbooks/lightspeed-runner.yml\",\"inventory\":${INV_ID},\"ask_variables_on_launch\":true}" \
    > /dev/null
  success "Job template created: lightspeed-generate-and-run"
else
  warn "Job template lightspeed-generate-and-run already exists — skipping"
fi

# =============================================================================
section "Step 5 — Import EDA Rulebook"
# =============================================================================
# EDA uses its own admin password (separate from AAP controller).
# Fetch it from the cluster secret, use basic auth for all EDA API calls.
EDA_HOST="https://eda-controller-aap.apps.cluster-ld5ww.ld5ww.sandbox123.opentlc.com"
EDA_PASS=$(oc get secret eda-controller-admin-password -n aap \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [[ -z "$EDA_PASS" ]]; then
  warn "Could not read EDA admin password — skipping EDA setup"
else
  eda_api() {
    local method=$1 path=$2 data=${3:-}
    if [[ -n "$data" ]]; then
      curl -s -X "${method}" "${EDA_HOST}/api/eda/v1${path}" \
        -u "admin:${EDA_PASS}" -H "Content-Type: application/json" \
        -d "${data}" --insecure
    else
      curl -s -X "${method}" "${EDA_HOST}/api/eda/v1${path}" \
        -u "admin:${EDA_PASS}" --insecure
    fi
  }

  EDA_ORG_ID=$(eda_api GET "/organizations/" | jq -r '.results[0].id // 1')

  info "Creating EDA project..."
  EDA_PROJ_ID=$(eda_api POST "/projects/" \
    "{\"name\":\"mec-content-rulebooks\",\"url\":\"${GIT_REPO_URL}\",\"organization_id\":${EDA_ORG_ID}}" | \
    jq -r '.id // empty')
  [[ -z "$EDA_PROJ_ID" ]] && \
    EDA_PROJ_ID=$(eda_api GET "/projects/?name=mec-content-rulebooks" | jq -r '.results[0].id // empty')
  [[ -z "$EDA_PROJ_ID" ]] && { error "Could not create EDA project"; exit 1; }
  success "EDA project ID: ${EDA_PROJ_ID}"

  wait_for "EDA project sync" 120 \
    "eda_api GET '/projects/${EDA_PROJ_ID}/' | jq -r '.import_state' | grep -qE 'completed|failed'"

  info "Getting EDA decision environment..."
  DE_ID=$(eda_api GET "/decision-environments/" | jq -r '.results[0].id // empty')

  info "Creating EDA rulebook activation..."
  EXISTING=$(eda_api GET "/activations/?name=mec-demand-predictions" | jq -r '.count')
  if [[ "$EXISTING" == "0" ]]; then
    eda_api POST "/activations/" \
      "{\"name\":\"mec-demand-predictions\",\"description\":\"MEC content pre-positioning — confidence ≥ 0.95 auto-trigger\",\"project\":${EDA_PROJ_ID},\"rulebook\":\"implementation/phase-04-automation/aap/eda-rulebook.yaml\",\"decision_environment\":${DE_ID},\"is_enabled\":true,\"restart_policy\":\"on-failure\"}" | \
      jq -r '.id // empty' | xargs -I{} echo "Activation ID: {}"
    success "EDA rulebook activation created and enabled"
  else
    warn "EDA activation mec-demand-predictions already exists — skipping"
  fi
fi

# =============================================================================
section "Step 5b — Configure Ansible Lightspeed (Granite 3.3 8B)"
# =============================================================================
# Point AAP Lightspeed at the self-hosted Granite model — no external WCA needed.
# Granite is purpose-built for Ansible/code generation and runs on the same GPU.
GRANITE_ENDPOINT="${VLLM_URL:-http://granite-3-3-8b-predictor.mec-content-ai.svc.cluster.local}"
info "Configuring AAP Lightspeed → Granite endpoint: ${GRANITE_ENDPOINT}"

if [[ -n "$AAP_TOKEN" && -n "$AAP_HOST" ]]; then
  # Enable Lightspeed with self-hosted Granite endpoint
  curl -ksS -X PATCH \
    -H "Authorization: Bearer ${AAP_TOKEN}" \
    -H "Content-Type: application/json" \
    "${AAP_HOST}/api/controller/v2/settings/ansible-lightspeed/" \
    -d "{
      \"ANSIBLE_AI_ENABLED\": true,
      \"ANSIBLE_AI_PROJECT_CONSUMPTION_AUDIT_ENABLED\": true,
      \"ANSIBLE_AI_MODEL_MESH_API_URL\": \"${GRANITE_ENDPOINT}\",
      \"ANSIBLE_AI_MODEL_MESH_MODEL_NAME\": \"granite-lightspeed\",
      \"ANSIBLE_AI_MODEL_MESH_API_KEY\": \"fake\"
    }" &>/dev/null && success "AAP Lightspeed configured with Granite endpoint" || \
    warn "Could not configure Lightspeed via API — configure manually in AAP UI → Settings → Ansible Lightspeed"

  # lightspeed-generate-and-run was already created in Step 4 — just verify
  EXISTING=$(aap_api GET "/job_templates/?name=lightspeed-generate-and-run" | jq -r '.count')
  if [[ "$EXISTING" != "0" && -n "$EXISTING" ]]; then
    success "Job template 'lightspeed-generate-and-run' confirmed in AAP"
  else
    # Re-create using the project/inventory from Step 4
    PROJECT_ID=$(aap_api GET "/projects/?name=mec-content-playbooks" | jq -r '.results[0].id // empty')
    INVENTORY_ID=$(aap_api GET "/inventories/?name=mec-sites" | jq -r '.results[0].id // empty')
    [[ -n "$PROJECT_ID" && -n "$INVENTORY_ID" ]] && \
      aap_api POST "/job_templates/" \
        "{\"name\":\"lightspeed-generate-and-run\",\"organization\":${ORG_ID},\"project\":${PROJECT_ID},\"playbook\":\"implementation/phase-04-automation/playbooks/lightspeed-runner.yml\",\"inventory\":${INVENTORY_ID},\"ask_variables_on_launch\":true}" \
        > /dev/null && success "Job template 'lightspeed-generate-and-run' created"
  fi
else
  warn "AAP_TOKEN not set — skipping Lightspeed API config. Configure manually in AAP UI → Settings → Ansible Lightspeed"
fi

# =============================================================================
section "Step 6 — End-to-End Test"
# =============================================================================
info "Publishing test demand event (confidence 0.97 → EDA auto-trigger)..."
oc run aap-e2e-test --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- bash -c \
  "echo '{\"mec_site_id\":\"mec-stadium-01\",\"content_id\":\"nfl-game-test\",\"content_url\":\"http://cdn-mock.mec-content-ai.svc.cluster.local:8080/nfl-game\",\"predicted_viewers\":48000,\"event_type\":\"live_sport\",\"event_start_utc\":\"2026-04-09T20:00:00Z\",\"confidence\":0.97,\"predicted_peak_in_minutes\":22}' | \
  bin/kafka-console-producer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic demand.predictions" \
  2>/dev/null && success "Test event published"

sleep 15
info "Checking for AAP job triggered by EDA..."
RECENT_JOB=$(aap_api GET "/jobs/?order_by=-created&page_size=3" | \
  jq -r '.results[] | select(.summary_fields.job_template.name=="prefetch-content") | .status' | head -1)
[[ -n "$RECENT_JOB" ]] && success "AAP job triggered: status=${RECENT_JOB}" || \
  warn "No AAP job found yet — EDA may still be processing (check https://${AAP_URL})"

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 04 complete.${NC}"
echo -e "    Next: ./scripts/phase-05-deploy.sh"

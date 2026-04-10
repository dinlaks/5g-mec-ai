#!/usr/bin/env bash
# =============================================================================
# phase-04-deploy.sh — Automation (AAP + EDA + Playbooks)
# Automates: implementation/phase-04-automation/COMMANDS.md
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
if ! oc whoami &>/dev/null; then error "Not logged in."; exit 1; fi
oc get csv -n aap --no-headers 2>/dev/null | grep -q Succeeded || \
  { error "AAP operator not ready — run phase-01 first."; exit 1; }
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
run "oc apply -f implementation/phase-04-automation/aap/automation-controller.yaml"
run "oc apply -f implementation/phase-04-automation/aap/eda-controller.yaml"

info "Waiting for AAP components (5–10 minutes)..."
wait_for "AutomationController pod running" 600 \
  "oc get pods -n aap -l app.kubernetes.io/name=controller --no-headers 2>/dev/null | grep -q Running"
wait_for "EDA Controller pod running" 600 \
  "oc get pods -n aap -l app.kubernetes.io/name=eda-controller --no-headers 2>/dev/null | grep -q Running"

AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null)
EDA_URL=$(oc get route eda-controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null)
success "AAP Controller: https://${AAP_URL}"
success "EDA Controller: https://${EDA_URL}"

# =============================================================================
section "Step 3 — ⏸ MANUAL: Get AAP API Token"
# =============================================================================
pause_for_human "Generate AAP API token:
  Option A (UI): https://${AAP_URL}
    → User icon → My Profile → Tokens → Add → Scope: Write → Save → Copy token

  Option B (API):
    curl -s -X POST 'https://${AAP_URL}/api/v2/tokens/' \\
      -H 'Content-Type: application/json' \\
      -u 'admin:\${AAP_ADMIN_PASSWORD}' \\
      -d '{\"description\":\"mcp-aap token\",\"scope\":\"write\"}' \\
      --insecure | jq '.token'

  Then add to configs/near-edge/env.sh:
    export AAP_TOKEN='<paste-token>'
    export AAP_HOST='https://${AAP_URL}'
  And run: source configs/near-edge/env.sh
  Then: ./scripts/apply-secrets.sh --phase 05"

[[ -z "${AAP_TOKEN:-}" ]] && { error "AAP_TOKEN not set. Set it in env.sh and re-source."; exit 1; }

# =============================================================================
section "Step 4 — Import Playbooks into AAP (via API)"
# =============================================================================
info "Creating AAP organization..."
ORG_ID=$(aap_api POST "/organizations/" \
  '{"name":"MEC Content Intelligence","description":"5G MEC Content Pre-positioning"}' \
  | jq -r '.id // empty')
[[ -z "$ORG_ID" ]] && \
  ORG_ID=$(aap_api GET "/organizations/?name=MEC+Content+Intelligence" | jq -r '.results[0].id')
success "Organization ID: ${ORG_ID}"

info "Creating AAP project (pointing to Git repo)..."
[[ -z "${GIT_REPO_URL:-}" ]] && { error "GIT_REPO_URL not set in env.sh"; exit 1; }
PROJ_ID=$(aap_api POST "/projects/" \
  "{\"name\":\"mec-content-playbooks\",\"organization\":${ORG_ID},\"scm_type\":\"git\",\"scm_url\":\"${GIT_REPO_URL}\",\"scm_branch\":\"main\",\"scm_update_on_launch\":true}" \
  | jq -r '.id // empty')
[[ -z "$PROJ_ID" ]] && \
  PROJ_ID=$(aap_api GET "/projects/?name=mec-content-playbooks" | jq -r '.results[0].id')
success "Project ID: ${PROJ_ID}"

info "Waiting for project sync..."
wait_for "AAP project sync complete" 120 \
  "aap_api GET '/projects/${PROJ_ID}/' | jq -r '.status' | grep -q successful"

info "Creating inventory..."
INV_ID=$(aap_api POST "/inventories/" \
  "{\"name\":\"mec-sites\",\"organization\":${ORG_ID}}" | jq -r '.id // empty')
[[ -z "$INV_ID" ]] && \
  INV_ID=$(aap_api GET "/inventories/?name=mec-sites" | jq -r '.results[0].id')
success "Inventory ID: ${INV_ID}"

info "Creating 5 job templates..."
for playbook in "prefetch-content:prefetch-content.yml" \
                "set-qos-policy:set-qos-policy.yml" \
                "push-abr-policy:push-abr-policy.yml" \
                "rollback-cache:rollback-cache.yml" \
                "alert-noc:alert-noc.yml"; do
  name="${playbook%%:*}"
  file="${playbook##*:}"
  EXISTING=$(aap_api GET "/job_templates/?name=${name}" | jq -r '.count')
  if [[ "$EXISTING" == "0" ]]; then
    aap_api POST "/job_templates/" \
      "{\"name\":\"${name}\",\"organization\":${ORG_ID},\"project\":${PROJ_ID},\"playbook\":\"implementation/phase-04-automation/playbooks/${file}\",\"inventory\":${INV_ID},\"ask_variables_on_launch\":true}" \
      > /dev/null
    success "Job template created: ${name}"
  else
    warn "Job template already exists: ${name} — skipping"
  fi
done

# =============================================================================
section "Step 5 — Import EDA Rulebook"
# =============================================================================
info "Getting EDA token..."
EDA_TOKEN=$(curl -s -X POST "https://${EDA_URL}/api/eda/v1/auth/token/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${AAP_ADMIN_PASSWORD}\"}" \
  --insecure | jq -r '.token // empty')
[[ -z "$EDA_TOKEN" ]] && { warn "Could not get EDA token — import EDA rulebook manually (see COMMANDS.md Step 6)"; }

if [[ -n "$EDA_TOKEN" ]]; then
  info "Creating EDA project..."
  EDA_PROJ_ID=$(curl -s -X POST "https://${EDA_URL}/api/eda/v1/projects/" \
    -H "Authorization: Bearer ${EDA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"mec-content-rulebooks\",\"url\":\"${GIT_REPO_URL}\"}" \
    --insecure | jq -r '.id // empty')
  success "EDA project created: ${EDA_PROJ_ID}"
  info "Activate rulebook via EDA UI: https://${EDA_URL}"
  info "See COMMANDS.md Step 6c for activation payload"
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

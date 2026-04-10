#!/usr/bin/env bash
# =============================================================================
# phase-08-deploy.sh — Validation & Demo Setup
# Automates: implementation/phase-08-validation/COMMANDS.md (Part A only)
#
# This script covers SETUP only:
#   - CDN mock deployment + Big Buck Bunny content seeding
#   - Demand spike CronJob (keeps demo pipeline warm)
#   - System smoke test
#
# LIVE DEMO execution is NOT automated here.
# During the presentation, run test-scenarios.sh manually:
#   ./implementation/phase-08-validation/test-scenarios.sh --scenario nfl
#   ./implementation/phase-08-validation/test-scenarios.sh --scenario synthetic
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

wait_for() {
  local desc=$1 max=$2 cmd=$3
  info "Waiting: ${desc} (max ${max}s)..."
  local elapsed=0
  while ! eval "$cmd" &>/dev/null; do
    sleep 10; elapsed=$((elapsed+10))
    [[ $elapsed -ge $max ]] && { error "Timeout: ${desc}"; exit 1; }
    echo -n "."
  done
  echo ""; success "${desc}"
}

# =============================================================================
section "Pre-flight Checks"
# =============================================================================
if ! oc whoami &>/dev/null; then error "Not logged in."; exit 1; fi
oc get deployment content-intelligence-agent -n mec-content-ai &>/dev/null || \
  { error "Agent not running — run phases 01-05 first."; exit 1; }
oc get route edgestream-iq -n mec-content-ai &>/dev/null || \
  { error "Dashboard not deployed — run phase-07 first."; exit 1; }
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Deploy CDN Mock"
# =============================================================================
run "oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-pvc.yaml"
run "oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-configmap.yaml"
run "oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-deployment.yaml"

wait_for "CDN mock pod running" 120 \
  "oc get pods -n mec-content-ai -l app.kubernetes.io/name=cdn-mock --no-headers 2>/dev/null | grep -q Running"

CDN_ROUTE=$(oc get route cdn-mock -n mec-content-ai -o jsonpath='{.spec.host}' 2>/dev/null)
curl -sk "https://${CDN_ROUTE}/health" | grep -q ok && \
  success "CDN mock healthy: https://${CDN_ROUTE}" || \
  warn "CDN mock health check failed — check pod logs"

# =============================================================================
section "Step 2 — Seed CDN Mock (Big Buck Bunny HLS)"
# =============================================================================
# Check if already seeded
if oc get job cdn-mock-seed -n mec-content-ai &>/dev/null; then
  SEED_STATUS=$(oc get job cdn-mock-seed -n mec-content-ai \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
  if [[ "$SEED_STATUS" == "True" ]]; then
    warn "Seed job already completed — skipping re-seed"
  else
    info "Seed job exists but not complete — waiting..."
    wait_for "Seed job complete" 600 \
      "oc get job cdn-mock-seed -n mec-content-ai \
       -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' 2>/dev/null | grep -q True"
  fi
else
  info "Starting seed job (downloads Big Buck Bunny HLS — 5-10 minutes)..."
  run "oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-seed-job.yaml"
  wait_for "Seed job complete" 600 \
    "oc get job cdn-mock-seed -n mec-content-ai \
     -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}' 2>/dev/null | grep -q True"
fi

success "CDN mock seeded — Big Buck Bunny HLS content ready"

# =============================================================================
section "Step 3 — Apply Demand Spike CronJob"
# =============================================================================
run "oc apply -f implementation/phase-08-validation/demand-spike-cronjob.yaml"

wait_for "CronJob created" 30 \
  "oc get cronjob demand-spike-simulator -n mec-content-ai &>/dev/null"

# Trigger one run immediately
info "Triggering initial demand event..."
oc create job "demand-spike-init-${RANDOM}" \
  --from=cronjob/demand-spike-simulator \
  -n mec-content-ai &>/dev/null
sleep 5
success "CronJob deployed — events will fire every 5 minutes automatically"

# =============================================================================
section "Step 4 — System Smoke Test"
# =============================================================================
info "Running validation scenario..."
if [[ "$DRY_RUN" == false ]]; then
  chmod +x implementation/phase-08-validation/test-scenarios.sh
  ./implementation/phase-08-validation/test-scenarios.sh --scenario validate || true
fi

# =============================================================================
section "Setup Complete"
# =============================================================================
DASHBOARD_URL=$(oc get route edgestream-iq -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)
AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)
LANGFUSE_URL=$(oc get route langfuse -n mec-ai-obs \
  -o jsonpath='{.spec.host}' 2>/dev/null)

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 08 setup complete. System is demo-ready.${NC}"
echo ""
echo -e "${BOLD}Dashboard URLs:${NC}"
echo -e "  Dashboard:   https://${DASHBOARD_URL}"
echo -e "  Agent API:   https://${AGENT_URL}/health"
echo -e "  Langfuse:    https://${LANGFUSE_URL}"
echo -e "  CDN Mock:    https://${CDN_ROUTE}"
echo ""
echo -e "${BOLD}${YELLOW}━━━ LIVE DEMO — Run these during your presentation ━━━${NC}"
echo ""
echo -e "  # EDA auto-trigger (fastest, confidence 0.97 — no agent)"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario eda${NC}"
echo ""
echo -e "  # NFL agent path (confidence 0.91 — full 8-node LangGraph flow)"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario nfl${NC}"
echo ""
echo -e "  # Human approval (confidence 0.72 — Slack card + dashboard approval)"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario synthetic${NC}"
echo ""
echo -e "  # Run all scenarios back to back"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --all${NC}"
echo ""
echo -e "${BOLD}Before going on stage:${NC}"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario validate${NC}"
echo ""

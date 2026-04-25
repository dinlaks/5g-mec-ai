#!/usr/bin/env bash
# =============================================================================
# deploy-all.sh — Master Deployment Orchestrator
# 5G MEC Content Intelligence
#
# Runs all available phase scripts in order with confirmation between phases.
# Pauses automatically at manual steps within each phase script.
#
# Usage:
#   source configs/near-edge/env.sh
#   ./scripts/deploy-all.sh                     # full run (phases 01-06)
#   ./scripts/deploy-all.sh --from-phase 03     # resume from a specific phase
#   ./scripts/deploy-all.sh --dry-run           # show what would run
#   ./scripts/deploy-all.sh --validate          # pre-checks only (all phases)
#
# Manual steps that will pause this script:
#   Phase 02 — Langfuse UI: create account + generate API keys → save to env.sh
#   Phase 04 — AAP UI: generate API token → save to env.sh
#
# Everything else is fully automated.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DRY_RUN=false
VALIDATE_ONLY=false
FROM_PHASE=1

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)      DRY_RUN=true; shift ;;
    --validate)     VALIDATE_ONLY=true; shift ;;
    --from-phase)   FROM_PHASE=$2; shift 2 ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; exit 1 ;;
  esac
done

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

confirm_phase() {
  local phase=$1 name=$2
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║  Ready to run Phase ${phase}: ${name}${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  read -rp "  Press Enter to start, or Ctrl+C to stop here... "
}

run_phase() {
  local phase=$1 name=$2 script=$3

  [[ $phase -lt $FROM_PHASE ]] && { info "Skipping Phase ${phase} (--from-phase ${FROM_PHASE})"; return; }

  if [[ "$VALIDATE_ONLY" == true ]]; then
    info "Validating Phase ${phase}: ${name}"
    bash "scripts/${script}" --validate
    return
  fi

  confirm_phase "${phase}" "${name}"

  local args=""
  [[ "$DRY_RUN" == true ]] && args="--dry-run"

  echo -e "\n${BOLD}Starting Phase ${phase} — ${name}${NC}\n"
  START=$(date +%s)

  bash "scripts/${script}" ${args}

  END=$(date +%s)
  ELAPSED=$((END - START))
  echo ""
  success "Phase ${phase} completed in $((ELAPSED/60))m $((ELAPSED%60))s"
  PHASE_TIMES["${phase}"]="${ELAPSED}"
}

# =============================================================================
# PRE-FLIGHT
# =============================================================================
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║   5G MEC Content Intelligence — Full Deployment          ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Mode:       $( [[ "$DRY_RUN" == true ]] && echo 'Dry Run' || echo 'Live' )"
echo -e "  Validate:   ${VALIDATE_ONLY}"
echo -e "  From phase: ${FROM_PHASE}"
echo ""
echo -e "${BOLD}Manual steps in this run:${NC}"
[[ $FROM_PHASE -le 2 ]] && \
  echo -e "  ${YELLOW}⏸${NC}  Phase 02 — Langfuse UI: create account + generate API keys"
[[ $FROM_PHASE -le 4 ]] && \
  echo -e "  ${YELLOW}⏸${NC}  Phase 04 — AAP UI: generate API token"
echo ""
echo -e "${BOLD}Estimated total time (first run):${NC}"
echo -e "  Phase 01: ~25 min  (wave-0 + wave-1 install in parallel per wave)"
echo -e "  Phase 02: ~10 min automated + manual Langfuse setup"
echo -e "  Phase 03: ~10 min automated + manual model download"
echo -e "  Phase 04: ~15 min automated + manual AAP token"
echo -e "  Phase 05: ~20 min (image builds take longest)"
echo -e "  Phase 06: ~10 min"
echo -e "  Phase 07: ~20 min (backend + frontend image builds)"
echo -e "  ${BOLD}Total: ~100-110 min${NC} (of which ~10 min is manual steps)"
echo ""

if ! oc whoami &>/dev/null; then
  error "Not logged into OpenShift. Run: oc login --server=<url> --username=kubeadmin"
  exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if [[ -z "${GIT_REPO_URL:-}" ]] && [[ "$VALIDATE_ONLY" != true ]]; then
  error "GIT_REPO_URL is not set in env.sh — required for Phase 05 BuildConfigs"
  error "Set it: export GIT_REPO_URL='https://github.com/dinlaks/5g-mec-ai.git'"
  exit 1
fi

declare -A PHASE_TIMES

# =============================================================================
# PHASE RUNS
# =============================================================================
run_phase 1 "Foundation (Operators + GitOps + ACM)"    "phase-01-deploy.sh"
run_phase 2 "Data Pipeline (Kafka + MinIO + Langfuse)"  "phase-02-deploy.sh"
run_phase 3 "AI Core (vLLM + LlamaStack)"               "phase-03-deploy.sh"
run_phase 4 "Automation (AAP + EDA + Playbooks)"        "phase-04-deploy.sh"
run_phase 5 "Agent & MCP (LangGraph + 7 MCP servers)"   "phase-05-deploy.sh"
run_phase 6 "Far Edge (SNO — telemetry + models + cache)" "phase-06-deploy.sh"
run_phase 7 "EdgeStream IQ Dashboard (FastAPI + React)"   "phase-07-deploy.sh"
run_phase 8 "Validation & Demo Setup (cdn-mock + CronJob)" "phase-08-deploy.sh"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║          Full Deployment Complete!                       ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}Phase timing:${NC}"
for phase in 1 2 3 4 5 6 7 8; do
  if [[ -n "${PHASE_TIMES[$phase]:-}" ]]; then
    t=${PHASE_TIMES[$phase]}
    printf "  Phase %s: %dm %ds\n" "$phase" "$((t/60))" "$((t%60))"
  fi
done

echo ""
echo -e "${BOLD}Key URLs:${NC}"
AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)
LANGFUSE_URL=$(oc get route langfuse -n mec-ai-obs \
  -o jsonpath='{.spec.host}' 2>/dev/null)
AAP_URL=$(oc get route controller -n aap \
  -o jsonpath='{.spec.host}' 2>/dev/null)
ARGOCD_URL=$(oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='{.spec.host}' 2>/dev/null)
DASHBOARD_URL=$(oc get route edgestream-iq -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)

[[ -n "$DASHBOARD_URL" ]] && echo -e "  Dashboard:    https://${DASHBOARD_URL}"
[[ -n "$AGENT_URL"    ]] && echo -e "  Agent API:    https://${AGENT_URL}/health"
[[ -n "$LANGFUSE_URL" ]] && echo -e "  Langfuse:     https://${LANGFUSE_URL}"
[[ -n "$AAP_URL"      ]] && echo -e "  AAP Console:  https://${AAP_URL}"
[[ -n "$ARGOCD_URL"   ]] && echo -e "  ArgoCD:       https://${ARGOCD_URL}"

echo ""
echo ""
echo -e "${BOLD}${YELLOW}━━━ SYSTEM IS DEMO-READY ━━━${NC}"
echo ""
echo -e "${BOLD}Live demo commands (run during presentation):${NC}"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario eda${NC}"
echo -e "      → EDA auto-trigger (confidence 0.97, no agent involved)"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario nfl${NC}"
echo -e "      → Full 8-node LangGraph flow (confidence 0.91)"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario synthetic${NC}"
echo -e "      → Human approval path (confidence 0.72, Slack card)"
echo ""
echo -e "${BOLD}Before going on stage — run this:${NC}"
echo -e "  ${CYAN}./implementation/phase-08-validation/test-scenarios.sh --scenario validate${NC}"
echo ""
echo -e "${BOLD}Update progress tracker:${NC}"
echo -e "  • logs/PROGRESS-TRACKER.md"
echo ""

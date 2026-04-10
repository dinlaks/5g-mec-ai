#!/usr/bin/env bash
# =============================================================================
# phase-07-deploy.sh — EdgeStream IQ Dashboard (FastAPI backend + React frontend)
# Automates: implementation/phase-07-dashboard/COMMANDS.md
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
oc get deployment content-intelligence-agent -n mec-content-ai &>/dev/null || \
  { error "Agent not running — run phase-05 first."; exit 1; }
oc get pods -n mec-ai-obs -l app.kubernetes.io/name=langfuse --no-headers 2>/dev/null | grep -q Running || \
  { error "Langfuse not running — run phase-02 first."; exit 1; }
[[ -z "${GIT_REPO_URL:-}" ]] && { error "GIT_REPO_URL not set in env.sh"; exit 1; }
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Apply Phase 07 Secrets"
# =============================================================================
./scripts/apply-secrets.sh --phase 07
success "edgestream-iq-secret created"

# =============================================================================
section "Step 2 — Apply BuildConfigs and ImageStreams"
# =============================================================================
# Patch Git URL into BuildConfigs
for bc_file in \
  implementation/phase-07-dashboard/backend/buildconfig.yaml \
  implementation/phase-07-dashboard/frontend/buildconfig.yaml; do
  TMP=$(mktemp)
  sed "s|\${GIT_REPO_URL}|${GIT_REPO_URL}|g" "${bc_file}" > "${TMP}"
  run "oc apply -f ${TMP}"
  rm -f "${TMP}"
done
success "BuildConfigs applied"

# =============================================================================
section "Step 3 — Build Backend and Frontend Images"
# =============================================================================
info "Starting builds (backend + frontend in parallel, ~5-10 mins each)..."
run "oc start-build edgestream-iq-backend  -n mec-content-ai"
run "oc start-build edgestream-iq-frontend -n mec-content-ai"

wait_for "Backend build Complete" 900 \
  "oc get builds -n mec-content-ai --no-headers 2>/dev/null | grep edgestream-iq-backend | grep -q Complete"
wait_for "Frontend build Complete" 900 \
  "oc get builds -n mec-content-ai --no-headers 2>/dev/null | grep edgestream-iq-frontend | grep -q Complete"
success "Both images built"

# =============================================================================
section "Step 4 — Deploy Backend and Frontend"
# =============================================================================
run "oc apply -f implementation/phase-07-dashboard/backend/deployment.yaml"
run "oc apply -f implementation/phase-07-dashboard/frontend/deployment.yaml"

wait_for "Backend available" 300 \
  "oc get deployment edgestream-iq-backend -n mec-content-ai --no-headers 2>/dev/null | awk '{print \$4}' | grep -qv '^0$'"
wait_for "Frontend available" 300 \
  "oc get deployment edgestream-iq-frontend -n mec-content-ai --no-headers 2>/dev/null | awk '{print \$4}' | grep -qv '^0$'"
success "Dashboard deployed"

# =============================================================================
section "Step 5 — Health Checks"
# =============================================================================
BACKEND_URL=$(oc get route edgestream-iq-backend -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)
FRONTEND_URL=$(oc get route edgestream-iq -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)

curl -sk "https://${BACKEND_URL}/health" | grep -q ok && \
  success "Backend healthy: https://${BACKEND_URL}" || \
  warn "Backend health check failed"

curl -sk "https://${FRONTEND_URL}/health" | grep -q ok && \
  success "Frontend healthy: https://${FRONTEND_URL}" || \
  warn "Frontend health check failed"

# =============================================================================
section "Step 6 — Verify WebSocket"
# =============================================================================
info "Testing WebSocket connectivity (requires wscat or curl)..."
if command -v curl &>/dev/null; then
  WS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    "https://${BACKEND_URL}/ws" 2>/dev/null || echo "000")
  [[ "$WS_STATUS" == "101" ]] && success "WebSocket upgrade: 101 Switching Protocols" || \
    info "WebSocket status: ${WS_STATUS} (101 expected — test via browser)"
fi

# =============================================================================
section "Summary"
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}✅  Phase 07 complete.${NC}"
echo ""
echo -e "${BOLD}Dashboard URLs:${NC}"
echo -e "  Frontend: https://${FRONTEND_URL}"
echo -e "  Backend:  https://${BACKEND_URL}"
echo -e "  API:      https://${BACKEND_URL}/api/sites"
echo -e "  WS:       wss://${BACKEND_URL}/ws"
echo ""
echo -e "${BOLD}Open the dashboard in your browser:${NC}"
echo -e "  https://${FRONTEND_URL}"
echo -e "  (Real-time updates via WebSocket — panels populate as Kafka data flows)"
echo ""
echo -e "    Next: ./scripts/phase-08-deploy.sh  (when Phase 08 is built)"

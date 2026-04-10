#!/usr/bin/env bash
# =============================================================================
# phase-05-deploy.sh — Agent & MCP Servers (LangGraph + 7 MCP servers)
# Automates: implementation/phase-05-agent-mcp/COMMANDS.md
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
oc get pods -n mec-ai-data -l app=minio --no-headers 2>/dev/null | grep -q Running || \
  { error "MinIO not running — run phase-02 first."; exit 1; }
[[ -z "${GIT_REPO_URL:-}" ]] && { error "GIT_REPO_URL not set in env.sh"; exit 1; }
[[ -z "${SLACK_BOT_TOKEN:-}" ]] && warn "SLACK_BOT_TOKEN not set — mcp-slack will fail at runtime"
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Apply Secrets"
# =============================================================================
./scripts/apply-secrets.sh --phase 05
success "Phase 05 secrets applied"

# =============================================================================
section "Step 2 — Apply RBAC"
# =============================================================================
run "oc apply -f implementation/phase-05-agent-mcp/rbac.yaml"
wait_for "All Phase 05 ServiceAccounts created" 60 \
  "[[ \$(oc get sa -n mec-content-ai --no-headers 2>/dev/null | grep -cE 'agent|mcp') -ge 7 ]]"
success "RBAC applied"

# =============================================================================
section "Step 3 — Patch BuildConfigs with Git Repo URL"
# =============================================================================
run "oc apply -f implementation/phase-05-agent-mcp/agent/buildconfig.yaml"
run "oc apply -f implementation/phase-05-agent-mcp/mcp-servers/mcp-servers-buildconfig.yaml"

for bc in content-intelligence-agent mcp-network-intel mcp-kafka mcp-aap \
          mcp-slack mcp-kubeflow mcp-openshift; do
  run "oc patch buildconfig ${bc} -n mec-content-ai \
    --type=merge \
    -p '{\"spec\":{\"source\":{\"git\":{\"uri\":\"${GIT_REPO_URL}\"}}}}'"
done
success "BuildConfigs patched with Git URL: ${GIT_REPO_URL}"

# =============================================================================
section "Step 4 — Build All Images (runs in parallel, ~5-8 mins each)"
# =============================================================================
info "Starting all 8 builds..."
for bc in content-intelligence-agent mcp-network-intel mcp-kafka mcp-aap \
          mcp-slack mcp-kubeflow mcp-openshift; do
  run "oc start-build ${bc} -n mec-content-ai"
done

info "Waiting for all builds to complete (up to 20 minutes)..."
wait_for "All 7 builds Complete" 1200 \
  "[[ \$(oc get builds -n mec-content-ai --no-headers 2>/dev/null | grep -c Complete) -ge 7 ]]"

# Verify all ImageStreams have latest tag
MISSING=$(oc get imagestream -n mec-content-ai --no-headers 2>/dev/null | \
  awk '$2 == "" {print $1}' | wc -l)
[[ "$MISSING" -gt 0 ]] && warn "Some ImageStreams may not have tags yet — check builds" || \
  success "All 8 images built and tagged"

# =============================================================================
section "Step 5 — Deploy MCP Servers + Agent"
# =============================================================================
run "oc apply -f implementation/phase-05-agent-mcp/mcp-servers/mcp-servers-deployment.yaml"
run "oc apply -f implementation/phase-05-agent-mcp/agent/deployment.yaml"

info "Waiting for all 8 pods to be Available (up to 5 minutes)..."
for dep in content-intelligence-agent mcp-network-intel mcp-kafka mcp-aap \
           mcp-slack mcp-kubeflow mcp-openshift; do
  wait_for "${dep} available" 300 \
    "oc get deployment ${dep} -n mec-content-ai --no-headers 2>/dev/null | awk '{print \$4}' | grep -qv '^0$'"
done
success "All deployments available"

# =============================================================================
section "Step 6 — Verify RBAC (mcp-openshift)"
# =============================================================================
CAN_PODS=$(oc auth can-i list pods \
  --as=system:serviceaccount:mec-content-ai:mcp-openshift-sa \
  --all-namespaces 2>/dev/null)
[[ "$CAN_PODS" == "yes" ]] && success "mcp-openshift-sa can list pods" || \
  warn "mcp-openshift-sa cannot list pods — check rbac.yaml"

# =============================================================================
section "Step 7 — Health Checks"
# =============================================================================
AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}' 2>/dev/null)
curl -sk "https://${AGENT_URL}/health" | grep -q "ok" && \
  success "Agent API healthy: https://${AGENT_URL}/health" || \
  warn "Agent health check failed — check pod logs"

AGENT_POD=$(oc get pod -l app.kubernetes.io/name=content-intelligence-agent \
  -n mec-content-ai -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$AGENT_POD" ]]; then
  info "Checking MCP server reachability from agent pod..."
  for server in mcp-network-intel mcp-kafka mcp-aap mcp-openshift; do
    STATUS=$(oc exec "${AGENT_POD}" -n mec-content-ai -- \
      curl -s "http://${server}:8000/health" 2>/dev/null | jq -r '.status // "error"')
    [[ "$STATUS" == "ok" ]] && success "${server}: ok" || warn "${server}: ${STATUS}"
  done
fi

# =============================================================================
section "Step 8 — End-to-End Test"
# =============================================================================
info "Publishing test demand event (confidence 0.88 → triggers agent)..."
oc run agent-e2e --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- bash -c \
  "echo '{\"mec_site_id\":\"mec-stadium-01\",\"content_id\":\"nfl-game-test\",\"content_url\":\"http://cdn-mock.mec-content-ai.svc.cluster.local:8080/nfl-game\",\"predicted_viewers\":42000,\"event_type\":\"live_sport\",\"event_start_utc\":\"2026-04-09T20:00:00Z\",\"confidence\":0.88,\"predicted_peak_in_minutes\":25}' | \
  bin/kafka-console-producer.sh --bootstrap-server kafka-cluster-kafka-bootstrap:9092 --topic demand.predictions" \
  2>/dev/null && success "Test event published"

sleep 20
info "Checking agent run via API..."
RUN_LIST=$(curl -sk "https://${AGENT_URL}/runs" 2>/dev/null | jq 'keys | length' 2>/dev/null)
[[ "${RUN_LIST:-0}" -gt 0 ]] && \
  success "Agent processed ${RUN_LIST} run(s) — check Langfuse for traces" || \
  warn "No agent runs yet — check agent pod logs: oc logs -f deployment/content-intelligence-agent -n mec-content-ai"

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 05 complete.${NC}"
echo -e "    Next: ./scripts/phase-06-deploy.sh"

#!/usr/bin/env bash
# =============================================================================
# phase-02-deploy.sh — Data Pipeline (Kafka + MinIO + Langfuse)
# Automates: implementation/phase-02-data-pipeline/COMMANDS.md
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
    sleep 10; elapsed=$((elapsed+10))
    [[ $elapsed -ge $max ]] && { error "Timeout: ${desc}"; exit 1; }
    echo -n "."
  done
  echo ""; success "${desc}"
}

# =============================================================================
section "Pre-flight Checks"
# =============================================================================
if ! oc whoami &>/dev/null; then error "Not logged in to OpenShift."; exit 1; fi
for ns in mec-ai-data mec-ai-obs; do
  oc get namespace "$ns" &>/dev/null || { error "Namespace '$ns' missing — run phase-01 first."; exit 1; }
done
oc get crd kafkas.kafka.strimzi.io --no-headers 2>/dev/null | grep . || { error > /dev/null"AMQ Streams operator not ready — run phase-01 first."; exit 1; }
success "Pre-checks passed"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Apply Secrets"
# =============================================================================
./scripts/apply-secrets.sh --phase 02 --validate
./scripts/apply-secrets.sh --phase 02
success "Phase 02 secrets applied"

# Apply RBAC first — ServiceAccounts needed by MinIO and Langfuse deployments
run "oc apply -f implementation/phase-02-data-pipeline/rbac.yaml"

# =============================================================================
section "Step 2 — Kafka Cluster + Topics"
# =============================================================================
run "oc apply -f implementation/phase-02-data-pipeline/kafka/kafka-cluster.yaml"
wait_for "Kafka cluster Ready" 300 \
  "oc get kafka kafka-cluster -n mec-ai-data -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep True > /dev/null"
run "oc apply -f implementation/phase-02-data-pipeline/kafka/kafka-topics.yaml"
wait_for "All 8 Kafka topics Ready" 120 \
  "[[ \$(oc get kafkatopics -n mec-ai-data --no-headers 2>/dev/null | grep -c 'True' || true) -ge 8 ]]"
success "Kafka cluster + 8 topics ready"

# =============================================================================
section "Step 3 — MinIO"
# =============================================================================
run "oc apply -f implementation/phase-02-data-pipeline/minio/minio-deployment.yaml"
wait_for "MinIO pod running" 90 \
  "oc get pods -n mec-ai-data -l app=minio --no-headers 2>/dev/null | grep Running > /dev/null"
success "MinIO ready"

# =============================================================================
section "Step 4 — Langfuse Backends (PostgreSQL + ClickHouse + Redis)"
# =============================================================================
run "oc apply -f implementation/phase-02-data-pipeline/langfuse/postgresql-deployment.yaml"
run "oc apply -f implementation/phase-02-data-pipeline/langfuse/clickhouse-deployment.yaml"
run "oc apply -f implementation/phase-02-data-pipeline/langfuse/redis-deployment.yaml"
wait_for "PostgreSQL ready" 90 "oc get pods -n mec-ai-obs -l app=postgresql --no-headers 2>/dev/null | grep Running > /dev/null"
wait_for "ClickHouse ready" 90 "oc get pods -n mec-ai-obs -l app=clickhouse --no-headers 2>/dev/null | grep Running > /dev/null"
wait_for "Redis ready"      90 "oc get pods -n mec-ai-obs -l app=redis      --no-headers 2>/dev/null | grep Running > /dev/null"
success "Langfuse backends ready"

# =============================================================================
section "Step 5 — Langfuse (Helm install)"
# =============================================================================
LANGFUSE_HOST="https://$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}' 2>/dev/null || echo 'pending')"

if oc get deployment langfuse-web -n mec-ai-obs &>/dev/null; then
  warn "Langfuse already installed — skipping Helm install"
else
  APPS_DOMAIN=$(echo "${NEAR_EDGE_API}" | sed 's|https://api\.||' | sed 's|:6443||')
  LANGFUSE_NEXTAUTH_URL="https://langfuse.apps.${APPS_DOMAIN}"
  run "helm repo add langfuse https://langfuse.github.io/langfuse-k8s 2>/dev/null || true"
  run "helm repo update"
  run "helm upgrade --install langfuse langfuse/langfuse \
    --namespace mec-ai-obs \
    --values implementation/phase-02-data-pipeline/langfuse/langfuse-values.yaml \
    --set langfuse.nextauth.url=${LANGFUSE_NEXTAUTH_URL} \
    --wait --timeout 10m"
  run "oc apply -f implementation/phase-02-data-pipeline/langfuse/langfuse-route.yaml"
fi

wait_for "Langfuse web pod running" 180 \
  "oc get pods -n mec-ai-obs -l app.kubernetes.io/name=langfuse --no-headers 2>/dev/null | grep Running > /dev/null"

LANGFUSE_URL=$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}' 2>/dev/null)
success "Langfuse ready: https://${LANGFUSE_URL}"

# =============================================================================
section "Step 6 — ⏸ MANUAL: Generate Langfuse API Keys"
# =============================================================================
pause_for_human "Open Langfuse UI in your browser:
  URL: https://${LANGFUSE_URL}
  1. Sign up → create org: mec-content-ai → project: 5g-mec-intelligence
  2. Settings → API Keys → Create new API key
  3. Copy BOTH keys (secret shown once only)
  4. Add to configs/near-edge/env.sh:
       export LANGFUSE_PUBLIC_KEY='pk-lf-...'
       export LANGFUSE_SECRET_KEY='sk-lf-...'
       export LANGFUSE_HOST='https://${LANGFUSE_URL}'
  5. Run: source configs/near-edge/env.sh"

# Apply Phase 05 secrets now that Langfuse keys are available
./scripts/apply-secrets.sh --phase 05
success "Phase 05 secrets pre-created with Langfuse API keys"

# =============================================================================
section "Validation"
# =============================================================================
echo ""
oc get pods -n mec-ai-data --no-headers 2>/dev/null
oc get pods -n mec-ai-obs  --no-headers 2>/dev/null
echo ""
oc get kafkatopics -n mec-ai-data --no-headers 2>/dev/null | awk '{print $1, $3}'
echo ""
curl -s "https://${LANGFUSE_URL}/api/public/health" 2>/dev/null || warn "Langfuse health check skipped (TLS)"

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 02 complete.${NC}"
echo -e "    Next: ./scripts/phase-03-deploy.sh"

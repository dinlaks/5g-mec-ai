#!/usr/bin/env bash
# =============================================================================
# apply-secrets.sh — Create / Update all OpenShift Secrets
# 5G MEC Content Intelligence — Intelligent Pre-positioning & Adaptive Streaming
#
# Usage:
#   source configs/near-edge/env.sh
#   ./scripts/apply-secrets.sh              # apply ALL secrets
#   ./scripts/apply-secrets.sh --phase 02   # apply Phase 02 secrets only
#   ./scripts/apply-secrets.sh --phase 05   # apply Phase 05 secrets only
#   ./scripts/apply-secrets.sh --dry-run    # show what would be created
#   ./scripts/apply-secrets.sh --validate   # check all required env vars are set
#
# How it works:
#   Uses: oc create secret --dry-run=client -o yaml | oc apply -f -
#   This pattern safely handles BOTH create (new) and update (existing) secrets.
#   Real passwords come from env.sh — NEVER hardcoded in this script or YAML files.
#
# ⚠️  IMPORTANT:
#   - Langfuse encryption-key and salt must NEVER change after first deploy
#   - Run --validate first to check all env vars before applying
# =============================================================================

set -euo pipefail

# ── COLOURS ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── ARGS ──────────────────────────────────────────────────────
PHASE=""
DRY_RUN=false
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase) PHASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --validate) VALIDATE_ONLY=true; shift ;;
    *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
  esac
done

# ── HELPERS ───────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }

# Apply a secret: create if not exists, update if it does
# Usage: apply_secret <name> <namespace> <...--from-literal args>
apply_secret() {
  local name=$1
  local ns=$2
  shift 2
  local literals=("$@")

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] Would create/update secret: ${BOLD}$name${NC} in namespace ${BOLD}$ns${NC}"
    return 0
  fi

  oc create secret generic "$name" \
    --namespace="$ns" \
    "${literals[@]}" \
    --dry-run=client -o yaml | oc apply -f - > /dev/null

  success "Secret ${BOLD}$name${NC} applied in namespace ${BOLD}$ns${NC}"
}

# Check a required env var is set and non-empty
check_var() {
  local var=$1
  local description=$2
  if [[ -z "${!var:-}" ]]; then
    error "Required variable ${BOLD}$var${NC} is not set — $description"
    return 1
  fi
  success "$var is set"
  return 0
}

# ── PRE-FLIGHT ────────────────────────────────────────────────
section "Pre-flight Checks"

# Check oc is available and logged in
if ! command -v oc &>/dev/null; then
  error "oc CLI not found. Install OpenShift CLI and try again."
  exit 1
fi

if ! oc whoami &>/dev/null; then
  error "Not logged into OpenShift. Run: oc login <api-url> --token=<token>"
  exit 1
fi

success "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

# ── VALIDATE ENV VARS ─────────────────────────────────────────
section "Validating Environment Variables"

ERRORS=0

# Phase 03 — AI Core
if [[ -z "$PHASE" || "$PHASE" == "03" ]]; then
  info "Checking Phase 03 (AI Core) variables..."
  check_var "MINIO_ACCESS_KEY" "MinIO access key (used for vLLM model data connection)" || ((ERRORS++))
  check_var "MINIO_SECRET_KEY" "MinIO secret key (used for vLLM model data connection)" || ((ERRORS++))
fi

# Phase 04 — Automation
if [[ -z "$PHASE" || "$PHASE" == "04" ]]; then
  info "Checking Phase 04 (Automation) variables..."
  check_var "AAP_ADMIN_PASSWORD" "AAP AutomationController admin password (generate with: openssl rand -hex 16)" || ((ERRORS++))
fi

# Phase 02 — Data Pipeline
if [[ -z "$PHASE" || "$PHASE" == "02" ]]; then
  info "Checking Phase 02 (Data Pipeline) variables..."
  check_var "PG_PASSWORD"               "PostgreSQL password for Langfuse" || ((ERRORS++))
  check_var "CH_PASSWORD"               "ClickHouse password for Langfuse" || ((ERRORS++))
  check_var "MINIO_ACCESS_KEY"          "MinIO access key" || ((ERRORS++))
  check_var "MINIO_SECRET_KEY"          "MinIO secret key" || ((ERRORS++))
  check_var "LANGFUSE_NEXTAUTH_SECRET"  "Langfuse NextAuth secret (generate once with: openssl rand -hex 32)" || ((ERRORS++))
  check_var "LANGFUSE_ENCRYPTION_KEY"   "Langfuse encryption key (generate once, NEVER change after deploy)" || ((ERRORS++))
  check_var "LANGFUSE_SALT"             "Langfuse salt (generate once, NEVER change after deploy)" || ((ERRORS++))
fi

# Phase 05 — Agent & MCP
if [[ -z "$PHASE" || "$PHASE" == "05" ]]; then
  info "Checking Phase 05 (Agent & MCP) variables..."
  check_var "SLACK_BOT_TOKEN"        "Slack bot token (xoxb-...)" || ((ERRORS++))
  check_var "SLACK_SIGNING_SECRET"   "Slack app signing secret" || ((ERRORS++))
  check_var "LANGFUSE_PUBLIC_KEY"    "Langfuse API public key (from Langfuse UI after Phase 02)" || ((ERRORS++))
  check_var "LANGFUSE_SECRET_KEY"    "Langfuse API secret key (from Langfuse UI after Phase 02)" || ((ERRORS++))
  check_var "AAP_TOKEN"              "AAP controller API token" || ((ERRORS++))
fi

# Phase 07 — Dashboard
if [[ -z "$PHASE" || "$PHASE" == "07" ]]; then
  info "Checking Phase 07 (Dashboard) variables..."
  check_var "LANGFUSE_PUBLIC_KEY"   "Langfuse API public key" || ((ERRORS++))
  check_var "LANGFUSE_SECRET_KEY"   "Langfuse API secret key" || ((ERRORS++))
  check_var "AAP_TOKEN"             "AAP controller API token" || ((ERRORS++))
fi

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  error "$ERRORS required variable(s) missing. Update configs/near-edge/env.sh and re-run."
  echo ""
  echo -e "${YELLOW}Hint — generate strong secrets:${NC}"
  echo "  export PG_PASSWORD=\$(openssl rand -hex 16)"
  echo "  export CH_PASSWORD=\$(openssl rand -hex 16)"
  echo "  export MINIO_SECRET_KEY=\$(openssl rand -hex 16)"
  echo "  export LANGFUSE_NEXTAUTH_SECRET=\$(openssl rand -hex 32)"
  echo "  export LANGFUSE_ENCRYPTION_KEY=\$(openssl rand -hex 32)"
  echo "  export LANGFUSE_SALT=\$(openssl rand -hex 16)"
  exit 1
fi

if [[ "$VALIDATE_ONLY" == true ]]; then
  echo ""
  success "All required variables are set. Run without --validate to apply."
  exit 0
fi

# ── PHASE 04 — AUTOMATION SECRETS ─────────────────────────────
if [[ -z "$PHASE" || "$PHASE" == "04" ]]; then
  section "Phase 04 — Automation Secrets"

  if ! oc get namespace "aap" &>/dev/null; then
    error "Namespace 'aap' does not exist. Run Phase 01 first."
    exit 1
  fi

  # AAP admin password — used by AutomationController CR
  # ⚠️  This secret must exist BEFORE the AutomationController CR is applied
  apply_secret "aap-admin-secret" "aap" \
    --from-literal=password="${AAP_ADMIN_PASSWORD}"

  success "Phase 04 secrets applied"
fi

# ── PHASE 02 — DATA PIPELINE SECRETS ──────────────────────────
if [[ -z "$PHASE" || "$PHASE" == "02" ]]; then
  section "Phase 02 — Data Pipeline Secrets"

  # Verify namespaces exist
  for ns in mec-ai-data mec-ai-obs; do
    if ! oc get namespace "$ns" &>/dev/null; then
      error "Namespace '$ns' does not exist. Run Phase 01 first."
      exit 1
    fi
  done

  # Single langfuse-secrets — consumed by Langfuse Helm chart (mirrors auto-darknoc pattern)
  # ⚠️  ENCRYPTION_KEY and SALT must NEVER change after first deploy
  apply_secret "langfuse-secrets" "mec-ai-obs" \
    --from-literal=DATABASE_PASSWORD="${PG_PASSWORD}" \
    --from-literal=CLICKHOUSE_PASSWORD="${CH_PASSWORD}" \
    --from-literal=REDIS_PASSWORD="" \
    --from-literal=NEXTAUTH_SECRET="${LANGFUSE_NEXTAUTH_SECRET}" \
    --from-literal=SALT="${LANGFUSE_SALT}" \
    --from-literal=ENCRYPTION_KEY="${LANGFUSE_ENCRYPTION_KEY}" \
    --from-literal=S3_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}" \
    --from-literal=S3_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}"

  # PostgreSQL deployment credentials (separate secret for the postgresql pod)
  apply_secret "langfuse-db-secret" "mec-ai-obs" \
    --from-literal=db-user="langfuse" \
    --from-literal=db-password="${PG_PASSWORD}"

  # ClickHouse deployment credentials (separate secret for the clickhouse pod)
  apply_secret "langfuse-clickhouse-secret" "mec-ai-obs" \
    --from-literal=user="langfuse" \
    --from-literal=password="${CH_PASSWORD}"

  # MinIO credentials (used by minio-deployment)
  apply_secret "minio-secret" "mec-ai-data" \
    --from-literal=access-key="${MINIO_ACCESS_KEY}" \
    --from-literal=secret-key="${MINIO_SECRET_KEY}"

  success "Phase 02 secrets applied"
fi

# ── PHASE 03 — AI CORE SECRETS ────────────────────────────────
if [[ -z "$PHASE" || "$PHASE" == "03" ]]; then
  section "Phase 03 — AI Core Secrets"

  if ! oc get namespace "mec-content-ai" &>/dev/null; then
    error "Namespace 'mec-content-ai' does not exist. Run Phase 01 first."
    exit 1
  fi

  # KServe/vLLM data connection — must be in the same namespace as the InferenceService
  # In RHOAI 3.3, InferenceServices run in user namespaces (mec-content-ai), not redhat-ods-applications
  apply_secret "aws-connection-mec-models" "mec-content-ai" \
    --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}" \
    --from-literal=AWS_S3_ENDPOINT="http://minio.mec-ai-data.svc.cluster.local:9000" \
    --from-literal=AWS_DEFAULT_REGION="us-east-1" \
    --from-literal=AWS_S3_BUCKET="mec-models" \
    --from-literal=AWS_S3_USE_PATH_STYLE="true"

  success "Phase 03 secrets applied"
fi

# ── PHASE 05 — AGENT & MCP SECRETS ────────────────────────────
if [[ -z "$PHASE" || "$PHASE" == "05" ]]; then
  section "Phase 05 — Agent & MCP Secrets"

  if ! oc get namespace "mec-content-ai" &>/dev/null; then
    error "Namespace 'mec-content-ai' does not exist. Run Phase 01 first."
    exit 1
  fi

  # Slack credentials (used by mcp-slack server)
  apply_secret "slack-secret" "mec-content-ai" \
    --from-literal=bot-token="${SLACK_BOT_TOKEN}" \
    --from-literal=signing-secret="${SLACK_SIGNING_SECRET}"

  # Langfuse API credentials (used by agent for trace ingestion)
  # Get these from Langfuse UI after Phase 02 is deployed
  apply_secret "langfuse-api-secret" "mec-content-ai" \
    --from-literal=public-key="${LANGFUSE_PUBLIC_KEY}" \
    --from-literal=secret-key="${LANGFUSE_SECRET_KEY}" \
    --from-literal=host="${LANGFUSE_HOST:-https://langfuse.apps.cluster.local}"

  # AAP credentials (used by mcp-aap server)
  apply_secret "aap-secret" "mec-content-ai" \
    --from-literal=host="${AAP_HOST:-https://controller.aap.svc.cluster.local}" \
    --from-literal=token="${AAP_TOKEN}"

  # MinIO credentials for agent (model access)
  apply_secret "minio-agent-secret" "mec-content-ai" \
    --from-literal=access-key="${MINIO_ACCESS_KEY}" \
    --from-literal=secret-key="${MINIO_SECRET_KEY}" \
    --from-literal=endpoint="${MINIO_ENDPOINT:-http://minio.mec-ai-data.svc.cluster.local:9000}"

  success "Phase 05 secrets applied"
fi

# ── PHASE 07 — DASHBOARD SECRETS ──────────────────────────────
if [[ -z "$PHASE" || "$PHASE" == "07" ]]; then
  section "Phase 07 — Dashboard Secrets"

  if ! oc get namespace "mec-content-ai" &>/dev/null; then
    error "Namespace 'mec-content-ai' does not exist. Run Phase 01 first."
    exit 1
  fi

  # EdgeStream IQ backend needs Langfuse + AAP
  apply_secret "edgestream-iq-secret" "mec-content-ai" \
    --from-literal=langfuse-public-key="${LANGFUSE_PUBLIC_KEY}" \
    --from-literal=langfuse-secret-key="${LANGFUSE_SECRET_KEY}" \
    --from-literal=langfuse-host="${LANGFUSE_HOST:-https://langfuse.apps.cluster.local}" \
    --from-literal=aap-token="${AAP_TOKEN}" \
    --from-literal=aap-host="${AAP_HOST:-https://controller.aap.svc.cluster.local}"

  success "Phase 07 secrets applied"
fi

# ── DONE ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅  All secrets applied successfully.${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
if [[ -z "$PHASE" || "$PHASE" == "04" ]]; then
  echo "  • Apply Phase 04 CRs: oc apply -f implementation/phase-04-automation/aap/"
  echo "  • Wait for AAP pods: oc get pods -n aap"
  echo "  • Get AAP token from UI → save to env.sh as AAP_TOKEN"
  echo "  • Import playbooks and EDA rulebook (see COMMANDS.md Step 5 + 6)"
fi
if [[ -z "$PHASE" || "$PHASE" == "02" ]]; then
  echo "  • Apply Phase 02 YAMLs: oc apply -f implementation/phase-02-data-pipeline/"
  echo "  • After Langfuse is up, generate API keys in Langfuse UI"
  echo "  • Add LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY to env.sh"
  echo "  • Re-run: ./scripts/apply-secrets.sh --phase 05"
fi
if [[ -z "$PHASE" || "$PHASE" == "05" ]]; then
  echo "  • Apply Phase 05 YAMLs: oc apply -f implementation/phase-05-agent-mcp/"
fi
echo ""
echo -e "${CYAN}Verify secrets:${NC}"
echo "  oc get secrets -n mec-ai-obs"
echo "  oc get secrets -n mec-ai-data"
echo "  oc get secrets -n mec-content-ai"

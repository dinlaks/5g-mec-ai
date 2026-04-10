#!/usr/bin/env bash
# =============================================================================
# phase-06-deploy.sh — Far Edge (SNO nodes — telemetry, models, cache, EDA)
# Automates: implementation/phase-06-far-edge/COMMANDS.md
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

MEC_01_KUBECONFIG="${MEC_KUBECONFIG_MEC_STADIUM_01:-${HOME}/mec-rhdp/mec-stadium-01-kubeconfig}"
MEC_02_KUBECONFIG="${MEC_KUBECONFIG_MEC_STADIUM_02:-${HOME}/mec-rhdp/mec-stadium-02-kubeconfig}"

sno_oc() {
  # Run oc against a specific SNO cluster
  local kc=$1; shift
  KUBECONFIG="${kc}" oc "$@"
}

# =============================================================================
section "Pre-flight Checks"
# =============================================================================
if ! oc whoami &>/dev/null; then error "Not logged in to near-edge cluster."; exit 1; fi

[[ -f "$MEC_01_KUBECONFIG" ]] || { error "MEC kubeconfig not found: ${MEC_01_KUBECONFIG}"; exit 1; }
[[ -f "$MEC_02_KUBECONFIG" ]] || { error "MEC kubeconfig not found: ${MEC_02_KUBECONFIG}"; exit 1; }

sno_oc "${MEC_01_KUBECONFIG}" get nodes --no-headers 2>/dev/null | grep -q Ready || \
  { error "mec-stadium-01 SNO not reachable. Check kubeconfig."; exit 1; }
sno_oc "${MEC_02_KUBECONFIG}" get nodes --no-headers 2>/dev/null | grep -q Ready || \
  { error "mec-stadium-02 SNO not reachable. Check kubeconfig."; exit 1; }

oc get managedcluster mec-stadium-01 --no-headers 2>/dev/null | grep -q True || \
  warn "mec-stadium-01 not showing Available in ACM — ApplicationSet may not sync"
oc get managedcluster mec-stadium-02 --no-headers 2>/dev/null | grep -q True || \
  warn "mec-stadium-02 not showing Available in ACM — ApplicationSet may not sync"

success "Pre-checks passed — both SNO clusters reachable"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Verify ACM Cluster Status"
# =============================================================================
# Note: With SNO, Edge Manager (flightctl) is NOT needed.
# ACM + ArgoCD + Machine Config Operator handle everything flightctl would do.
# ACM manages the cluster, ArgoCD deploys workloads, MCO manages OS config.

for CLUSTER in mec-stadium-01 mec-stadium-02; do
  STATUS=$(oc get managedcluster "${CLUSTER}" \
    -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' \
    2>/dev/null)
  [[ "$STATUS" == "True" ]] && \
    success "ACM: ${CLUSTER} Available" || \
    warn "ACM: ${CLUSTER} not Available — check registration"
done

# =============================================================================
section "Step 2 — Upload LSTM Demo Model to MinIO"
# =============================================================================
info "Uploading placeholder LSTM model to MinIO..."
oc port-forward svc/minio 9000:9000 -n mec-ai-data &
PF_PID=$!
sleep 5

python3 - << 'PYEOF'
import boto3, os, struct

s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:9000",
    aws_access_key_id=os.getenv("MINIO_ACCESS_KEY", "mec-minio-admin"),
    aws_secret_access_key=os.getenv("MINIO_SECRET_KEY", ""),
)

# Create bucket if not exists
try:
    s3.create_bucket(Bucket="mec-models")
    print("Created bucket: mec-models")
except Exception:
    print("Bucket mec-models already exists")

# Upload placeholder model
s3.put_object(
    Bucket="mec-models",
    Key="lstm-demand/latest/model.onnx",
    Body=b"PLACEHOLDER_ONNX_MODEL",
)
print("Uploaded placeholder lstm-demand model — server will use rules-based fallback")
PYEOF

kill $PF_PID 2>/dev/null || true
success "LSTM placeholder model uploaded to MinIO"

# =============================================================================
section "Step 3 — Verify ACM ApplicationSet Synced to SNO Nodes"
# =============================================================================
wait_for "ArgoCD app for mec-stadium-01 exists" 120 \
  "oc get application far-edge-mec-stadium-01 -n openshift-gitops &>/dev/null"
wait_for "ArgoCD app for mec-stadium-02 exists" 120 \
  "oc get application far-edge-mec-stadium-02 -n openshift-gitops &>/dev/null"

# Give ArgoCD time to sync
info "Waiting for ArgoCD to sync far-edge workloads (up to 5 minutes)..."
wait_for "far-edge-mec-stadium-01 Synced" 300 \
  "oc get application far-edge-mec-stadium-01 -n openshift-gitops \
   -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"
wait_for "far-edge-mec-stadium-02 Synced" 300 \
  "oc get application far-edge-mec-stadium-02 -n openshift-gitops \
   -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"
success "ApplicationSet synced to both SNO nodes"

# =============================================================================
section "Step 4 — Verify Pods on SNO Nodes"
# =============================================================================
EXPECTED_PODS="telemetry-collector demand-predictor lstm-demand-predictor abr-policy-engine cache-manager eda-receiver"

for SITE_INFO in "stadium-01:${MEC_01_KUBECONFIG}" "stadium-02:${MEC_02_KUBECONFIG}"; do
  SITE="${SITE_INFO%%:*}"
  KC="${SITE_INFO##*:}"

  info "Checking pods on mec-${SITE}..."
  wait_for "All pods Running on mec-${SITE}" 300 \
    "[[ \$(KUBECONFIG=${KC} oc get pods -n far-edge-mec --no-headers 2>/dev/null | grep -c Running) -ge 6 ]]"

  sno_oc "${KC}" get pods -n far-edge-mec --no-headers 2>/dev/null | \
    awk '{printf "  mec-%-12s  %-45s  %s\n", "'${SITE}'", $1, $3}'
done
success "All far-edge pods running"

# =============================================================================
section "Step 5 — Health Checks"
# =============================================================================
info "Port-forwarding services on mec-stadium-01 for health checks..."
sno_oc "${MEC_01_KUBECONFIG}" port-forward svc/cache-manager       8091:8080 -n far-edge-mec &
sno_oc "${MEC_01_KUBECONFIG}" port-forward svc/lstm-demand-predictor 8092:8080 -n far-edge-mec &
sno_oc "${MEC_01_KUBECONFIG}" port-forward svc/abr-policy-engine    8093:8080 -n far-edge-mec &
sleep 8

curl -s http://localhost:8091/health | grep -q ok && \
  success "cache-manager healthy" || warn "cache-manager health check failed"
curl -s http://localhost:8092/v1/models/lstm-demand | grep -q ready && \
  success "lstm-demand-predictor healthy" || warn "lstm-demand-predictor health check failed"
curl -s http://localhost:8093/v1/models/abr-policy | grep -q ready && \
  success "abr-policy-engine healthy" || warn "abr-policy-engine health check failed"

# Test ABR quality decision
ABR_RESP=$(curl -s -X POST http://localhost:8093/v1/models/abr-policy:predict \
  -H "Content-Type: application/json" \
  -d '{"subscriber_id":"test","subscriber_tier":"premium","signal_strength_dbm":-75}' 2>/dev/null)
echo "${ABR_RESP}" | grep -q quality_tier && \
  success "ABR decision: $(echo ${ABR_RESP} | jq -r '.outputs[0].data[0]')" || \
  warn "ABR decision test failed"

# Kill port-forwards
kill $(jobs -p) 2>/dev/null || true

# =============================================================================
section "Step 6 — Verify Kafka Telemetry Flowing"
# =============================================================================
info "Consuming from content.requests.live (waiting up to 60 seconds)..."
MSG=$(oc run kafka-check-${RANDOM} --rm -it --restart=Never \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic content.requests.live \
  --max-messages 1 --timeout-ms 60000 2>/dev/null)

[[ -n "$MSG" ]] && success "Telemetry flowing on content.requests.live" || \
  warn "No telemetry messages yet — telemetry-collector may still be starting"

info "Consuming from demand.predictions (waiting up to 120 seconds for first prediction)..."
PRED=$(oc run kafka-pred-${RANDOM} --rm -it --restart=Never \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions \
  --max-messages 1 --timeout-ms 120000 2>/dev/null)

[[ -n "$PRED" ]] && success "Demand predictions flowing: $(echo $PRED | jq -r '{site:.mec_site_id,content:.content_id,confidence:.confidence}' 2>/dev/null || echo $PRED)" || \
  warn "No demand predictions yet — demand-predictor needs ~60s of telemetry to start predicting"

# =============================================================================
section "Summary"
# =============================================================================
echo ""
echo -e "${BOLD}Far Edge Status:${NC}"
for SITE_INFO in "stadium-01:${MEC_01_KUBECONFIG}" "stadium-02:${MEC_02_KUBECONFIG}"; do
  SITE="${SITE_INFO%%:*}"; KC="${SITE_INFO##*:}"
  RUNNING=$(sno_oc "${KC}" get pods -n far-edge-mec --no-headers 2>/dev/null | grep -c Running || echo 0)
  echo -e "  mec-${SITE}: ${RUNNING}/6 pods Running"
done

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 06 complete.${NC}"
echo -e "    Next: ./scripts/phase-07-deploy.sh  (when Phase 07 is built)"

#!/usr/bin/env bash
# =============================================================================
# phase-01-deploy.sh — Foundation (Operators + GitOps + ACM)
# 5G MEC Content Intelligence
#
# Automates: implementation/phase-01-foundation/COMMANDS.md
# Idempotent — safe to re-run. Skips already-complete steps.
#
# Usage:
#   source configs/near-edge/env.sh
#   ./scripts/phase-01-deploy.sh
#   ./scripts/phase-01-deploy.sh --validate    # pre-checks only
#   ./scripts/phase-01-deploy.sh --dry-run
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DRY_RUN=false; VALIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)  DRY_RUN=true; shift ;;
    --validate) VALIDATE_ONLY=true; shift ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; exit 1 ;;
  esac
done

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }
run()     { [[ "$DRY_RUN" == true ]] && { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; return; }; eval "$*"; }

# Helper: get installed or current CSV for a subscription
_get_csv() {
  local sub=$1 ns=$2
  local csv
  csv=$(oc get subscriptions.operators.coreos.com "$sub" -n "$ns" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  [[ -z "$csv" ]] && csv=$(oc get subscriptions.operators.coreos.com "$sub" -n "$ns" \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  echo "$csv"
}

# Apply subscription only — do NOT wait. Skips if already Succeeded.
# Usage: ensure_operator "desc" "sub-name" "namespace" "yaml"
ensure_operator() {
  local desc=$1 sub=$2 ns=$3 yaml=$4
  local csv phase
  csv=$(_get_csv "$sub" "$ns")
  if [[ -n "$csv" ]]; then
    phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Succeeded" ]]; then
      success "${desc} already installed (${csv}) — skipping"
      return
    fi
  fi
  [[ "$DRY_RUN" == true ]] && { echo -e "${YELLOW}[DRY-RUN]${NC} oc apply -f ${yaml}"; return; }
  oc apply -f "${yaml}"
  info "${desc} subscription applied"
}

# Wait for subscription CSV to reach Succeeded. Skips immediately if already done.
# Usage: wait_operator "desc" "sub-name" "namespace" "timeout_secs"
wait_operator() {
  local desc=$1 sub=$2 ns=$3 timeout=$4
  local csv phase
  csv=$(_get_csv "$sub" "$ns")
  if [[ -n "$csv" ]]; then
    phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Succeeded" ]]; then
      success "${desc} ready (${csv})"
      return
    fi
  fi
  info "Waiting: ${desc} ready (max ${timeout}s)..."
  local elapsed=0
  while true; do
    csv=$(_get_csv "$sub" "$ns")
    if [[ -n "$csv" ]]; then
      phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [[ "$phase" == "Succeeded" ]]; then
        echo ""; success "${desc} ready (${csv})"; return
      fi
    fi
    sleep 15; elapsed=$((elapsed+15))
    [[ $elapsed -ge $timeout ]] && { echo ""; error "Timeout waiting for ${desc}"; exit 1; }
    echo -n "."
  done
}

# Apply a CR only if it does not already exist.
# Usage: apply_cr "desc" "kind" "name" "-n namespace" "yaml"
#        Pass "" as ns_arg for cluster-scoped resources.
apply_cr() {
  local desc=$1 kind=$2 name=$3 ns_arg=$4 yaml=$5
  if oc get "$kind" "$name" ${ns_arg} --no-headers 2>/dev/null | grep .; then > /dev/null
    info "${desc} already exists — skipping"
    return
  fi
  run "oc apply -f ${yaml}"
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
if ! oc whoami &>/dev/null; then
  error "Not logged into OpenShift. Run: oc login --server=<url> --username=kubeadmin"
  exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"
[[ "$VALIDATE_ONLY" == true ]] && { success "Validate-only — done."; exit 0; }

# =============================================================================
section "Step 1 — Wave 0 Operators (cert-manager, NFD, GPU) — parallel install"
# =============================================================================
# Apply all wave-0 subscriptions at once so operators install in parallel
ensure_operator "cert-manager" "openshift-cert-manager-operator" "cert-manager-operator" \
  "implementation/phase-01-foundation/operators/wave-0-certmanager-subscription.yaml"
ensure_operator "NFD" "nfd" "openshift-nfd" \
  "implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml"
ensure_operator "GPU operator" "gpu-operator-certified" "gpu-operator" \
  "implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml"

# Wait for all wave-0 CSVs
wait_operator "cert-manager" "openshift-cert-manager-operator" "cert-manager-operator" 300
wait_operator "NFD"          "nfd"                             "openshift-nfd"          300
wait_operator "GPU operator" "gpu-operator-certified"          "gpu-operator"           300

# Apply CRs after operators are ready
apply_cr "NFD instance"    "NodeFeatureDiscovery" "nfd-instance"      "-n openshift-nfd" \
  "implementation/phase-01-foundation/operators/wave-0-nfd-instance.yaml"
apply_cr "GPU ClusterPolicy" "ClusterPolicy"      "gpu-cluster-policy" "" \
  "implementation/phase-01-foundation/operators/wave-0-gpu-cluster-policy.yaml"

success "Wave 0 operators ready"

# =============================================================================
section "Step 2 — Bootstrap OpenShift GitOps (ArgoCD)"
# =============================================================================
ensure_operator "GitOps operator" "openshift-gitops-operator" "openshift-gitops-operator" \
  "gitops/bootstrap/01-gitops-operator.yaml"
wait_operator "GitOps operator" "openshift-gitops-operator" "openshift-gitops-operator" 300

apply_cr "ArgoCD instance" "ArgoCD"      "openshift-gitops" "-n openshift-gitops" \
  "gitops/bootstrap/02-argocd-instance.yaml"
apply_cr "ArgoCD project"  "AppProject"  "mec-content-ai"   "-n openshift-gitops" \
  "gitops/bootstrap/03-argocd-project.yaml"
wait_for "ArgoCD server running" 300 \
  "oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-server --no-headers 2>/dev/null | grep Running > /dev/null"

# Fix argocd-cm: operator generates broken 'cnectors' key and omits 'url' field.
# Wait 15s for operator to reconcile first, then overwrite with correct config.
info "Patching argocd-cm to fix OpenShift OAuth (operator typo workaround)..."
APPS_DOMAIN=$(echo "${NEAR_EDGE_API}" | sed 's|https://api\.||' | sed 's|:6443||')
ARGOCD_URL="https://openshift-gitops-server-openshift-gitops.${APPS_DOMAIN}"
OAUTH_URL="https://oauth-openshift.${APPS_DOMAIN}"
sleep 15
[[ "$DRY_RUN" == false ]] && {
  oc patch cm argocd-cm -n openshift-gitops --type merge \
    -p "{\"data\":{\"url\":\"${ARGOCD_URL}\"}}"
  oc patch cm argocd-cm -n openshift-gitops --type merge \
    -p "{\"data\":{\"dex.config\":\"connectors:\\n- type: openshift\\n  id: openshift\\n  name: OpenShift\\n  config:\\n    issuer: ${OAUTH_URL}\\n    clientID: system:serviceaccount:openshift-gitops:openshift-gitops-argocd-dex-server\\n    clientSecret: \\\$oidc.dex.clientSecret\\n    insecureCA: true\\n    groups: []\\n\"}}"
  oc rollout restart deployment openshift-gitops-dex-server openshift-gitops-server -n openshift-gitops
  oc rollout status deployment openshift-gitops-dex-server openshift-gitops-server -n openshift-gitops
}
success "GitOps bootstrapped"

# =============================================================================
section "Step 3a — Wave 1 Prerequisites (Service Mesh, Serverless, Kafka, AAP, ACM) — parallel install"
# =============================================================================
# Apply all subscriptions at once so operators install in parallel
ensure_operator "Service Mesh 3.x"   "servicemeshoperator3"                 "openshift-operators"      \
  "implementation/phase-01-foundation/operators/wave-1-servicemesh-subscription.yaml"
ensure_operator "Serverless"          "serverless-operator"                  "openshift-serverless"     \
  "implementation/phase-01-foundation/operators/wave-1-serverless-subscription.yaml"
ensure_operator "Kafka (AMQ Streams)" "amq-streams"                          "amq-streams"              \
  "implementation/phase-01-foundation/operators/wave-1-kafka-subscription.yaml"
ensure_operator "AAP"                 "ansible-automation-platform-operator" "aap"                      \
  "implementation/phase-01-foundation/operators/wave-1-aap-subscription.yaml"
ensure_operator "ACM"                 "advanced-cluster-management"          "open-cluster-management"  \
  "implementation/phase-01-foundation/operators/wave-1-acm-subscription.yaml"

# Wait for all wave-1a CSVs
wait_operator "Service Mesh 3.x"   "servicemeshoperator3"                 "openshift-operators"     300
wait_operator "Serverless"         "serverless-operator"                  "openshift-serverless"    300
wait_operator "Kafka (AMQ Streams)" "amq-streams"                         "amq-streams"             300
wait_operator "AAP"                "ansible-automation-platform-operator" "aap"                     300
wait_operator "ACM"                "advanced-cluster-management"          "open-cluster-management" 600

apply_cr "MultiClusterHub" "MultiClusterHub" "multiclusterhub" "-n open-cluster-management" \
  "implementation/phase-01-foundation/operators/wave-1-acm-multiclusterhub.yaml"
wait_for "ACM MultiClusterHub running" 600 \
  "oc get multiclusterhub -n open-cluster-management --no-headers 2>/dev/null | grep Running > /dev/null"

# =============================================================================
section "Step 3b — RHOAI 3.x (requires Service Mesh 3.x + Serverless)"
# =============================================================================
ensure_operator "RHOAI" "rhods-operator" "redhat-ods-operator" \
  "implementation/phase-01-foundation/operators/wave-1-rhoai-subscription.yaml"
wait_operator "RHOAI" "rhods-operator" "redhat-ods-operator" 600

wait_for "DataScienceCluster CRD ready" 120 \
  "oc get crd datascienceclusters.datasciencecluster.opendatahub.io --no-headers 2>/dev/null | grep . > /dev/null"
wait_for "DSCInitialization CRD ready" 60 \
  "oc get crd dscinitializations.dscinitialization.opendatahub.io --no-headers 2>/dev/null | grep . > /dev/null"
apply_cr "DSCInitialization" "DSCInitialization" "default-dsci" "" \
  "implementation/phase-01-foundation/operators/wave-1-rhoai-dsciinitialization.yaml"
apply_cr "DataScienceCluster" "DataScienceCluster" "default-dsc" "" \
  "implementation/phase-01-foundation/operators/wave-1-rhoai-datasciencecluster.yaml"

wait_for "RHOAI DataScienceCluster Ready" 300 \
  "oc get datasciencecluster default-dsc \
   -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep True > /dev/null"

step "Enabling RHOAI dashboard features (GenAI Studio, Evaluation, Feature Store, Registries)"
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge -p '{
    "spec": {
      "dashboardConfig": {
        "genAiStudio": true,
        "disableLLMd": false,
        "disableLMEval": false,
        "disableTrustyBiasMetrics": false,
        "disableFeatureStore": false,
        "disableModelRegistry": false,
        "disableModelCatalog": false,
        "disablePipelines": false
      }
    }
  }' 2>&1 && success "RHOAI dashboard features enabled" || \
  warn "OdhDashboardConfig patch failed — apply manually after RHOAI is Ready"

success "Wave 1 operators ready"

# =============================================================================
section "Step 4 — Create Namespaces"
# =============================================================================
run "oc apply -f implementation/phase-01-foundation/namespaces/namespaces.yaml"
for ns in mec-content-ai mec-ai-data mec-ai-obs far-edge-mec; do
  wait_for "Namespace ${ns} active" 60 "oc get namespace ${ns} --no-headers 2>/dev/null | grep Active > /dev/null"
done
success "Namespaces created"

# =============================================================================
section "Step 5 — Configure ACM + GitOps Integration"
# =============================================================================
run "oc apply -f gitops/acm/managedclusterset.yaml"
run "oc apply -f gitops/acm/clusterset-binding.yaml"
run "oc apply -f gitops/acm/placement-near-edge.yaml"
run "oc apply -f gitops/acm/placement-far-edge.yaml"
run "oc apply -f gitops/acm/gitopscluster.yaml"
success "ACM + GitOps integration configured"

# =============================================================================
section "Step 6 — Deploy ArgoCD Applications (GitOps takes over)"
# =============================================================================
run "oc apply -f gitops/apps/near-edge/"
run "oc apply -f gitops/apps/far-edge/"
wait_for "ArgoCD apps created" 120 \
  "oc get applications -n openshift-gitops --no-headers 2>/dev/null | wc -l | grep -v '^0$' > /dev/null"
success "ArgoCD Applications deployed"

# =============================================================================
section "Validation"
# =============================================================================
echo ""
oc get csv -A --no-headers 2>/dev/null | \
  grep -E "cert-manager|nfd|gpu|rhods|amq|aap|advanced-cluster|gitops|servicemesh|serverless" | \
  awk '{printf "%-50s %s\n", $2, $7}'
echo ""
oc get namespaces | grep mec
echo ""
oc get applications -n openshift-gitops --no-headers 2>/dev/null | awk '{print $1, $2}'

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 01 complete.${NC}"
echo -e "    Next: ./scripts/phase-02-deploy.sh"

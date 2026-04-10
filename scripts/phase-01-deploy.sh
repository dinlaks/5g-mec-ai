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
section "Step 1 — Wave 0 Operators (cert-manager, NFD, GPU, GitOps)"
# =============================================================================
for f in \
  implementation/phase-01-foundation/operators/wave-0-certmanager-subscription.yaml \
  implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml \
  implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml; do
  run "oc apply -f ${f}"
done

wait_for "cert-manager pods running" 300 \
  "oc get pods -n cert-manager-operator --no-headers 2>/dev/null | grep -q Running"
wait_for "NFD pods running" 300 \
  "oc get pods -n openshift-nfd --no-headers 2>/dev/null | grep -q Running"
success "Wave 0 operators ready"

# =============================================================================
section "Step 2 — Bootstrap OpenShift GitOps (ArgoCD)"
# =============================================================================
run "oc apply -f gitops/bootstrap/01-gitops-operator.yaml"
wait_for "GitOps operator ready" 300 \
  "oc get csv -n openshift-gitops-operator --no-headers 2>/dev/null | grep -q Succeeded"

run "oc apply -f gitops/bootstrap/02-argocd-instance.yaml"
run "oc apply -f gitops/bootstrap/03-argocd-project.yaml"
wait_for "ArgoCD server running" 300 \
  "oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-server --no-headers 2>/dev/null | grep -q Running"
success "GitOps bootstrapped"

# =============================================================================
section "Step 3 — Wave 1 Operators (RHOAI, Kafka, AAP, ACM)"
# =============================================================================
for f in \
  implementation/phase-01-foundation/operators/wave-1-rhoai-subscription.yaml \
  implementation/phase-01-foundation/operators/wave-1-kafka-subscription.yaml \
  implementation/phase-01-foundation/operators/wave-1-aap-subscription.yaml \
  implementation/phase-01-foundation/operators/wave-1-acm-subscription.yaml \
  implementation/phase-01-foundation/operators/wave-1-gitops-subscription.yaml; do
  run "oc apply -f ${f}"
done

info "Waiting for wave 1 operators (this takes 5–10 minutes)..."
wait_for "RHOAI operator ready"  600 "oc get csv -n redhat-ods-operator    --no-headers 2>/dev/null | grep -q Succeeded"
wait_for "Kafka operator ready"  300 "oc get csv -n amq-streams             --no-headers 2>/dev/null | grep -q Succeeded"
wait_for "AAP operator ready"    300 "oc get csv -n aap                     --no-headers 2>/dev/null | grep -q Succeeded"
wait_for "ACM operator ready"    600 "oc get csv -n open-cluster-management --no-headers 2>/dev/null | grep -q Succeeded"
wait_for "ACM MultiClusterHub running" 600 \
  "oc get multiclusterhub -n open-cluster-management --no-headers 2>/dev/null | grep -q Running"
success "Wave 1 operators ready"

# =============================================================================
section "Step 4 — Create Namespaces"
# =============================================================================
run "oc apply -f implementation/phase-01-foundation/namespaces/namespaces.yaml"
for ns in mec-content-ai mec-ai-data mec-ai-obs far-edge-mec; do
  wait_for "Namespace ${ns} active" 60 "oc get namespace ${ns} --no-headers 2>/dev/null | grep -q Active"
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
  "oc get applications -n openshift-gitops --no-headers 2>/dev/null | wc -l | grep -qv '^0$'"
success "ArgoCD Applications deployed"

# =============================================================================
section "Validation"
# =============================================================================
echo ""
oc get csv -A --no-headers 2>/dev/null | grep -E "cert-manager|nfd|gpu|rhoai|amq|aap|acm|gitops" | \
  awk '{printf "%-50s %s\n", $2, $7}'
echo ""
oc get namespaces | grep mec
echo ""
oc get applications -n openshift-gitops --no-headers 2>/dev/null | awk '{print $1, $2}'

echo ""
echo -e "${GREEN}${BOLD}✅  Phase 01 complete.${NC}"
echo -e "    Next: ./scripts/phase-02-deploy.sh"

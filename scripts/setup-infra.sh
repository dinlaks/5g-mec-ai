#!/usr/bin/env bash
# =============================================================================
# setup-infra.sh — Full Infrastructure Bootstrap
# 5G MEC Content Intelligence — RHDP OpenShift 4.21 + OpenShift SNO Far Edge
#
# Automates everything in docs/deployment/aws-infra-setup.md:
#   1. Pre-flight checks (oc login, aws credentials, tools)
#   2. Capture cluster values (INFRA_ID, VPC_ID, apps domain)
#   3. Add GPU worker node (g5.2xlarge) via MachineSet
#   4. Install NFD + GPU Operator → wait for GPU detected
#   5. Deploy 2 × OpenShift SNO clusters (MEC nodes) via openshift-install
#   6. Register both MEC SNO clusters with ACM
#   7. Verify full connectivity
#   8. Write populated env.sh
#
# Usage:
#   ./scripts/setup-infra.sh                        # full run
#   ./scripts/setup-infra.sh --validate             # pre-flight only
#   ./scripts/setup-infra.sh --skip-gpu             # skip GPU node (no quota yet)
#   ./scripts/setup-infra.sh --skip-mec             # skip MEC SNO setup
#   ./scripts/setup-infra.sh --dry-run              # show what would happen
#
# Prerequisites:
#   - oc CLI logged in to RHDP cluster (oc login ...)
#   - AWS CLI configured with RHDP credentials (aws configure --profile rhdp)
#   - openshift-install CLI available (for SNO cluster creation)
#   - Red Hat pull secret at ~/.openshift/pull-secret.json
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Args ──────────────────────────────────────────────────────────────────────
SKIP_GPU=false
SKIP_MEC=false
DRY_RUN=false
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-gpu)      SKIP_GPU=true; shift ;;
    --skip-mec)      SKIP_MEC=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --validate)      VALIDATE_ONLY=true; shift ;;
    *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"; }
step()    { echo -e "\n${BOLD}── $* ${NC}"; }

run() {
  # Wrapper: print command, skip if dry-run
  local cmd="$*"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: ${cmd}"
    return 0
  fi
  eval "$cmd"
}

wait_for() {
  # wait_for <description> <max_seconds> <check_command>
  local desc=$1
  local max=$2
  local cmd=$3
  local elapsed=0
  local interval=15

  info "Waiting for: ${desc} (max ${max}s)..."
  while ! eval "$cmd" &>/dev/null; do
    sleep $interval
    elapsed=$((elapsed + interval))
    if [[ $elapsed -ge $max ]]; then
      error "Timed out waiting for: ${desc}"
      exit 1
    fi
    echo -n "."
  done
  echo ""
  success "${desc} — ready"
}


# ── State directory ───────────────────────────────────────────────────────────
STATE_DIR="${HOME}/mec-rhdp"
mkdir -p "${STATE_DIR}"
LOG_FILE="${STATE_DIR}/setup-infra.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║  5G MEC Content Intelligence — Infra Setup  ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo -e "  Log: ${LOG_FILE}"
echo -e "  Dry-run: ${DRY_RUN} | Skip GPU: ${SKIP_GPU} | Skip MEC: ${SKIP_MEC}"
echo ""

# =============================================================================
# SECTION 1 — PRE-FLIGHT CHECKS
# =============================================================================
section "Pre-flight Checks"

ERRORS=0

step "Checking required tools"
for tool in oc aws ssh scp jq; do
  if command -v "$tool" &>/dev/null; then
    success "$tool found: $(command -v $tool)"
  else
    error "$tool not found — install it before running this script"
    ((ERRORS++))
  fi
done

step "Checking SSH key"
if [[ -f "${HOME}/.ssh/mec-key" ]]; then
  success "SSH key found: ~/.ssh/mec-key"
else
  error "SSH key not found. Run: ssh-keygen -t ed25519 -f ~/.ssh/mec-key -N ''"
  ((ERRORS++))
fi

step "Checking Red Hat pull secret"
if [[ -f "${HOME}/.openshift/pull-secret.json" ]]; then
  success "Pull secret found: ~/.openshift/pull-secret.json"
else
  error "Pull secret not found at ~/.openshift/pull-secret.json"
  error "Download from: https://console.redhat.com/openshift/downloads"
  ((ERRORS++))
fi

step "Checking openshift-install CLI"
if command -v openshift-install &>/dev/null; then
  success "openshift-install found: $(openshift-install version 2>/dev/null | head -1)"
else
  warn "openshift-install not found — required for SNO MEC node setup (--skip-mec to bypass)"
fi

step "Checking oc login"
if oc whoami &>/dev/null; then
  OC_USER=$(oc whoami)
  OC_SERVER=$(oc whoami --show-server)
  success "Logged in as: ${OC_USER} on ${OC_SERVER}"
else
  error "Not logged into OpenShift. Run: oc login --server=<api-url> --username=kubeadmin --password=<password>"
  ((ERRORS++))
fi

step "Checking AWS credentials"
if aws sts get-caller-identity &>/dev/null; then
  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  success "AWS credentials valid — account: ${AWS_ACCOUNT}"
else
  error "AWS credentials not configured. Run: aws configure"
  ((ERRORS++))
fi

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  error "${ERRORS} pre-flight check(s) failed. Fix the above and re-run."
  exit 1
fi

success "All pre-flight checks passed"

[[ "$VALIDATE_ONLY" == true ]] && { echo ""; success "Validate-only mode — exiting."; exit 0; }

# =============================================================================
# SECTION 2 — CAPTURE CLUSTER VALUES
# =============================================================================
section "Capturing Cluster Values"

step "Saving near-edge kubeconfig"
oc config view --raw > "${STATE_DIR}/near-edge-kubeconfig"
chmod 600 "${STATE_DIR}/near-edge-kubeconfig"
success "Kubeconfig saved: ${STATE_DIR}/near-edge-kubeconfig"

step "Reading cluster metadata"
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
APPS_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')

success "Infrastructure ID: ${INFRA_ID}"
success "Apps domain:       ${APPS_DOMAIN}"
success "AWS region:        ${AWS_REGION}"

step "Getting VPC ID"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region "${AWS_REGION}")

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  error "Could not find VPC for cluster ${INFRA_ID}. Is AWS configured for the right account?"
  exit 1
fi
success "VPC ID: ${VPC_ID}"

step "Getting reference worker MachineSet"
WORKER_MS=$(oc get machinesets -n openshift-machine-api \
  -o jsonpath='{.items[0].metadata.name}')
AMI_ID=$(oc get machineset "${WORKER_MS}" -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.ami.id}')
AZ=$(oc get machineset "${WORKER_MS}" -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
WORKER_SG=$(oc get machineset "${WORKER_MS}" -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.securityGroups[0].filters[0].values[0]}')

success "Worker MachineSet: ${WORKER_MS}"
success "AMI ID:            ${AMI_ID}"
success "AZ:                ${AZ}"
success "Worker SG:         ${WORKER_SG}"

step "Getting OCP worker node IP (used as SSH jump host)"
OCP_JUMP_IP=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
success "OCP jump host IP: ${OCP_JUMP_IP}"

step "Getting private subnet for far-edge EC2s"
FAR_EDGE_SUBNET=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=*private*" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "${AWS_REGION}")
success "Far edge subnet: ${FAR_EDGE_SUBNET}"

# =============================================================================
# SECTION 3 — GPU WORKER NODE
# =============================================================================
if [[ "$SKIP_GPU" == false ]]; then
  section "Adding GPU Worker Node (g5.2xlarge)"

  GPU_MS_NAME="${INFRA_ID}-gpu-${AZ}"

  # Check if MachineSet already exists
  if oc get machineset "${GPU_MS_NAME}" -n openshift-machine-api &>/dev/null; then
    warn "MachineSet ${GPU_MS_NAME} already exists — skipping creation"
  else
    step "Creating GPU MachineSet"
    cat > /tmp/gpu-machineset.yaml << EOF
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${GPU_MS_NAME}
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
      machine.openshift.io/cluster-api-machineset: ${GPU_MS_NAME}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${GPU_MS_NAME}
    spec:
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AWSMachineProviderConfig
          ami:
            id: ${AMI_ID}
          instanceType: g5.2xlarge
          placement:
            availabilityZone: ${AZ}
            region: ${AWS_REGION}
          subnet:
            filters:
              - name: tag:Name
                values:
                  - ${INFRA_ID}-subnet-private-${AZ}
          securityGroups:
            - filters:
                - name: tag:Name
                  values:
                    - ${WORKER_SG}
          iamInstanceProfile:
            id: ${INFRA_ID}-worker-profile
          userDataSecret:
            name: worker-user-data
          credentialsSecret:
            name: aws-cloud-credentials
          blockDevices:
            - ebs:
                iops: 3000
                volumeSize: 120
                volumeType: gp3
          tags:
            - name: kubernetes.io/cluster/${INFRA_ID}
              value: owned
            - name: project
              value: mec-content-ai
            - name: node-role
              value: gpu-worker
      metadata:
        labels:
          node-role.kubernetes.io/worker: ""
          node-role.kubernetes.io/gpu-worker: ""
EOF
    run "oc apply -f /tmp/gpu-machineset.yaml"
    success "GPU MachineSet created: ${GPU_MS_NAME}"
  fi

  step "Waiting for GPU node to join cluster (up to 15 minutes)"
  wait_for "GPU Machine in Running state" 900 \
    "oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=${GPU_MS_NAME} -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running"

  wait_for "GPU Node in Ready state" 300 \
    "oc get nodes -l node-role.kubernetes.io/gpu-worker --no-headers 2>/dev/null | grep -q Ready"

  step "Installing NFD and GPU Operator"
  run "oc apply -f implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml"
  run "oc apply -f implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml"

  wait_for "NFD operator available" 300 \
    "oc get deployment nfd-controller-manager -n openshift-nfd --no-headers 2>/dev/null | grep -q '1/1'"

  wait_for "GPU detected on node (nvidia.com/gpu)" 600 \
    "oc describe node -l node-role.kubernetes.io/gpu-worker 2>/dev/null | grep -q 'nvidia.com/gpu: 1'"

  success "GPU worker node ready with NVIDIA A10G detected"
else
  warn "Skipping GPU node setup (--skip-gpu)"
fi

# =============================================================================
# SECTION 4 — DEPLOY SNO FAR-EDGE CLUSTERS
# =============================================================================
if [[ "$SKIP_MEC" == false ]]; then
  section "Deploying OpenShift SNO Far-Edge Clusters"

  # Verify openshift-install is available
  if ! command -v openshift-install &>/dev/null; then
    error "openshift-install not found. Install it:"
    error "  curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.21.0/openshift-install-mac.tar.gz"
    error "  tar xzf openshift-install-mac.tar.gz && sudo mv openshift-install /usr/local/bin/"
    exit 1
  fi
  success "openshift-install found: $(openshift-install version | head -1)"

  # Get the base domain from the near-edge cluster (SNO will use a subdomain)
  BASE_DOMAIN=$(oc get dns.config cluster -o jsonpath='{.spec.baseDomain}')
  PULL_SECRET=$(cat "${HOME}/.openshift/pull-secret.json" | tr -d '\n')
  SSH_PUB_KEY=$(cat "${HOME}/.ssh/mec-key.pub")

  success "Base domain: ${BASE_DOMAIN}"

  MEC_01_IP="<set-after-install>"
  MEC_02_IP="<set-after-install>"

  # =============================================================================
  # SECTION 5 — INSTALL SNO (runs openshift-install for each MEC site)
  # =============================================================================
  section "Installing OpenShift SNO on MEC Nodes (takes ~45 min each)"

  info "SNO installs run sequentially. Each takes ~45 minutes unattended."
  info "Total time for 2 SNO nodes: ~90 minutes."

  for SITE in stadium-01 stadium-02; do
    CLUSTER_NAME="mec-${SITE}"
    INSTALL_DIR="${STATE_DIR}/sno-${SITE}"

    # Check if already installed (kubeconfig exists and cluster is responding)
    if [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
      if KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig" oc get nodes &>/dev/null; then
        warn "SNO cluster ${CLUSTER_NAME} already installed and responding — skipping"
        continue
      fi
    fi

    step "Creating install-config for ${CLUSTER_NAME}"
    mkdir -p "${INSTALL_DIR}"

    cat > "${INSTALL_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}

# SNO: 0 workers, 1 control plane (the single node acts as both)
compute:
  - name: worker
    replicas: 0

controlPlane:
  name: master
  replicas: 1
  platform:
    aws:
      type: m5.2xlarge          # 8 vCPU, 32GB RAM — SNO minimum
      rootVolume:
        iops: 3000
        size: 120
        type: gp3
      zones:
        - ${AZ}

networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  serviceNetwork:
    - 172.30.0.0/16

platform:
  aws:
    region: ${AWS_REGION}
    subnets:
      - ${FAR_EDGE_SUBNET}      # reuse RHDP VPC private subnet
    userTags:
      project: mec-content-ai
      role: far-edge-sno
      site: ${SITE}

pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUB_KEY}
EOF

    success "install-config.yaml created for ${CLUSTER_NAME}"

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY-RUN] Would run: openshift-install create cluster --dir ${INSTALL_DIR}"
      continue
    fi

    step "Running openshift-install for ${CLUSTER_NAME} (this takes ~45 minutes)..."
    openshift-install create cluster \
      --dir "${INSTALL_DIR}" \
      --log-level=info 2>&1 | tee "${INSTALL_DIR}/install.log" | \
      grep -E "INFO|WARN|ERROR|level=info|level=warn|level=error" | tail -20

    if [[ $? -ne 0 ]]; then
      error "SNO install failed for ${CLUSTER_NAME}. Check: ${INSTALL_DIR}/install.log"
      error "Also check: ${INSTALL_DIR}/.openshift_install.log"
      exit 1
    fi

    success "SNO cluster ${CLUSTER_NAME} installed"

    # Save kubeconfig
    KUBECONFIG_PATH="${STATE_DIR}/${CLUSTER_NAME}-kubeconfig"
    cp "${INSTALL_DIR}/auth/kubeconfig" "${KUBECONFIG_PATH}"
    chmod 600 "${KUBECONFIG_PATH}"
    success "Kubeconfig saved: ${KUBECONFIG_PATH}"

    # Get SNO node IP from AWS (installer tagged it)
    SNO_INSTANCE_ID=$(aws ec2 describe-instances \
      --filters \
        "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
        "Name=instance-state-name,Values=running" \
      --query "Reservations[0].Instances[0].InstanceId" \
      --output text --region "${AWS_REGION}")

    SNO_IP=$(aws ec2 describe-instances \
      --instance-ids "${SNO_INSTANCE_ID}" \
      --query "Reservations[0].Instances[0].PrivateIpAddress" \
      --output text --region "${AWS_REGION}")

    if [[ "$SITE" == "stadium-01" ]]; then MEC_01_IP="${SNO_IP}"; fi
    if [[ "$SITE" == "stadium-02" ]]; then MEC_02_IP="${SNO_IP}"; fi
    success "${CLUSTER_NAME} node IP: ${SNO_IP}"
  done

  # Reload kubeconfigs after all installs
  if [[ -f "${STATE_DIR}/mec-stadium-01-kubeconfig" ]]; then
    MEC_01_IP=$(KUBECONFIG="${STATE_DIR}/mec-stadium-01-kubeconfig" \
      oc get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "${MEC_01_IP}")
  fi
  if [[ -f "${STATE_DIR}/mec-stadium-02-kubeconfig" ]]; then
    MEC_02_IP=$(KUBECONFIG="${STATE_DIR}/mec-stadium-02-kubeconfig" \
      oc get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "${MEC_02_IP}")
  fi

  success "mec-stadium-01 IP: ${MEC_01_IP}"
  success "mec-stadium-02 IP: ${MEC_02_IP}"

  # =============================================================================
  # SECTION 6 — REGISTER MEC NODES WITH ACM
  # =============================================================================
  section "Registering MEC Nodes with ACM"

  export KUBECONFIG="${STATE_DIR}/near-edge-kubeconfig"

  wait_for "ACM MultiClusterHub running" 300 \
    "oc get multiclusterhub -n open-cluster-management --no-headers 2>/dev/null | grep -q Running"

  for SITE in stadium-01 stadium-02; do
    CLUSTER_NAME="mec-${SITE}"

    step "Registering ${CLUSTER_NAME} with ACM"

    # Create ManagedCluster (idempotent)
    cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${CLUSTER_NAME}
  labels:
    cluster.open-cluster-management.io/clusterset: far-edge-mec-clusters
    mec.site: ${SITE}
    mec.tier: far-edge
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF

    # Wait for import secret
    wait_for "Import secret for ${CLUSTER_NAME}" 120 \
      "oc get secret ${CLUSTER_NAME}-import -n ${CLUSTER_NAME} &>/dev/null"

    # Extract import manifest
    oc get secret "${CLUSTER_NAME}-import" \
      -n "${CLUSTER_NAME}" \
      -o jsonpath='{.data.import\.yaml}' | base64 -d > "/tmp/${CLUSTER_NAME}-import.yaml"

    # Apply import manifest directly to SNO cluster via its kubeconfig (no SSH needed)
    SNO_KUBECONFIG="${STATE_DIR}/${CLUSTER_NAME}-kubeconfig"
    KUBECONFIG="${SNO_KUBECONFIG}" oc apply -f "/tmp/${CLUSTER_NAME}-import.yaml"

    # Wait for cluster to show Available in ACM
    wait_for "${CLUSTER_NAME} available in ACM" 300 \
      "oc get managedcluster ${CLUSTER_NAME} -o jsonpath='{.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}' 2>/dev/null | grep -q True"

    success "${CLUSTER_NAME} registered and available in ACM"
  done

  step "Storing MEC kubeconfigs as OpenShift Secrets"
  # Create namespace first if not exists (Phase 01 may not be run yet)
  oc create namespace mec-content-ai &>/dev/null || true

  for SITE in stadium-01 stadium-02; do
    CLUSTER_NAME="mec-${SITE}"
    KUBECONFIG_PATH="${STATE_DIR}/${CLUSTER_NAME}-kubeconfig"
    oc create secret generic "${CLUSTER_NAME}-kubeconfig" \
      --from-file=kubeconfig="${KUBECONFIG_PATH}" \
      -n mec-content-ai \
      --dry-run=client -o yaml | oc apply -f -
    success "Secret ${CLUSTER_NAME}-kubeconfig created in mec-content-ai"
  done

else
  warn "Skipping MEC node setup (--skip-mec)"
  MEC_01_IP="<not-set>"
  MEC_02_IP="<not-set>"
fi

# =============================================================================
# SECTION 7 — WRITE POPULATED env.sh
# =============================================================================
section "Writing populated env.sh"

ENV_SH_PATH="configs/near-edge/env.sh"

# Back up existing env.sh if present
if [[ -f "${ENV_SH_PATH}" ]]; then
  cp "${ENV_SH_PATH}" "${ENV_SH_PATH}.backup.$(date +%Y%m%d%H%M%S)"
  info "Backed up existing env.sh"
fi

cat > "${ENV_SH_PATH}" << EOF
#!/usr/bin/env bash
# configs/near-edge/env.sh
# Auto-generated by scripts/setup-infra.sh on $(date)
# Source before any deployment step: source configs/near-edge/env.sh
# ⚠️  DO NOT commit this file — it contains secrets and cluster-specific values

# ── Cluster (Near Edge) ───────────────────────────────────────────────────────
export OCP_API_URL="$(oc whoami --show-server)"
export OCP_CONSOLE_URL="$(oc whoami --show-console)"
export OCP_APPS_DOMAIN="${APPS_DOMAIN}"
export INFRA_ID="${INFRA_ID}"
export AWS_REGION="${AWS_REGION}"
export KUBECONFIG="${STATE_DIR}/near-edge-kubeconfig"

# ── Far Edge MEC Nodes ────────────────────────────────────────────────────────
export MEC_01_IP="${MEC_01_IP}"
export MEC_02_IP="${MEC_02_IP}"
export MEC_KUBECONFIG_MEC_STADIUM_01="${STATE_DIR}/mec-stadium-01-kubeconfig"
export MEC_KUBECONFIG_MEC_STADIUM_02="${STATE_DIR}/mec-stadium-02-kubeconfig"

# ── Secrets (fill these in after Phase 02 Langfuse setup) ────────────────────
export PG_PASSWORD=""
export CH_PASSWORD=""
export MINIO_ACCESS_KEY=""
export MINIO_SECRET_KEY=""
export LANGFUSE_NEXTAUTH_SECRET=""
export LANGFUSE_ENCRYPTION_KEY=""
export LANGFUSE_SALT=""

# ── Secrets (fill these in after Phase 04 AAP setup) ─────────────────────────
export AAP_ADMIN_PASSWORD=""
export AAP_TOKEN=""
export AAP_HOST="https://controller-aap.${APPS_DOMAIN}"

# ── Secrets (fill these in after Phase 05 Slack + Langfuse API key setup) ────
export SLACK_BOT_TOKEN=""
export SLACK_SIGNING_SECRET=""
export SLACK_WEBHOOK_URL=""
export SLACK_NOC_CHANNEL="#mec-ai-ops"
export LANGFUSE_PUBLIC_KEY=""
export LANGFUSE_SECRET_KEY=""
export LANGFUSE_HOST="https://langfuse.${APPS_DOMAIN}"

# ── Git repo (fill in after pushing to GitHub/GitLab) ────────────────────────
export GIT_REPO_URL=""
EOF

success "env.sh written: ${ENV_SH_PATH}"

# =============================================================================
# SECTION 8 — FINAL VERIFICATION
# =============================================================================
section "Final Verification"

step "Near-edge cluster nodes"
oc get nodes

step "ACM managed clusters"
oc get managedcluster 2>/dev/null || warn "ACM not yet installed — run Phase 01 first"

if [[ "$SKIP_GPU" == false ]]; then
  step "GPU detection"
  GPU_CHECK=$(oc describe node -l node-role.kubernetes.io/gpu-worker 2>/dev/null | grep "nvidia.com/gpu" || echo "not-found")
  if echo "$GPU_CHECK" | grep -q "nvidia.com/gpu: 1"; then
    success "NVIDIA GPU detected on GPU worker node"
  else
    warn "GPU not yet detected — NFD/GPU operator may still be initialising"
  fi
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        Infrastructure Setup Complete!        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}What was set up:${NC}"
[[ "$SKIP_GPU" == false ]] && echo -e "  ${GREEN}✅${NC}  GPU worker node (g5.2xlarge, NVIDIA A10G)"
[[ "$SKIP_MEC" == false ]] && echo -e "  ${GREEN}✅${NC}  mec-stadium-01 (SNO) — ${MEC_01_IP}"
[[ "$SKIP_MEC" == false ]] && echo -e "  ${GREEN}✅${NC}  mec-stadium-02 (SNO) — ${MEC_02_IP}"
[[ "$SKIP_MEC" == false ]] && echo -e "  ${GREEN}✅${NC}  Both MEC nodes registered with ACM"
echo -e "  ${GREEN}✅${NC}  env.sh populated: ${ENV_SH_PATH}"
echo ""
echo -e "${BOLD}Files saved:${NC}"
echo -e "  ${STATE_DIR}/near-edge-kubeconfig"
[[ "$SKIP_MEC" == false ]] && echo -e "  ${STATE_DIR}/mec-stadium-01-kubeconfig"
[[ "$SKIP_MEC" == false ]] && echo -e "  ${STATE_DIR}/mec-stadium-02-kubeconfig"
echo -e "  ${LOG_FILE}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo -e "  1. Fill in secret values in: ${ENV_SH_PATH}"
echo -e "     (GIT_REPO_URL is required before Phase 01)"
echo -e "  2. Source env.sh: source ${ENV_SH_PATH}"
echo -e "  3. Start Phase 01: see docs/deployment/START-HERE.md"
echo ""
echo -e "${YELLOW}⚠️  Remember: RHDP sandbox expires — save ${STATE_DIR}/ externally${NC}"
echo ""

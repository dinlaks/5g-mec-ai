#!/usr/bin/env bash
# =============================================================================
# setup-infra.sh — Infrastructure Bootstrap
# 5G MEC Content Intelligence — RHDP OpenShift 4.20+ (SNO + GPU + Worker)
#
# Run ONCE before any phase deployment. Provisions the cluster infrastructure
# and writes a populated configs/near-edge/env.sh for all phase scripts.
#
# What it does:
#   1. Pre-flight  — tool checks (oc, aws, jq, yq), kubeconfig, AWS credentials
#   2. Cluster     — capture INFRA_ID, APPS_DOMAIN, AWS_REGION, zone, AMI
#   3. GPU node    — build MachineSet YAML from cluster template → oc apply
#                    g5.2xlarge (NVIDIA A10G 24GB) | OCP IPI naming conventions
#   3.5 Worker node — scale worker MachineSet to 1 (general workloads:
#                    RHOAI dashboard, Kafka, Langfuse — avoids SNO CPU overload)
#   
#                    Granite (0.20) can run simultaneously (~20.4GB of 24GB)
#   4. MEC nodes   — deploy 2 × OpenShift SNO via openshift-install (optional)
#   5. ACM         — register MEC SNO clusters (optional, requires --skip-mec=false)
#   6. env.sh      — write populated configs/near-edge/env.sh (idempotent,
#                    preserves all manually-filled secrets via \${VAR:-})
#   7. Verify      — cluster nodes, ACM managed clusters
#
# Usage:
#   ./scripts/setup-infra.sh --skip-mec            # typical RHDP run (no MEC SNO)
#   ./scripts/setup-infra.sh --skip-mec --skip-gpu # skip both (env.sh only)
#   ./scripts/setup-infra.sh --dry-run             # print commands without running
#   ./scripts/setup-infra.sh --validate            # pre-flight checks only
#
# GPU instance override (default g5.2xlarge):
#   GPU_INSTANCE_TYPE=g6.8xlarge ./scripts/setup-infra.sh --skip-mec
#
# Prerequisites (always):
#   - oc CLI logged in:  oc login --server=<url> --username=kubeadmin
#   - AWS credentials in configs/near-edge/env.sh (auto-sourced on startup)
#     Required for: GPU MachineSet (spot pricing), MEC SNO (VPC/subnet lookups)
#     Not required for: --skip-mec --skip-gpu
#
# Prerequisites (MEC SNO only, --skip-mec=false):
#   - openshift-install CLI
#   - SSH key at ~/.ssh/mec-key
#   - Red Hat pull secret at ~/.openshift/pull-secret.json
#
# Confirmed working on: OCP 4.20 SNO (sandbox123.opentlc.com), RHOAI 3.3
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


# ── Source env.sh if it exists — picks up AWS credentials and cluster vars ────
# Save the current KUBECONFIG first: env.sh may reference a path that doesn't
# exist yet on first run, which would break all oc commands.
ENV_SH="configs/near-edge/env.sh"
# Save the shell's active KUBECONFIG before sourcing env.sh.
# env.sh sets KUBECONFIG to the saved near-edge path (for phase scripts),
# but setup-infra.sh itself needs the KUBECONFIG that's already active in
# the shell (the one the user ran oc login with). Always restore it.
_PREV_KUBECONFIG="${KUBECONFIG:-}"
if [[ -f "${ENV_SH}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_SH}"
fi
# KUBECONFIG selection priority (permanent logic — handles all run scenarios):
#   1. env.sh KUBECONFIG exists on disk → user ran oc login with it; keep it.
#   2. Pre-env.sh KUBECONFIG existed    → restore it.
#   3. Neither                          → unset; oc falls back to ~/.kube/config.
_ENV_KUBECONFIG="${KUBECONFIG:-}"
if [[ -n "${_ENV_KUBECONFIG}" && -f "${_ENV_KUBECONFIG}" ]]; then
  export KUBECONFIG="${_ENV_KUBECONFIG}"
elif [[ -n "${_PREV_KUBECONFIG}" ]]; then
  export KUBECONFIG="${_PREV_KUBECONFIG}"
else
  unset KUBECONFIG
fi

# Unset empty AWS credential vars — an exported empty string causes the AWS CLI
# to skip static credentials and fall through to EC2 metadata (169.254.169.254),
# which hangs for ~60s on a non-EC2 machine (e.g. a Mac).
[[ -z "${AWS_ACCESS_KEY_ID:-}" ]]     && unset AWS_ACCESS_KEY_ID
[[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] && unset AWS_SECRET_ACCESS_KEY

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
for tool in oc aws ssh scp jq yq; do
  if command -v "$tool" &>/dev/null; then
    success "$tool found: $(command -v $tool)"
  else
    error "$tool not found — install it before running this script"
    ((ERRORS++))
  fi
done

if [[ "$SKIP_MEC" == false ]]; then
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
else
  info "Skipping SSH key + pull secret checks (--skip-mec)"
fi

if [[ "$SKIP_MEC" == false ]]; then
  step "Checking openshift-install CLI"
  if command -v openshift-install &>/dev/null; then
    # Use timeout to avoid hanging on the update check openshift-install makes
    OI_VER=$(timeout 5 openshift-install version 2>/dev/null | head -1 || echo "version check skipped")
    success "openshift-install found: ${OI_VER}"
  else
    error "openshift-install not found. Install it before running without --skip-mec."
    ((ERRORS++))
  fi
else
  info "Skipping openshift-install check (--skip-mec)"
fi

step "Checking oc login"
# Test actual authentication — not just kubeconfig file presence.
# Uses a short timeout so an unreachable server fails fast rather than hanging.
if oc whoami --request-timeout=10s &>/dev/null 2>&1; then
  OC_USER=$(oc whoami --request-timeout=10s 2>/dev/null)
  OC_SERVER=$(oc whoami --show-server --request-timeout=10s 2>/dev/null)
  success "Logged in as: ${OC_USER} on ${OC_SERVER}"
else
  error "Not logged into OpenShift (token missing or expired)."
  error "Run: oc login --server=<api-url> --username=kubeadmin --password=<password>"
  ((ERRORS++))
fi

step "Checking AWS credentials"
# AWS_EC2_METADATA_DISABLED prevents the CLI falling through to the EC2 metadata
# endpoint (169.254.169.254) which hangs for ~60s on a non-EC2 machine.
if AWS_EC2_METADATA_DISABLED=true aws sts get-caller-identity \
     --cli-connect-timeout 5 --cli-read-timeout 5 &>/dev/null 2>&1; then
  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  success "AWS credentials valid — account: ${AWS_ACCOUNT}"
else
  # Required only for MEC SNO provisioning (VPC/subnet lookups).
  # Fill in AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in configs/near-edge/env.sh.
  if [[ "$SKIP_MEC" == false ]]; then
    error "AWS credentials not configured — required for MEC SNO provisioning."
    error "Add your RHDP AWS keys to configs/near-edge/env.sh and re-run."
    ((ERRORS++))
  else
    warn "AWS credentials not configured (not required — MEC provisioning skipped)"
  fi
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
# Copy the kubeconfig that oc is actually using right now (verified by oc whoami).
# We know pre-flight oc whoami passed, so this source is valid and authenticated.
_KUBECONFIG_SOURCE="${KUBECONFIG:-${HOME}/.kube/config}"
[[ "${_KUBECONFIG_SOURCE}" != "${STATE_DIR}/near-edge-kubeconfig" ]] && \
  cp "${_KUBECONFIG_SOURCE}" "${STATE_DIR}/near-edge-kubeconfig"
chmod 600 "${STATE_DIR}/near-edge-kubeconfig"
success "Kubeconfig saved: ${STATE_DIR}/near-edge-kubeconfig (from ${_KUBECONFIG_SOURCE})"

step "Reading cluster metadata"
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
APPS_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')

success "Infrastructure ID: ${INFRA_ID}"
success "Apps domain:       ${APPS_DOMAIN}"
success "AWS region:        ${AWS_REGION}"

if [[ "$SKIP_MEC" == false ]]; then
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
else
  VPC_ID=""
fi

step "Getting cluster zone, subnet and RHCOS AMI"
ZONE=$(oc get nodes \
  -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)
[[ -z "$ZONE" ]] && ZONE="${AWS_REGION}b"

# Pull subnet filter and AZ directly from the worker MachineSet — guaranteed valid.
# Do NOT derive subnet name from the spot AZ: single-AZ RHDP clusters have no
# subnet in other AZs, causing "no subnet IDs found" errors.
WORKER_MS=$(oc get machinesets.machine.openshift.io -n openshift-machine-api \
  --no-headers 2>/dev/null | grep -v "gpu" | head -1 | awk '{print $1}' || true)
if [[ -n "$WORKER_MS" ]]; then
  CLUSTER_AZ=$(oc get machineset.machine.openshift.io "${WORKER_MS}" \
    -n openshift-machine-api \
    -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}' 2>/dev/null || true)
  SUBNET_FILTER=$(oc get machineset.machine.openshift.io "${WORKER_MS}" \
    -n openshift-machine-api \
    -o jsonpath='{.spec.template.spec.providerSpec.value.subnet.filters[0].values[0]}' 2>/dev/null || true)
fi
[[ -z "$CLUSTER_AZ" ]]     && CLUSTER_AZ="${ZONE}"
[[ -z "$SUBNET_FILTER" ]]  && SUBNET_FILTER="${INFRA_ID}-subnet-private-${CLUSTER_AZ}"

# coreos-bootimages CM is the authoritative RHCOS AMI for this cluster — no AWS needed
AMI_ID=$(oc get cm coreos-bootimages -n openshift-machine-config-operator \
  -o jsonpath='{.data.stream}' 2>/dev/null | \
  jq -r ".architectures.x86_64.images.aws.regions[\"${AWS_REGION}\"].image" 2>/dev/null || true)

if [[ -z "$AMI_ID" || "$AMI_ID" == "null" ]]; then
  warn "Could not read AMI from coreos-bootimages CM — GPU node creation will be skipped"
  SKIP_GPU=true
else
  success "Zone: ${CLUSTER_AZ} | Subnet: ${SUBNET_FILTER} | AMI: ${AMI_ID}"
fi

if [[ "$SKIP_MEC" == false ]]; then
  step "Getting OCP worker node IP (used as SSH jump host)"
  OCP_JUMP_IP=$(oc get node -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  if [[ -n "$OCP_JUMP_IP" ]]; then
    success "OCP jump host IP: ${OCP_JUMP_IP}"
  else
    warn "Could not determine worker node IP — jump host unavailable"
  fi
else
  OCP_JUMP_IP=""
fi

if [[ "$SKIP_MEC" == false ]]; then
  step "Getting private subnet for far-edge EC2s"
  FAR_EDGE_SUBNET=$(aws ec2 describe-subnets \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=*private*" \
    --query "Subnets[0].SubnetId" \
    --output text \
    --region "${AWS_REGION}")
  success "Far edge subnet: ${FAR_EDGE_SUBNET}"
else
  FAR_EDGE_SUBNET=""
fi

# =============================================================================
# SECTION 3 — GPU WORKER NODE
# =============================================================================
if [[ "$SKIP_GPU" == false ]]; then

  # ── Instance type (override: GPU_INSTANCE_TYPE=g6.8xlarge ./scripts/setup-infra.sh)
  GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.2xlarge}"
  case "${GPU_INSTANCE_TYPE}" in
    p4d*)  GPU_DESC="a100" ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-1500}" ;;
    g6e*)  GPU_DESC="l40s" ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-1000}" ;;
    g6.*)  GPU_DESC="l4"   ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-1000}" ;;
    g5.*)  GPU_DESC="a10g" ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-200}"  ;;
    p3.*)  GPU_DESC="v100" ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-1000}" ;;
    g4dn*) GPU_DESC="t4"   ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-500}"  ;;
    g4ad*) GPU_DESC="amd"  ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-500}"  ;;
    *)     GPU_DESC="gpu"  ; GPU_STORAGE_GB="${GPU_STORAGE_GB:-200}"  ;;
  esac

  section "Adding GPU Worker Node (${GPU_INSTANCE_TYPE} / ${GPU_DESC})"

  AZ="${CLUSTER_AZ}"
  GPU_MS_NAME="${INFRA_ID}-gpu-worker-${AZ}"
  GPU_MS_YAML="/tmp/${GPU_MS_NAME}.yaml"

  # ── Build clean MachineSet YAML from scratch ──────────────────────────────────
  # Builds from known-good values only — no stale server-side fields from export.
  # Structure mirrors the auto-darknoc reference with OCP IPI naming conventions.
  if oc get machineset.machine.openshift.io "${GPU_MS_NAME}" -n openshift-machine-api &>/dev/null; then
    warn "MachineSet ${GPU_MS_NAME} already exists — skipping creation"
  else
    step "Generating GPU MachineSet: ${GPU_MS_NAME}"
    cat > "${GPU_MS_YAML}" << EOF
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
      metadata:
        labels:
          node-role.kubernetes.io/gpu-worker: ""
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AWSMachineProviderConfig
          ami:
            id: ${AMI_ID}
          instanceType: ${GPU_INSTANCE_TYPE}
          placement:
            availabilityZone: ${AZ}
            region: ${AWS_REGION}
          subnet:
            filters:
              - name: tag:Name
                values:
                  - ${SUBNET_FILTER}
          securityGroups:
            - filters:
                - name: tag:Name
                  values:
                    - ${INFRA_ID}-node
            - filters:
                - name: tag:Name
                  values:
                    - ${INFRA_ID}-lb
          iamInstanceProfile:
            id: ${INFRA_ID}-worker-profile
          userDataSecret:
            name: worker-user-data
          credentialsSecret:
            name: aws-cloud-credentials
          blockDevices:
            - ebs:
                volumeType: gp3
                volumeSize: ${GPU_STORAGE_GB}
                iops: 3000
                encrypted: true
          tags:
            - name: kubernetes.io/cluster/${INFRA_ID}
              value: owned
            - name: node-role
              value: gpu-worker
EOF
    success "GPU MachineSet YAML: ${GPU_MS_YAML}"
    run "oc apply -f ${GPU_MS_YAML}"
    success "GPU MachineSet applied: ${GPU_MS_NAME}"
  fi

  # ── Quick SCP check (30s) then move on — provisioning is async ───────────────
  step "Checking for provisioning errors (30s)"
  sleep 30
  MACHINE_ERR=$(oc get machines.machine.openshift.io -n openshift-machine-api \
    -l machine.openshift.io/cluster-api-machineset="${GPU_MS_NAME}" \
    -o jsonpath='{.items[*].status.errorMessage}' 2>/dev/null || true)
  if echo "${MACHINE_ERR}" | grep -qi "not authorized\|explicit deny\|RunInstances\|service_control_policy"; then
    error "GPU node launch blocked by AWS Service Control Policy (SCP)."
    error "Options: --skip-gpu to continue without GPU, or request RHDP catalog item with GPU."
    oc delete machineset.machine.openshift.io "${GPU_MS_NAME}" \
      -n openshift-machine-api &>/dev/null || true
    exit 1
  fi

  success "GPU MachineSet provisioning started — continuing without waiting"
  info "Monitor progress:"
  info "  oc get machines.machine.openshift.io -n openshift-machine-api -w"
  info "  oc get nodes -l node-role.kubernetes.io/gpu-worker -w"
  info "NFD + GPU Operator will be installed by Phase 01 (phase-01-deploy.sh)"


else
  warn "Skipping GPU node setup (--skip-gpu)"
fi

# =============================================================================
# SECTION 3.5 — GENERAL WORKER NODE
# Scale the standard worker MachineSet to 1 so non-GPU workloads (RHOAI
# dashboard, Kafka, Langfuse, etc.) have a dedicated node. Without this,
# everything lands on the SNO control-plane node which hits CPU request limits.
# =============================================================================
section "Scaling Worker Node (general workloads)"

WORKER_MS_NAME=$(oc get machinesets.machine.openshift.io -n openshift-machine-api \
  --no-headers 2>/dev/null | grep -v "gpu" | head -1 | awk '{print $1}' || true)

if [[ -z "$WORKER_MS_NAME" ]]; then
  warn "No worker MachineSet found — skipping worker node scaling"
else
  CURRENT_REPLICAS=$(oc get machineset.machine.openshift.io "${WORKER_MS_NAME}" \
    -n openshift-machine-api -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "$CURRENT_REPLICAS" -ge 1 ]]; then
    success "Worker MachineSet ${WORKER_MS_NAME} already has ${CURRENT_REPLICAS} replica(s) — skipping"
  else
    step "Scaling ${WORKER_MS_NAME} to 1 replica"
    run "oc scale machineset.machine.openshift.io ${WORKER_MS_NAME} \
      -n openshift-machine-api --replicas=1"
    success "Worker node provisioning started: ${WORKER_MS_NAME}"
    info "Worker node will be Ready in ~5 min — continuing without waiting"
    info "Monitor: oc get machines.machine.openshift.io -n openshift-machine-api -w"
  fi
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
    "oc get multiclusterhub -n open-cluster-management --no-headers 2>/dev/null | grep Running > /dev/null"

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
      "oc get managedcluster ${CLUSTER_NAME} -o jsonpath='{.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}' 2>/dev/null | grep True > /dev/null"

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

# Read cluster URLs from kubeconfig locally — no network call
_OCP_API_URL=$(oc config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
_OCP_CONSOLE_URL="https://console-openshift-console.${APPS_DOMAIN}"

cat > "${ENV_SH_PATH}" << EOF
#!/usr/bin/env bash
# configs/near-edge/env.sh
# Auto-generated by scripts/setup-infra.sh on $(date)
# Source before any deployment step: source configs/near-edge/env.sh
# ⚠️  DO NOT commit this file — it contains secrets and cluster-specific values
# Re-running setup-infra.sh is safe — all filled-in values are preserved via \${VAR:-}.

# ── AWS credentials (copy from RHDP sandbox portal or ~/.aws/credentials) ─────
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# ── Cluster (Near Edge) ───────────────────────────────────────────────────────
export OCP_API_URL="${_OCP_API_URL}"
export OCP_CONSOLE_URL="${_OCP_CONSOLE_URL}"
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
export PG_PASSWORD="${PG_PASSWORD:-}"
export CH_PASSWORD="${CH_PASSWORD:-}"
export MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
export MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
export LANGFUSE_NEXTAUTH_SECRET="${LANGFUSE_NEXTAUTH_SECRET:-}"
export LANGFUSE_ENCRYPTION_KEY="${LANGFUSE_ENCRYPTION_KEY:-}"
export LANGFUSE_SALT="${LANGFUSE_SALT:-}"

# ── Secrets (fill these in after Phase 04 AAP setup) ─────────────────────────
export AAP_ADMIN_PASSWORD="${AAP_ADMIN_PASSWORD:-}"
export AAP_TOKEN="${AAP_TOKEN:-}"
export AAP_HOST="https://controller-aap.${APPS_DOMAIN}"

# ── Secrets (fill these in after Phase 05 Slack + Langfuse API key setup) ────
export SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
export SLACK_SIGNING_SECRET="${SLACK_SIGNING_SECRET:-}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
export SLACK_NOC_CHANNEL="${SLACK_NOC_CHANNEL:-#mec-ai-ops}"
export LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
export LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"
export LANGFUSE_HOST="https://langfuse.${APPS_DOMAIN}"

# ── AI Core (populated by phase-03-deploy.sh) ────────────────────────────────
export VLLM_URL="${VLLM_URL:-http://granite-3-3-8b-predictor.mec-content-ai.svc.cluster.local}"
export LLAMASTACK_URL="${LLAMASTACK_URL:-http://mec-llamastack.mec-content-ai.svc.cluster.local:8321}"

# ── Git repo (required before Phase 01) ──────────────────────────────────────
export GIT_REPO_URL="${GIT_REPO_URL:-}"
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
  if echo "$GPU_CHECK" | grep "nvidia.com/gpu: 1" > /dev/null; then
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

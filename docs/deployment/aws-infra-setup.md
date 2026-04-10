# AWS Infrastructure Setup Guide
# 5G MEC Content Intelligence — RHDP OpenShift 4.21 + SNO Far Edge

## Overview

This guide sets up the full two-tier infrastructure using:
- **Near Edge:** Pre-provisioned OpenShift 4.21 from Red Hat Demo Platform (RHDP)
  with a GPU worker node added for vLLM
- **Far Edge:** 2 × OpenShift SNO (Single Node OpenShift) clusters deployed
  in the same RHDP AWS VPC — simulating MEC nodes with full OpenShift APIs

```
RHDP AWS Account
├── Near Edge — OpenShift 4.21 (pre-provisioned cluster from RHDP)
│     ├── Existing node(s) from RHDP sandbox
│     └── + 1 GPU worker node (g5.2xlarge — NVIDIA A10G) ← you add this
│
└── Far Edge — 2 × OpenShift SNO (MEC node simulation)
      ├── mec-stadium-01 (m5.2xlarge SNO)
      └── mec-stadium-02 (m5.2xlarge SNO)
```

**Time to complete:** ~3 hours (SNO installs take ~45 min each, unattended)
**Prerequisites:** RHDP account, RHEL subscription, Red Hat pull secret, openshift-install CLI

> **RHDP Sandbox note:** RHDP sandboxes have a time limit (typically 8–48 hours,
> extendable). Plan your build sessions accordingly. The cluster and AWS resources
> are torn down when the sandbox expires. Save your kubeconfigs and env.sh externally.

---

## Table of Contents

1. [Prerequisites & Tools](#1-prerequisites--tools)
2. [Provision RHDP Sandbox](#2-provision-rhdp-sandbox)
3. [Access the OpenShift Cluster](#3-access-the-openshift-cluster)
4. [Add GPU Worker Node](#4-add-gpu-worker-node)
5. [Post-Cluster Verification](#5-post-cluster-verification)
6. [Deploy SNO Far-Edge Clusters](#6-deploy-sno-far-edge-clusters)
7. [Register MEC Nodes with ACM](#7-register-mec-nodes-with-acm)
8. [Verify Full Connectivity](#8-verify-full-connectivity)
9. [Cost & Time Management](#9-cost--time-management)

---

## 1. Prerequisites & Tools

### Install on your laptop (macOS)

```bash
# OpenShift CLI (oc)
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.21.0/openshift-client-mac.tar.gz
tar xzf openshift-client-mac.tar.gz
sudo mv oc kubectl /usr/local/bin/

# AWS CLI
brew install awscli

# Verify
oc version
aws --version
```

### Get your Red Hat pull secret

1. Go to https://console.redhat.com/openshift/downloads
2. Scroll to **Pull secret** → click **Copy pull secret**
3. Save it:

```bash
mkdir -p ~/.openshift
cat > ~/.openshift/pull-secret.json << 'EOF'
<paste your pull secret here>
EOF
```

### Generate SSH key pair (for MEC node access)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mec-key -N ""
```

---

## 2. Provision RHDP Sandbox

### 2a — Request the sandbox

1. Go to https://catalog.demo.redhat.com
2. Filter by **Open Environments** category
3. Find **"OpenShift 4.21 on AWS"** (or the closest available version)
4. Click **Order** → fill in purpose (e.g. "5G MEC AI demo PoC")
5. Select activity type: **Development**
6. Submit the order

### 2b — Wait for provisioning email

RHDP sends two emails once ready:
- **Cluster credentials email** — contains:
  - Cluster API URL (`https://api.<cluster-name>.<domain>:6443`)
  - Web console URL
  - `kubeadmin` password
- **AWS credentials email** — contains:
  - AWS Access Key ID
  - AWS Secret Access Key
  - AWS region
  - Account ID

Save both emails. You will need all values throughout this guide.

### 2c — Configure AWS CLI with RHDP credentials

```bash
aws configure --profile rhdp
# AWS Access Key ID:     <from RHDP email>
# AWS Secret Access Key: <from RHDP email>
# Default region:        <from RHDP email — e.g. us-east-1 or eu-west-1>
# Default output format: json

# Set as default for this session
export AWS_PROFILE=rhdp
export AWS_DEFAULT_REGION=<region-from-rhdp-email>

# Verify
aws sts get-caller-identity
# Expected: RHDP account ID + ARN
```

---

## 3. Access the OpenShift Cluster

### 3a — Log in via oc CLI

```bash
# Use credentials from the RHDP cluster email
oc login \
  --server=https://api.<cluster-name>.<domain>:6443 \
  --username=kubeadmin \
  --password=<kubeadmin-password-from-email>

# Verify login
oc whoami
# Expected: kubeadmin

oc get nodes
# Expected: existing cluster node(s) in Ready state
```

### 3b — Save kubeconfig

```bash
mkdir -p ~/mec-rhdp
oc config view --raw > ~/mec-rhdp/near-edge-kubeconfig
chmod 600 ~/mec-rhdp/near-edge-kubeconfig
export KUBECONFIG=~/mec-rhdp/near-edge-kubeconfig
```

### 3c — Capture key cluster values

```bash
# Infrastructure ID — used for MachineSet naming
INFRA_ID=$(oc get infrastructure cluster \
  -o jsonpath='{.status.infrastructureName}')
echo "Infrastructure ID: ${INFRA_ID}"

# Apps domain — used in env.sh
APPS_DOMAIN=$(oc get ingress.config cluster \
  -o jsonpath='{.spec.domain}')
echo "Apps domain: ${APPS_DOMAIN}"

# AWS region from cluster
AWS_REGION=$(oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.aws.region}')
echo "AWS region: ${AWS_REGION}"

# VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --query "Vpcs[0].VpcId" \
  --output text)
echo "VPC ID: ${VPC_ID}"
```

> Save these values — you will need INFRA_ID, APPS_DOMAIN, AWS_REGION,
> and VPC_ID throughout the rest of this guide.

### 3d — Update configs/near-edge/env.sh

```bash
# Update env.sh with actual values from this cluster
cat >> configs/near-edge/env.sh << EOF

# ── Cluster values (from RHDP provisioning) ───────────────────────────────
export OCP_API_URL="https://api.<cluster-name>.<domain>:6443"
export OCP_APPS_DOMAIN="${APPS_DOMAIN}"
export AWS_REGION="${AWS_REGION}"
export INFRA_ID="${INFRA_ID}"
EOF
```

---

## 4. Add GPU Worker Node

The RHDP cluster does not include a GPU node. You add one via a MachineSet
pointing to a g5.2xlarge instance (NVIDIA A10G GPU) in the same AWS VPC.

### 4a — Get reference values from existing worker MachineSet

```bash
# List existing MachineSets
oc get machinesets -n openshift-machine-api

# Get the first worker MachineSet name
WORKER_MS=$(oc get machinesets -n openshift-machine-api \
  -o jsonpath='{.items[0].metadata.name}')
echo "Reference MachineSet: ${WORKER_MS}"

# Get the AMI ID used by existing workers
AMI_ID=$(oc get machineset ${WORKER_MS} \
  -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.ami.id}')
echo "AMI ID: ${AMI_ID}"

# Get availability zone from existing workers
AZ=$(oc get machineset ${WORKER_MS} \
  -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
echo "Availability Zone: ${AZ}"

# Get worker security group
WORKER_SG=$(oc get machineset ${WORKER_MS} \
  -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.securityGroups[0].filters[0].values[0]}')
echo "Worker SG: ${WORKER_SG}"
```

### 4b — Check GPU quota in your RHDP AWS account

```bash
# Check current quota for G and VT instances (covers g5 family)
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --region ${AWS_REGION} \
  --query "Quota.Value" \
  --output text
# If 0 — request an increase before proceeding (takes up to 24 hours)

# Request increase to 8 vCPUs (g5.2xlarge = 8 vCPUs)
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --desired-value 8 \
  --region ${AWS_REGION}
```

> ⚠️ If quota increase is pending, continue with Sections 6 and 7 (MEC nodes)
> while waiting. Come back to this step once approved.

### 4c — Create GPU MachineSet

```bash
cat > ~/mec-rhdp/gpu-machineset.yaml << EOF
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${INFRA_ID}-gpu-${AZ}
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
      machine.openshift.io/cluster-api-machineset: ${INFRA_ID}-gpu-${AZ}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${INFRA_ID}
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${INFRA_ID}-gpu-${AZ}
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

oc apply -f ~/mec-rhdp/gpu-machineset.yaml
```

### 4d — Wait for GPU node to join (5–10 minutes)

```bash
# Watch machine provisioning
oc get machines -n openshift-machine-api -w
# Wait for state: Provisioning → Provisioned → Running

# Verify node joined
oc get nodes -l node-role.kubernetes.io/gpu-worker
# Expected: 1 node in Ready state
```

### 4e — Install NFD and GPU Operator

```bash
# Apply Phase 01 NFD and GPU Operator subscriptions
oc apply -f implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml

# Wait for operators to be ready (5–10 minutes)
oc wait --for=condition=available deployment/nfd-controller-manager \
  -n openshift-nfd --timeout=300s

# Verify GPU is detected
oc describe node -l node-role.kubernetes.io/gpu-worker | grep "nvidia.com/gpu"
# Expected: nvidia.com/gpu: 1
```

---

## 5. Post-Cluster Verification

```bash
# All nodes Ready (RHDP nodes + new GPU node)
oc get nodes

# Cluster operators healthy
oc get co | grep -v "True.*False.*False"
# All operators should show Available=True, Progressing=False, Degraded=False

# GPU node details
oc describe node -l node-role.kubernetes.io/gpu-worker | grep -A5 "Capacity:"
# Expected: nvidia.com/gpu: 1

# Web console accessible
oc whoami --show-console
```

---

## 6. Deploy SNO Far-Edge Clusters

Each MEC node simulation is a **Single Node OpenShift (SNO)** cluster deployed
in the same RHDP AWS VPC. SNO runs a full OpenShift cluster on a single EC2 node —
same APIs as the near-edge cluster, no separate tooling required.

> **Why SNO instead of MicroShift?**
> SNO uses the same OpenShift APIs, operators, and tooling as the near-edge cluster.
> This eliminates the need for MicroShift-specific workarounds and allows full
> KServe/RHOAI support on the far-edge nodes for the demo.

> **Time:** Each SNO install takes ~45 minutes unattended. Both run sequentially.
> Total: ~90 minutes. Start this and come back.

### 6a — Install openshift-install CLI (if not already installed)

```bash
# macOS
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.21.0/openshift-install-mac.tar.gz
tar xzf openshift-install-mac.tar.gz
sudo mv openshift-install /usr/local/bin/

openshift-install version
# Expected: openshift-install 4.21.x
```

### 6b — Get the private subnet from RHDP VPC

```bash
FAR_EDGE_SUBNET=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=*private*" \
  --query "Subnets[0].SubnetId" \
  --output text)
echo "Far Edge Subnet: ${FAR_EDGE_SUBNET}"

# Get the availability zone of this subnet
AZ=$(aws ec2 describe-subnets \
  --subnet-ids ${FAR_EDGE_SUBNET} \
  --query "Subnets[0].AvailabilityZone" \
  --output text)
echo "Availability Zone: ${AZ}"
```

### 6c — Create SNO install configs for both MEC sites

```bash
BASE_DOMAIN=$(oc get dns.config cluster -o jsonpath='{.spec.baseDomain}')
PULL_SECRET=$(cat ~/.openshift/pull-secret.json | tr -d '\n')
SSH_PUB_KEY=$(cat ~/.ssh/mec-key.pub)

for SITE in stadium-01 stadium-02; do
  INSTALL_DIR=~/mec-rhdp/sno-${SITE}
  mkdir -p ${INSTALL_DIR}

  cat > ${INSTALL_DIR}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: mec-${SITE}

# SNO: 0 workers — the single control-plane node acts as both master and worker
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

  echo "install-config.yaml created for mec-${SITE}"
  # Back up — openshift-install consumes it
  cp ${INSTALL_DIR}/install-config.yaml ${INSTALL_DIR}/install-config.yaml.backup
done
```

### 6d — Run openshift-install for each SNO site

> Run sequentially. Each takes ~45 minutes.

```bash
for SITE in stadium-01 stadium-02; do
  INSTALL_DIR=~/mec-rhdp/sno-${SITE}
  echo "Starting SNO install for mec-${SITE}..."

  openshift-install create cluster \
    --dir ${INSTALL_DIR} \
    --log-level=info

  echo "mec-${SITE} install complete"

  # Save kubeconfig
  cp ${INSTALL_DIR}/auth/kubeconfig \
     ~/mec-rhdp/mec-${SITE}-kubeconfig
  chmod 600 ~/mec-rhdp/mec-${SITE}-kubeconfig
done
```

### 6e — Verify SNO clusters are up

```bash
# mec-stadium-01
KUBECONFIG=~/mec-rhdp/mec-stadium-01-kubeconfig oc get nodes
# Expected: 1 node Ready (master + worker roles)

# mec-stadium-02
KUBECONFIG=~/mec-rhdp/mec-stadium-02-kubeconfig oc get nodes
# Expected: 1 node Ready

# Get SNO node IPs from AWS (installer tags them with the cluster name)
for SITE in stadium-01 stadium-02; do
  IP=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:kubernetes.io/cluster/mec-${SITE},Values=owned" \
      "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text)
  echo "mec-${SITE}: ${IP}"
done

# Save IPs to env.sh
export MEC_01_IP=<mec-stadium-01-ip-from-above>
export MEC_02_IP=<mec-stadium-02-ip-from-above>
```

---

## 7. Register MEC Nodes with ACM

ACM is installed in Phase 01. Once it is up, register both MEC nodes.

### 7a — Verify ACM is ready

```bash
export KUBECONFIG=~/mec-rhdp/near-edge-kubeconfig

oc get multiclusterhub -n open-cluster-management
# Expected: MultiClusterHub — status: Running
```

### 7b — Register mec-stadium-01

```bash
# Create ManagedCluster
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: mec-stadium-01
  labels:
    cluster.open-cluster-management.io/clusterset: far-edge
    mec.site: stadium-01
    mec.tier: far-edge
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF

# Wait for import secret to be created
oc wait secret/mec-stadium-01-import \
  -n mec-stadium-01 \
  --for=jsonpath='{.data.import\.yaml}' \
  --timeout=60s

# Extract import manifest
oc get secret mec-stadium-01-import \
  -n mec-stadium-01 \
  -o jsonpath='{.data.import\.yaml}' | base64 -d > /tmp/mec-stadium-01-import.yaml

# Apply on the MEC node
scp -i ~/.ssh/mec-key \
  -J ec2-user@${OCP_NODE_IP} \
  /tmp/mec-stadium-01-import.yaml \
  ec2-user@${MEC_01_IP}:/tmp/

ssh -i ~/.ssh/mec-key \
  -J ec2-user@${OCP_NODE_IP} \
  ec2-user@${MEC_01_IP} \
  "KUBECONFIG=~/.kube/config oc apply -f /tmp/mec-stadium-01-import.yaml"
```

### 7c — Register mec-stadium-02

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: mec-stadium-02
  labels:
    cluster.open-cluster-management.io/clusterset: far-edge
    mec.site: stadium-02
    mec.tier: far-edge
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF

oc get secret mec-stadium-02-import \
  -n mec-stadium-02 \
  -o jsonpath='{.data.import\.yaml}' | base64 -d > /tmp/mec-stadium-02-import.yaml

scp -i ~/.ssh/mec-key \
  -J ec2-user@${OCP_NODE_IP} \
  /tmp/mec-stadium-02-import.yaml \
  ec2-user@${MEC_02_IP}:/tmp/

ssh -i ~/.ssh/mec-key \
  -J ec2-user@${OCP_NODE_IP} \
  ec2-user@${MEC_02_IP} \
  "KUBECONFIG=~/.kube/config oc apply -f /tmp/mec-stadium-02-import.yaml"
```

### 7d — Verify both MEC nodes registered

```bash
oc get managedcluster
# Expected:
# NAME              HUB ACCEPTED   JOINED   AVAILABLE
# local-cluster     true           True     True
# mec-stadium-01    true           True     True
# mec-stadium-02    true           True     True
```

---

## 8. Verify Full Connectivity

### 8a — Store MEC kubeconfigs as OpenShift secrets

```bash
# These are used by AAP playbooks to reach MEC clusters
oc create secret generic mec-stadium-01-kubeconfig \
  --from-file=kubeconfig=~/mec-rhdp/mec-stadium-01-kubeconfig \
  -n mec-content-ai

oc create secret generic mec-stadium-02-kubeconfig \
  --from-file=kubeconfig=~/mec-rhdp/mec-stadium-02-kubeconfig \
  -n mec-content-ai
```

### 8b — Update env.sh with MEC node details

```bash
cat >> configs/near-edge/env.sh << EOF

# ── Far Edge MEC nodes ────────────────────────────────────────────────────
export MEC_01_IP="${MEC_01_IP}"
export MEC_02_IP="${MEC_02_IP}"
export MEC_KUBECONFIG_MEC_STADIUM_01="${HOME}/mec-rhdp/mec-stadium-01-kubeconfig"
export MEC_KUBECONFIG_MEC_STADIUM_02="${HOME}/mec-rhdp/mec-stadium-02-kubeconfig"
EOF
```

### 8c — Full connectivity check

```bash
# Near-edge cluster healthy
oc get nodes
oc get co | grep -v "True.*False.*False"

# GPU node available
oc describe node -l node-role.kubernetes.io/gpu-worker \
  | grep "nvidia.com/gpu"
# Expected: nvidia.com/gpu: 1

# Both MEC nodes registered and available via ACM
oc get managedcluster | grep mec-stadium

# MEC node 1 — MicroShift responding
KUBECONFIG=~/mec-rhdp/mec-stadium-01-kubeconfig oc get nodes

# MEC node 2 — MicroShift responding
KUBECONFIG=~/mec-rhdp/mec-stadium-02-kubeconfig oc get nodes

# VPC connectivity — ping MEC from near-edge worker
OCP_NODE_IP=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
ssh -i ~/.ssh/mec-key ec2-user@${OCP_NODE_IP} \
  "curl -sk https://${MEC_01_IP}:6443/healthz"
# Expected: ok
```

---

## 9. Cost & Time Management

### What you pay for on RHDP

The OpenShift cluster itself is covered by RHDP — no cost to you.
You pay AWS charges only for resources **you add** to the RHDP account:

| Resource | Type | $/hour | Note |
|---|---|---|---|
| GPU worker node | g5.2xlarge | ~$1.21 | Your main cost — stop when not testing vLLM |
| MEC node 1 | m5.xlarge | ~$0.19 | Stop when not active |
| MEC node 2 | m5.xlarge | ~$0.19 | Stop when not active |
| EBS volumes | ~200GB gp3 | ~$0.02/hr | Always running (attached to EC2) |

**Estimated cost for an 8-hour active session:** ~$13

### Stop and restart MEC nodes between sessions

```bash
# Stop MEC nodes when done for the day
MEC_INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:role,Values=far-edge-mec" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text)
aws ec2 stop-instances --instance-ids ${MEC_INSTANCES}

# Stop GPU worker between vLLM test sessions
GPU_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:node-role,Values=gpu-worker" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)
aws ec2 stop-instances --instance-ids ${GPU_INSTANCE}

# Restart when resuming
aws ec2 start-instances --instance-ids ${MEC_INSTANCES} ${GPU_INSTANCE}
# Wait ~5 mins after GPU node restart for it to rejoin OCP cluster
```

### RHDP sandbox expiry

RHDP sandboxes expire after the agreed period. Before expiry:

```bash
# Save all kubeconfigs externally
cp ~/mec-rhdp/ <external-backup>/

# Save env.sh
cp configs/near-edge/env.sh <external-backup>/

# Export any Langfuse data if needed
# Everything else is in Git — no other state to save
```

---

## Summary — What You Have After This Guide

```
✅ OpenShift 4.21 (near edge) — RHDP pre-provisioned cluster
✅ GPU worker node (g5.2xlarge, NVIDIA A10G) added and verified
✅ NFD + GPU Operator installed, GPU detected
✅ 2 × OpenShift SNO clusters (mec-stadium-01, mec-stadium-02) — m5.2xlarge each
✅ Both SNO clusters registered with ACM (far-edge clusterset)
✅ kubeconfigs stored locally and as OCP secrets for AAP access
✅ env.sh updated with all cluster values
✅ VPC-internal connectivity verified between near-edge and far-edge SNO clusters

Next: Phase-by-phase deployment — start with Phase 01
      Reference: docs/deployment/START-HERE.md
```

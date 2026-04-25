# Phase 01 — Foundation

## Goal
Get all operators running, GPU node labelled, namespaces created, and GitOps bootstrapped.
Everything after this phase is deployed via ArgoCD — not manual `oc apply`.

## What Gets Installed

### Wave 0 (no dependencies — apply first, wait for CRDs)
| Operator | Namespace | Why |
|---|---|---|
| cert-manager | cert-manager-operator | TLS for RHOAI, LlamaStack, Langfuse |
| Node Feature Discovery (NFD) | openshift-nfd | Labels GPU node for GPU Operator |
| NVIDIA GPU Operator | gpu-operator | GPU drivers + device plugin for vLLM |
| OpenShift GitOps | openshift-gitops-operator | ArgoCD — bootstrap before wave 1 |

### Wave 1 (depends on wave 0 CRDs)
| Operator | Namespace | Why |
|---|---|---|
| RHOAI 3.3 | redhat-ods-operator | vLLM + KServe + Kubeflow Pipelines |
| AMQ Streams 3.1 | amq-streams | Kafka event bus |
| AAP 2.5 | aap | Playbook execution + EDA |
| ACM 2.15 | open-cluster-management | Multi-cluster management |

## Namespaces Created
| Namespace | Contents |
|---|---|
| `mec-content-ai` | Agent, MCP servers, LlamaStack, EdgeStream IQ |
| `mec-ai-data` | Kafka cluster, MinIO |
| `mec-ai-obs` | Langfuse, ClickHouse, Redis |
| `far-edge-mec` | Far-edge workloads (deployed via ApplicationSet to MEC nodes) |

## Prerequisites
```bash
source configs/near-edge/env.sh
./scripts/phase-01-deploy.sh --validate   # must pass before proceeding
```

## Step-by-Step

### Step 1 — Apply wave 0 operators
```bash
oc apply -f implementation/phase-01-foundation/operators/wave-0-certmanager-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml

# Wait for wave 0 operators to be ready
oc wait --for=condition=Ready pods --all -n cert-manager-operator --timeout=300s
oc wait --for=condition=Ready pods --all -n openshift-nfd --timeout=300s
oc wait --for=condition=Ready pods --all -n gpu-operator --timeout=300s
```

### Step 2 — Bootstrap OpenShift GitOps (ArgoCD)
```bash
# Apply GitOps operator (from gitops/bootstrap — done manually, once only)
oc apply -f gitops/bootstrap/01-gitops-operator.yaml
oc wait --for=condition=Ready pods --all -n openshift-gitops-operator --timeout=300s

oc apply -f gitops/bootstrap/02-argocd-instance.yaml
oc apply -f gitops/bootstrap/03-argocd-project.yaml
```

### Step 3 — Apply wave 1 operators
```bash
oc apply -f implementation/phase-01-foundation/operators/wave-1-rhoai-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-1-kafka-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-1-aap-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-1-acm-subscription.yaml

# Wait for wave 1 operators
oc wait --for=condition=Ready pods --all -n redhat-ods-operator --timeout=600s
oc wait --for=condition=Ready pods --all -n amq-streams --timeout=300s
oc wait --for=condition=Ready pods --all -n aap --timeout=300s
oc wait --for=condition=Ready pods --all -n open-cluster-management --timeout=600s
```

### Step 4 — Create namespaces
```bash
oc apply -f implementation/phase-01-foundation/namespaces/namespaces.yaml
```

### Step 5 — Label GPU node
```bash
# Find your GPU node name
oc get nodes -l nvidia.com/gpu.present=true

# Verify NFD has labelled it
oc describe node <gpu-node-name> | grep nvidia
```

### Step 6 — Configure ACM + GitOps integration
```bash
oc apply -f gitops/acm/managedclusterset.yaml
oc apply -f gitops/acm/clusterset-binding.yaml
oc apply -f gitops/acm/placement-near-edge.yaml
oc apply -f gitops/acm/placement-far-edge.yaml
oc apply -f gitops/acm/gitopscluster.yaml
```

### Step 7 — Deploy ArgoCD Applications (from here, GitOps takes over)

```bash
oc apply -f gitops/apps/near-edge/
oc apply -f gitops/apps/far-edge/
# ArgoCD will now sync all subsequent phases from Git automatically
```

## Validation
```bash
# All operators running
oc get csv -A | grep -E "cert-manager|nfd|gpu|rhoai|amq|aap|acm|gitops"

# GPU node detected
oc get nodes -l nvidia.com/gpu.present=true

# ArgoCD accessible
echo "ArgoCD URL: $(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"

# All namespaces created
oc get namespaces | grep mec

# ArgoCD Applications created and syncing
oc get applications -n openshift-gitops
```

## Troubleshooting
- **GPU not detected**: Check NFD is running and node has NVIDIA hardware — `oc describe node <node>`
- **RHOAI times out**: cert-manager must be fully running first — check cert-manager pods
- **ACM GitOpsCluster not syncing**: Verify ManagedClusterSetBinding exists in openshift-gitops namespace
- **ArgoCD Apps stuck OutOfSync**: Check repo URL in app YAMLs matches your actual GitHub org

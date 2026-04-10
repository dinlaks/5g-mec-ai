# Phase 01 — Foundation — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Update "Actual Output" and "Status" as you run each command.

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc version` | Confirm OCP CLI version matches cluster | `Client: 4.21.x` | | ⬜ |
| `oc whoami` | Confirm logged into near-edge cluster as cluster-admin | `system:admin` or your user | | ⬜ |
| `oc get nodes` | Check all nodes Ready | All nodes `Ready` | | ⬜ |
| `./scripts/preflight.sh` | Full pre-flight check | `All checks passed` | | ⬜ |

---

## Wave 0 — Apply

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-01-foundation/operators/wave-0-certmanager-subscription.yaml` | Install cert-manager | `namespace/cert-manager-operator created` | | ⬜ |
| `oc apply -f implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml` | Install NFD | `namespace/openshift-nfd created` | | ⬜ |
| `oc apply -f implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml` | Install GPU Operator | `namespace/gpu-operator created` | | ⬜ |

## Wave 0 — Wait

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get csv -n cert-manager-operator` | Check cert-manager CSV | `Succeeded` | | ⬜ |
| `oc get csv -n openshift-nfd` | Check NFD CSV | `Succeeded` | | ⬜ |
| `oc get csv -n gpu-operator` | Check GPU Operator CSV | `Succeeded` | | ⬜ |
| `oc get pods -n cert-manager` | cert-manager pods running | All `Running` | | ⬜ |
| `oc get nfd -n openshift-nfd` | NFD instance created | `nfd-instance` | | ⬜ |

---

## GitOps Bootstrap

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f gitops/bootstrap/01-gitops-operator.yaml` | Install GitOps operator | `subscription.operators.coreos.com/openshift-gitops-operator created` | | ⬜ |
| `oc get csv -n openshift-gitops-operator` | GitOps CSV ready | `Succeeded` | | ⬜ |
| `oc get pods -n openshift-gitops` | ArgoCD pods running | All `Running` | | ⬜ |
| `oc apply -f gitops/bootstrap/02-argocd-instance.yaml` | Configure ArgoCD | `argocd.argoproj.io/openshift-gitops configured` | | ⬜ |
| `oc apply -f gitops/bootstrap/03-argocd-project.yaml` | Create ArgoCD project | `appproject.argoproj.io/mec-content-ai created` | | ⬜ |
| `oc get route openshift-gitops-server -n openshift-gitops` | Get ArgoCD URL | `openshift-gitops-server-openshift-gitops.apps.<cluster>` | | ⬜ |

---

## Wave 1 — Apply

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-01-foundation/operators/wave-1-rhoai-subscription.yaml` | Install RHOAI 3.3 | created | | ⬜ |
| `oc apply -f implementation/phase-01-foundation/operators/wave-1-kafka-subscription.yaml` | Install AMQ Streams | created | | ⬜ |
| `oc apply -f implementation/phase-01-foundation/operators/wave-1-aap-subscription.yaml` | Install AAP 2.5 | created | | ⬜ |
| `oc apply -f implementation/phase-01-foundation/operators/wave-1-acm-subscription.yaml` | Install ACM 2.15 | created | | ⬜ |

## Wave 1 — Wait

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get csv -n redhat-ods-operator` | RHOAI CSV ready | `Succeeded` | | ⬜ |
| `oc get datasciencecluster` | DSC created and ready | `Ready` | | ⬜ |
| `oc get csv -n amq-streams` | Kafka CSV ready | `Succeeded` | | ⬜ |
| `oc get csv -n aap` | AAP CSV ready | `Succeeded` | | ⬜ |
| `oc get mch -n open-cluster-management` | ACM hub ready | `Running` | | ⬜ |

---

## Namespaces

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-01-foundation/namespaces/namespaces.yaml` | Create all custom namespaces | 4 namespaces created | | ⬜ |
| `oc get namespaces \| grep mec` | Verify namespaces exist | `mec-content-ai`, `mec-ai-data`, `mec-ai-obs`, `far-edge-mec` | | ⬜ |

---

## GPU Node

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get nodes -l nvidia.com/gpu.present=true` | Verify GPU node detected | GPU node listed | | ⬜ |
| `oc describe node <gpu-node> \| grep -i nvidia` | Check GPU labels | Multiple `nvidia.com/` labels | | ⬜ |
| `oc get pods -n gpu-operator \| grep nvidia` | GPU driver pods running | All `Running` | | ⬜ |

---

## ACM + GitOps Integration

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f gitops/acm/managedclusterset.yaml` | Create cluster sets | 2 ManagedClusterSets created | | ⬜ |
| `oc apply -f gitops/acm/clusterset-binding.yaml` | Bind sets to gitops namespace | 2 ManagedClusterSetBindings created | | ⬜ |
| `oc apply -f gitops/acm/placement-near-edge.yaml` | Create near-edge placement | Placement created | | ⬜ |
| `oc apply -f gitops/acm/placement-far-edge.yaml` | Create far-edge placement | Placement created | | ⬜ |
| `oc apply -f gitops/acm/gitopscluster.yaml` | Link ACM → ArgoCD | 2 GitOpsClusters created | | ⬜ |
| `oc get gitopscluster -n openshift-gitops` | Verify GitOpsClusters | Both `Ready` | | ⬜ |

---

## ArgoCD Applications

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f gitops/apps/near-edge/` | Create all near-edge ArgoCD apps | 5 Applications created | | ⬜ |
| `oc apply -f gitops/apps/far-edge/` | Create far-edge ApplicationSet | 1 ApplicationSet created | | ⬜ |
| `oc get applications -n openshift-gitops` | Verify apps created | All apps listed | | ⬜ |

---

## Phase 01 Complete ✅

When all rows above are ✅, Phase 01 is done.
ArgoCD will now automatically sync Phases 02–07 from Git.
Check ArgoCD UI to monitor sync status before proceeding to Phase 02.

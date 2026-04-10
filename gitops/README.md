# GitOps — 5G MEC Content Intelligence

## Deployment Model

This project uses **OpenShift GitOps (ArgoCD)** as the single deployment mechanism.
No manual `oc apply` after bootstrap. Git is the source of truth for all cluster state.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Git Repo (this repo, main branch)                                  │
│  Source of truth for ALL cluster state                              │
└──────────────────────┬──────────────────────────────────────────────┘
                       │ ArgoCD watches & syncs
┌──────────────────────▼──────────────────────────────────────────────┐
│  OpenShift GitOps (ArgoCD) — near-edge cluster                     │
│  Namespace: openshift-gitops                                        │
└──────────────────────┬──────────────────────────────────────────────┘
                       │ ACM GitOpsCluster integration
┌──────────────────────▼──────────────────────────────────────────────┐
│  ACM 2.15 Hub — governs all cluster targeting                      │
│  Placement → ManagedClusterSet → GitOpsCluster                     │
│                                                                     │
│  ┌─────────────────────┐    ┌────────────────────────────────────┐ │
│  │  NEAR EDGE          │    │  FAR EDGE MEC NODES (fleet)        │ │
│  │  ArgoCD Apps:       │    │  ApplicationSet (one per MEC node) │ │
│  │  • data-pipeline    │    │  • far-edge-mec workloads          │ │
│  │  • ai-core          │    │    (OS managed by MCO,             │ │
│  │  • automation       │    │     models via MinIO initContainer) │ │
│  │  • agent-mcp        │    └────────────────────────────────────┘ │
│  │  • dashboard        │                                           │
│  └─────────────────────┘                                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Folder Structure

```
gitops/
├── README.md                     ← this file
├── bootstrap/                    ← one-time setup (run once to get GitOps going)
│   ├── 01-gitops-operator.yaml   ← installs OpenShift GitOps operator
│   ├── 02-argocd-instance.yaml   ← configures ArgoCD instance
│   └── 03-argocd-project.yaml    ← ArgoCD AppProject: mec-content-ai
├── acm/                          ← ACM resources (GitOps integration)
│   ├── managedclusterset.yaml    ← defines near-edge + far-edge cluster sets
│   ├── clusterset-binding.yaml   ← binds cluster sets to namespaces
│   ├── placement-near-edge.yaml  ← selects near-edge cluster
│   ├── placement-far-edge.yaml   ← selects all far-edge MEC clusters
│   └── gitopscluster.yaml        ← links ACM placements → ArgoCD
├── apps/
│   ├── near-edge/                ← ArgoCD Applications (near-edge cluster)
│   │   ├── app-data-pipeline.yaml
│   │   ├── app-ai-core.yaml
│   │   ├── app-automation.yaml
│   │   ├── app-agent-mcp.yaml
│   │   └── app-dashboard.yaml
│   └── far-edge/
│       └── appset-far-edge-mec.yaml  ← ApplicationSet targeting all MEC nodes
```

## Deployment Flow

### Bootstrap (one-time)
```bash
source configs/near-edge/env.sh
# 1. Install GitOps operator
oc apply -f gitops/bootstrap/01-gitops-operator.yaml
oc wait --for=condition=Ready csv -n openshift-gitops-operator -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator --timeout=300s
# 2. Configure ArgoCD instance
oc apply -f gitops/bootstrap/02-argocd-instance.yaml
# 3. Create ArgoCD project
oc apply -f gitops/bootstrap/03-argocd-project.yaml
# 4. Configure ACM → ArgoCD integration
oc apply -f gitops/acm/
# 5. Deploy near-edge ArgoCD Applications
oc apply -f gitops/apps/near-edge/
# 6. Deploy far-edge ApplicationSet
oc apply -f gitops/apps/far-edge/
```

### Day-2 Deployments (GitOps driven)
```bash
# All changes after bootstrap go through Git:
git add implementation/phase-XX-*/
git commit -m "feat: add Kafka topic for qoe.metrics"
git push origin main
# ArgoCD auto-syncs within 3 minutes (or trigger manually in ArgoCD UI)
```

## Sync Policy

| App | Auto-sync | Prune | Self-heal |
|---|---|---|---|
| data-pipeline | Yes | Yes | Yes |
| ai-core | No (manual — model changes) | No | Yes |
| automation | No (manual — AAP changes) | No | Yes |
| agent-mcp | Yes | Yes | Yes |
| dashboard | Yes | Yes | Yes |
| far-edge ApplicationSet | Yes | Yes | Yes |

`ai-core` and `automation` are manual-sync to avoid unintended model or playbook rollouts.

## Cluster Labels Required

ACM Placement uses labels to select clusters. Apply these to managed clusters:

```bash
# Near-edge cluster
oc label managedcluster <near-edge-cluster-name> \
  cluster-role=near-edge \
  environment=production \
  region=us-west

# Far-edge MEC nodes
oc label managedcluster <mec-node-name> \
  cluster-role=far-edge \
  site-type=mec \
  venue-type=stadium   # or: venue-type=cell-site
```

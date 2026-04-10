# Start Here — 5G MEC Content Intelligence

Read this before touching anything. This is the authoritative deployment guide.

---

## Deployment Model

**Everything is GitOps after Phase 01 bootstrap.**

```
Phase 01: Manual oc apply (operators + GitOps bootstrap)
    │
    └── ArgoCD + ACM take over
            │
            ├── Phases 02–05, 07: ArgoCD syncs from Git automatically
            ├── Phase 06: ACM ApplicationSet deploys to far-edge MEC nodes
```

You apply YAMLs manually **only in Phase 01** and for the initial `gitops/` bootstrap.
After that: commit to Git → ArgoCD syncs → clusters update.

---

## Environment Setup (do this first)

```bash
# 1. Clone repo
git clone https://github.com/dinlaks/5g-mec-ai.git
cd 5g-mec-ai

# 2. Configure near-edge environment
cp configs/near-edge/env.sh.example configs/near-edge/env.sh
# Edit configs/near-edge/env.sh — fill in ALL values before proceeding

# 3. Source environment
source configs/near-edge/env.sh

# 4. Login to near-edge cluster
oc login $NEAR_EDGE_API --token=$NEAR_EDGE_TOKEN

# 5. Run preflight
./scripts/preflight.sh
# Fix any failures before proceeding
```

---

## Deployment Order

| Order | What | How | GitOps? |
|---|---|---|---|
| 1 | Wave 0 operators | `oc apply -f implementation/phase-01-foundation/operators/wave-0-*` | No |
| 2 | OpenShift GitOps bootstrap | `oc apply -f gitops/bootstrap/` | No |
| 3 | Wave 1 operators | `oc apply -f implementation/phase-01-foundation/operators/wave-1-*` | No |
| 4 | Namespaces | `oc apply -f implementation/phase-01-foundation/namespaces/` | No |
| 5 | ACM + GitOps integration | `oc apply -f gitops/acm/` | No |
| 6 | ArgoCD Applications | `oc apply -f gitops/apps/` | No — but after this, ArgoCD manages |
| 7 | Phase 02–07 | Commit to Git | **Yes — ArgoCD syncs automatically** |
| 8 | Far-edge MEC nodes | Label clusters in ACM | ApplicationSet auto-deploys |

---

## Phase 01 Commands (the only manual phase)

Full step-by-step: [`implementation/phase-01-foundation/README.md`](../../implementation/phase-01-foundation/README.md)
Command log: [`implementation/phase-01-foundation/COMMANDS.md`](../../implementation/phase-01-foundation/COMMANDS.md)

```bash
# Quick reference — run in order:
source configs/near-edge/env.sh
./scripts/preflight.sh

# Wave 0
oc apply -f implementation/phase-01-foundation/operators/wave-0-certmanager-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-0-nfd-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-0-gpu-operator-subscription.yaml
# Wait for wave 0 (check: oc get csv -A | grep -E "cert-manager|nfd|gpu")

# GitOps bootstrap
oc apply -f gitops/bootstrap/01-gitops-operator.yaml
oc apply -f gitops/bootstrap/02-argocd-instance.yaml
oc apply -f gitops/bootstrap/03-argocd-project.yaml
# Wait for ArgoCD (check: oc get pods -n openshift-gitops)

# Wave 1
oc apply -f implementation/phase-01-foundation/operators/wave-1-rhoai-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-1-kafka-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-1-aap-subscription.yaml
oc apply -f implementation/phase-01-foundation/operators/wave-1-acm-subscription.yaml
# Wait for wave 1 (check: oc get csv -A | grep -E "rhoai|amq|aap|acm")

# Namespaces + ACM + GitOps wiring
oc apply -f implementation/phase-01-foundation/namespaces/namespaces.yaml
oc apply -f gitops/acm/
oc apply -f gitops/apps/near-edge/
oc apply -f gitops/apps/far-edge/

# Done — ArgoCD takes over from here
echo "ArgoCD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
```

---

## After Phase 01 — GitOps Workflow

```bash
# All changes from here go through Git:
# 1. Make your changes in the implementation/ folder
# 2. Commit and push
git add implementation/phase-02-data-pipeline/
git commit -m "feat(phase-02): add Kafka cluster and topics"
git push origin main

# 3. ArgoCD syncs automatically (or trigger manually):
oc get applications -n openshift-gitops
# Force sync if needed:
argocd app sync mec-data-pipeline
```

---

## Tracking Progress

- Live status: [`logs/PROGRESS-TRACKER.md`](../../logs/PROGRESS-TRACKER.md)
- Command log: [`logs/COMMANDS-LOG.md`](../../logs/COMMANDS-LOG.md)
- Recovery: [`RECOVERY-CHECKLIST.md`](../../RECOVERY-CHECKLIST.md)

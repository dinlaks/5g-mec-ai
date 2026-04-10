# Phase 08 — Validation & Demo — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Status: ✅ Success | ❌ Failed | ⬜ Not yet run | 🔄 In progress

> **Phase 08 has two parts:**
>
> **Part A — Setup** (run once before demo day):
> Deploy cdn-mock, seed Big Buck Bunny content, apply demand-spike-cronjob.
> These are done by `./scripts/phase-08-deploy.sh` or `deploy-all.sh`.
>
> **Part B — Live Demo** (run during the presentation):
> Use `test-scenarios.sh` to trigger specific scenarios in front of the audience.
> This is NOT automated in the master script — it is interactive.

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `source configs/near-edge/env.sh` | Load env vars | Silent | | ⬜ |
| `oc get pods -n mec-content-ai \| grep agent` | Agent running (Phase 05) | `Running` | | ⬜ |
| `oc get route edgestream-iq -n mec-content-ai` | Dashboard deployed (Phase 07) | Route listed | | ⬜ |
| `oc get kafkatopic demand.predictions -n mec-ai-data` | Kafka topic exists | `Ready` | | ⬜ |

---

## Part A — Setup (run once before demo day)

### Step 1 — Deploy CDN Mock

```bash
oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-pvc.yaml
oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-configmap.yaml
oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-deployment.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f cdn-mock-pvc.yaml` | Create 5Gi PVC for video content | PVC created | | ⬜ |
| `oc apply -f cdn-mock-deployment.yaml` | Deploy Nginx CDN mock + Service + Route | 3 resources created | | ⬜ |
| `oc get pods -n mec-content-ai \| grep cdn-mock` | CDN mock running | `Running` | | ⬜ |
| `oc get route cdn-mock -n mec-content-ai` | Route accessible | Route listed | | ⬜ |

---

### Step 2 — Seed CDN Mock with Big Buck Bunny HLS

> Downloads 360p + 720p + 1080p segments (~800MB, takes 5-10 minutes).
> If seed fails, cdn-mock still works via public CDN fallback proxy.

```bash
oc apply -f implementation/phase-08-validation/cdn-mock/cdn-mock-seed-job.yaml

# Watch progress
oc logs -f job/cdn-mock-seed -n mec-content-ai

# Verify seed complete
oc wait job/cdn-mock-seed --for=condition=Complete --timeout=600s -n mec-content-ai
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f cdn-mock-seed-job.yaml` | Start seeding job | Job created | | ⬜ |
| `oc wait job/cdn-mock-seed --for=condition=Complete` | Seed complete | `condition met` | | ⬜ |
| `curl -s http://cdn-mock.mec-content-ai.svc.cluster.local:8080/nfl-game/manifest.m3u8` | Content served locally | HLS manifest content | | ⬜ |

---

### Step 3 — Apply Demand Spike CronJob

> Publishes realistic demand events every 5 minutes to keep the demo pipeline warm.
> Alternates between high-confidence (EDA path) and medium-confidence (agent path).

```bash
oc apply -f implementation/phase-08-validation/demand-spike-cronjob.yaml

# Verify CronJob created
oc get cronjob demand-spike-simulator -n mec-content-ai

# Trigger one immediately (don't wait 5 minutes)
oc create job demand-spike-now \
  --from=cronjob/demand-spike-simulator \
  -n mec-content-ai
oc logs job/demand-spike-now -n mec-content-ai
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f demand-spike-cronjob.yaml` | Deploy CronJob | `cronjob created` | | ⬜ |
| `oc create job demand-spike-now ...` | Trigger immediately | Events published to Kafka | | ⬜ |
| Consume `demand.predictions` | Verify event in Kafka | JSON with mec_site_id + confidence | | ⬜ |

---

### Step 4 — Full System Smoke Test

```bash
# Run the validate scenario
chmod +x implementation/phase-08-validation/test-scenarios.sh
./implementation/phase-08-validation/test-scenarios.sh --scenario validate
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `test-scenarios.sh --scenario validate` | All components running | All pods Running, URLs listed | | ⬜ |

---

## Part B — Live Demo Execution (demo day)

> Run these during the presentation. Each takes 1-3 minutes to show the full pipeline.
> Open the dashboard (`https://<edgestream-iq-route>`) in a browser before starting.

### Demo Script — Recommended order

```bash
chmod +x implementation/phase-08-validation/test-scenarios.sh

# 1. Start with EDA auto-trigger (fastest, most visual — confidence 0.97)
#    Shows: demand.predictions → EDA → AAP job auto-fires (no agent)
./implementation/phase-08-validation/test-scenarios.sh --scenario eda

# 2. NFL game — agent path (confidence 0.91)
#    Shows: demand.predictions → LangGraph 8 nodes → AAP → cache hit jump
./implementation/phase-08-validation/test-scenarios.sh --scenario nfl

# 3. Human approval (confidence 0.72 — below threshold)
#    Shows: agent suspends → Slack card → you approve → agent resumes
./implementation/phase-08-validation/test-scenarios.sh --scenario synthetic

# 4. (Optional) Stress test — show multi-site simultaneous events
./implementation/phase-08-validation/test-scenarios.sh --scenario stress
```

### What to show on the dashboard during each scenario

| Scenario | Panel to highlight | What audience sees |
|---|---|---|
| EDA auto-trigger | Panel B (predictions) + Panel F (KPIs) | Confidence 0.97 → AAP job fires immediately, no agent involved |
| NFL agent path | Panel C (agent graph) | 8 nodes lighting up in sequence, cache hit rate jumps |
| Human approval | Panel C (approval queue) | Slack card appears, you click Approve, agent resumes |
| After any prefetch | Panel D (cache) | Hit rate jumps from ~12% → 80%+ |

---

## Phase 08 Complete ✅

When setup steps (Part A) are all ✅, the system is demo-ready.

```bash
# Quick system check before going on stage
./implementation/phase-08-validation/test-scenarios.sh --scenario validate

# Open dashboard
echo "Dashboard: https://$(oc get route edgestream-iq -n mec-content-ai -o jsonpath='{.spec.host}')"
```

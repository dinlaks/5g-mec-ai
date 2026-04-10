# Phase 04 — Automation — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Update "Actual Output" and "Status" as you run each command.
Status: ✅ Success | ❌ Failed | ⬜ Not yet run | 🔄 In progress

> **Note:** AAP operator CRs (aap-platform, automation-controller, eda-controller) are
> managed by ArgoCD Application `mec-automation` (auto-sync from Git).
> **Playbooks and EDA rulebook** must be imported into AAP via API/UI — these are
> one-time setup steps not managed by GitOps.

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `source configs/near-edge/env.sh` | Load environment variables | No output (silent) | | ⬜ |
| `oc get namespace aap` | AAP namespace exists from Phase 01 | `Active` | | ⬜ |
| `oc get csv -n aap \| grep aap` | AAP operator ready | `Succeeded` | | ⬜ |
| `oc get kafka -n mec-ai-data` | Kafka cluster ready (Phase 02 dependency) | `kafka-cluster` Ready | | ⬜ |
| `oc get kafkatopic demand-predictions -n mec-ai-data` | demand.predictions topic exists | `Ready` | | ⬜ |

---

## Step 1 — Apply Phase 04 Secrets (manual — not GitOps managed)

> The AAP admin password secret must exist before the AutomationController CR is applied.
> Create it now so ArgoCD sync does not fail waiting for it.

```bash
# Generate a strong AAP admin password
export AAP_ADMIN_PASSWORD=$(openssl rand -hex 16)
echo "Save this password: $AAP_ADMIN_PASSWORD"

# Add to configs/near-edge/env.sh
echo "export AAP_ADMIN_PASSWORD=${AAP_ADMIN_PASSWORD}" >> configs/near-edge/env.sh
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `./scripts/apply-secrets.sh --validate` | Check Phase 04 env vars set | `All required variables are set` | | ⬜ |
| `./scripts/apply-secrets.sh --phase 04` | Create AAP admin secret | `aap-admin-secret` applied in `aap` namespace | | ⬜ |
| `oc get secret aap-admin-secret -n aap` | Verify secret exists | Secret listed | | ⬜ |

---

## Step 2 — Deploy AAP Platform (GitOps)

> ArgoCD Application `mec-automation` auto-syncs these from Git.
> Manual apply only if ArgoCD is not yet set up.

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-04-automation/aap/aap-platform.yaml` | Deploy AAP platform CR | `ansibleautomationplatform/aap created` | | ⬜ |
| `oc get ansibleautomationplatform -n aap` | AAP platform CR exists | `aap` listed | | ⬜ |
| `oc apply -f implementation/phase-04-automation/aap/automation-controller.yaml` | Deploy AutomationController | `automationcontroller/controller created` | | ⬜ |
| `oc apply -f implementation/phase-04-automation/aap/eda-controller.yaml` | Deploy EDAController | `edacontroller/eda-controller created` | | ⬜ |

---

## Step 3 — Wait for AAP Components to Be Ready

> AAP takes 5–10 minutes to fully initialize. Be patient — do not proceed to Step 4 until all pods are Running.

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get pods -n aap` | Watch AAP pods come up | All pods `Running` (controller-web, controller-task, eda-controller) | | ⬜ |
| `oc wait deployment/controller --for=condition=Available --timeout=600s -n aap` | AutomationController ready | `condition met` | | ⬜ |
| `oc wait deployment/eda-controller --for=condition=Available --timeout=600s -n aap` | EDAController ready | `condition met` | | ⬜ |
| `oc get route controller -n aap -o jsonpath='{.spec.host}'` | Get AAP controller URL | `controller.apps.<cluster>` | | ⬜ |
| `oc get route eda-controller -n aap -o jsonpath='{.spec.host}'` | Get EDA controller URL | `eda-controller.apps.<cluster>` | | ⬜ |

### Verify AAP UI is accessible
```bash
AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}')
echo "AAP UI: https://${AAP_URL}"
# Open in browser — login with admin / $AAP_ADMIN_PASSWORD
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| AAP UI accessible in browser | Confirm AAP is working | Login page loads | | ⬜ |
| Login with `admin` / `$AAP_ADMIN_PASSWORD` | Verify admin credentials work | Dashboard visible | | ⬜ |

---

## Step 4 — Get AAP API Token (needed for mcp-aap in Phase 05)

> The agent calls AAP via REST API. It needs a long-lived API token — not the admin password.

### 4a — Create token via AAP UI
1. Log into AAP UI → top right → **User icon** → **My Profile**
2. Click **Tokens** tab → **Add** → Scope: **Write** → Save
3. Copy the token — shown only once

### 4b — Or create via API
```bash
AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}')

curl -s -X POST "https://${AAP_URL}/api/v2/tokens/" \
  -H "Content-Type: application/json" \
  -u "admin:${AAP_ADMIN_PASSWORD}" \
  -d '{"description":"mcp-aap agent token","application":null,"scope":"write"}' \
  --insecure | jq '.token'
```

### 4c — Save token to env.sh
```bash
# Edit configs/near-edge/env.sh
export AAP_TOKEN="<paste-token-here>"
export AAP_HOST="https://$(oc get route controller -n aap -o jsonpath='{.spec.host}')"

# Source and re-apply Phase 05 secrets (AAP_TOKEN is needed there)
source configs/near-edge/env.sh
./scripts/apply-secrets.sh --phase 05
```

| Step | Why | Expected | Actual | Status |
|---|---|---|---|---|
| AAP API token generated | Agent needs this to trigger playbooks | Token string (long alphanumeric) | | ⬜ |
| `AAP_TOKEN` saved to `configs/near-edge/env.sh` | Single source of truth | Variable set | | ⬜ |
| `./scripts/apply-secrets.sh --phase 05` | Update aap-secret in mec-content-ai ns | `aap-secret` updated | | ⬜ |

---

## Step 5 — Import Playbooks into AAP

> Playbooks are stored in this Git repo. AAP pulls them via an SCM (Source Control) project.
> This is a one-time setup — after this, playbooks are available as Job Templates.

### 5a — Create AAP Organization
```bash
AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}')

curl -s -X POST "https://${AAP_URL}/api/v2/organizations/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  -d '{"name":"MEC Content Intelligence","description":"5G MEC Content Pre-positioning"}' \
  --insecure | jq '.id'
# Note the organization ID
```

### 5b — Create SCM Credential (for private Git repo)
```bash
# Skip if repo is public. For private repo:
curl -s -X POST "https://${AAP_URL}/api/v2/credentials/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  -d "{
    \"name\": \"mec-git-credential\",
    \"organization\": <org-id>,
    \"credential_type\": 2,
    \"inputs\": {
      \"username\": \"${GIT_USERNAME}\",
      \"password\": \"${GIT_TOKEN}\"
    }
  }" \
  --insecure | jq '.id'
```

### 5c — Create AAP Project (points to this Git repo)
```bash
curl -s -X POST "https://${AAP_URL}/api/v2/projects/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  -d "{
    \"name\": \"mec-content-playbooks\",
    \"organization\": <org-id>,
    \"scm_type\": \"git\",
    \"scm_url\": \"${GIT_REPO_URL}\",
    \"scm_branch\": \"main\",
    \"scm_update_on_launch\": true,
    \"credential\": <scm-credential-id-or-null>
  }" \
  --insecure | jq '.id'
# Note the project ID — wait for sync to complete before Step 5d
```

### 5d — Wait for project sync
```bash
# Check project sync status
curl -s "https://${AAP_URL}/api/v2/projects/<project-id>/" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  --insecure | jq '.status'
# Wait until: "successful"
```

### 5e — Create Inventory (MEC sites)
```bash
curl -s -X POST "https://${AAP_URL}/api/v2/inventories/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  -d "{
    \"name\": \"mec-sites\",
    \"organization\": <org-id>,
    \"description\": \"MEC node fleet inventory\"
  }" \
  --insecure | jq '.id'
```

### 5f — Create Job Templates (one per playbook)

```bash
# Helper function
create_job_template() {
  local NAME=$1
  local PLAYBOOK=$2
  curl -s -X POST "https://${AAP_URL}/api/v2/job_templates/" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AAP_TOKEN}" \
    -d "{
      \"name\": \"${NAME}\",
      \"organization\": <org-id>,
      \"project\": <project-id>,
      \"playbook\": \"implementation/phase-04-automation/playbooks/${PLAYBOOK}\",
      \"inventory\": <inventory-id>,
      \"ask_variables_on_launch\": true,
      \"extra_vars\": \"{}\"
    }" \
    --insecure | jq '.id'
}

create_job_template "prefetch-content"   "prefetch-content.yml"
create_job_template "set-qos-policy"     "set-qos-policy.yml"
create_job_template "push-abr-policy"    "push-abr-policy.yml"
create_job_template "rollback-cache"     "rollback-cache.yml"
create_job_template "alert-noc"          "alert-noc.yml"
```

| Step | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Organization created | Namespace for all AAP objects | `MEC Content Intelligence` org exists | | ⬜ |
| Project created + synced | AAP can see the playbooks from Git | Project status `successful` | | ⬜ |
| Inventory created | Target for playbook execution | `mec-sites` inventory exists | | ⬜ |
| 5 job templates created | Agent calls these via REST API by name | `prefetch-content`, `set-qos-policy`, `push-abr-policy`, `rollback-cache`, `alert-noc` all listed | | ⬜ |

---

## Step 6 — Import EDA Rulebook

> The EDA rulebook is in `aap/eda-rulebook.yaml`. It must be imported into the
> EDA Controller via its REST API and activated as a Rulebook Activation.

### 6a — Get EDA Controller URL and token
```bash
EDA_URL=$(oc get route eda-controller -n aap -o jsonpath='{.spec.host}')
echo "EDA URL: https://${EDA_URL}"

# Get EDA token (uses same AAP admin credentials)
EDA_TOKEN=$(curl -s -X POST "https://${EDA_URL}/api/eda/v1/auth/token/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${AAP_ADMIN_PASSWORD}\"}" \
  --insecure | jq -r '.token')
echo "EDA Token obtained: ${EDA_TOKEN:0:10}..."
```

### 6b — Create EDA Project (same Git repo)
```bash
curl -s -X POST "https://${EDA_URL}/api/eda/v1/projects/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${EDA_TOKEN}" \
  -d "{
    \"name\": \"mec-content-rulebooks\",
    \"url\": \"${GIT_REPO_URL}\",
    \"description\": \"MEC Content Intelligence EDA rulebooks\"
  }" \
  --insecure | jq '.id'
# Note the EDA project ID — wait for sync
```

### 6c — Create Rulebook Activation
```bash
curl -s -X POST "https://${EDA_URL}/api/eda/v1/activations/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${EDA_TOKEN}" \
  -d "{
    \"name\": \"mec-demand-predictions-listener\",
    \"description\": \"Listens on demand.predictions — auto-triggers prefetch at confidence >= 0.95\",
    \"rulebook_id\": <rulebook-id>,
    \"project_id\": <eda-project-id>,
    \"decision_environment_id\": 1,
    \"awx_token_id\": <aap-token-id>,
    \"restart_policy\": \"always\",
    \"extra_var\": \"{\\\"kafka_bootstrap_host\\\": \\\"kafka-cluster-kafka-bootstrap.mec-ai-data.svc.cluster.local\\\", \\\"kafka_bootstrap_port\\\": 9092}\"
  }" \
  --insecure | jq '.id'
```

### 6d — Verify activation is running
```bash
curl -s "https://${EDA_URL}/api/eda/v1/activations/" \
  -H "Authorization: Bearer ${EDA_TOKEN}" \
  --insecure | jq '.results[] | {name, status}'
# Expected: "status": "running"
```

| Step | Why | Expected | Actual | Status |
|---|---|---|---|---|
| EDA token obtained | Authenticate with EDA Controller | Token returned | | ⬜ |
| EDA project created + synced | EDA can see the rulebook from Git | Project synced | | ⬜ |
| Rulebook activation created | EDA is listening on Kafka | Activation `running` | | ⬜ |
| Activation status `running` | Confirm EDA is actively consuming | `"status": "running"` | | ⬜ |

---

## Step 7 — End-to-End Test

> Publish a test event to `demand.predictions` with confidence ≥ 0.95.
> EDA should auto-trigger the `prefetch-content` job template within seconds.

### 7a — Publish test demand event
```bash
# Publish a high-confidence demand prediction to Kafka
oc run eda-test-producer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions
```

When the prompt appears, paste this JSON and press Enter, then Ctrl+C:
```json
{"mec_site_id":"mec-stadium-01","content_id":"nfl-game-test","content_url":"http://cdn-mock.mec-content-ai.svc.cluster.local:8080/nfl-game","predicted_viewers":48000,"event_type":"live_sport","event_start_utc":"2026-04-08T20:00:00Z","confidence":0.97,"predicted_peak_in_minutes":22}
```

### 7b — Verify EDA triggered AAP job
```bash
# Watch for new AAP job in the last 60 seconds
AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}')
curl -s "https://${AAP_URL}/api/v2/jobs/?order_by=-created&page_size=5" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  --insecure | jq '.results[] | {id, name: .summary_fields.job_template.name, status, started}'
```

### 7c — Check job completed successfully
```bash
# Get the job ID from 7b output, then:
JOB_ID=<job-id-from-above>
curl -s "https://${AAP_URL}/api/v2/jobs/${JOB_ID}/" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  --insecure | jq '{status, started, finished, elapsed}'
# Expected: "status": "successful"
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Publish test event to `demand.predictions` | Trigger EDA → AAP flow | Message produced | | ⬜ |
| AAP job appears within 10s | EDA picked up event and triggered job | New `prefetch-content` job in AAP | | ⬜ |
| AAP job status `successful` | Playbook ran end-to-end without errors | `"status": "successful"` | | ⬜ |
| `cache.state` topic has new message | Playbook published cache update to Kafka | Message visible in consumer | | ⬜ |

### Verify cache.state message
```bash
oc run cache-state-consumer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic cache.state \
  --from-beginning \
  --max-messages 1
```

---

## Phase 04 Complete ✅

When all rows above are ✅, Phase 04 is done.

### Quick validation summary
```bash
# AAP components running
oc get pods -n aap

# All 5 job templates exist
AAP_URL=$(oc get route controller -n aap -o jsonpath='{.spec.host}')
curl -s "https://${AAP_URL}/api/v2/job_templates/" \
  -H "Authorization: Bearer ${AAP_TOKEN}" \
  --insecure | jq '.results[].name'

# EDA activation running
EDA_URL=$(oc get route eda-controller -n aap -o jsonpath='{.spec.host}')
curl -s "https://${EDA_URL}/api/eda/v1/activations/" \
  -H "Authorization: Bearer ${EDA_TOKEN}" \
  --insecure | jq '.results[] | {name, status}'
```

**Next:** Phase 05 — Agent & MCP (`state.py` → `agent.py` → 7 MCP servers).
`AAP_TOKEN` is now in `env.sh` and Phase 05 `aap-secret` is ready.

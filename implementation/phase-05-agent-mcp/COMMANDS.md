# Phase 05 — Agent & MCP Servers — Commands Log

Format: `Command | Why | Expected Output | Actual Output | Status`
Update "Actual Output" and "Status" as you run each command.
Status: ✅ Success | ❌ Failed | ⬜ Not yet run | 🔄 In progress

> **Note:** GitOps (ArgoCD app `mec-agent-mcp`) manages the deployment YAMLs.
> Images must be built first via BuildConfigs — ArgoCD cannot do this.
> Order: RBAC → Secrets → Build images → Deploy → Verify → Test

---

## Pre-checks

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `source configs/near-edge/env.sh` | Load env vars | Silent | | ⬜ |
| `oc get namespace mec-content-ai` | Namespace exists from Phase 01 | `Active` | | ⬜ |
| `oc get pods -n mec-ai-obs \| grep langfuse` | Langfuse running (Phase 02 dep) | `langfuse-web` Running | | ⬜ |
| `oc get inferenceservice -n redhat-ods-applications` | LlamaStack ready (Phase 03 dep) | InferenceService listed | | ⬜ |
| `oc get automationcontroller -n aap` | AAP running (Phase 04 dep) | `controller` listed | | ⬜ |
| `oc get kafkatopic demand-predictions -n mec-ai-data` | demand.predictions topic ready | `Ready` | | ⬜ |

---

## Step 1 — Apply Secrets

> Phase 05 secrets (Slack, Langfuse API key, AAP token) must exist
> before deploying. These were created in Phase 02 Step 7 and Phase 04 Step 4.
> Verify they exist — if missing, re-run apply-secrets.sh.

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get secret slack-secret -n mec-content-ai` | Slack bot token secret exists | Secret listed | | ⬜ |
| `oc get secret langfuse-api-secret -n mec-content-ai` | Langfuse API key secret exists | Secret listed | | ⬜ |
| `oc get secret aap-secret -n mec-content-ai` | AAP token secret exists | Secret listed | | ⬜ |

### If any secret is missing — re-apply
```bash
source configs/near-edge/env.sh
./scripts/apply-secrets.sh --validate
./scripts/apply-secrets.sh --phase 05
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `./scripts/apply-secrets.sh --phase 05` | Re-create missing secrets | All 5 secrets applied | | ⬜ |

---

## Step 2 — Apply RBAC

> Must be applied before deployments — pods will fail to start without ServiceAccounts
> and mcp-openshift will crash without its ClusterRole.

```bash
oc apply -f implementation/phase-05-agent-mcp/rbac.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f implementation/phase-05-agent-mcp/rbac.yaml` | Create all SAs, ClusterRole, RoleBindings | 7 SAs + 1 ClusterRole + 2 bindings created | | ⬜ |
| `oc get sa -n mec-content-ai \| grep -E "agent\|mcp"` | All 7 ServiceAccounts exist | 7 SAs listed | | ⬜ |
| `oc get clusterrole mcp-openshift-role` | ClusterRole created | `mcp-openshift-role` listed | | ⬜ |
| `oc get clusterrolebinding mcp-openshift-role-binding` | ClusterRoleBinding created | Listed | | ⬜ |
| `oc get rolebinding mec-content-ai-image-pullers -n mec-content-ai` | Image-puller binding created | Listed | | ⬜ |

---

## Step 3 — Patch BuildConfigs with Git Repo URL

> BuildConfigs reference `${GIT_REPO_URL}` — replace with your actual Git remote URL.

```bash
# Set your Git repo URL
export GIT_REPO_URL="https://github.com/dinlaks/5g-mec-ai.git"

# Patch agent BuildConfig
oc patch buildconfig content-intelligence-agent -n mec-content-ai \
  --type=merge \
  -p "{\"spec\":{\"source\":{\"git\":{\"uri\":\"${GIT_REPO_URL}\"}}}}"

# Patch all 7 MCP server BuildConfigs
for server in mcp-network-intel mcp-kafka mcp-aap mcp-slack mcp-kubeflow mcp-openshift; do
  oc patch buildconfig ${server} -n mec-content-ai \
    --type=merge \
    -p "{\"spec\":{\"source\":{\"git\":{\"uri\":\"${GIT_REPO_URL}\"}}}}"
  echo "Patched: ${server}"
done
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Patch agent BuildConfig (above) | Set Git URL | `buildconfig.build.openshift.io/content-intelligence-agent patched` | | ⬜ |
| Patch all 6 MCP BuildConfigs (above) | Set Git URL for each | 6 × `patched` | | ⬜ |

---

## Step 4 — Apply BuildConfigs and ImageStreams

```bash
# Agent
oc apply -f implementation/phase-05-agent-mcp/agent/buildconfig.yaml

# MCP servers (all 7 ImageStreams + BuildConfigs in one file)
oc apply -f implementation/phase-05-agent-mcp/mcp-servers/mcp-servers-buildconfig.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f .../agent/buildconfig.yaml` | Create agent ImageStream + BuildConfig | 2 resources created | | ⬜ |
| `oc apply -f .../mcp-servers-buildconfig.yaml` | Create 6 × ImageStream + BuildConfig | 12 resources created | | ⬜ |
| `oc get buildconfig -n mec-content-ai` | All 7 BuildConfigs exist | 7 BCs listed | | ⬜ |
| `oc get imagestream -n mec-content-ai` | All 7 ImageStreams exist | 7 ISs listed | | ⬜ |

---

## Step 5 — Build All Images

> Builds run in parallel. Each takes 3–8 minutes depending on pip install time.
> Monitor with `oc logs -f bc/<name> -n mec-content-ai`.

```bash
# Start all builds in parallel
for bc in content-intelligence-agent mcp-network-intel mcp-kafka mcp-aap \
          mcp-slack mcp-kubeflow mcp-openshift; do
  echo "Starting build: ${bc}"
  oc start-build ${bc} -n mec-content-ai
done
```

### Monitor build progress
```bash
# Watch all builds
oc get builds -n mec-content-ai -w

# Tail logs for a specific build (replace name)
oc logs -f bc/content-intelligence-agent -n mec-content-ai
oc logs -f bc/mcp-network-intel -n mec-content-ai
```

| Build | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `content-intelligence-agent` | Agent image | Build `Complete` | | ⬜ |
| `mcp-network-intel` | MCP server image | Build `Complete` | | ⬜ |
| `mcp-kafka` | MCP server image | Build `Complete` | | ⬜ |
| `mcp-aap` | MCP server image | Build `Complete` | | ⬜ |
| `mcp-slack` | MCP server image | Build `Complete` | | ⬜ |
| `mcp-kubeflow` | MCP server image | Build `Complete` | | ⬜ |
| `mcp-openshift` | MCP server image | Build `Complete` | | ⬜ |

### Verify all ImageStreams have a tag
```bash
oc get imagestream -n mec-content-ai \
  -o custom-columns='NAME:.metadata.name,TAGS:.status.tags[*].tag'
# Expected: every IS shows "latest" tag
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get imagestream -n mec-content-ai` (above) | All images built and tagged | All ISs show `latest` | | ⬜ |

---

## Step 6 — Deploy MCP Servers and Agent

> ArgoCD auto-syncs these from Git. If ArgoCD is not yet watching, apply manually.

```bash
# Apply MCP server deployments
oc apply -f implementation/phase-05-agent-mcp/mcp-servers/mcp-servers-deployment.yaml

# Apply agent deployment
oc apply -f implementation/phase-05-agent-mcp/agent/deployment.yaml
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc apply -f .../mcp-servers-deployment.yaml` | Deploy all 6 MCP servers | 6 Deployments + 6 Services + 1 SA + 1 CRB + 1 Secret created | | ⬜ |
| `oc apply -f .../agent/deployment.yaml` | Deploy agent | Deployment + Service + Route created | | ⬜ |

---

## Step 7 — Verify All Pods Running

```bash
# Watch pods come up
oc get pods -n mec-content-ai -w
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc get pods -n mec-content-ai \| grep mcp` | All 6 MCP server pods running | 6 pods `Running` | | ⬜ |
| `oc get pods -n mec-content-ai \| grep agent` | Agent pod running | 1 pod `Running` | | ⬜ |
| `oc wait deployment/content-intelligence-agent --for=condition=Available --timeout=120s -n mec-content-ai` | Agent available | `condition met` | | ⬜ |
| `oc wait deployment/mcp-network-intel --for=condition=Available --timeout=120s -n mec-content-ai` | mcp-network-intel available | `condition met` | | ⬜ |
| `oc wait deployment/mcp-kafka --for=condition=Available --timeout=120s -n mec-content-ai` | mcp-kafka available | `condition met` | | ⬜ |
| `oc wait deployment/mcp-aap --for=condition=Available --timeout=120s -n mec-content-ai` | mcp-aap available | `condition met` | | ⬜ |
| `oc wait deployment/mcp-slack --for=condition=Available --timeout=120s -n mec-content-ai` | mcp-slack available | `condition met` | | ⬜ |
| `oc wait deployment/mcp-openshift --for=condition=Available --timeout=120s -n mec-content-ai` | mcp-openshift available | `condition met` | | ⬜ |

### Troubleshoot if pods are not Running
```bash
# Check pod events (SCC issues show here)
oc describe pod -l app.kubernetes.io/name=content-intelligence-agent -n mec-content-ai

# Check container logs
oc logs -l app.kubernetes.io/name=mcp-openshift -n mec-content-ai

# Check SCC assignment
oc get pod -l app.kubernetes.io/name=mcp-openshift -n mec-content-ai \
  -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}'
# Expected: restricted-v2
```

---

## Step 8 — Health Checks

```bash
AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}')
echo "Agent URL: https://${AGENT_URL}"
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `curl -sk https://${AGENT_URL}/health` | Agent API responding | `{"status":"ok","service":"content-intelligence-agent"}` | | ⬜ |
| `curl -sk http://mcp-network-intel:8000/health` (from agent pod) | mcp-network-intel healthy | `{"status":"ok"}` | | ⬜ |
| `curl -sk http://mcp-kafka:8000/health` (from agent pod) | mcp-kafka healthy | `{"status":"ok"}` | | ⬜ |
| `curl -sk http://mcp-openshift:8000/health` (from agent pod) | mcp-openshift healthy | `{"status":"ok"}` | | ⬜ |

### Health check all MCP servers from agent pod
```bash
AGENT_POD=$(oc get pod -l app.kubernetes.io/name=content-intelligence-agent \
  -n mec-content-ai -o jsonpath='{.items[0].metadata.name}')

for server in mcp-network-intel mcp-kafka mcp-aap mcp-slack \
              mcp-kubeflow mcp-openshift; do
  STATUS=$(oc exec ${AGENT_POD} -n mec-content-ai -- \
    curl -s http://${server}:8000/health 2>/dev/null)
  echo "${server}: ${STATUS}"
done
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| MCP health check loop (above) | All 6 MCP servers reachable from agent | 6 × `{"status":"ok"}` | | ⬜ |

---

## Step 9 — Verify mcp-openshift RBAC

```bash
# Confirm mcp-openshift-sa can read pods across namespaces
oc auth can-i list pods --as=system:serviceaccount:mec-content-ai:mcp-openshift-sa \
  --all-namespaces
# Expected: yes

# Confirm it can read InferenceServices
oc auth can-i list inferenceservices.serving.kserve.io \
  --as=system:serviceaccount:mec-content-ai:mcp-openshift-sa \
  --all-namespaces
# Expected: yes

# Confirm it CANNOT read secrets (least privilege check)
oc auth can-i list secrets \
  --as=system:serviceaccount:mec-content-ai:mcp-openshift-sa \
  --all-namespaces
# Expected: no
```

| Command | Why | Expected | Actual | Status |
|---|---|---|---|---|
| `oc auth can-i list pods` (above) | mcp-openshift can read pods | `yes` | | ⬜ |
| `oc auth can-i list inferenceservices` (above) | mcp-openshift can read KServe ISVCs | `yes` | | ⬜ |
| `oc auth can-i list secrets` (above) | Least privilege — no secret access | `no` | | ⬜ |

---

## Step 10 — End-to-End Test

> Publish a synthetic demand event to Kafka. The agent should wake up,
> run the full 8-node graph, and produce output in Langfuse + Kafka.

### 10a — Publish test demand event
```bash
oc run e2e-test-producer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic demand.predictions
```

Paste this JSON when prompted (confidence 0.88 — triggers agent, not EDA):
```json
{"mec_site_id":"mec-stadium-01","content_id":"nfl-game-test","content_url":"http://cdn-mock.mec-content-ai.svc.cluster.local:8080/nfl-game","predicted_viewers":42000,"event_type":"live_sport","event_start_utc":"2026-04-08T20:00:00Z","confidence":0.88,"predicted_peak_in_minutes":25}
```

### 10b — Watch agent logs
```bash
oc logs -f deployment/content-intelligence-agent -n mec-content-ai
# Look for: "New demand event → run_id=...", then node progression:
# demand_reader → context_enricher → strategy_reasoner → confidence_gate → ...
```

### 10c — Check agent state via API
```bash
# Get run_id from logs, then:
AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai \
  -o jsonpath='{.spec.host}')
RUN_ID=<run-id-from-logs>

curl -sk "https://${AGENT_URL}/agent/state/${RUN_ID}" | jq '{node_history, confidence, strategy, outcome}'
```

### 10d — Verify Langfuse trace
```bash
LANGFUSE_URL=$(oc get route langfuse -n mec-ai-obs -o jsonpath='{.spec.host}')
echo "Langfuse: https://${LANGFUSE_URL}"
# Open in browser → Traces → find run_id
# Expected: 5–8 spans visible (one per node visited)
```

### 10e — Check remediation.outcomes Kafka topic
```bash
oc run outcomes-consumer --rm -it \
  --image=registry.redhat.io/amq-streams/kafka-38-rhel9:latest \
  -n mec-ai-data -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-cluster-kafka-bootstrap:9092 \
  --topic remediation.outcomes \
  --from-beginning \
  --max-messages 1
```

| Step | Why | Expected | Actual | Status |
|---|---|---|---|---|
| Publish demand event | Trigger agent | Message produced | | ⬜ |
| Agent logs show node progression | Agent processed event | `demand_reader → ... → kubeflow_trigger` in logs | | ⬜ |
| `GET /agent/state/{run_id}` returns state | Agent API working | JSON with `node_history`, `strategy`, `outcome` | | ⬜ |
| Langfuse trace visible | Observability working | Trace with 5–8 spans in Langfuse UI | | ⬜ |
| `remediation.outcomes` has message | Agent published final outcome | JSON outcome message in topic | | ⬜ |

---

## Phase 05 Complete ✅

When all rows above are ✅, Phase 05 is done.

### Quick validation summary
```bash
# All 8 pods running
oc get pods -n mec-content-ai | grep -E "agent|mcp"

# Agent API healthy
AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai -o jsonpath='{.spec.host}')
curl -sk https://${AGENT_URL}/health

# List active runs
curl -sk https://${AGENT_URL}/runs | jq
```

**Next:** Phase 06 — Far Edge (KServe LSTM, ABR Policy Engine, Cache Manager, Telemetry Collector on SNO).

### Prerequisites reminder before Phase 06
- At least one MEC node running **OpenShift SNO** must be registered with ACM
- ACM ApplicationSet (`gitops/apps/far-edge/appset-far-edge-mec.yaml`) must be applied

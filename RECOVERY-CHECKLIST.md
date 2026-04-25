# Recovery Checklist — 5G MEC Content Intelligence

Use this before a redeploy or when recovering from a partial failure.
Work through each section top to bottom. Do not skip steps.

---

## Pre-Redeploy Safety

- [ ] Both cluster contexts available: `oc config get-contexts`
- [ ] Near-edge env sourced: `source configs/near-edge/env.sh`
- [ ] Far-edge env sourced: `source configs/far-edge/env.sh`
- [ ] Pull secret present: `ls configs/near-edge/pull-secret.json`
- [ ] Slack bot token set: `echo $SLACK_BOT_TOKEN`
- [ ] Ran preflight: `./scripts/phase-01-deploy.sh --validate`
- [ ] Ran dry-run: `./scripts/deploy-dry-run.sh`

---

## Phase 01 — Foundation

- [ ] cert-manager operator Running: `oc get pods -n cert-manager-operator`
- [ ] NFD operator Running: `oc get pods -n openshift-nfd`
- [ ] GPU operator Running: `oc get pods -n gpu-operator`
- [ ] RHOAI operator Running: `oc get pods -n redhat-ods-operator`
- [ ] AMQ Streams operator Running: `oc get pods -n amq-streams`
- [ ] AAP operator Running: `oc get pods -n aap`
- [ ] ACM operator Running: `oc get pods -n open-cluster-management`
- [ ] All namespaces created: `oc get namespaces | grep mec`
- [ ] GPU node labelled and detected: `oc get nodes -l nvidia.com/gpu.present=true`

## Phase 02 — Data Pipeline

- [ ] Kafka cluster Ready: `oc get kafka -n mec-ai-data`
- [ ] All 8 Kafka topics created: `oc get kafkatopics -n mec-ai-data`
- [ ] Langfuse pod Running: `oc get pods -n mec-ai-obs | grep langfuse`
- [ ] ClickHouse pod Running: `oc get pods -n mec-ai-obs | grep clickhouse`
- [ ] Redis pod Running: `oc get pods -n mec-ai-obs | grep redis`
- [ ] MinIO pod Running: `oc get pods -n mec-ai-data | grep minio`
- [ ] Langfuse route accessible: `curl -s $LANGFUSE_HOST/api/public/health`

## Phase 03 — AI Core

- [ ] RHOAI DataScienceCluster Ready: `oc get datasciencecluster`
- [ ] vLLM InferenceService Ready: `oc get inferenceservice -n redhat-ods-applications`
- [ ] Model loaded and responsive: `curl $VLLM_URL/health`
- [ ] LlamaStack pod Running: `oc get pods -n mec-content-ai | grep llamastack`
- [ ] LlamaStack model registered: check LlamaStack API

## Phase 04 — Automation

- [ ] AAP controller Running: `oc get automationcontroller -n aap`
- [ ] EDA controller Running: `oc get edacontroller -n aap`
- [ ] EDA rulebook activated and listening on Kafka
- [ ] ACM hub Running: `oc get mch -n open-cluster-management`
- [ ] All 5 AAP playbooks imported in controller

## Phase 05 — Agent & MCP

- [ ] All 6 MCP servers Running: `oc get pods -n mec-content-ai | grep mcp`
- [ ] Agent pod Running: `oc get pods -n mec-content-ai | grep agent`
- [ ] Agent health: `curl $AGENT_URL/health`
- [ ] MCP connectivity test: `curl $AGENT_URL/mcp/status`
- [ ] Langfuse traces appearing for test runs

## Phase 06 — Far Edge

- [ ] KServe LSTM pod Running on far-edge SNO node
- [ ] Telemetry Collector publishing to Kafka: check topic `content.requests.live`
- [ ] Cache Manager running (Nginx + NVMe)
- [ ] ABR Policy Engine running
- [ ] EDA Receiver listening on far edge

## Phase 07 — Dashboard

- [ ] EdgeStream IQ backend Running: `oc get pods -n mec-content-ai | grep edgestream-backend`
- [ ] EdgeStream IQ frontend Running: `oc get pods -n mec-content-ai | grep edgestream-frontend`
- [ ] Dashboard route accessible: `curl -s $EDGESTREAM_URL`
- [ ] WebSocket connects and Kafka data flows to panels
- [ ] Agent node graph renders in Panel C

## Phase 08 — Validation

- [ ] Demand spike simulator CronJob deployed
- [ ] Run NFL scenario: `./scripts/validate-demo.sh nfl`
- [ ] Agent completes full cycle (demand_reader → kubeflow_trigger)
- [ ] Slack notification received on #mec-ai-ops
- [ ] EdgeStream IQ panels update live during scenario
- [ ] Cache hit rate rises from ~12% to ~80%+ after prefetch

---

## Emergency Teardown

```bash
source configs/near-edge/env.sh
./scripts/teardown.sh
```

**WARNING:** This removes all custom deployments. Operators remain installed.
To remove operators too, pass `--include-operators` flag.

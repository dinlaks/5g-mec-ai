# Phase 04 — Automation (AAP + EDA)

## What This Phase Does

Deploys Ansible Automation Platform 2.5 and Event-Driven Ansible on the near-edge OpenShift
cluster. After this phase:

- **AutomationController** is running — hosts playbooks, job templates, inventories, credentials
- **EDAController** is running — listens on Kafka `demand.predictions` topic, auto-triggers
  `prefetch-content` playbook when confidence > 0.95 (bypassing the LangGraph agent entirely
  for the highest-confidence events to save latency)
- **5 playbooks** are imported and ready to be called via AAP REST API by `mcp-aap` (Phase 05)

## Architecture Context

```
Kafka: demand.predictions
        │
        ▼
   EDA Controller ──────────────────────────────────────┐
   (near edge)                                           │
   Rule: confidence > 0.95                               │
        │                                                │
        │ NO (handled by LangGraph agent via mcp-aap)    │ YES (auto-trigger, bypass agent)
        ▼                                                ▼
   LangGraph agent                               AAP AutomationController
   (Phase 05)                                         │
        │                                        job: prefetch-content
        ▼                                             │
   mcp-aap ──────────────────────────────────────────►│
   (REST API call)                                    │
                                          ┌───────────┼───────────────┐
                                          ▼           ▼               ▼
                                  Far Edge MEC   PCF/UPF API     Slack webhook
                                  (NVMe cache)   (QoS rules)     (NOC alert)
```

## Playbooks in This Phase

| Playbook | Triggered By | What It Does |
|---|---|---|
| `prefetch-content.yml` | EDA (auto, conf >0.95) + agent via mcp-aap | SSH to MEC nodes, pull video segments into `/var/mec-cache` via Nginx |
| `set-qos-policy.yml` | Agent via mcp-aap | Call PCF API to apply per-UE QoS policy |
| `push-abr-policy.yml` | Agent via mcp-aap | Push ABR quality tier config to far-edge KServe ABR engine |
| `rollback-cache.yml` | Agent via mcp-aap (on bad QoE) | Flush NVMe cache, restore default Nginx config |
| `alert-noc.yml` | Agent via mcp-aap (any critical event) | Send structured Slack notification to NOC channel |

## Files in This Phase

```
phase-04-automation/
├── README.md                          ← this file
├── COMMANDS.md                        ← step-by-step deployment + verification
├── aap/
│   ├── aap-platform.yaml             ← AnsibleAutomationPlatform CR (top-level)
│   ├── automation-controller.yaml    ← AutomationController CR
│   ├── eda-controller.yaml           ← EDAController CR
│   └── eda-rulebook.yaml             ← Ansible Rulebook (imported into EDA via API)
└── playbooks/
    ├── prefetch-content.yml          ← pre-cache video segments on MEC nodes
    ├── set-qos-policy.yml            ← apply per-UE QoS via PCF API
    ├── push-abr-policy.yml           ← push ABR quality tiers to far edge
    ├── rollback-cache.yml            ← emergency cache flush + restore
    └── alert-noc.yml                 ← Slack notification to NOC channel
```

## Namespaces

| Namespace | What Lives Here |
|---|---|
| `aap` | AutomationController, EDAController, AAP platform pods |

## Dependencies

| Dependency | Why | Phase |
|---|---|---|
| Operators deployed | `aap-operator` must be `Succeeded` | Phase 01 wave-1 |
| Namespace `aap` exists | All AAP resources deploy here | Phase 01 |
| Kafka `demand.predictions` topic | EDA subscribes to this | Phase 02 |
| `aap-admin-secret` in `aap` ns | Admin password for AAP controller | apply-secrets.sh --phase 04 |

## GitOps Note

> Phase 04 is managed by ArgoCD Application `mec-automation` (auto-sync).
> The **operator CRs** (aap-platform, automation-controller, eda-controller) are applied via GitOps.
> **Playbooks** must be imported into AAP via Git SCM source (see COMMANDS.md Step 5).
> **EDA rulebook** is imported via EDA REST API (see COMMANDS.md Step 6).

## After This Phase

| Ready | Component |
|---|---|
| ✅ | AAP AutomationController UI accessible via Route |
| ✅ | EDA Controller UI accessible via Route |
| ✅ | 5 job templates created in AAP |
| ✅ | EDA rulebook activation running (listening on demand.predictions) |
| ✅ | End-to-end test: publish test event → EDA fires prefetch job |

Next: **Phase 05 — Agent & MCP** (`mcp-aap` server calls AAP REST API using the token created here)

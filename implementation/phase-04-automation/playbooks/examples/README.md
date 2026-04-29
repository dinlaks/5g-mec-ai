# Playbook Examples — Granite Lightspeed Reference

These playbooks are **not imported into AAP**. They serve as few-shot examples
embedded in the Granite Lightspeed system prompt to guide playbook generation.

When the LangGraph agent calls `lightspeed_node`, the agent passes:
1. The reasoning output (strategy, mec_site_id, content_id, predicted_viewers, etc.)
2. These example playbooks as context so Granite generates valid, idiomatic Ansible

## Examples

| File | Purpose | When used as reference |
|---|---|---|
| `prefetch-content.yml` | Cache HLS/DASH segments to NVMe at MEC | High viewer demand predictions |
| `push-abr-policy.yml` | Adjust ABR quality caps on MEC node | Network capacity constraints |
| `set-qos-policy.yml` | Set PCF QoS per subscriber tier | Premium vs standard UE differentiation |
| `rollback-cache.yml` | Flush cache + restore defaults | Post-action failure remediation |
| `alert-noc.yml` | Send Slack notification to NOC | Any agent decision requiring human awareness |

## How Granite uses these

The `lightspeed_node` in the LangGraph agent constructs a prompt like:

```
You are an Ansible expert for 5G MEC infrastructure.
Generate a playbook to: {agent_strategy_description}
Target: MEC site {mec_site_id}, content {content_id}

Use these examples as style reference:
--- example: prefetch-content.yml ---
{file contents}
```

Granite generates a new playbook tailored to the specific situation.
The generated YAML is passed to AAP's `lightspeed-generate-and-run` job template.

"""
mcp-slack — Slack MCP Server
Wraps: Slack Web API (via httpx — no Bolt needed for outgoing messages)
Used by: human_approver_node, kubeflow_trigger_node, aap_executor_node

Tools:
  post_approval_request(channel, run_id, mec_site_id, ...)
  send_notification(channel, alert_type, mec_site_id, message, ...)
"""

import os
import httpx
from fastmcp import FastMCP

mcp = FastMCP("mcp-slack")

SLACK_BOT_TOKEN    = os.getenv("SLACK_BOT_TOKEN", "")
SLACK_WEBHOOK_URL  = os.getenv("SLACK_WEBHOOK_URL", "")   # optional, for simple notifications
AGENT_API_URL      = os.getenv("AGENT_API_URL", "https://content-intelligence-agent.mec-content-ai.svc.cluster.local")

SLACK_API_BASE = "https://slack.com/api"

def _slack_headers() -> dict:
    return {"Authorization": f"Bearer {SLACK_BOT_TOKEN}", "Content-Type": "application/json"}


# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def post_approval_request(
    channel: str,
    run_id: str,
    mec_site_id: str,
    content_id: str,
    predicted_viewers: int,
    confidence: float,
    strategy_action: str,
    strategy_reasoning: str,
    playbooks: list,
    approval_url: str,
) -> dict:
    """
    Post a human approval card to a Slack channel.
    Includes approve/reject buttons that call POST /agent/resume/{run_id}.
    Used by human_approver_node when confidence < threshold.
    """
    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "🙋 Human Approval Required — MEC Content Intelligence"},
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*MEC Site:*\n{mec_site_id}"},
                {"type": "mrkdwn", "text": f"*Content:*\n{content_id}"},
                {"type": "mrkdwn", "text": f"*Predicted Viewers:*\n{predicted_viewers:,}"},
                {"type": "mrkdwn", "text": f"*LSTM Confidence:*\n{confidence:.0%}"},
                {"type": "mrkdwn", "text": f"*Proposed Action:*\n`{strategy_action}`"},
                {"type": "mrkdwn", "text": f"*Playbooks:*\n{', '.join(playbooks) if playbooks else 'none'}"},
            ],
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*Agent Reasoning:*\n_{strategy_reasoning}_"},
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*Run ID:* `{run_id}`\nApprove or reject below, or via the <{AGENT_API_URL.replace('svc.cluster.local', 'apps.cluster.local')}/|EdgeStream IQ Dashboard>."},
        },
        {
            "type": "actions",
            "elements": [
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "✅ Approve"},
                    "style": "primary",
                    "url": f"{approval_url}",
                    "action_id": "approve",
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "❌ Reject"},
                    "style": "danger",
                    "url": f"{approval_url}?decision=rejected",
                    "action_id": "reject",
                },
            ],
        },
    ]

    with httpx.Client(timeout=15) as client:
        resp = client.post(
            f"{SLACK_API_BASE}/chat.postMessage",
            headers=_slack_headers(),
            json={"channel": channel, "blocks": blocks},
        )
        result = resp.json()
        return {
            "status":  "sent" if result.get("ok") else "failed",
            "channel": channel,
            "ts":      result.get("ts"),
            "error":   result.get("error"),
        }


@mcp.tool()
def send_notification(
    channel: str,
    alert_type: str,
    mec_site_id: str,
    message: str,
    content_id: str = "",
    action_taken: str = "",
    triggered_by: str = "langgraph-agent",
) -> dict:
    """
    Send an informational Slack notification (not an approval request).
    alert_type: "action_taken" | "rollback" | "anomaly" | "info"
    """
    emoji_map = {
        "action_taken": "⚡",
        "rollback":     "🔄",
        "anomaly":      "⚠️",
        "info":         "ℹ️",
    }
    color_map = {
        "action_taken": "#36a64f",
        "rollback":     "#e01e5a",
        "anomaly":      "#ff9900",
        "info":         "#1d9bd1",
    }
    emoji = emoji_map.get(alert_type, "ℹ️")
    color = color_map.get(alert_type, "#1d9bd1")

    attachment = {
        "color": color,
        "title": f"{emoji} {alert_type.replace('_', ' ').title()} — {mec_site_id}",
        "text":  message,
        "fields": [
            {"title": "Site",       "value": mec_site_id,  "short": True},
            {"title": "Content",    "value": content_id or "N/A", "short": True},
            {"title": "Action",     "value": action_taken or "N/A", "short": True},
            {"title": "Source",     "value": triggered_by, "short": True},
        ],
        "footer": "MEC Content Intelligence",
    }

    with httpx.Client(timeout=15) as client:
        resp = client.post(
            f"{SLACK_API_BASE}/chat.postMessage",
            headers=_slack_headers(),
            json={"channel": channel, "attachments": [attachment]},
        )
        result = resp.json()
        return {
            "status":  "sent" if result.get("ok") else "failed",
            "channel": channel,
            "error":   result.get("error"),
        }


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

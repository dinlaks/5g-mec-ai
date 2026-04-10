"""
mcp-aap — Ansible Automation Platform MCP Server
Wraps: AAP 2.5 REST API (AutomationController)
Used by: aap_executor_node, outcome_verifier_node (rollback)

Tools:
  trigger_playbook(job_template_name, extra_vars)
  get_job_status(job_id)
  list_job_templates()
"""

import os
import httpx
from fastmcp import FastMCP

mcp = FastMCP("mcp-aap")

AAP_HOST  = os.getenv("AAP_HOST", "https://controller.aap.svc.cluster.local")
AAP_TOKEN = os.getenv("AAP_TOKEN", "")
VERIFY_SSL = os.getenv("AAP_VERIFY_SSL", "false").lower() == "true"

def _aap_headers() -> dict:
    return {"Authorization": f"Bearer {AAP_TOKEN}", "Content-Type": "application/json"}

# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def trigger_playbook(job_template_name: str, extra_vars: dict) -> dict:
    """
    Trigger an AAP Job Template by name.
    Returns: job_id, job_url, status
    """
    # First find the job template ID by name
    with httpx.Client(verify=VERIFY_SSL, timeout=30) as client:
        resp = client.get(
            f"{AAP_HOST}/api/v2/job_templates/",
            headers=_aap_headers(),
            params={"name": job_template_name},
        )
        resp.raise_for_status()
        results = resp.json().get("results", [])
        if not results:
            return {"error": f"Job template '{job_template_name}' not found in AAP"}

        template_id = results[0]["id"]

        # Launch the job
        launch_resp = client.post(
            f"{AAP_HOST}/api/v2/job_templates/{template_id}/launch/",
            headers=_aap_headers(),
            json={"extra_vars": extra_vars},
        )
        launch_resp.raise_for_status()
        job = launch_resp.json()

        return {
            "job_id":   str(job.get("id")),
            "job_url":  f"{AAP_HOST}/api/v2/jobs/{job.get('id')}/",
            "status":   job.get("status", "pending"),
            "template": job_template_name,
        }


@mcp.tool()
def get_job_status(job_id: str) -> dict:
    """
    Get the status of an AAP job by ID.
    Returns: job_id, status, started, finished, elapsed
    Possible statuses: pending, waiting, running, successful, failed, error, canceled
    """
    with httpx.Client(verify=VERIFY_SSL, timeout=30) as client:
        resp = client.get(
            f"{AAP_HOST}/api/v2/jobs/{job_id}/",
            headers=_aap_headers(),
        )
        resp.raise_for_status()
        job = resp.json()

        return {
            "job_id":   job_id,
            "status":   job.get("status"),
            "started":  job.get("started"),
            "finished": job.get("finished"),
            "elapsed":  job.get("elapsed"),
            "failed":   job.get("failed", False),
        }


@mcp.tool()
def list_job_templates() -> dict:
    """List all available AAP job templates. Useful for agent introspection."""
    with httpx.Client(verify=VERIFY_SSL, timeout=30) as client:
        resp = client.get(f"{AAP_HOST}/api/v2/job_templates/", headers=_aap_headers())
        resp.raise_for_status()
        templates = [
            {"id": t["id"], "name": t["name"], "playbook": t.get("playbook")}
            for t in resp.json().get("results", [])
        ]
        return {"templates": templates, "count": len(templates)}


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

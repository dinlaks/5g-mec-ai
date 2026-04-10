"""
mcp-kubeflow — Kubeflow Pipelines + MLflow MCP Server
Wraps: Kubeflow Pipelines REST API + MLflow Model Registry
Used by: kubeflow_trigger_node

Tools:
  trigger_training_pipeline(pipeline_name, params)
  get_pipeline_status(run_id)
  register_model(model_name, model_uri, metrics)
  list_registered_models()
"""

import os
import httpx
from datetime import datetime, timezone
from fastmcp import FastMCP

mcp = FastMCP("mcp-kubeflow")

KUBEFLOW_HOST = os.getenv("KUBEFLOW_HOST", "http://ds-pipeline-dspa.redhat-ods-applications.svc.cluster.local:8888")
MLFLOW_HOST   = os.getenv("MLFLOW_HOST",   "http://mlflow.mec-ai-data.svc.cluster.local:5000")
KF_TOKEN      = os.getenv("KUBEFLOW_TOKEN", "")

def _kf_headers() -> dict:
    return {"Authorization": f"Bearer {KF_TOKEN}", "Content-Type": "application/json"}

# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def trigger_training_pipeline(pipeline_name: str, params: dict) -> dict:
    """
    Trigger a Kubeflow Pipeline run for LSTM demand model retraining.
    pipeline_name: "lstm-demand-retraining"
    params: mec_site_id, trigger_reason, run_id
    Returns: pipeline_run_id, status, pipeline_url
    """
    with httpx.Client(timeout=30) as client:
        # Find pipeline by name
        resp = client.get(
            f"{KUBEFLOW_HOST}/apis/v2beta1/pipelines",
            headers=_kf_headers(),
            params={"filter": f'{{"predicates":[{{"key":"name","op":"EQUALS","string_value":"{pipeline_name}"}}]}}'},
        )
        resp.raise_for_status()
        pipelines = resp.json().get("pipelines", [])

        if not pipelines:
            return {"error": f"Pipeline '{pipeline_name}' not found in Kubeflow"}

        pipeline_id = pipelines[0]["pipeline_id"]

        # Create a pipeline run
        run_payload = {
            "display_name": f"{pipeline_name}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}",
            "description":  f"Triggered by agent. Reason: {params.get('trigger_reason', 'unknown')}",
            "pipeline_version_reference": {"pipeline_id": pipeline_id},
            "runtime_config": {"parameters": {k: str(v) for k, v in params.items()}},
        }

        run_resp = client.post(
            f"{KUBEFLOW_HOST}/apis/v2beta1/runs",
            headers=_kf_headers(),
            json=run_payload,
        )
        run_resp.raise_for_status()
        run = run_resp.json()

        return {
            "pipeline_run_id": run.get("run_id"),
            "status":          run.get("state", "PENDING"),
            "pipeline_name":   pipeline_name,
            "pipeline_url":    f"{KUBEFLOW_HOST}/#/runs/details/{run.get('run_id')}",
        }


@mcp.tool()
def get_pipeline_status(pipeline_run_id: str) -> dict:
    """Get the status of a Kubeflow Pipeline run."""
    with httpx.Client(timeout=15) as client:
        resp = client.get(
            f"{KUBEFLOW_HOST}/apis/v2beta1/runs/{pipeline_run_id}",
            headers=_kf_headers(),
        )
        resp.raise_for_status()
        run = resp.json()
        return {
            "pipeline_run_id": pipeline_run_id,
            "status":          run.get("state"),
            "created_at":      run.get("created_at"),
            "finished_at":     run.get("finished_at"),
        }


@mcp.tool()
def register_model(model_name: str, model_uri: str, metrics: dict) -> dict:
    """
    Register a trained model in the MLflow Model Registry.
    Called after a successful Kubeflow Pipeline retraining run.
    """
    with httpx.Client(timeout=30) as client:
        # Create or get registered model
        resp = client.post(
            f"{MLFLOW_HOST}/api/2.0/mlflow/registered-models/create",
            json={"name": model_name},
        )
        # 400 is OK — model already exists
        if resp.status_code not in (200, 400):
            resp.raise_for_status()

        # Create a model version
        ver_resp = client.post(
            f"{MLFLOW_HOST}/api/2.0/mlflow/model-versions/create",
            json={"name": model_name, "source": model_uri},
        )
        ver_resp.raise_for_status()
        version = ver_resp.json().get("model_version", {})

        return {
            "model_name":    model_name,
            "version":       version.get("version"),
            "status":        version.get("status"),
            "model_uri":     model_uri,
            "metrics":       metrics,
        }


@mcp.tool()
def list_registered_models() -> dict:
    """List all models registered in MLflow Model Registry."""
    with httpx.Client(timeout=15) as client:
        resp = client.get(f"{MLFLOW_HOST}/api/2.0/mlflow/registered-models/list")
        resp.raise_for_status()
        models = resp.json().get("registered_models", [])
        return {
            "models": [{"name": m["name"], "latest_version": m.get("latest_versions", [{}])[-1].get("version")} for m in models],
            "count":  len(models),
        }


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

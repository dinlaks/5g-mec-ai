"""
mcp-openshift — OpenShift / Kubernetes API MCP Server
Wraps: OpenShift/K8s API via kubernetes Python client
Used by: context_enricher_node, outcome_verifier_node

Tools:
  get_pod_health(namespace, label_selector)
  get_inferenceservice_status(name, namespace)
  get_deployment_status(name, namespace)
  get_node_resources(node_name)
"""

import os
from datetime import datetime, timezone
from fastmcp import FastMCP

from kubernetes import client as k8s_client, config as k8s_config

mcp = FastMCP("mcp-openshift")

# Load in-cluster config (when running inside OpenShift pod)
# Falls back to kubeconfig for local development
try:
    k8s_config.load_incluster_config()
except k8s_config.ConfigException:
    k8s_config.load_kube_config()

core_v1  = k8s_client.CoreV1Api()
apps_v1  = k8s_client.AppsV1Api()
custom   = k8s_client.CustomObjectsApi()

# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def get_pod_health(namespace: str, label_selector: str) -> dict:
    """
    Check health of pods matching a label selector in a namespace.
    Used by context_enricher (far-edge pod status) and outcome_verifier (post-action check).
    label_selector example: "mec.site=mec-stadium-01"
    """
    try:
        pods = core_v1.list_namespaced_pod(
            namespace=namespace,
            label_selector=label_selector,
        )
        pod_list = []
        for pod in pods.items:
            phase = pod.status.phase
            containers_ready = all(
                c.ready for c in (pod.status.container_statuses or [])
            )
            pod_list.append({
                "name":             pod.metadata.name,
                "status":           phase,
                "ready":            containers_ready,
                "restart_count":    sum(c.restart_count for c in (pod.status.container_statuses or [])),
                "node":             pod.spec.node_name,
            })

        all_running = all(p["status"] == "Running" and p["ready"] for p in pod_list)
        return {
            "namespace":      namespace,
            "label_selector": label_selector,
            "pods":           pod_list,
            "total":          len(pod_list),
            "all_healthy":    all_running,
            "timestamp":      datetime.now(timezone.utc).isoformat(),
        }
    except Exception as e:
        return {"namespace": namespace, "label_selector": label_selector, "error": str(e)}


@mcp.tool()
def get_inferenceservice_status(name: str, namespace: str) -> dict:
    """
    Check the status of a KServe InferenceService.
    Used to verify LSTM and ABR Policy Engine model health at far edge.
    """
    try:
        svc = custom.get_namespaced_custom_object(
            group="serving.kserve.io",
            version="v1beta1",
            namespace=namespace,
            plural="inferenceservices",
            name=name,
        )
        conditions = svc.get("status", {}).get("conditions", [])
        ready_condition = next((c for c in conditions if c.get("type") == "Ready"), {})
        is_ready = ready_condition.get("status") == "True"
        url = svc.get("status", {}).get("url", "")

        return {
            "name":       name,
            "namespace":  namespace,
            "ready":      is_ready,
            "url":        url,
            "conditions": [{"type": c.get("type"), "status": c.get("status")} for c in conditions],
        }
    except Exception as e:
        return {"name": name, "namespace": namespace, "error": str(e)}


@mcp.tool()
def get_deployment_status(name: str, namespace: str) -> dict:
    """
    Check the status of a Kubernetes Deployment.
    Used by outcome_verifier for self-health check of agent and MCP servers.
    """
    try:
        dep = apps_v1.read_namespaced_deployment(name=name, namespace=namespace)
        spec_replicas    = dep.spec.replicas or 0
        ready_replicas   = dep.status.ready_replicas or 0
        updated_replicas = dep.status.updated_replicas or 0

        return {
            "name":              name,
            "namespace":         namespace,
            "desired_replicas":  spec_replicas,
            "ready_replicas":    ready_replicas,
            "updated_replicas":  updated_replicas,
            "available":         ready_replicas >= spec_replicas and spec_replicas > 0,
        }
    except Exception as e:
        return {"name": name, "namespace": namespace, "error": str(e)}


@mcp.tool()
def get_node_resources(node_name: str) -> dict:
    """
    Get CPU, memory, and GPU resource usage for a cluster node.
    Used by context_enricher to check if near-edge GPU node is at capacity.
    """
    try:
        node = core_v1.read_node(name=node_name)
        capacity    = node.status.capacity or {}
        allocatable = node.status.allocatable or {}

        labels = node.metadata.labels or {}
        has_gpu = "nvidia.com/gpu" in capacity

        return {
            "node_name":     node_name,
            "cpu_capacity":  capacity.get("cpu"),
            "cpu_allocatable": allocatable.get("cpu"),
            "memory_capacity": capacity.get("memory"),
            "memory_allocatable": allocatable.get("memory"),
            "gpu_capacity":  capacity.get("nvidia.com/gpu", "0"),
            "has_gpu":       has_gpu,
            "ready":         any(
                c.type == "Ready" and c.status == "True"
                for c in (node.status.conditions or [])
            ),
            "labels":        {k: v for k, v in labels.items() if "nvidia" in k or "gpu" in k},
        }
    except Exception as e:
        return {"node_name": node_name, "error": str(e)}


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

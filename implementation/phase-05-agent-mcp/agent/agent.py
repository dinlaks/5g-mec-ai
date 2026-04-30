"""
agent.py — ContentIntelligenceAgent
5G MEC Content Pre-positioning & Adaptive Streaming

LangGraph 8-node StateGraph that:
  1. Reads demand predictions from Kafka (demand.predictions)
  2. Enriches with network context via MCP tools
  3. Reasons via LlamaStack → vLLM (Llama 3.1 8B)
  4. Gates on confidence → autonomous or human-in-loop
  5. Executes AAP playbooks via mcp-aap
  6. Verifies outcome, rolls back if needed
  7. Triggers retraining via Kubeflow if needed
  8. Reports to Slack and EdgeStream IQ dashboard

Node flow:
  demand_reader → context_enricher → strategy_reasoner → confidence_gate
      → [≥0.85] aap_executor → outcome_verifier → kubeflow_trigger
      → [<0.85] human_approver → aap_executor (on approve) or outcome_verifier (on reject)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Literal

import httpx
from confluent_kafka import Consumer, KafkaError
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from langchain_core.messages import HumanMessage, AIMessage, SystemMessage
from langgraph.graph import StateGraph, END
from langgraph.types import interrupt
from langfuse import Langfuse
from llama_stack_client import LlamaStackClient
from tenacity import retry, stop_after_attempt, wait_exponential

from state import ContentIntelligenceState, DemandEvent

# ── Logging ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
log = logging.getLogger("content-intelligence-agent")

# ── Config from environment ────────────────────────────────────────────────────
KAFKA_BOOTSTRAP    = os.getenv("KAFKA_BOOTSTRAP", "kafka-cluster-kafka-bootstrap.mec-ai-data.svc.cluster.local:9092")
LLAMASTACK_URL     = os.getenv("LLAMASTACK_URL", "http://mec-llamastack.mec-content-ai.svc.cluster.local:8321")
MODEL_ID           = os.getenv("MODEL_ID", "granite-3-3-8b")
LANGFUSE_HOST      = os.getenv("LANGFUSE_HOST", "https://langfuse.apps.cluster.local")
LANGFUSE_PUBLIC_KEY= os.getenv("LANGFUSE_PUBLIC_KEY", "")
LANGFUSE_SECRET_KEY= os.getenv("LANGFUSE_SECRET_KEY", "")
CONFIDENCE_THRESHOLD = float(os.getenv("CONFIDENCE_THRESHOLD", "0.85"))

MCP_NETWORK_INTEL  = os.getenv("MCP_NETWORK_INTEL_URL", "http://mcp-network-intel:8000/mcp")
MCP_KAFKA          = os.getenv("MCP_KAFKA_URL", "http://mcp-kafka:8000/mcp")
MCP_AAP            = os.getenv("MCP_AAP_URL", "http://mcp-aap:8000/mcp")
MCP_SLACK          = os.getenv("MCP_SLACK_URL", "http://mcp-slack:8000/mcp")
MCP_KUBEFLOW       = os.getenv("MCP_KUBEFLOW_URL", "http://mcp-kubeflow:8000/mcp")
MCP_OPENSHIFT      = os.getenv("MCP_OPENSHIFT_URL", "http://mcp-openshift:8000/mcp")

SLACK_OPS_CHANNEL  = os.getenv("SLACK_OPS_CHANNEL", "#mec-ai-ops")
AGENT_API_URL      = os.getenv("AGENT_API_URL", "http://content-intelligence-agent.mec-content-ai.svc.cluster.local:8000")

# ── Clients ────────────────────────────────────────────────────────────────────
langfuse = Langfuse(
    public_key=LANGFUSE_PUBLIC_KEY,
    secret_key=LANGFUSE_SECRET_KEY,
    host=LANGFUSE_HOST,
)

llama_client = LlamaStackClient(base_url=LLAMASTACK_URL)

# In-flight runs: run_id → asyncio.Event (for human approval resume)
pending_approvals: dict[str, asyncio.Event] = {}
approval_decisions: dict[str, str] = {}       # run_id → "approved" | "rejected"
agent_states: dict[str, ContentIntelligenceState] = {}  # run_id → latest state


# ── MCP Helper ────────────────────────────────────────────────────────────────

@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10))
async def call_mcp(server_url: str, tool: str, args: dict) -> dict:
    """Call an MCP tool on any MCP server via HTTP."""
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{server_url}/tools/{tool}",
            json={"arguments": args},
        )
        response.raise_for_status()
        return response.json()


# ── Node 1: demand_reader ──────────────────────────────────────────────────────

def demand_reader_node(state: ContentIntelligenceState) -> dict:
    """
    Reads the demand prediction event from state (set by Kafka consumer before graph entry).
    Validates required fields and sets working confidence.
    """
    log.info(f"[{state['run_id']}] demand_reader: processing event for {state.get('mec_site_id', 'unknown')}")

    demand = state.get("demand_event")
    if not demand:
        return {
            "error": "demand_reader: no demand_event in state",
            "node_history": state.get("node_history", []) + ["demand_reader"],
        }

    confidence = demand.get("confidence", 0.0)

    return {
        "mec_site_id": demand["mec_site_id"],
        "confidence": confidence,
        "node_history": state.get("node_history", []) + ["demand_reader"],
        "messages": [
            HumanMessage(content=(
                f"New demand prediction received for MEC site {demand['mec_site_id']}. "
                f"Content: {demand['content_id']}, "
                f"Expected viewers: {demand['predicted_viewers']}, "
                f"Event type: {demand['event_type']}, "
                f"LSTM confidence: {confidence:.2f}, "
                f"Peak in: {demand.get('predicted_peak_in_minutes', '?')} minutes."
            ))
        ],
    }


# ── Node 2: context_enricher ──────────────────────────────────────────────────

async def context_enricher_node(state: ContentIntelligenceState) -> dict:
    """
    Enriches the demand event with real-time network context via MCP tools.
    Calls: mcp-network-intel, mcp-openshift, mcp-kafka (cache.state)
    """
    run_id = state["run_id"]
    site_id = state["mec_site_id"]
    log.info(f"[{run_id}] context_enricher: enriching context for {site_id}")

    trace = langfuse.trace(name="content-intelligence-agent", id=run_id)
    span = trace.span(name="context_enricher", input={"mec_site_id": site_id})

    try:
        # Parallel MCP calls for efficiency
        network_cap, cache_state, event_schedule, far_edge_health = await asyncio.gather(
            call_mcp(MCP_NETWORK_INTEL, "get_network_capacity", {"mec_site_id": site_id}),
            call_mcp(MCP_KAFKA,         "read_latest_messages", {"topic": "cache.state", "max_messages": 5, "filter_key": "mec_site_id", "filter_value": site_id}),
            call_mcp(MCP_NETWORK_INTEL, "get_event_schedule",   {"mec_site_id": site_id, "hours_ahead": 4}),
            call_mcp(MCP_OPENSHIFT,     "get_pod_health",       {"namespace": "far-edge-mec", "label_selector": f"mec.site={site_id}"}),
        )

        demand = state["demand_event"]
        content_id = demand["content_id"]

        # Check if content is already cached
        cached_items = cache_state.get("messages", [])
        content_already_cached = any(
            msg.get("content_id") == content_id and msg.get("status") == "ready"
            for msg in cached_items
        )

        # Check far-edge component health
        pods = far_edge_health.get("pods", [])
        lstm_healthy = any("lstm" in p.get("name", "") and p.get("status") == "Running" for p in pods)
        abr_healthy  = any("abr"  in p.get("name", "") and p.get("status") == "Running" for p in pods)
        cache_healthy= any("cache" in p.get("name","") and p.get("status") == "Running" for p in pods)

        # Check event schedule confirmation
        events = event_schedule.get("events", [])
        matching_event = next(
            (e for e in events if content_id in e.get("content_ids", [])), None
        )

        network_context = {
            "backhaul_capacity_mbps":    network_cap.get("capacity_mbps", 1000),
            "backhaul_utilization_pct":  network_cap.get("utilization_pct", 50),
            "backhaul_headroom_mbps":    network_cap.get("headroom_mbps", 500),
            "cache_hit_rate_pct":        network_cap.get("cache_hit_rate_pct", 12),
            "cache_used_gb":             network_cap.get("cache_used_gb", 0),
            "cache_total_gb":            network_cap.get("cache_total_gb", 500),
            "content_already_cached":    content_already_cached,
            "active_ues":                network_cap.get("active_ues", 0),
            "premium_ue_count":          network_cap.get("premium_ue_count", 0),
            "standard_ue_count":         network_cap.get("standard_ue_count", 0),
            "event_confirmed":           matching_event is not None,
            "event_name":                matching_event.get("name") if matching_event else None,
            "far_edge_healthy":          lstm_healthy and abr_healthy and cache_healthy,
            "lstm_model_healthy":        lstm_healthy,
            "abr_engine_healthy":        abr_healthy,
            "cache_manager_healthy":     cache_healthy,
        }

        span.end(output=network_context)

        return {
            "network_context": network_context,
            "node_history": state.get("node_history", []) + ["context_enricher"],
            "messages": [
                HumanMessage(content=(
                    f"Network context for {site_id}: "
                    f"backhaul headroom={network_context['backhaul_headroom_mbps']}Mbps, "
                    f"current cache hit rate={network_context['cache_hit_rate_pct']}%, "
                    f"content already cached={content_already_cached}, "
                    f"event confirmed={network_context['event_confirmed']}, "
                    f"far-edge healthy={network_context['far_edge_healthy']}, "
                    f"active UEs={network_context['active_ues']}."
                ))
            ],
        }

    except Exception as e:
        log.error(f"[{run_id}] context_enricher error: {e}")
        span.end(level="ERROR", status_message=str(e))
        return {
            "error": f"context_enricher: {e}",
            "node_history": state.get("node_history", []) + ["context_enricher"],
        }


# ── Node 3: strategy_reasoner ─────────────────────────────────────────────────

async def strategy_reasoner_node(state: ContentIntelligenceState) -> dict:
    """
    Calls LlamaStack → vLLM (Llama 3.1 8B) to reason about the optimal strategy.
    Produces a Strategy with action, playbooks, quality caps, and confidence.
    Langfuse traces the full LLM call with input/output.
    """
    run_id = state["run_id"]
    log.info(f"[{run_id}] strategy_reasoner: calling LLM for strategic decision")

    trace = langfuse.trace(name="content-intelligence-agent", id=run_id)
    span = trace.span(name="strategy_reasoner")

    demand = state["demand_event"]
    context = state["network_context"]

    system_prompt = """You are the ContentIntelligenceAgent for a 5G MEC network.
Your job is to decide the optimal pre-positioning strategy for video content at a MEC edge node.

You will receive a demand prediction and network context. Respond with a JSON strategy object ONLY.
No explanation outside the JSON.

Strategy JSON format:
{
  "action": "prefetch_and_cap" | "cap_only" | "monitor" | "no_action",
  "reasoning": "<1-2 sentence explanation>",
  "playbooks": ["prefetch-content", "push-abr-policy", "set-qos-policy"],
  "premium_quality": "4K" | "1080p" | "720p" | "360p",
  "standard_quality": "1080p" | "720p" | "360p",
  "urgency": "immediate" | "scheduled" | "low",
  "estimated_backhaul_saving_mbps": <number>,
  "confidence": <0.0-1.0>
}

Rules:
- If content is already cached AND headroom > 50%: action = "monitor"
- If far_edge is unhealthy: action = "no_action", add note in reasoning
- If viewers > 20000 AND headroom < 40%: action = "prefetch_and_cap" (urgent)
- If viewers < 5000: action = "monitor" or "cap_only"
- premium_quality is always one tier above standard_quality
- For live_sport: always set urgency="immediate" if peak < 30 minutes away"""

    user_prompt = f"""Demand Prediction:
- MEC Site: {demand['mec_site_id']}
- Content: {demand['content_id']} ({demand['event_type']})
- Predicted viewers: {demand['predicted_viewers']}
- LSTM confidence: {demand['confidence']:.2f}
- Peak in: {demand.get('predicted_peak_in_minutes', '?')} minutes

Network Context:
- Backhaul headroom: {context['backhaul_headroom_mbps']} Mbps ({100 - context['backhaul_utilization_pct']:.0f}% free)
- Current cache hit rate: {context['cache_hit_rate_pct']}%
- Content already cached: {context['content_already_cached']}
- Active UEs: {context['active_ues']} (premium: {context['premium_ue_count']}, standard: {context['standard_ue_count']})
- Event confirmed in schedule: {context['event_confirmed']} ({context.get('event_name', 'N/A')})
- Far-edge healthy: {context['far_edge_healthy']} (LSTM: {context['lstm_model_healthy']}, ABR: {context['abr_engine_healthy']}, Cache: {context['cache_manager_healthy']})

Decide the optimal strategy."""

    try:
        messages_payload = [
            {"role": "system", "content": system_prompt},
            {"role": "user",   "content": user_prompt},
        ]

        response = llama_client.inference.chat_completion(
            model_id=MODEL_ID,
            messages=messages_payload,
            sampling_params={"temperature": 0.1, "max_tokens": 512},
        )

        llm_response = response.completion_message.content.text.strip()
        log.info(f"[{run_id}] LLM response: {llm_response[:200]}")

        # Parse JSON strategy from LLM response
        # Strip markdown code blocks if present
        if "```" in llm_response:
            llm_response = llm_response.split("```")[1]
            if llm_response.startswith("json"):
                llm_response = llm_response[4:]

        strategy = json.loads(llm_response)

        # Validate required fields and apply defaults
        strategy.setdefault("action", "monitor")
        strategy.setdefault("reasoning", "No reasoning provided")
        strategy.setdefault("playbooks", [])
        strategy.setdefault("premium_quality", "1080p")
        strategy.setdefault("standard_quality", "720p")
        strategy.setdefault("urgency", "scheduled")
        strategy.setdefault("estimated_backhaul_saving_mbps", 0)
        strategy.setdefault("confidence", demand["confidence"])

        span.end(
            output=strategy,
            metadata={"model": MODEL_ID, "tokens": len(llm_response.split())},
        )

        langfuse.generation(
            trace_id=run_id,
            name="llm-strategy-reasoning",
            model=MODEL_ID,
            input=messages_payload,
            output=strategy,
        )

        return {
            "strategy": strategy,
            "confidence": float(strategy.get("confidence", demand["confidence"])),
            "node_history": state.get("node_history", []) + ["strategy_reasoner"],
            "messages": [AIMessage(content=f"Strategy decided: {strategy['action']}. {strategy['reasoning']}")],
        }

    except Exception as e:
        log.error(f"[{run_id}] strategy_reasoner error: {e}")
        span.end(level="ERROR", status_message=str(e))
        # Fallback strategy on LLM failure — safe default
        fallback = {
            "action": "monitor",
            "reasoning": f"LLM unavailable ({e}). Defaulting to monitor.",
            "playbooks": [],
            "premium_quality": "1080p",
            "standard_quality": "720p",
            "urgency": "low",
            "estimated_backhaul_saving_mbps": 0,
            "confidence": 0.5,
        }
        return {
            "strategy": fallback,
            "confidence": 0.5,
            "node_history": state.get("node_history", []) + ["strategy_reasoner"],
            "messages": [AIMessage(content=f"LLM failed, using fallback strategy: monitor.")],
        }


# ── Node 4: confidence_gate ───────────────────────────────────────────────────

def confidence_gate_node(state: ContentIntelligenceState) -> dict:
    """
    Pure routing node — no MCP calls, no LLM.
    Sets human_approval_required based on confidence score.
    """
    run_id = state["run_id"]
    confidence = state.get("confidence", 0.0)
    strategy = state.get("strategy", {})
    action = strategy.get("action", "monitor")

    requires_human = confidence < CONFIDENCE_THRESHOLD or action == "no_action"

    log.info(
        f"[{run_id}] confidence_gate: confidence={confidence:.2f}, "
        f"action={action}, human_required={requires_human}"
    )

    return {
        "human_approval_required": requires_human,
        "node_history": state.get("node_history", []) + ["confidence_gate"],
    }


def route_after_confidence_gate(state: ContentIntelligenceState) -> Literal["aap_executor", "human_approver"]:
    """Edge function: route to aap_executor or human_approver."""
    if state.get("human_approval_required") or state.get("strategy", {}).get("action") == "monitor":
        return "human_approver"
    return "aap_executor"


# ── Node 5: aap_executor ──────────────────────────────────────────────────────

async def aap_executor_node(state: ContentIntelligenceState) -> dict:
    """
    Triggers AAP playbooks via mcp-aap based on the strategy's playbook list.
    Polls job status until all jobs complete (success or failure).
    """
    run_id = state["run_id"]
    strategy = state.get("strategy", {})
    demand = state["demand_event"]
    context = state.get("network_context", {})
    playbooks = strategy.get("playbooks", [])

    log.info(f"[{run_id}] aap_executor: triggering {len(playbooks)} playbook(s): {playbooks}")

    trace = langfuse.trace(name="content-intelligence-agent", id=run_id)
    span = trace.span(name="aap_executor", input={"playbooks": playbooks})

    job_ids = []

    # Common extra_vars for all playbooks
    base_vars = {
        "mec_site_id":          demand["mec_site_id"],
        "content_id":           demand["content_id"],
        "content_url":          demand["content_url"],
        "predicted_viewers":    demand["predicted_viewers"],
        "event_type":           demand["event_type"],
        "event_start_utc":      demand["event_start_utc"],
        "confidence":           state.get("confidence", 0),
        "premium_max_quality":  strategy.get("premium_quality", "1080p"),
        "standard_max_quality": strategy.get("standard_quality", "720p"),
        "triggered_by":         "langgraph-agent",
    }

    for playbook in playbooks:
        try:
            result = await call_mcp(MCP_AAP, "trigger_playbook", {
                "job_template_name": playbook,
                "extra_vars": base_vars,
            })
            job_id = result.get("job_id")
            if job_id:
                job_ids.append(str(job_id))
                log.info(f"[{run_id}] Triggered '{playbook}' → job_id={job_id}")
        except Exception as e:
            log.error(f"[{run_id}] Failed to trigger '{playbook}': {e}")

    # Poll all jobs until complete (max 10 minutes)
    if job_ids:
        log.info(f"[{run_id}] Polling {len(job_ids)} AAP jobs for completion...")
        for _ in range(60):  # 60 × 10s = 10 minutes max
            await asyncio.sleep(10)
            statuses = await asyncio.gather(*[
                call_mcp(MCP_AAP, "get_job_status", {"job_id": jid})
                for jid in job_ids
            ])
            all_done = all(s.get("status") in ("successful", "failed", "error") for s in statuses)
            if all_done:
                log.info(f"[{run_id}] All AAP jobs complete: {[s.get('status') for s in statuses]}")
                break

    span.end(output={"job_ids": job_ids})

    return {
        "aap_job_ids": job_ids,
        "node_history": state.get("node_history", []) + ["aap_executor"],
        "messages": [AIMessage(content=f"AAP jobs triggered: {job_ids}. Playbooks: {playbooks}.")],
    }


# ── Node 6: human_approver ────────────────────────────────────────────────────

async def human_approver_node(state: ContentIntelligenceState) -> dict:
    """
    Posts a Slack approval card and SUSPENDS the graph.
    Graph resumes when POST /agent/resume/{run_id} is called
    (from Slack interactive button OR EdgeStream IQ dashboard Panel C).
    """
    run_id = state["run_id"]
    strategy = state.get("strategy", {})
    demand = state["demand_event"]
    log.info(f"[{run_id}] human_approver: posting Slack approval request")

    resume_url = f"{AGENT_API_URL}/agent/resume/{run_id}"

    await call_mcp(MCP_SLACK, "post_approval_request", {
        "channel": SLACK_OPS_CHANNEL,
        "run_id": run_id,
        "mec_site_id": demand["mec_site_id"],
        "content_id": demand["content_id"],
        "predicted_viewers": demand["predicted_viewers"],
        "confidence": state.get("confidence", 0),
        "strategy_action": strategy.get("action", "unknown"),
        "strategy_reasoning": strategy.get("reasoning", ""),
        "playbooks": strategy.get("playbooks", []),
        "approval_url": resume_url,
    })

    # Suspend graph — wait for resume signal
    event = asyncio.Event()
    pending_approvals[run_id] = event
    agent_states[run_id] = state

    log.info(f"[{run_id}] Graph suspended. Waiting for human decision at {resume_url}")

    # LangGraph interrupt — suspends execution until resumed
    decision = interrupt({
        "type": "human_approval_required",
        "run_id": run_id,
        "resume_url": resume_url,
    })

    human_decision = approval_decisions.pop(run_id, "rejected")
    log.info(f"[{run_id}] Human decision: {human_decision}")

    return {
        "human_decision": human_decision,
        "node_history": state.get("node_history", []) + ["human_approver"],
        "messages": [HumanMessage(content=f"Human decision received: {human_decision}")],
    }


def route_after_human_approver(state: ContentIntelligenceState) -> Literal["aap_executor", "outcome_verifier"]:
    """Edge function: route to aap_executor on approve, skip to outcome_verifier on reject."""
    if state.get("human_decision") == "approved":
        return "aap_executor"
    return "outcome_verifier"


# ── Node 7: outcome_verifier ──────────────────────────────────────────────────

async def outcome_verifier_node(state: ContentIntelligenceState) -> dict:
    """
    Verifies the outcome of AAP playbook execution by checking:
    - Cache hit rate improvement (mcp-kafka: qoe.metrics)
    - Far-edge pod health post-action (mcp-openshift)
    - Triggers rollback if QoE degraded (mcp-aap: rollback-cache)
    """
    run_id = state["run_id"]
    demand = state["demand_event"]
    context = state.get("network_context", {})
    log.info(f"[{run_id}] outcome_verifier: checking post-action metrics")

    trace = langfuse.trace(name="content-intelligence-agent", id=run_id)
    span = trace.span(name="outcome_verifier")

    # Wait a moment for metrics to propagate
    await asyncio.sleep(15)

    try:
        qoe_data, cache_data, pod_health = await asyncio.gather(
            call_mcp(MCP_KAFKA,     "read_latest_messages", {"topic": "qoe.metrics", "max_messages": 10, "filter_key": "mec_site_id", "filter_value": demand["mec_site_id"]}),
            call_mcp(MCP_KAFKA,     "read_latest_messages", {"topic": "cache.state", "max_messages": 5,  "filter_key": "mec_site_id", "filter_value": demand["mec_site_id"]}),
            call_mcp(MCP_OPENSHIFT, "get_pod_health",       {"namespace": "far-edge-mec", "label_selector": f"mec.site={demand['mec_site_id']}"}),
        )

        # Parse metrics
        qoe_messages = qoe_data.get("messages", [])
        latest_qoe = qoe_messages[-1] if qoe_messages else {}
        qoe_score = float(latest_qoe.get("qoe_score", 70))
        buffering_rate = float(latest_qoe.get("buffering_rate_pct", 5))

        cache_messages = cache_data.get("messages", [])
        latest_cache = cache_messages[-1] if cache_messages else {}
        cache_hit_rate_after = float(latest_cache.get("cache_hit_rate_pct", context.get("cache_hit_rate_pct", 12)))
        cache_hit_rate_before = float(context.get("cache_hit_rate_pct", 12))
        delta = cache_hit_rate_after - cache_hit_rate_before

        pods = pod_health.get("pods", [])
        all_pods_healthy = all(p.get("status") == "Running" for p in pods)
        aap_jobs_ok = bool(state.get("aap_job_ids"))  # simplified: assume success if jobs were triggered

        # Determine verdict
        if delta >= 20 and qoe_score >= 75 and all_pods_healthy:
            verdict = "success"
            rollback = False
        elif delta < -5 or qoe_score < 50:
            verdict = "failure"
            rollback = True
        elif delta >= 5:
            verdict = "partial"
            rollback = False
        else:
            verdict = "partial"
            rollback = False

        # Trigger rollback if QoE degraded
        if rollback:
            log.warning(f"[{run_id}] QoE degraded — triggering rollback on {demand['mec_site_id']}")
            await call_mcp(MCP_AAP, "trigger_playbook", {
                "job_template_name": "rollback-cache",
                "extra_vars": {
                    "mec_site_id": demand["mec_site_id"],
                    "content_id": demand["content_id"],
                    "rollback_reason": f"QoE degraded: score={qoe_score}, delta={delta:.1f}%",
                    "triggered_by": "langgraph-agent",
                    "restore_qos": True,
                },
            })

        outcome = {
            "cache_hit_rate_after": cache_hit_rate_after,
            "cache_hit_rate_before": cache_hit_rate_before,
            "cache_hit_rate_delta": delta,
            "qoe_score_after": qoe_score,
            "buffering_rate_pct": buffering_rate,
            "backhaul_utilization_after": float(latest_qoe.get("backhaul_utilization_pct", 50)),
            "aap_jobs_succeeded": aap_jobs_ok,
            "verdict": verdict,
        }

        span.end(output=outcome)
        log.info(f"[{run_id}] Outcome: {verdict} | cache delta={delta:.1f}% | QoE={qoe_score}")

        return {
            "outcome": outcome,
            "qoe_improved": verdict in ("success", "partial"),
            "cache_hit_rate_after": cache_hit_rate_after,
            "rollback_triggered": rollback,
            "node_history": state.get("node_history", []) + ["outcome_verifier"],
            "messages": [AIMessage(content=f"Outcome: {verdict}. Cache hit rate: {cache_hit_rate_before:.0f}% → {cache_hit_rate_after:.0f}% (Δ{delta:+.0f}%). QoE score: {qoe_score:.0f}.")],
        }

    except Exception as e:
        log.error(f"[{run_id}] outcome_verifier error: {e}")
        span.end(level="ERROR", status_message=str(e))
        return {
            "outcome": {"verdict": "unknown", "error": str(e)},
            "node_history": state.get("node_history", []) + ["outcome_verifier"],
            "error": f"outcome_verifier: {e}",
        }


# ── Node 8: kubeflow_trigger ──────────────────────────────────────────────────

async def kubeflow_trigger_node(state: ContentIntelligenceState) -> dict:
    """
    Final node. Decides if LSTM retraining is needed based on outcome.
    Publishes final outcome to Kafka, sends Slack summary report.
    """
    run_id = state["run_id"]
    demand = state["demand_event"]
    outcome = state.get("outcome", {})
    verdict = outcome.get("verdict", "unknown")

    log.info(f"[{run_id}] kubeflow_trigger: finalising run, verdict={verdict}")

    trace = langfuse.trace(name="content-intelligence-agent", id=run_id)
    span = trace.span(name="kubeflow_trigger")

    retraining_triggered = False

    # Trigger retraining if outcome was failure or rollback happened
    if verdict == "failure" or state.get("rollback_triggered"):
        try:
            log.info(f"[{run_id}] Triggering LSTM retraining via Kubeflow")
            await call_mcp(MCP_KUBEFLOW, "trigger_training_pipeline", {
                "pipeline_name": "lstm-demand-retraining",
                "params": {
                    "mec_site_id":    demand["mec_site_id"],
                    "trigger_reason": f"Agent outcome: {verdict}",
                    "run_id":         run_id,
                },
            })
            retraining_triggered = True
        except Exception as e:
            log.error(f"[{run_id}] Kubeflow trigger failed: {e}")

    # Publish final outcome to Kafka remediation.outcomes
    try:
        await call_mcp(MCP_KAFKA, "publish_message", {
            "topic": "remediation.outcomes",
            "message": {
                "run_id":               run_id,
                "mec_site_id":          demand["mec_site_id"],
                "content_id":           demand["content_id"],
                "predicted_viewers":    demand["predicted_viewers"],
                "strategy_action":      state.get("strategy", {}).get("action", "unknown"),
                "verdict":              verdict,
                "cache_delta":          outcome.get("cache_hit_rate_delta", 0),
                "qoe_score":            outcome.get("qoe_score_after", 0),
                "retraining_triggered": retraining_triggered,
                "human_involved":       state.get("human_approval_required", False),
                "timestamp":            datetime.now(timezone.utc).isoformat(),
            },
        })
    except Exception as e:
        log.warning(f"[{run_id}] Kafka publish failed: {e}")

    # Send Slack summary
    try:
        delta = outcome.get("cache_hit_rate_delta", 0)
        await call_mcp(MCP_SLACK, "send_notification", {
            "channel": SLACK_OPS_CHANNEL,
            "alert_type": "action_taken" if verdict == "success" else "anomaly",
            "mec_site_id": demand["mec_site_id"],
            "message": (
                f"Run {run_id[:8]} complete. "
                f"Verdict: *{verdict}*. "
                f"Cache hit rate: {outcome.get('cache_hit_rate_before', 0):.0f}% → {outcome.get('cache_hit_rate_after', 0):.0f}% (Δ{delta:+.0f}%). "
                f"QoE: {outcome.get('qoe_score_after', 0):.0f}/100. "
                f"Retraining: {'✅' if retraining_triggered else '—'}."
            ),
            "content_id": demand["content_id"],
            "action_taken": state.get("strategy", {}).get("action", "unknown"),
            "triggered_by": "langgraph-agent",
        })
    except Exception as e:
        log.warning(f"[{run_id}] Slack notify failed: {e}")

    span.end(output={"verdict": verdict, "retraining": retraining_triggered})

    # Update Langfuse trace URL in state for EdgeStream IQ
    trace_url = f"{LANGFUSE_HOST}/trace/{run_id}"

    return {
        "retraining_triggered": retraining_triggered,
        "langfuse_trace_url": trace_url,
        "node_history": state.get("node_history", []) + ["kubeflow_trigger"],
        "messages": [AIMessage(content=f"Run complete. Verdict: {verdict}. Langfuse: {trace_url}")],
    }


# ── Graph Assembly ────────────────────────────────────────────────────────────

def build_graph() -> StateGraph:
    graph = StateGraph(ContentIntelligenceState)

    # Register nodes
    graph.add_node("demand_reader",     demand_reader_node)
    graph.add_node("context_enricher",  context_enricher_node)
    graph.add_node("strategy_reasoner", strategy_reasoner_node)
    graph.add_node("confidence_gate",   confidence_gate_node)
    graph.add_node("aap_executor",      aap_executor_node)
    graph.add_node("human_approver",    human_approver_node)
    graph.add_node("outcome_verifier",  outcome_verifier_node)
    graph.add_node("kubeflow_trigger",  kubeflow_trigger_node)

    # Linear edges
    graph.set_entry_point("demand_reader")
    graph.add_edge("demand_reader",     "context_enricher")
    graph.add_edge("context_enricher",  "strategy_reasoner")
    graph.add_edge("strategy_reasoner", "confidence_gate")

    # Conditional: confidence_gate → aap_executor OR human_approver
    graph.add_conditional_edges(
        "confidence_gate",
        route_after_confidence_gate,
        {"aap_executor": "aap_executor", "human_approver": "human_approver"},
    )

    # Conditional: human_approver → aap_executor (approved) OR outcome_verifier (rejected)
    graph.add_conditional_edges(
        "human_approver",
        route_after_human_approver,
        {"aap_executor": "aap_executor", "outcome_verifier": "outcome_verifier"},
    )

    # aap_executor always goes to outcome_verifier
    graph.add_edge("aap_executor",      "outcome_verifier")
    graph.add_edge("outcome_verifier",  "kubeflow_trigger")
    graph.add_edge("kubeflow_trigger",  END)

    return graph.compile()


agent_graph = build_graph()


# ── Kafka Consumer Loop ────────────────────────────────────────────────────────

async def kafka_consumer_loop():
    """Continuously reads demand.predictions and spawns agent runs."""
    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": "content-intelligence-agent",
        "auto.offset.reset": "latest",
        "enable.auto.commit": True,
    })
    consumer.subscribe(["demand.predictions"])
    log.info("Kafka consumer started — listening on demand.predictions")

    loop = asyncio.get_event_loop()

    while True:
        msg = await loop.run_in_executor(None, consumer.poll, 1.0)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() != KafkaError._PARTITION_EOF:
                log.error(f"Kafka error: {msg.error()}")
            continue

        try:
            event: DemandEvent = json.loads(msg.value().decode("utf-8"))
            confidence = float(event.get("confidence", 0))

            # EDA handles confidence >= 0.95 automatically — only process 0.85–0.94 here
            if confidence < CONFIDENCE_THRESHOLD:
                log.debug(f"Skipping event: confidence={confidence:.2f} below threshold {CONFIDENCE_THRESHOLD}")
                continue

            run_id = str(uuid.uuid4())
            log.info(f"New demand event → run_id={run_id}, confidence={confidence:.2f}, site={event.get('mec_site_id')}")

            initial_state: ContentIntelligenceState = {
                "run_id":                  run_id,
                "mec_site_id":             event.get("mec_site_id", "unknown"),
                "demand_event":            event,
                "network_context":         None,
                "strategy":                None,
                "outcome":                 None,
                "confidence":              confidence,
                "human_approval_required": False,
                "human_decision":          None,
                "aap_job_ids":             [],
                "retraining_triggered":    False,
                "rollback_triggered":      False,
                "messages":                [],
                "node_history":            [],
                "error":                   None,
                "langfuse_trace_url":      None,
            }

            agent_states[run_id] = initial_state
            asyncio.create_task(run_agent(run_id, initial_state))

        except Exception as e:
            log.error(f"Failed to process Kafka message: {e}")


async def run_agent(run_id: str, initial_state: ContentIntelligenceState):
    """Run the agent graph for a single demand event."""
    try:
        config = {"configurable": {"thread_id": run_id}}
        final_state = await agent_graph.ainvoke(initial_state, config=config)
        agent_states[run_id] = final_state
        log.info(f"[{run_id}] Agent run complete. Nodes visited: {final_state.get('node_history', [])}")
    except Exception as e:
        log.error(f"[{run_id}] Agent run failed: {e}")
        if run_id in agent_states:
            agent_states[run_id]["error"] = str(e)


# ── FastAPI App ───────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    asyncio.create_task(kafka_consumer_loop())
    log.info("ContentIntelligenceAgent started")
    yield
    log.info("ContentIntelligenceAgent shutting down")

app = FastAPI(
    title="ContentIntelligenceAgent",
    description="5G MEC Content Pre-positioning — LangGraph Agent API",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
def health():
    return {"status": "ok", "service": "content-intelligence-agent"}


@app.get("/agent/state/{run_id}")
def get_agent_state(run_id: str):
    """EdgeStream IQ dashboard polls this to visualise node progress."""
    state = agent_states.get(run_id)
    if not state:
        raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
    return JSONResponse({
        "run_id":                  run_id,
        "node_history":            state.get("node_history", []),
        "current_node":            state.get("node_history", ["unknown"])[-1],
        "confidence":              state.get("confidence", 0),
        "human_approval_required": state.get("human_approval_required", False),
        "human_decision":          state.get("human_decision"),
        "strategy":                state.get("strategy"),
        "outcome":                 state.get("outcome"),
        "error":                   state.get("error"),
        "langfuse_trace_url":      state.get("langfuse_trace_url"),
    })


@app.post("/agent/resume/{run_id}")
async def resume_agent(run_id: str, body: dict):
    """
    Called by Slack interactive button OR EdgeStream IQ dashboard Panel C.
    Resumes a suspended human_approver_node.
    Body: {"decision": "approved" | "rejected", "approver": "username"}
    """
    decision = body.get("decision", "rejected")
    approver = body.get("approver", "unknown")

    event = pending_approvals.pop(run_id, None)
    if not event:
        raise HTTPException(status_code=404, detail=f"No pending approval for run {run_id}")

    approval_decisions[run_id] = decision
    log.info(f"[{run_id}] Resuming agent: decision={decision}, approver={approver}")
    event.set()

    return {"status": "resumed", "run_id": run_id, "decision": decision}


@app.get("/runs")
def list_runs():
    """List all in-memory runs (for debugging)."""
    return {
        run_id: {
            "node_history": state.get("node_history", []),
            "confidence": state.get("confidence", 0),
            "human_pending": run_id in pending_approvals,
        }
        for run_id, state in agent_states.items()
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)

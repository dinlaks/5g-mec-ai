"""
state.py — ContentIntelligenceState
5G MEC Content Pre-positioning & Adaptive Streaming

Defines the single typed state object that flows through all 8 LangGraph nodes.
Every node reads from and writes to this state — no node holds local state.

Import in agent.py:
    from state import ContentIntelligenceState, DemandEvent, NetworkContext, Strategy
"""

from __future__ import annotations
from typing import TypedDict, Optional, Annotated
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage


# ── Sub-types (nested dicts in state) ─────────────────────────────────────────

class DemandEvent(TypedDict):
    """Raw demand prediction published by far-edge LSTM model to demand.predictions."""
    mec_site_id: str                    # e.g. "mec-stadium-01"
    content_id: str                     # e.g. "nfl-chiefs-ravens-2026-01-18"
    content_url: str                    # CDN origin URL for this content
    predicted_viewers: int              # expected concurrent viewers
    event_type: str                     # "live_sport" | "live_concert" | "vod_premiere"
    event_start_utc: str                # ISO8601
    confidence: float                   # LSTM confidence score (0.0–1.0)
    predicted_peak_in_minutes: int      # how soon the spike is expected


class NetworkContext(TypedDict):
    """Enriched context collected by context_enricher_node via MCP tools."""
    # Backhaul
    backhaul_capacity_mbps: float       # total backhaul capacity for this MEC site
    backhaul_utilization_pct: float     # current utilization %
    backhaul_headroom_mbps: float       # available capacity

    # Cache state
    cache_hit_rate_pct: float           # current cache hit rate %
    cache_used_gb: float                # NVMe cache used (GB)
    cache_total_gb: float               # NVMe total capacity (GB)
    content_already_cached: bool        # is this content_id already cached?

    # Subscriber state
    active_ues: int                     # currently connected UEs at this site
    premium_ue_count: int               # premium tier subscribers
    standard_ue_count: int              # standard tier subscribers

    # Event schedule
    event_confirmed: bool               # is the event confirmed in event schedule?
    event_name: Optional[str]           # event name from schedule (e.g. "NFL: Chiefs vs Ravens")

    # Far-edge health
    far_edge_healthy: bool              # overall far-edge MEC node status
    lstm_model_healthy: bool            # KServe LSTM InferenceService ready
    abr_engine_healthy: bool            # KServe ABR Policy Engine ready
    cache_manager_healthy: bool         # Nginx + NVMe Cache Manager pod running


class Strategy(TypedDict):
    """Agent strategic decision produced by strategy_reasoner_node via LLM."""
    action: str                         # "prefetch_and_cap" | "cap_only" | "monitor" | "no_action"
    reasoning: str                      # LLM explanation of why this strategy was chosen
    playbooks: list[str]                # AAP playbooks to trigger in order
    premium_quality: str                # quality cap for premium UEs: "4K"|"1080p"|"720p"|"360p"
    standard_quality: str               # quality cap for standard UEs
    urgency: str                        # "immediate" | "scheduled" | "low"
    estimated_backhaul_saving_mbps: float  # projected backhaul reduction
    confidence: float                   # strategy confidence (may differ from LSTM confidence)


class OutcomeMetrics(TypedDict):
    """Post-action metrics collected by outcome_verifier_node."""
    cache_hit_rate_after: float         # cache hit rate after pre-caching
    cache_hit_rate_before: float        # cache hit rate before (from context)
    cache_hit_rate_delta: float         # improvement
    qoe_score_after: float              # QoE score (0–100)
    buffering_rate_pct: float           # % of sessions buffering
    backhaul_utilization_after: float   # backhaul % after action
    aap_jobs_succeeded: bool            # all triggered AAP jobs completed OK
    verdict: str                        # "success" | "partial" | "failure" | "rolled_back"


# ── Main State ─────────────────────────────────────────────────────────────────

class ContentIntelligenceState(TypedDict):
    """
    Single state object flowing through all 8 LangGraph nodes.

    Design rules:
    - Every field is Optional unless it is set at graph entry
    - Nodes only update the fields they own — they pass through everything else
    - messages uses add_messages reducer (LangGraph built-in for LLM chat history)
    - node_history is append-only — never overwrite
    """

    # ── Identity ──────────────────────────────────────────────────────────────
    run_id: str                                 # unique run UUID (set at entry)
    mec_site_id: str                            # target MEC site (from demand_event)

    # ── Data flowing through the graph ────────────────────────────────────────
    demand_event: Optional[DemandEvent]         # set by demand_reader_node
    network_context: Optional[NetworkContext]   # set by context_enricher_node
    strategy: Optional[Strategy]               # set by strategy_reasoner_node
    outcome: Optional[OutcomeMetrics]           # set by outcome_verifier_node

    # ── Confidence & routing ──────────────────────────────────────────────────
    confidence: float                           # working confidence score
    human_approval_required: bool               # set by confidence_gate_node
    human_decision: Optional[str]               # "approved" | "rejected" — set on resume

    # ── Execution tracking ────────────────────────────────────────────────────
    aap_job_ids: list[str]                      # AAP job IDs from aap_executor_node
    retraining_triggered: bool                  # set by kubeflow_trigger_node
    rollback_triggered: bool                    # set by outcome_verifier_node if QoE failed

    # ── LLM conversation (strategy_reasoner) ──────────────────────────────────
    messages: Annotated[list[BaseMessage], add_messages]

    # ── Observability ─────────────────────────────────────────────────────────
    node_history: list[str]                     # ordered list of nodes visited
    error: Optional[str]                        # error message if a node failed
    langfuse_trace_url: Optional[str]           # Langfuse trace URL for this run

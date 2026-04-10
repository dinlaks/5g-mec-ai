"""
mcp-network-intel — 5G Network Intelligence MCP Server
Wraps: 5G network APIs (backhaul capacity, cache inventory, event schedule, subscriber context)
Used by: context_enricher_node, strategy_reasoner_node

For demo/PoC: returns realistic mock data.
For production: replace _get_* functions with real 5G Core API calls
  (NEF northbound API, OSS/BSS REST APIs, event management system).
"""

import os
import random
from datetime import datetime, timedelta, timezone
from fastmcp import FastMCP

mcp = FastMCP("mcp-network-intel")

# Config
NETWORK_INTEL_API_URL = os.getenv("NETWORK_INTEL_API_URL", "")  # real API in production
MOCK_MODE = os.getenv("MOCK_MODE", "true").lower() == "true"

# ── Mock data helpers ─────────────────────────────────────────────────────────

SITE_PROFILES = {
    "mec-stadium-01":  {"capacity_mbps": 2000, "base_ues": 45000, "location": "SoFi Stadium, LA"},
    "mec-stadium-02":  {"capacity_mbps": 1500, "base_ues": 30000, "location": "Arrowhead Stadium, KC"},
    "mec-urban-01":    {"capacity_mbps": 5000, "base_ues": 8000,  "location": "Downtown LA"},
    "mec-campus-01":   {"capacity_mbps": 1000, "base_ues": 5000,  "location": "UCLA Campus"},
}

EVENT_SCHEDULE = {
    "mec-stadium-01": [
        {"name": "NFL: Chiefs vs Ravens", "content_ids": ["nfl-chiefs-ravens-2026-01-18", "nfl-game"], "start_utc": "2026-04-08T20:00:00Z"},
        {"name": "Concert: Taylor Swift",  "content_ids": ["swift-concert-2026-04-15"],                "start_utc": "2026-04-15T19:30:00Z"},
    ],
    "mec-stadium-02": [
        {"name": "NFL: Playoffs Round 2",  "content_ids": ["nfl-playoffs-r2-2026"],                   "start_utc": "2026-04-09T18:00:00Z"},
    ],
}


# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def get_network_capacity(mec_site_id: str) -> dict:
    """
    Get real-time backhaul capacity and utilisation for a MEC site.
    Returns: capacity_mbps, utilization_pct, headroom_mbps, active_ues,
             cache_hit_rate_pct, cache_used_gb, cache_total_gb,
             premium_ue_count, standard_ue_count
    """
    profile = SITE_PROFILES.get(mec_site_id, {"capacity_mbps": 1000, "base_ues": 5000})
    capacity = profile["capacity_mbps"]
    utilization = random.uniform(45, 75)  # mock: 45–75% utilised
    active_ues = int(profile["base_ues"] * random.uniform(0.6, 0.9))

    return {
        "mec_site_id":          mec_site_id,
        "capacity_mbps":        capacity,
        "utilization_pct":      round(utilization, 1),
        "headroom_mbps":        round(capacity * (1 - utilization / 100), 0),
        "active_ues":           active_ues,
        "premium_ue_count":     int(active_ues * 0.15),
        "standard_ue_count":    int(active_ues * 0.85),
        "cache_hit_rate_pct":   round(random.uniform(10, 18), 1),  # low before pre-cache
        "cache_used_gb":        round(random.uniform(50, 150), 1),
        "cache_total_gb":       500,
        "timestamp":            datetime.now(timezone.utc).isoformat(),
    }


@mcp.tool()
def get_event_schedule(mec_site_id: str, hours_ahead: int = 4) -> dict:
    """
    Get upcoming events at a MEC site within the next N hours.
    Returns: list of events with name, content_ids, start_utc
    """
    events = EVENT_SCHEDULE.get(mec_site_id, [])
    now = datetime.now(timezone.utc)
    cutoff = now + timedelta(hours=hours_ahead)

    upcoming = []
    for event in events:
        try:
            event_start = datetime.fromisoformat(event["start_utc"].replace("Z", "+00:00"))
            if now <= event_start <= cutoff:
                upcoming.append(event)
        except Exception:
            upcoming.append(event)  # include if parsing fails

    return {
        "mec_site_id": mec_site_id,
        "hours_ahead": hours_ahead,
        "events":      upcoming,
        "timestamp":   now.isoformat(),
    }


@mcp.tool()
def get_cache_inventory(mec_site_id: str) -> dict:
    """
    Get current cache inventory for a MEC site.
    Returns: list of cached content items with content_id, size_gb, hit_rate, age_hours
    """
    # Mock: return a few cached items
    return {
        "mec_site_id": mec_site_id,
        "cached_items": [
            {"content_id": "vod-popular-01", "size_gb": 12.4, "hit_rate_pct": 45, "age_hours": 6},
            {"content_id": "vod-popular-02", "size_gb": 8.1,  "hit_rate_pct": 23, "age_hours": 12},
        ],
        "total_cached_gb": 20.5,
        "total_capacity_gb": 500,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@mcp.tool()
def get_subscriber_context(mec_site_id: str) -> dict:
    """
    Get subscriber tier distribution and device profile for a MEC site.
    Returns: total_subscribers, premium_count, standard_count, device_breakdown
    """
    profile = SITE_PROFILES.get(mec_site_id, {"base_ues": 5000})
    total = profile["base_ues"]

    return {
        "mec_site_id":     mec_site_id,
        "total_subscribers": total,
        "premium_count":   int(total * 0.15),
        "standard_count":  int(total * 0.85),
        "device_breakdown": {
            "5g_capable":  int(total * 0.70),
            "4g_lte":      int(total * 0.28),
            "other":       int(total * 0.02),
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

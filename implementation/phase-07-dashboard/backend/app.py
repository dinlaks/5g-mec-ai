"""
app.py — EdgeStream IQ Backend
FastAPI server with WebSocket hub for real-time dashboard updates.

Endpoints:
  GET  /health                          — health check
  GET  /api/sites                       — MEC site summary (from Kafka cache)
  GET  /api/predictions                 — latest demand predictions
  GET  /api/agent/runs                  — active agent runs
  GET  /api/agent/state/{run_id}        — specific run state (proxies agent API)
  POST /api/agent/resume/{run_id}       — human approval relay (proxies agent API)
  GET  /api/langfuse/traces             — recent Langfuse traces
  GET  /api/aap/jobs                    — recent AAP jobs
  WS   /ws                             — WebSocket for real-time push to frontend
"""

import asyncio
import json
import logging
import os
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from kafka_consumer import start_consumers

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] edgestream-backend — %(message)s",
)
log = logging.getLogger("edgestream-backend")

# ── Config ────────────────────────────────────────────────────────────────────
AGENT_API_URL    = os.getenv("AGENT_API_URL",    "http://content-intelligence-agent.mec-content-ai.svc.cluster.local:8080")
LANGFUSE_HOST    = os.getenv("LANGFUSE_HOST",    "https://langfuse.apps.cluster.local")
LANGFUSE_PK      = os.getenv("LANGFUSE_PUBLIC_KEY", "")
LANGFUSE_SK      = os.getenv("LANGFUSE_SECRET_KEY", "")
AAP_HOST         = os.getenv("AAP_HOST",         "https://controller.aap.svc.cluster.local")
AAP_TOKEN        = os.getenv("AAP_TOKEN",        "")

# ── In-memory state (latest values per topic/site) ────────────────────────────
# Keeps only the most recent N messages per topic for late-joining clients
state: dict[str, deque] = defaultdict(lambda: deque(maxlen=50))

# ── WebSocket connection manager ───────────────────────────────────────────────
class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)
        log.info(f"WebSocket connected. Total: {len(self.active)}")
        # Send current state to new client
        for topic, msgs in state.items():
            for msg in msgs:
                try:
                    await ws.send_json(msg)
                except Exception:
                    pass

    def disconnect(self, ws: WebSocket):
        if ws in self.active:
            self.active.remove(ws)
        log.info(f"WebSocket disconnected. Total: {len(self.active)}")

    async def broadcast(self, message: dict):
        """Broadcast to all connected WebSocket clients."""
        state[message.get("topic", "unknown")].append(message)
        dead = []
        for ws in self.active:
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)

manager = ConnectionManager()

# Thread-safe broadcast wrapper (called from Kafka consumer threads)
def sync_broadcast(message: dict):
    """Called from Kafka consumer threads — schedules coroutine on event loop."""
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            asyncio.run_coroutine_threadsafe(manager.broadcast(message), loop)
    except Exception as e:
        log.warning(f"Broadcast failed: {e}")

# ── Lifespan ───────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting EdgeStream IQ backend...")
    # Start Kafka consumer threads
    threads = start_consumers(sync_broadcast)
    log.info(f"Started {len(threads)} Kafka consumer threads")
    yield
    log.info("EdgeStream IQ backend shutting down")

app = FastAPI(
    title="EdgeStream IQ Backend",
    description="5G MEC Content Intelligence — Live Dashboard API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── WebSocket endpoint ─────────────────────────────────────────────────────────
@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await manager.connect(ws)
    try:
        while True:
            # Keep connection alive — frontend sends pings
            data = await ws.receive_text()
            if data == "ping":
                await ws.send_text("pong")
    except WebSocketDisconnect:
        manager.disconnect(ws)

# ── Health ─────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "edgestream-iq-backend",
        "websocket_clients": len(manager.active),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

# ── MEC Site summary ───────────────────────────────────────────────────────────
@app.get("/api/sites")
def get_sites():
    """Return latest state per MEC site aggregated from Kafka."""
    sites: dict[str, dict] = {}

    for topic_deque in state.values():
        for msg in topic_deque:
            data = msg.get("data", {})
            site_id = data.get("mec_site_id")
            if not site_id:
                continue
            if site_id not in sites:
                sites[site_id] = {"mec_site_id": site_id}
            sites[site_id].update({
                k: v for k, v in data.items()
                if k not in ("timestamp", "mec_site_id")
            })

    return JSONResponse(list(sites.values()))

# ── Predictions ────────────────────────────────────────────────────────────────
@app.get("/api/predictions")
def get_predictions():
    """Return latest demand predictions from Kafka cache."""
    msgs = list(state.get("demand.predictions", []))
    return JSONResponse([m.get("data", {}) for m in msgs[-20:]])

# ── Agent runs ─────────────────────────────────────────────────────────────────
@app.get("/api/agent/runs")
async def get_agent_runs():
    """Proxy to agent API — list all active runs."""
    async with httpx.AsyncClient(timeout=5, verify=False) as client:
        try:
            resp = await client.get(f"{AGENT_API_URL}/runs")
            return JSONResponse(resp.json())
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=503)

@app.get("/api/agent/state/{run_id}")
async def get_agent_state(run_id: str):
    """Proxy to agent API — get state for a specific run."""
    async with httpx.AsyncClient(timeout=5, verify=False) as client:
        try:
            resp = await client.get(f"{AGENT_API_URL}/agent/state/{run_id}")
            return JSONResponse(resp.json(), status_code=resp.status_code)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=503)

@app.post("/api/agent/resume/{run_id}")
async def resume_agent(run_id: str, body: dict):
    """
    Human approval relay — Panel C approve/reject buttons call this.
    Proxies to agent API POST /agent/resume/{run_id}.
    """
    async with httpx.AsyncClient(timeout=5, verify=False) as client:
        try:
            resp = await client.post(
                f"{AGENT_API_URL}/agent/resume/{run_id}",
                json=body,
            )
            result = resp.json()
            # Broadcast approval event to all dashboard clients
            await manager.broadcast({
                "type":      "human-approval",
                "panel":     "agent-decisions",
                "run_id":    run_id,
                "decision":  body.get("decision"),
                "approver":  body.get("approver", "dashboard"),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })
            return JSONResponse(result, status_code=resp.status_code)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=503)

# ── Langfuse traces ────────────────────────────────────────────────────────────
@app.get("/api/langfuse/traces")
async def get_langfuse_traces():
    """Fetch recent traces from Langfuse API for Panel G (AI Health)."""
    async with httpx.AsyncClient(timeout=10, verify=False) as client:
        try:
            resp = await client.get(
                f"{LANGFUSE_HOST}/api/public/traces",
                params={"limit": 20, "orderBy": "timestamp.desc"},
                auth=(LANGFUSE_PK, LANGFUSE_SK),
            )
            data = resp.json()
            traces = data.get("data", [])
            return JSONResponse({
                "traces": traces,
                "total":  len(traces),
                "langfuse_url": LANGFUSE_HOST,
            })
        except Exception as e:
            return JSONResponse({"error": str(e), "traces": []}, status_code=503)

# ── AAP jobs ───────────────────────────────────────────────────────────────────
@app.get("/api/aap/jobs")
async def get_aap_jobs():
    """Fetch recent AAP job executions for Panel C (agent actions)."""
    async with httpx.AsyncClient(timeout=10, verify=False) as client:
        try:
            resp = await client.get(
                f"{AAP_HOST}/api/v2/jobs/",
                headers={"Authorization": f"Bearer {AAP_TOKEN}"},
                params={"order_by": "-created", "page_size": 10},
            )
            data = resp.json()
            jobs = [
                {
                    "id":        j.get("id"),
                    "name":      j.get("summary_fields", {}).get("job_template", {}).get("name"),
                    "status":    j.get("status"),
                    "started":   j.get("started"),
                    "finished":  j.get("finished"),
                    "elapsed":   j.get("elapsed"),
                }
                for j in data.get("results", [])
            ]
            return JSONResponse({"jobs": jobs})
        except Exception as e:
            return JSONResponse({"error": str(e), "jobs": []}, status_code=503)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)

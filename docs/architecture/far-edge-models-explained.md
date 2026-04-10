# Far Edge Models — LSTM & ABR Policy Engine

## What This Is About

The far edge (MEC node) runs two small AI models on CPU. They handle everything
at the subscriber level in real time — no GPU, no cloud, no LLM involved.

- **LSTM model** — looks ahead. Predicts what content demand is coming.
- **KServe ABR Policy Engine** — serves in the moment. Decides what quality each subscriber gets.

They do different jobs at different timescales and never talk to each other.

---

## How They Map in the Use Case

### The problem they solve

A cell tower near a stadium is about to serve 50,000 people watching video at halftime.
The backhaul pipe (tower → internet) can't handle 50,000 people at 4K simultaneously.
Without any intervention: everyone buffers, complaints flood in.

### LSTM — Demand Prediction

The LSTM model watches live signals at the MEC node continuously:
- How many subscribers are connected right now
- What content they are requesting
- Network capacity trends
- Time of day and known event schedules

From these signals it **predicts future demand**:
> "In the next 20 minutes, ~40,000 subscribers will request the NFL halftime stream. Confidence: 0.91"

It publishes this prediction to the Kafka `demand.predictions` topic every 30 seconds.
That's what wakes up the LangGraph agent (or EDA if confidence > 0.95).

**LSTM job: predict what's coming → trigger the system to act early.**

---

### KServe ABR Policy Engine — Quality Enforcement

Once the agent has acted (pre-cached content + pushed a quality cap config via AAP),
the ABR Policy Engine takes over at the subscriber level.

Every time a subscriber's phone requests the next video segment, the ABR Policy Engine
intercepts it and decides:
> "This subscriber: standard tier, moderate signal → serve 720p."
> "This subscriber: premium tier, strong signal → serve 1080p."

It enforces a config that was pushed to it by the AAP playbook. Before the agent acted,
the default was "serve the best quality possible." After the agent acts, the new config
caps quality per tier to fit available capacity.

**ABR Policy Engine job: enforce the quality cap per subscriber, per request, in real time.**

---

## Side by Side

| | LSTM | KServe ABR Policy Engine |
|---|---|---|
| **What it does** | Predicts demand spikes 20–30 mins ahead | Decides quality tier per subscriber per video segment |
| **When it runs** | Every 30 seconds | Every video segment request (sub-millisecond) |
| **Input** | UE density, content requests, capacity trends, time of day | Subscriber ID + SLA tier, signal strength, backhaul headroom, active quality cap config |
| **Output** | Predicted demand + content ID + confidence score | Quality tier to serve: 360p / 720p / 1080p / 4K |
| **Triggers** | Internal schedule (cron-like) | Every HTTP request from subscriber's player hitting Nginx |
| **Talks to** | Kafka — publishes to `demand.predictions` topic | Nginx — receives query, returns quality decision; reads config file written by AAP |
| **Where config comes from** | No external config — learns from telemetry data | AAP playbook (`push-abr-policy.yml`) writes a quality cap config file to the MEC node |
| **What happens without it** | No early warning → agent never wakes up → no pre-caching | Default: serve best possible quality (unmanaged, leads to congestion) |
| **Model type** | LSTM sequence model (time-series forecasting) | Lightweight ML classifier (fast inference, no GPU needed) |
| **Model size** | ~15 MB | A few MB — optimized for edge CPU |

---

## Where ABR Traditionally Lives (Without AI)

In a traditional streaming setup, ABR logic lives entirely on the **subscriber's phone/device**.
The player (Netflix app, YouTube app) monitors its own download speed and decides which quality
to request next — all by itself. There is no server enforcing anything.

The telco can influence this **indirectly** — the 5G Core PCF can cap a subscriber's throughput
to 2 Mbps, and the phone's player will naturally land on 720p because that's all the pipe allows.
But there is no explicit ABR policy engine in traditional deployments. The phone decides.

**What we add in this use case:** An active, AI-driven policy engine sitting at the MEC node
that makes quality decisions ahead of the phone — before the phone even negotiates. It is a
custom component we deploy, not something that exists in a standard telco stack.

---

## How AAP Pushes Config to the ABR Engine and How It Intercepts Requests

This is the most important flow to understand. Here is exactly what happens step by step.

### Step 1 — AAP pushes the quality cap config

When the LangGraph agent triggers `push-abr-policy.yml`, Ansible SSHes into the MEC node
and writes a config file. It looks like this:

```yaml
# /etc/mec/abr-policy.yaml  (written by AAP playbook)
event: NFL_halftime
valid_until: "2026-04-07T22:00:00Z"
backhaul_headroom_mbps: 120
rules:
  - subscriber_tier: premium
    max_quality: 1080p
  - subscriber_tier: standard
    max_quality: 720p
  - signal_strength_below_dbm: -100
    max_quality: 360p   # weak signal — drop further regardless of tier
default_quality: 720p
```

The ABR Policy Engine (KServe) watches this file with a hot-reload watcher.
No restart needed — it picks up the new config within seconds.

---

### Step 2 — Subscriber requests a video segment

The subscriber's phone is playing the NFL stream. Every few seconds the player requests
the next video segment. That HTTP request arrives at **Nginx** (the Cache Manager).

Nginx does NOT serve the segment immediately. It is configured to first call the
ABR Policy Engine:

```
Phone → HTTP GET /nfl-stream/segment_042.m3u8
               ↓
           Nginx (Cache Manager)
               ↓ calls KServe ABR inference endpoint
           ABR Policy Engine
```

---

### Step 3 — ABR engine identifies the subscriber and decides quality

The request arriving at the ABR engine carries:
- **Subscriber ID** — injected into the HTTP header by the UPF (5G user plane) as traffic
  passes through. The UPF knows who each IP belongs to.
- **Signal strength** — the Telemetry Collector keeps a small in-memory table updated
  every few seconds: `subscriber_id → RSRP (signal strength)`. The ABR engine reads this.

The engine then:
1. Looks up the subscriber's SLA tier (premium / standard) from a local subscriber table
2. Looks up their current signal strength from the telemetry cache
3. Applies the active quality cap config (loaded from `/etc/mec/abr-policy.yaml`)
4. Returns a quality decision: `720p`

---

### Step 4 — Nginx serves the right quality segment

Nginx receives the quality decision back from the ABR engine and serves the matching
pre-fetched segment from the NVMe cache:

```
ABR engine → "720p"
    ↓
Nginx → serves /cache/nfl-stream/segment_042_720p.ts from NVMe
    ↓
Phone receives 720p segment instantly (local cache, no backhaul)
```

If the segment were not pre-cached, Nginx would have to fetch it from the internet CDN —
slow and expensive. Pre-caching (Phase 04 `prefetch-content.yml`) ensures it is already local.

---

### Full interception picture

```
[Phone]
  │ GET /nfl-stream/segment_042
  ▼
[Nginx — Cache Manager]
  │ → POST /infer  (subscriber_id, signal_strength, timestamp)
  ▼
[KServe ABR Policy Engine]
  │   reads: active config from /etc/mec/abr-policy.yaml  (written by AAP)
  │   reads: signal_strength from telemetry cache
  │   reads: subscriber tier from subscriber table
  │   decides: 720p
  │ ← returns: { "quality": "720p" }
  ▼
[Nginx]
  │ serves: /cache/nfl-stream/segment_042_720p.ts  (from NVMe)
  ▼
[Phone] ← receives 720p video segment
```

This entire round trip (Nginx → ABR engine → Nginx → phone) happens in under 5 milliseconds.

---

## How It Is Implemented

### Hardware

Both models run on the **far edge MEC node** — CPU only, no GPU.
MEC nodes are physically small (base of a cell tower, inside a stadium rack).
Models are chosen specifically to be tiny enough to run on commodity CPU hardware.

### Deployment

Both are served on the **far-edge SNO node** as lightweight Python FastAPI services
with a KServe-compatible REST API. No RHOAI/KServe installation required on far-edge nodes.

```
MEC Node (SNO)
├── lstm-demand-predictor Deployment   ← demand-prediction model server
├── abr-policy-engine Deployment       ← quality decision model server
├── Nginx + NVMe (Cache Manager)           ← serves video segments
└── Telemetry Collector                    ← feeds raw data to LSTM
```

### Model delivery

Models are stored in MinIO (near-edge) and downloaded by each SNO node's pod initContainer at startup.

### Config updates (ABR Policy Engine)

The ABR Policy Engine's quality cap config is updated by AAP playbooks triggered by
the LangGraph agent. The playbook pushes a new config file to the MEC node. The
ABR Policy Engine picks it up and starts enforcing the new caps immediately.

---

## Full Flow (Where Both Models Fit)

```
① Telemetry Collector
     reads: UE density, content requests, capacity
     every 30s → raw data

② LSTM model
     reads: raw telemetry
     predicts: "40K users, NFL game, 20 mins, confidence 0.91"
     publishes → Kafka: demand.predictions

③ EDA / LangGraph Agent (near edge)
     reads: demand.predictions
     reasons: low backhaul headroom, event confirmed
     triggers AAP playbooks:
       - prefetch-content.yml  → video pulled into NVMe cache
       - push-abr-policy.yml   → new quality cap config pushed to ABR engine
       - set-qos-policy.yml    → PCF QoS flows updated per subscriber tier

④ ABR Policy Engine
     receives: new quality cap config from AAP
     now enforces: standard → 720p, premium → 1080p

⑤ Subscriber requests video
     ABR Policy Engine: "720p for this subscriber"
     Cache Manager (Nginx): serves 720p segment from local NVMe
     Result: instant playback, no backhaul used
```

---

## Key Point

The LSTM and ABR Policy Engine never talk to each other directly.
The LSTM triggers the agent. The agent triggers AAP. AAP configures the ABR engine.
They are connected through the system — not directly.

**One looks ahead. One serves in the moment.**

---

## Business Value

For full stakeholder-level business value, objection handling, and pitch guidance see:
**[docs/business/business-value.md](../business/business-value.md)**

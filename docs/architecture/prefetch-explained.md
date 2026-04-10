# Content Pre-positioning (Prefetch) — Explained Simply
# For: understanding + explaining to others
# Context: 5G MEC Content Intelligence — What AAP prefetch actually does

---

## What is Being Cached?

Video content is NOT delivered as one big file. It is split into small chunks
called **segments** (typically 2–10 seconds each) in formats called HLS or DASH.

```
NFL Sunday Ticket 4K stream on CDN origin:
  nfl-game-4k-manifest.m3u8        ← "table of contents" (tells player where segments are)
  nfl-game-4k-segment-0001.ts      ← first 4 seconds of video
  nfl-game-4k-segment-0002.ts      ← next 4 seconds
  nfl-game-4k-segment-0003.ts      ← next 4 seconds
  ... thousands of segments for a 3-hour game
```

Every subscriber's video player fetches these segments one by one as they watch.
The question is: **where do those segments come from?**

---

## Without Pre-positioning

Every subscriber's player fetches each segment from a distant CDN origin server:

```
📱 Subscriber's phone
      │ "give me segment-0001.ts"
      ▼
📡 Cell Tower → MEC Node
      │ not here — go further
      ▼
🌐 Backhaul network (expensive shared pipe)
      │
      ▼
☁️  CDN Origin (200–500 miles away)
      │ here you go
      ▼ (streams all the way back through backhaul)
📱 Subscriber receives it
     (buffering possible if backhaul is congested)
```

**The problem:**
Same segment fetched once per subscriber from origin.
50,000 fans at a stadium = same 4 MB segment fetched 50,000 times.
All of that traffic hammers the backhaul simultaneously.

---

## With Pre-positioning (After Prefetch)

Segments are already on the MEC node's local NVMe drive before fans hit play:

```
📱 Subscriber's phone
      │ "give me segment-0001.ts"
      ▼
📡 Cell Tower → MEC Node
      │ already here — serving from local NVMe
      ▼
📱 Subscriber receives it instantly (zero buffering)

— CDN origin is never contacted for these requests —
— 50,000 fans served from 1 NVMe drive, 1 hop away —
```

**The result:**
Same segment fetched ONCE from origin (by the AAP playbook).
Served 50,000 times locally — zero backhaul cost per fan.

---

## What the AAP Prefetch Playbook Actually Does

The `prefetch-content.yml` Ansible playbook runs on the MEC node and executes
these steps:

```
AAP Controller (near edge)
      │ "run prefetch-content.yml on stadium-mec-07"
      │  args: titles=["NFL-4K", "FoxSports"], storage_limit=200GB
      ▼
Ansible Execution Environment
      │
      ▼
MEC Node (stadium-mec-07) via Kubernetes API (SNO)
      │
      ├── Step 1: Calculate how much to fetch
      │           "200GB free on NVMe — fetch top 3 titles"
      │
      ├── Step 2: Pull manifest files from CDN origin
      │           curl https://cdn.nfl.com/sunday-ticket/4k/manifest.m3u8
      │           → save to /var/mec-cache/content/nfl-4k/manifest.m3u8
      │
      ├── Step 3: Pre-fetch first 60 min of segments
      │           curl https://cdn.nfl.com/.../segment-0001.ts
      │           → save to /var/mec-cache/content/nfl-4k/segment-0001.ts
      │           curl ... segment-0002.ts → save locally
      │           curl ... segment-0003.ts → save locally
      │           (60 min of content ≈ 3,600 segments per stream)
      │
      ├── Step 4: Tell Nginx to serve from local cache path
      │           update nginx.conf:
      │             location /nfl-4k/ → /var/mec-cache/content/nfl-4k/
      │           reload nginx
      │
      └── Step 5: Report completion to Kafka cache.state topic
                  { site: "stadium-mec-07",
                    cached_titles: ["NFL-4K", "FoxSports"],
                    storage_used_gb: 48,
                    cache_ready: true }
```

---

## The Numbers — Why This Matters

```
Stadium scenario:
  50,000 fans watching NFL 4K stream simultaneously
  Each video segment = 4 seconds duration = ~4 MB at 4K quality

Without pre-positioning:
  50,000 fans × 4 MB every 4 seconds = 200 GB/min hitting backhaul
  Same segment fetched 50,000 times from origin     ← massively wasteful

With pre-positioning:
  Segment fetched ONCE from origin by AAP playbook  ← 4 MB total
  Served 50,000 times from local NVMe               ← zero backhaul per fan
  Backhaul savings: ~199.996 GB/min for that segment alone
```

---

## The Parallel Safety Net — EDA + Agent

This is why EDA fires immediately for very high confidence predictions
(>0.95) without waiting for the full LangGraph agent reasoning cycle:

```
Demand prediction arrives: confidence 0.97, spike in 10 minutes
         │
         ├─────────────────────────────────────────────┐
         │                                             │
         ▼                                             ▼
  LangGraph Agent                              EDA Controller
  (full reasoning cycle)                       (simple rule: > 0.95)
         │                                             │
  demand_reader       (~0.1s)                  YES → fire immediately
  context_enricher    (~0.5s)                  AAP prefetch starts NOW
  strategy_reasoner   (~1-2s)                          │
  confidence_gate     (instant)                Cache warming...
  aap_executor → AAP  (~30-60s)                        │
         │                                             │
         ▼                                             ▼
  outcome_verifier checks                    Cache already 60% warmed
  cache hit rate —                           by the time agent's
  already rising ✅                          aap_executor fires ✅
```

**EDA = quick reflex** — no thinking, reacts instantly to obvious signals.
**Agent = careful brain** — reasons fully, verifies, learns, handles edge cases.
Both listen to the same Kafka topic. For >0.95 confidence, both fire.

---

## The Three Confidence Zones

| Confidence | Who Acts | Result |
|---|---|---|
| **> 0.95** | EDA fires immediately + Agent also runs | Cache pre-warming starts within seconds. Agent verifies and learns. |
| **0.85 – 0.95** | Agent only (autonomous) | Agent reasons → aap_executor → AAP prefetch |
| **< 0.85** | Agent only (human approval) | Agent reasons → Slack/dashboard approval → AAP prefetch |
| **< 0.70** | Nothing fires | Signal too uncertain — discarded |

---

## The One-Liner

> **"Pre-positioning means pulling video segments from a distant CDN origin onto
> a local NVMe drive at the MEC node — so that when thousands of fans hit play
> simultaneously, every segment is served locally in milliseconds instead of
> travelling hundreds of miles through an expensive backhaul network."**

---

## If Someone Asks "Why Not Just Use a CDN?"

> "A CDN caches content at regional PoPs — still 50–200 miles away, still
> uses backhaul. We cache directly at the MEC node — 1 hop from the subscriber,
> inside the operator's own network. And unlike a CDN which reacts to demand,
> our AI predicts demand 30–60 minutes ahead and pre-positions before the spike
> hits — so the first subscriber to hit play gets the same experience as the
> millionth."

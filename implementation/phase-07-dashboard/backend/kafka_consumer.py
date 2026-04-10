"""
kafka_consumer.py — Background Kafka consumer threads
Reads all 8 Kafka topics and pushes updates to the WebSocket hub.
Each topic runs in its own thread to avoid blocking.
"""

import json
import logging
import os
import threading
from datetime import datetime, timezone
from typing import Callable

from confluent_kafka import Consumer, KafkaError

log = logging.getLogger("edgestream-kafka")

KAFKA_BOOTSTRAP = os.getenv(
    "KAFKA_BOOTSTRAP",
    "kafka-cluster-kafka-bootstrap.mec-ai-data.svc.cluster.local:9092",
)

# All 8 topics and the dashboard panel they feed
TOPIC_MAP = {
    "content.requests.live":  "site-map",
    "ue.density.live":        "site-map",
    "network.capacity.live":  "site-map",
    "demand.predictions":     "prediction-feed",
    "cache.state":            "cache-intelligence",
    "qoe.metrics":            "qoe-live",
    "agent.decisions":        "agent-decisions",
    "remediation.outcomes":   "business-kpis",
}


def start_consumers(broadcast: Callable[[dict], None]) -> list[threading.Thread]:
    """
    Start one consumer thread per topic group.
    broadcast: async-compatible callback that sends data to all WebSocket clients.
    Returns list of threads (already started).
    """
    threads = []
    for topic, panel in TOPIC_MAP.items():
        t = threading.Thread(
            target=_consume_topic,
            args=(topic, panel, broadcast),
            daemon=True,
            name=f"kafka-{topic}",
        )
        t.start()
        threads.append(t)
        log.info(f"Consumer started: {topic} → panel:{panel}")
    return threads


def _consume_topic(topic: str, panel: str, broadcast: Callable[[dict], None]):
    """Consume a single Kafka topic and broadcast messages to WebSocket clients."""
    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id":          f"edgestream-iq-{topic}",
        "auto.offset.reset": "latest",
        "enable.auto.commit": True,
    })
    consumer.subscribe([topic])
    log.info(f"Subscribed to: {topic}")

    while True:
        try:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    log.error(f"Kafka error on {topic}: {msg.error()}")
                continue

            payload = json.loads(msg.value().decode("utf-8"))
            broadcast({
                "type":      "kafka",
                "panel":     panel,
                "topic":     topic,
                "data":      payload,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })

        except json.JSONDecodeError:
            pass  # skip non-JSON messages
        except Exception as e:
            log.error(f"Error consuming {topic}: {e}")

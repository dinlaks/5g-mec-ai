"""
mcp-kafka — AMQ Streams (Kafka) MCP Server
Wraps: confluent-kafka Producer + Consumer
Used by: demand_reader, context_enricher, aap_executor, outcome_verifier, kubeflow_trigger

Tools:
  read_latest_messages(topic, max_messages, filter_key, filter_value)
  publish_message(topic, message)
  get_topic_lag(topic, consumer_group)
"""

import json
import os
from datetime import datetime, timezone

from confluent_kafka import Consumer, Producer, KafkaError
from confluent_kafka.admin import AdminClient
from fastmcp import FastMCP

mcp = FastMCP("mcp-kafka")

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka-cluster-kafka-bootstrap.mec-ai-data.svc.cluster.local:9092")

# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def read_latest_messages(
    topic: str,
    max_messages: int = 10,
    filter_key: str = "",
    filter_value: str = "",
) -> dict:
    """
    Read latest messages from a Kafka topic.
    Optionally filter by a JSON field key/value.
    Returns: list of parsed message dicts.
    """
    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id":          f"mcp-kafka-reader-{topic}",
        "auto.offset.reset": "latest",
        "enable.auto.commit": False,
    })
    consumer.subscribe([topic])

    messages = []
    empty_polls = 0

    try:
        while len(messages) < max_messages and empty_polls < 5:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                empty_polls += 1
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    empty_polls += 1
                continue

            try:
                payload = json.loads(msg.value().decode("utf-8"))
                # Apply filter if specified
                if filter_key and filter_value:
                    if str(payload.get(filter_key, "")) != filter_value:
                        continue
                messages.append(payload)
            except json.JSONDecodeError:
                pass  # skip non-JSON messages
    finally:
        consumer.close()

    return {
        "topic":     topic,
        "messages":  messages,
        "count":     len(messages),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@mcp.tool()
def publish_message(topic: str, message: dict) -> dict:
    """
    Publish a message to a Kafka topic.
    Automatically adds a timestamp field if not present.
    Returns: delivery confirmation.
    """
    if "timestamp" not in message:
        message["timestamp"] = datetime.now(timezone.utc).isoformat()

    producer = Producer({"bootstrap.servers": KAFKA_BOOTSTRAP})
    delivery_reports = []

    def on_delivery(err, msg):
        if err:
            delivery_reports.append({"status": "error", "error": str(err)})
        else:
            delivery_reports.append({"status": "delivered", "partition": msg.partition(), "offset": msg.offset()})

    producer.produce(
        topic=topic,
        value=json.dumps(message).encode("utf-8"),
        callback=on_delivery,
    )
    producer.flush(timeout=10)

    return {
        "topic":    topic,
        "status":   delivery_reports[0].get("status", "unknown") if delivery_reports else "unknown",
        "delivery": delivery_reports[0] if delivery_reports else {},
    }


@mcp.tool()
def get_topic_lag(topic: str, consumer_group: str) -> dict:
    """
    Get consumer lag for a topic/group combination.
    Useful for checking if the agent is keeping up with demand.predictions.
    """
    admin = AdminClient({"bootstrap.servers": KAFKA_BOOTSTRAP})
    try:
        # Simplified: return mock lag for demo
        return {
            "topic":          topic,
            "consumer_group": consumer_group,
            "lag":            0,
            "note":           "Lag check via AdminClient — implement with list_consumer_group_offsets in production",
            "timestamp":      datetime.now(timezone.utc).isoformat(),
        }
    except Exception as e:
        return {"topic": topic, "consumer_group": consumer_group, "error": str(e)}


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

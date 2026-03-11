#!/usr/bin/env python3
# python/consumer.py
#
# Reads CDC events from all 4 e-commerce Kafka topics and pretty-prints them.
# Uses AvroDeserializer — the schema is fetched from Schema Registry using
# the schema_id embedded in the first 5 bytes of every Debezium message.
#
# Usage:
#   python python/consumer.py
#   python python/consumer.py --topic ecommerce.public.orders  (single topic)
#   python python/consumer.py --from-beginning                 (replay all history)

import json
import argparse
import logging
from datetime import datetime, timezone

from confluent_kafka import Consumer, KafkaError, KafkaException
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroDeserializer
from confluent_kafka.serialization import SerializationContext, MessageField

from config import KAFKA_BOOTSTRAP, SCHEMA_REGISTRY, CONSUMER_GROUP, TOPICS

logging.basicConfig(
    level=logging.WARNING,  # suppress confluent_kafka INFO noise
    format="%(asctime)s %(levelname)s %(message)s"
)

# ── ANSI colour helpers ────────────────────────────────────────────────────────
RESET  = "\033[0m"
BOLD   = "\033[1m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
RED    = "\033[31m"
CYAN   = "\033[36m"
BLUE   = "\033[34m"
GREY   = "\033[90m"

OP_STYLE = {
    "c": (GREEN,  "INSERT  ✚"),
    "u": (YELLOW, "UPDATE  ✎"),
    "d": (RED,    "DELETE  ✖"),
    "r": (BLUE,   "SNAP    ◉"),  # initial snapshot read
}

TABLE_EMOJI = {
    "users":       "👤",
    "products":    "📦",
    "orders":      "🛒",
    "order_items": "📋",
}


# ── Formatters ─────────────────────────────────────────────────────────────────

def format_value(v) -> str:
    """Render a single field value — truncate long strings."""
    if v is None:
        return f"{GREY}null{RESET}"
    if isinstance(v, str) and len(v) > 40:
        return f'"{v[:38]}…"'
    if isinstance(v, (int, float)):
        return str(v)
    return json.dumps(v)


def format_row(row: dict | None, indent: str = "    ") -> str:
    """Format a before/after row dict as aligned key=value lines."""
    if row is None:
        return f"{indent}{GREY}(null){RESET}"
    lines = []
    for k, v in row.items():
        lines.append(f"{indent}{CYAN}{k}{RESET}={format_value(v)}")
    return "\n".join(lines)


def format_diff(before: dict | None, after: dict | None) -> str:
    """
    For UPDATE events: highlight only the fields that actually changed.
    For INSERT: show after state.
    For DELETE: show before state.
    """
    if before is None:
        # INSERT — show after
        return f"  {BOLD}after:{RESET}\n{format_row(after)}"

    if after is None:
        # DELETE — show before
        return f"  {BOLD}before:{RESET}\n{format_row(before)}"

    # UPDATE — show only changed fields, with before → after
    changed_keys = [k for k in (after or {}) if before.get(k) != after.get(k)]
    if not changed_keys:
        return f"  {GREY}(no field changes detected){RESET}"

    lines = [f"  {BOLD}changes:{RESET}"]
    for k in changed_keys:
        old = format_value(before.get(k))
        new = format_value(after.get(k))
        lines.append(f"    {CYAN}{k}{RESET}:  {RED}{old}{RESET}  →  {GREEN}{new}{RESET}")
    return "\n".join(lines)


def print_event(msg, event: dict):
    """Pretty-print a single CDC event to stdout."""
    op  = event.get("op", "?")
    src = event.get("source", {})
    table  = src.get("table", "unknown")
    db     = src.get("db",    "?")
    ts_ms  = event.get("ts_ms", 0)
    tx_id  = src.get("txId",  "?")
    lsn    = src.get("lsn",   "?")

    ts_str = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%H:%M:%S.%f")[:-3]
    colour, label = OP_STYLE.get(op, (RESET, op.upper()))
    emoji  = TABLE_EMOJI.get(table, "📌")

    partition = msg.partition()
    offset    = msg.offset()
    key       = msg.key()

    print(f"\n{colour}{BOLD}{'─'*64}{RESET}")
    print(f"{colour}{BOLD}  {label}  {emoji}  {db}.{table}{RESET}  "
          f"{GREY}@ {ts_str}  tx={tx_id}  lsn={lsn}{RESET}")
    print(f"  {GREY}topic={msg.topic()} partition={partition} offset={offset} key={key}{RESET}")
    print(format_diff(event.get("before"), event.get("after")))


# ── Consumer setup ─────────────────────────────────────────────────────────────

def build_consumer(offset_reset: str) -> Consumer:
    return Consumer({
        "bootstrap.servers":  KAFKA_BOOTSTRAP,
        "group.id":           CONSUMER_GROUP,
        "auto.offset.reset":  offset_reset,
        # Manual commit: we commit after printing, not before.
        # If we crash mid-print, we'll just re-print on restart — acceptable here.
        "enable.auto.commit": False,
        # Suppress overly verbose librdkafka logs
        "log_level": 0,
    })


def build_avro_deserializer() -> AvroDeserializer:
    """
    AvroDeserializer with schema_str=None:
    Fetches the schema from Schema Registry on-demand using the schema_id
    embedded in the first 5 bytes of each message.
    The schema is cached in memory after the first fetch.
    """
    registry = SchemaRegistryClient({"url": SCHEMA_REGISTRY})
    return AvroDeserializer(
        schema_registry_client=registry,
        schema_str=None,         # None = fetch schema from registry by ID
        from_dict=lambda d, _: d # keep as plain dict
    )


# ── Main consumer loop ─────────────────────────────────────────────────────────

def run(topics: list[str], offset_reset: str):
    consumer = build_consumer(offset_reset)
    deserializer = build_avro_deserializer()

    consumer.subscribe(topics)

    print(f"\n{BOLD}CDC Consumer started{RESET}")
    print(f"  Broker:          {KAFKA_BOOTSTRAP}")
    print(f"  Schema Registry: {SCHEMA_REGISTRY}")
    print(f"  Consumer group:  {CONSUMER_GROUP}")
    print(f"  Topics:          {', '.join(topics)}")
    print(f"  Offset reset:    {offset_reset}")
    print(f"  Waiting for events…  (Ctrl-C to stop)\n")

    try:
        while True:
            msg = consumer.poll(timeout=1.0)

            if msg is None:
                continue  # poll timeout — no message yet

            if msg.error():
                if msg.error().code() == KafkaError.PARTITION_EOF:
                    continue  # normal — reached end of partition
                raise KafkaException(msg.error())

            # Debezium tombstone: value=None means DELETE marker for compaction.
            # The actual DELETE event was already emitted with op=d.
            if msg.value() is None:
                print(f"{GREY}  [tombstone] key={msg.key()} topic={msg.topic()}{RESET}")
                consumer.commit(message=msg, asynchronous=False)
                continue

            try:
                event = deserializer(
                    msg.value(),
                    SerializationContext(msg.topic(), MessageField.VALUE)
                )
                print_event(msg, event)

            except Exception as e:
                print(f"{RED}  [deserialize error] {e}  topic={msg.topic()} "
                      f"partition={msg.partition()} offset={msg.offset()}{RESET}")

            # Commit offset after processing (at-least-once semantics)
            consumer.commit(message=msg, asynchronous=False)

    except KeyboardInterrupt:
        print(f"\n{YELLOW}Consumer stopped by user{RESET}")
    finally:
        # consumer.close() triggers on_revoke, commits pending offsets
        consumer.close()


def main():
    parser = argparse.ArgumentParser(description="CDC event consumer")
    parser.add_argument("--topic", help="Single topic to consume (default: all)")
    parser.add_argument("--from-beginning", action="store_true",
                        help="Reset offset to beginning (replay all history)")
    args = parser.parse_args()

    topics       = [args.topic] if args.topic else TOPICS
    offset_reset = "earliest" if args.from_beginning else "latest"

    run(topics, offset_reset)


if __name__ == "__main__":
    main()
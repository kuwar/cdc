#!/usr/bin/env bash
# scripts/create_topics.sh
#
# Creates CDC Kafka topics with log compaction BEFORE Debezium starts.
# If Debezium creates topics automatically, it uses default retention policy
# (time-based delete), not compaction. We pre-create with correct settings.
#
# cleanup.policy=compact: keeps the latest message per key indefinitely.
# For CDC: the key is the row's primary key. Compaction ensures that a new
# consumer can always read the latest state for every entity ever seen.
#
# ── WHY docker exec + INTERNAL port ──────────────────────────────────────────
# We run kafka-topics.sh via docker exec (inside the container) for two reasons:
#
#   1. Full path requirement: apache/kafka:4.x keeps scripts at
#      /opt/kafka/bin/ which is NOT in $PATH inside the container.
#      We call /opt/kafka/bin/kafka-topics.sh with the full path.
#      On the host, you would need the Kafka tarball installed separately.
#      docker exec avoids that dependency.
#
#   2. Correct bootstrap port: processes inside the container use the
#      INTERNAL listener (localhost:9092). The EXTERNAL listener (9093)
#      is for host-machine processes connecting via -p NAT. Both work
#      from inside the container (0.0.0.0 binds both), but 9092 is
#      the semantically correct choice for intra-container commands.
#
# Summary of which port to use:
#   docker exec cdc-kafka ...  → bootstrap = localhost:9092  (inside container)
#   running on host machine    → bootstrap = localhost:9093  (via -p NAT)

set -euo pipefail

# INTERNAL listener — used because kafka-topics.sh runs inside the container
# via docker exec. 9092 is bound on 0.0.0.0 so localhost resolves to it.
BOOTSTRAP="localhost:9092"

# Full path to kafka-topics.sh inside apache/kafka:4.x image.
# /opt/kafka/bin/ is not in $PATH — must use absolute path.
KAFKA_TOPICS="/opt/kafka/bin/kafka-topics.sh"

# Helper: create topic only if it doesn't already exist
create_topic() {
    local topic="$1" partitions="${2:-3}"
    echo "  Creating topic: $topic (partitions=$partitions)"
    docker exec cdc-kafka "$KAFKA_TOPICS" \
        --bootstrap-server "$BOOTSTRAP" \
        --create \
        --if-not-exists \
        --topic "$topic" \
        --partitions "$partitions" \
        --replication-factor 1 \
        --config cleanup.policy=compact \
        --config min.cleanable.dirty.ratio=0.1 \
        --config segment.ms=60000 \
        --config delete.retention.ms=86400000
}

echo "[CDC] Creating CDC topics..."

# 3 partitions per topic:
#   - Partition key = row primary key (Debezium default)
#   - Same entity always lands on same partition → ordered per entity
#   - 3 partitions = up to 3 parallel consumers per topic per consumer group
create_topic "ecommerce.public.users"        3
create_topic "ecommerce.public.products"     3
create_topic "ecommerce.public.orders"       3
create_topic "ecommerce.public.order_items"  3

echo "[CDC] Topics created:"
docker exec cdc-kafka "$KAFKA_TOPICS" \
    --bootstrap-server "$BOOTSTRAP" \
    --list | grep ecommerce
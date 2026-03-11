#!/usr/bin/env bash
# scripts/stop.sh
#
# Stops and removes all CDC containers.
# Volumes are preserved by default (pass --clean to also remove volumes).

set -euo pipefail

CLEAN="${1:-}"

echo "[CDC] Stopping containers..."
docker stop  cdc-debezium cdc-schema-registry cdc-postgres cdc-kafka 2>/dev/null || true
docker rm    cdc-debezium cdc-schema-registry cdc-postgres cdc-kafka 2>/dev/null || true

if [[ "$CLEAN" == "--clean" ]]; then
    echo "[CDC] Removing volumes (--clean flag set)..."
    docker volume rm cdc-kafka-data cdc-postgres-data 2>/dev/null || true
    echo "[CDC] Removing network..."
    docker network rm cdc-network 2>/dev/null || true
    echo "[CDC] Full cleanup complete."
else
    echo "[CDC] Containers stopped. Data volumes preserved."
    echo "      Run with --clean to also remove volumes and network."
fi
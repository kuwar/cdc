#!/usr/bin/env bash
# scripts/stop.sh
#
# Stops and removes all CDC containers.
# Volumes are preserved by default (pass --clean to also remove volumes).
#
# Usage:
#   ./scripts/stop.sh           stop containers, keep data volumes
#   ./scripts/stop.sh --clean   stop containers AND wipe all volumes + network

set -euo pipefail

CLEAN="${1:-}"

echo "[CDC] Stopping containers..."
docker stop  cdc-kafka-connect cdc-ksqldb-server cdc-schema-registry cdc-postgres cdc-kafka cdc-minio 2>/dev/null || true
docker rm    cdc-kafka-connect cdc-ksqldb-server cdc-schema-registry cdc-postgres cdc-kafka cdc-minio 2>/dev/null || true

if [[ "$CLEAN" == "--clean" ]]; then
    echo "[CDC] Removing volumes (--clean flag set)..."
    docker volume rm cdc-kafka-data cdc-postgres-data cdc-minio-data 2>/dev/null || true
    echo "[CDC] Removing network..."
    docker network rm cdc-network 2>/dev/null || true
    echo "[CDC] Full cleanup complete."
else
    echo "[CDC] Containers stopped. Data volumes preserved."
    echo "      Run with --clean to also remove volumes and network."
fi
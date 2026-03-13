#!/usr/bin/env bash
# scripts/register-connectors/sink_minio.sh
#
# Registers the S3 sink connector pointed at the local MinIO instance.
#
# What this connector does:
#   Reads Avro CDC events from all four ecommerce Kafka topics and writes
#   them as Avro container files into the MinIO bucket ecommerce-cdc.
#
#   Object layout in MinIO:
#     ecommerce-cdc/raw/cdc/
#       ecommerce.public.orders/
#         year=2026/month=03/day=10/hour=14/
#           ecommerce.public.orders+0+000000000.avro
#
# Prerequisites:
#   - cdc-minio is running  (./scripts/start.sh starts it)
#   - bucket ecommerce-cdc exists  (./scripts/start.sh creates it)
#   - env.minio provides AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#     to the cdc-debezium container (passed via --env-file in start.sh)
#
# Usage:
#   bash scripts/register-connectors/sink_minio.sh
#   bash scripts/register-connectors/sink_minio.sh --force

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$SCRIPT_DIR/_lib.sh"

FORCE="${1:-}"

CONNECTOR_NAME="ecommerce-minio-sink"
CONNECTOR_CONFIG="config/kafka-connect/sink/minio-sink-connector.json"

register_connector "$CONNECTOR_NAME" "$CONNECTOR_CONFIG" "$FORCE"
print_status
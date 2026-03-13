#!/usr/bin/env bash
# scripts/register-connectors/source_postgres.sh
#
# Registers the Debezium PostgreSQL source connector.
#
# What this connector does:
#   Connects to cdc-postgres via the PostgreSQL logical replication protocol,
#   reads the WAL (Write-Ahead Log) using the pgoutput plugin, and publishes
#   every INSERT / UPDATE / DELETE as an Avro-serialised CDC event to Kafka.
#
#   Topics produced (one per table, named <prefix>.<schema>.<table>):
#     ecommerce.public.users
#     ecommerce.public.products
#     ecommerce.public.orders
#     ecommerce.public.order_items
#
# Usage:
#   bash scripts/register-connectors/source_postgres.sh
#   bash scripts/register-connectors/source_postgres.sh --force

set -euo pipefail

# Resolve project root regardless of where the script is called from.
# SCRIPT_DIR = .../scripts/register-connectors/
# PROJECT_ROOT = two levels up
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$SCRIPT_DIR/_lib.sh"

FORCE="${1:-}"

CONNECTOR_NAME="ecommerce-postgres-cdc"
CONNECTOR_CONFIG="config/kafka-connect/source/postgres-connector.json"

register_connector "$CONNECTOR_NAME" "$CONNECTOR_CONFIG" "$FORCE"
print_status
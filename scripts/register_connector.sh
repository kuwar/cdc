#!/usr/bin/env bash
# scripts/register_connector.sh
#
# Registers the Debezium PostgreSQL connector via Kafka Connect REST API.
#
# IDEMPOTENCY BEHAVIOUR:
#   - If connector does not exist → register it
#   - If connector exists and is RUNNING → skip (do nothing)
#   - If connector exists and is FAILED/PAUSED → delete and re-register
#
# This means:
#   - Running start.sh multiple times does NOT reset a healthy connector
#   - A failed connector is automatically re-registered on next start
#   - Pass --force to always delete and re-register regardless of state

set -euo pipefail

CONNECT_URL="http://localhost:8083"
CONNECTOR_NAME="ecommerce-postgres-cdc"
CONFIG_FILE="config/kafka-connect/source/postgres-connector.json"
FORCE="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[CDC]${NC} $*"; }
warn() { echo -e "${YELLOW}[CDC]${NC} $*"; }
err()  { echo -e "${RED}[CDC]${NC} $*"; exit 1; }

# ── Check if connector already exists ────────────────────────────────────────
EXISTING=$(curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]]; then
    STATE=$(echo "$EXISTING" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")

    if [[ "$STATE" == "RUNNING" && "$FORCE" != "--force" ]]; then
        log "Connector '$CONNECTOR_NAME' is already RUNNING — skipping registration."
        log "Use --force to delete and re-register: bash scripts/register_connector.sh --force"
        exit 0
    fi

    warn "Connector '$CONNECTOR_NAME' exists with state=$STATE — deleting before re-registration..."
    curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME" > /dev/null
    sleep 3
fi

# ── Register connector ────────────────────────────────────────────────────────
log "Registering connector from $CONFIG_FILE ..."
RESPONSE=$(curl -sf \
    -X POST "$CONNECT_URL/connectors" \
    -H "Content-Type: application/json" \
    -d @"$CONFIG_FILE")

log "Registered: $(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'])")"

# ── Wait for RUNNING state ────────────────────────────────────────────────────
log "Waiting for connector to reach RUNNING state..."
for i in $(seq 1 30); do
    STATE=$(curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" \
        2>/dev/null || echo "PENDING")
    echo "  [$i] state: $STATE"
    [[ "$STATE" == "RUNNING" ]] && break
    [[ "$STATE" == "FAILED"  ]] && {
        err "Connector failed to start. Check: docker logs cdc-debezium"
    }
    sleep 3
done

log "Final connector status:"
curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" | python3 -m json.tool
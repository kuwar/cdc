#!/usr/bin/env bash
# scripts/start.sh
#
# Starts all CDC containers in dependency order.
# Does NOT rebuild images — use scripts/build.sh for that.
#
# Usage:
#   ./scripts/start.sh           normal start (skips connector if already RUNNING)
#   ./scripts/start.sh --clean   wipe all volumes and start fresh
#
# Run from the project root (cdc-ecommerce/).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

CLEAN="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[CDC]${NC} $*"; }
warn() { echo -e "${YELLOW}[CDC]${NC} $*"; }
err()  { echo -e "${RED}[CDC]${NC} $*"; exit 1; }

wait_for_port() {
    local host="$1" port="$2" label="$3" timeout="${4:-90}"
    local elapsed=0
    warn "Waiting for $label ($host:$port)..."
    until nc -z "$host" "$port" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed+2))
        [[ $elapsed -ge $timeout ]] && err "$label did not become ready in ${timeout}s"
        echo -n "."
    done
    echo ""; log "$label is ready"
}

wait_for_http() {
    local url="$1" label="$2" timeout="${3:-90}"
    local elapsed=0
    warn "Waiting for $label ($url)..."
    until curl -sf "$url" > /dev/null 2>&1; do
        sleep 3; elapsed=$((elapsed+3))
        [[ $elapsed -ge $timeout ]] && err "$label did not respond in ${timeout}s"
        echo -n "."
    done
    echo ""; log "$label is ready"
}

# ── Optional clean wipe ───────────────────────────────────────────────────────
if [[ "$CLEAN" == "--clean" ]]; then
    warn "Clean start: removing existing containers and volumes..."
    docker stop  cdc-debezium cdc-schema-registry cdc-postgres cdc-kafka 2>/dev/null || true
    docker rm    cdc-debezium cdc-schema-registry cdc-postgres cdc-kafka 2>/dev/null || true
    docker volume rm cdc-kafka-data cdc-postgres-data 2>/dev/null || true
    log "Clean wipe done"
fi

# ── Network ───────────────────────────────────────────────────────────────────
docker network create cdc-network 2>/dev/null && log "Network created" || warn "Network cdc-network already exists"

# ── Step 1: Kafka ─────────────────────────────────────────────────────────────
if docker inspect cdc-kafka > /dev/null 2>&1; then
    warn "cdc-kafka already exists — starting if stopped..."
    docker start cdc-kafka 2>/dev/null || true
else
    log "Starting Kafka..."
    docker run -d \
        --name cdc-kafka \
        --network cdc-network \
        --hostname cdc-kafka \
        -p 9093:9093 \
        --restart unless-stopped \
        -v cdc-kafka-data:/var/lib/kafka/data \
        cdc-kafka:latest
fi
wait_for_port localhost 9093 "Kafka" 120

# ── Step 2: Schema Registry ───────────────────────────────────────────────────
if docker inspect cdc-schema-registry > /dev/null 2>&1; then
    warn "cdc-schema-registry already exists — starting if stopped..."
    docker start cdc-schema-registry 2>/dev/null || true
else
    log "Starting Schema Registry..."
    docker run -d \
        --name cdc-schema-registry \
        --network cdc-network \
        --hostname cdc-schema-registry \
        -p 8081:8081 \
        --restart unless-stopped \
        cdc-schema-registry:latest
fi
wait_for_http "http://localhost:8081/subjects" "Schema Registry" 90

# ── Step 3: PostgreSQL ────────────────────────────────────────────────────────
if docker inspect cdc-postgres > /dev/null 2>&1; then
    warn "cdc-postgres already exists — starting if stopped..."
    docker start cdc-postgres 2>/dev/null || true
else
    log "Starting PostgreSQL..."
    docker run -d \
        --name cdc-postgres \
        --network cdc-network \
        --hostname cdc-postgres \
        -p 5432:5432 \
        --restart unless-stopped \
        -v cdc-postgres-data:/var/lib/postgresql/data \
        -e POSTGRES_USER=ecommerce_user \
        -e POSTGRES_PASSWORD=ecommerce_pass \
        -e POSTGRES_DB=ecommerce \
        cdc-postgres:latest
fi
log "Waiting for PostgreSQL..."
until docker exec cdc-postgres pg_isready -U ecommerce_user -d ecommerce -q 2>/dev/null; do
    sleep 2; echo -n "."; done; echo ""
log "PostgreSQL is ready"

# ── Step 4: Create Kafka topics (idempotent — --if-not-exists) ────────────────
log "Ensuring Kafka CDC topics exist..."
bash scripts/create_topics.sh

# ── Step 5: Kafka Connect (cp-kafka-connect) ──────────────────────────────────
if docker inspect cdc-kafka-connect > /dev/null 2>&1; then
    warn "cdc-kafka-connect already exists — starting if stopped..."
    docker start cdc-kafka-connect 2>/dev/null || true
else
    log "Starting Kafka Connect..."
    docker run -d \
        --name cdc-kafka-connect \
        --network cdc-network \
        --hostname cdc-kafka-connect \
        -p 8083:8083 \
        --restart unless-stopped \
        -v "$(pwd)/config/kafka-connect/aws-credentials.properties:/etc/kafka-connect/aws-credentials.properties:ro" \
        --env-file "$(pwd)/env.aws" \
        cdc-kafka-connect:latest
fi
wait_for_http "http://localhost:8083/connectors" "Kafka Connect" 120

# ── Step 6: Register connector (skips if already RUNNING) ─────────────────────
log "Checking connector registration..."
bash scripts/register_connector.sh

# ── Done ──────────────────────────────────────────────────────────────────────
log "================================================="
log " CDC stack is running!"
log ""
log " Services:"
log "   Kafka           → localhost:9093  (EXTERNAL listener)"
log "   Schema Registry → http://localhost:8081"
log "   PostgreSQL      → localhost:5432  (db: ecommerce)"
log "   Kafka Connect   → http://localhost:8083"
log ""
log " Connector status:"
log "   curl http://localhost:8083/connectors/ecommerce-postgres-cdc/status"
log ""
log " Run simulation:  python python/simulate.py"
log " Run consumer:    python python/consumer.py"
log ""
log " To fully reset:  ./scripts/start.sh --clean"
log "================================================="
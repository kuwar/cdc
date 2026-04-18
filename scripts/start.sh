#!/usr/bin/env bash
# scripts/start.sh
#
# Starts all CDC containers in dependency order.
# Does NOT rebuild images — use scripts/build.sh for that.
#
# Usage:
#   ./scripts/start.sh           normal start (idempotent — safe to run repeatedly)
#   ./scripts/start.sh --clean   wipe all volumes and start completely fresh
#
# Object storage: MinIO (S3-compatible, local).
# To switch to real AWS S3: replace --env-file env.minio with --env-file aws.env
# in the cdc-kafka-connect step and register ecommerce-s3-sink instead of
# ecommerce-minio-sink in register_connector.sh.
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

# ── Prerequisite check ────────────────────────────────────────────────────────
[[ -f "env.minio" ]] || err \
    "env.minio not found.\n" \
    "Copy the template and set credentials:\n" \
    "  cp env.minio.template env.minio"

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
    docker stop  cdc-kafka-connect cdc-schema-registry cdc-postgres cdc-kafka cdc-minio cdc-ksqldb-server 2>/dev/null || true
    docker rm    cdc-kafka-connect cdc-schema-registry cdc-postgres cdc-kafka cdc-minio cdc-ksqldb-server 2>/dev/null || true
    docker volume rm cdc-kafka-data cdc-postgres-data cdc-minio-data 2>/dev/null || true
    docker network rm cdc-network 2>/dev/null || true
    log "Clean wipe done"
fi

# ── Network ───────────────────────────────────────────────────────────────────
docker network create cdc-network 2>/dev/null \
    && log "Network cdc-network created" \
    || warn "Network cdc-network already exists"

# ── Step 1: Kafka ─────────────────────────────────────────────────────────────
if docker container inspect cdc-kafka > /dev/null 2>&1; then
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
if docker container inspect cdc-schema-registry > /dev/null 2>&1; then
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

# ── Step 3: ksqlDB ───────────────────────────────────────────────────────────
#
# ksqlDB depends on Kafka (bootstrap) and Schema Registry (Avro decoding).
# It must start AFTER both are healthy. PostgreSQL and Kafka Connect are not
# required for ksqlDB itself — it only reads from Kafka topics.
#
# Port 8088: ksqlDB REST API. Connect from the host with:
#   docker exec -it cdc-ksqldb-server ksql http://localhost:8088
#   curl http://localhost:8088/info
if docker container inspect cdc-ksqldb-server > /dev/null 2>&1; then
    warn "cdc-ksqldb-server already exists — starting if stopped..."
    docker start cdc-ksqldb-server 2>/dev/null || true
else
    log "Starting ksqlDB..."
    docker run -d \
        --name cdc-ksqldb-server \
        --network cdc-network \
        --hostname cdc-ksqldb-server \
        -p 8088:8088 \
        --restart unless-stopped \
        cdc-ksqldb:latest
fi
wait_for_http "http://localhost:8088/info" "ksqlDB" 120

# ── Step 4: PostgreSQL ────────────────────────────────────────────────────────
if docker container inspect cdc-postgres > /dev/null 2>&1; then
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

# ── Step 5: Create Kafka topics (idempotent — --if-not-exists) ────────────────
log "Ensuring Kafka CDC topics exist..."
bash scripts/create_topics.sh

# ── Step 6: MinIO ─────────────────────────────────────────────────────────────
#
# MinIO starts with credentials from minio.env (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD).
# The volume cdc-minio-data persists all objects across container restarts.
#
# Port mapping:
#   9000 → MinIO S3 API   (used by cdc-kafka-connect / S3 connector internally via cdc-minio:9000)
#   9001 → MinIO Console  (open http://localhost:9001 in your browser)
if docker container inspect cdc-minio > /dev/null 2>&1; then
    warn "cdc-minio already exists — starting if stopped..."
    docker start cdc-minio 2>/dev/null || true
else
    log "Starting MinIO..."
    docker run -d \
        --name cdc-minio \
        --network cdc-network \
        --hostname cdc-minio \
        -p 9000:9000 \
        -p 9001:9001 \
        --restart unless-stopped \
        -v cdc-minio-data:/data \
        --env-file "$(pwd)/env.minio" \
        cdc-minio:latest
fi
wait_for_http "http://localhost:9000/minio/health/live" "MinIO" 60

# ── Step 6a: Create MinIO bucket ──────────────────────────────────────────────
#
# Bucket creation is a one-time operation. We use the official minio/mc image
# (MinIO Client) as a one-shot container — it connects to cdc-minio, creates
# the bucket if it does not already exist, then exits.
#
# MC_HOST_local sets a named alias "local" pointing at the MinIO server.
# Format: http://<access-key>:<secret-key>@<host>:<port>
#
# Reading credentials from env.minio rather than hardcoding them here.
MINIO_USER=$(grep '^MINIO_ROOT_USER='     "$(pwd)/env.minio" | cut -d= -f2)
MINIO_PASS=$(grep '^MINIO_ROOT_PASSWORD=' "$(pwd)/env.minio" | cut -d= -f2)

BUCKET_EXISTS=$(docker run --rm \
    --network cdc-network \
    -e "MC_HOST_local=http://${MINIO_USER}:${MINIO_PASS}@cdc-minio:9000" \
    minio/mc ls local/ 2>/dev/null | grep -c "ecommerce-cdc" || true)

if [[ "$BUCKET_EXISTS" -eq 0 ]]; then
    log "Creating MinIO bucket: ecommerce-cdc ..."
    docker run --rm \
        --network cdc-network \
        -e "MC_HOST_local=http://${MINIO_USER}:${MINIO_PASS}@cdc-minio:9000" \
        minio/mc mb local/ecommerce-cdc
    log "Bucket ecommerce-cdc created"
else
    warn "Bucket ecommerce-cdc already exists — skipping creation"
fi

# ── Step 7: Kafka Connect (cp-kafka-connect) ──────────────────────────────────
#
# TWO VARIANTS — only one docker run should be active at a time.
#
# VARIANT A: MinIO (local, default)
#   Uses env.minio for credentials (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#   map to MinIO root credentials). The aws-credentials.properties file is
#   still mounted so the FileConfigProvider can start cleanly, but the active
#   connector uses minio-connector.json which does not reference it.
#
# VARIANT B: AWS S3 (real cloud)
#   Uses env.aws for real IAM credentials. The aws-credentials.properties file
#   supplies s3.bucket.name and s3.region to s3-connector.json via
#   FileConfigProvider (${file:...} interpolation).
#   Prerequisites before switching:
#     1. Populate env.aws with real AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#     2. Populate config/kafka-connect/aws-credentials.properties with
#        aws.s3.bucket.name and aws.s3.region
#     3. Ensure the S3 bucket exists and the IAM user has s3:PutObject,
#        s3:GetObject, s3:ListBucket, s3:AbortMultipartUpload,
#        s3:ListMultipartUploadParts on that bucket
#     4. In Step 8 below, switch register_connector.sh to use
#        sink_aws_s3.sh instead of sink_minio.sh
if docker container inspect cdc-kafka-connect > /dev/null 2>&1; then
    warn "cdc-kafka-connect already exists — starting if stopped..."
    docker start cdc-kafka-connect 2>/dev/null || true
else
    log "Starting Kafka Connect..."

    # VARIANT A: MinIO (active)
    docker run -d \
        --name cdc-kafka-connect \
        --network cdc-network \
        --hostname cdc-kafka-connect \
        -p 8083:8083 \
        --restart unless-stopped \
        --env-file "$(pwd)/env.minio" \
        -v "$(pwd)/config/kafka-connect/aws-credentials.properties:/etc/kafka-connect/aws-credentials.properties:ro" \
        cdc-kafka-connect:latest

    # VARIANT B: AWS S3 (inactive — comment out VARIANT A above and uncomment below)
    # docker run -d \
    #     --name cdc-kafka-connect \
    #     --network cdc-network \
    #     --hostname cdc-kafka-connect \
    #     -p 8083:8083 \
    #     --restart unless-stopped \
    #     --env-file "$(pwd)/env.aws" \
    #     -v "$(pwd)/config/kafka-connect/aws-credentials.properties:/etc/kafka-connect/aws-credentials.properties:ro" \
    #     cdc-kafka-connect:latest
fi
wait_for_http "http://localhost:8083/connectors" "Kafka Connect" 120

# ── Step 8: Register connectors (skips any already RUNNING) ───────────────────
log "Checking connector registration..."
bash scripts/register_connector.sh

# ── Done ──────────────────────────────────────────────────────────────────────
log "======================================================="
log " CDC stack is running!"
log ""
log " Services:"
log "   Kafka           → localhost:9093"
log "   Schema Registry → http://localhost:8081"
log "   PostgreSQL      → localhost:5432  (db: ecommerce)"
log "   Kafka Connect   → http://localhost:8083"
log "   ksqlDB          → http://localhost:8088"
log "   MinIO S3 API    → http://localhost:9000"
log "   MinIO Console   → http://localhost:9001  ← browse your data here"
log ""
log " MinIO credentials (from config/connect/minio.env):"
log "   User: ${MINIO_USER}"
log "   Pass: (see minio.env)"
log ""
log " Connector status:"
log "   curl http://localhost:8083/connectors/ecommerce-postgres-cdc/status"
log "   curl http://localhost:8083/connectors/ecommerce-minio-sink/status"
log ""
log " ksqlDB CLI:"
log "   docker exec -it cdc-ksqldb-server ksql http://localhost:8088"
log ""
log " Run simulation:  python python/simulate.py"
log " Run consumer:    python python/consumer.py"
log ""
log " To fully reset:  ./scripts/start.sh --clean"
log "======================================================="
#!/usr/bin/env bash
# scripts/build.sh
#
# Builds all Docker images.
# Separated from start.sh so you can restart containers without rebuilding.
#
# Usage:
#   ./scripts/build.sh              build all images
#   ./scripts/build.sh kafka        build only the kafka image
#   ./scripts/build.sh connect      build only the kafka-connect image
#   ./scripts/build.sh minio        build only the minio image
#
# Run from the project root (cdc-ecommerce/).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[CDC]${NC} $*"; }

TARGET="${1:-all}"

# Native arm64 images available — no platform flag needed
build_kafka()    { log "Building cdc-kafka...";           docker build -f docker/Dockerfile.kafka              -t cdc-kafka:latest           .; }
build_postgres() { log "Building cdc-postgres...";        docker build -f docker/Dockerfile.postgres           -t cdc-postgres:latest        .; }
build_minio()    { log "Building cdc-minio...";           docker build -f docker/Dockerfile.minio              -t cdc-minio:latest           .; }

# Confluent images are amd64-only; --platform makes the intent explicit and
# suppresses the platform-mismatch warning at run time.
build_registry() { log "Building cdc-schema-registry..."; docker build --platform linux/amd64 -f docker/Dockerfile.cp-schema-registry -t cdc-schema-registry:latest .; }
build_connect()  { log "Building cdc-kafka-connect...";   docker build --platform linux/amd64 -f docker/Dockerfile.cp-kafka-connect   -t cdc-kafka-connect:latest   .; }
build_ksqldb()     { log "Building cdc-ksqldb...";        docker build --platform linux/amd64 -f docker/Dockerfile.cp-ksqldb-server   -t cdc-ksqldb:latest          .; }
build_ksqldb_cli() { log "Building cdc-ksqldb-cli...";    docker build --platform linux/amd64 -f docker/Dockerfile.cp-ksqldb-cli      -t cdc-ksqldb-cli:latest      .; }

case "$TARGET" in
    kafka)       build_kafka       ;;
    postgres)    build_postgres    ;;
    registry)    build_registry    ;;
    connect)     build_connect     ;;
    minio)       build_minio       ;;
    ksqldb)      build_ksqldb      ;;
    ksqldb-cli)  build_ksqldb_cli  ;;
    all)
        build_kafka
        build_postgres
        build_registry
        build_connect
        build_minio
        build_ksqldb
        build_ksqldb_cli
        log "All images built"
        ;;
    *)
        echo "Usage: $0 [all|kafka|postgres|registry|connect|minio|ksqldb|ksqldb-cli]"
        exit 1
        ;;
esac
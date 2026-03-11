#!/usr/bin/env bash
# scripts/build.sh
#
# Builds all Docker images.
# Separated from start.sh so you can restart containers without rebuilding.
#
# Usage:
#   ./scripts/build.sh           build all images
#   ./scripts/build.sh kafka     build only the kafka image
#   ./scripts/build.sh connect   build only the kafka-connect image
#
# Run from the project root (cdc-ecommerce/).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[CDC]${NC} $*"; }

TARGET="${1:-all}"

build_kafka()    { log "Building cdc-kafka...";           docker build -f docker/Dockerfile.kafka          -t cdc-kafka:latest           .; }
build_postgres() { log "Building cdc-postgres...";        docker build -f docker/Dockerfile.postgres       -t cdc-postgres:latest        .; }
build_registry() { log "Building cdc-schema-registry..."; docker build -f docker/Dockerfile.cp-schema-registry -t cdc-schema-registry:latest .; }
build_connect()  { log "Building cdc-kafka-connect...";   docker build -f docker/Dockerfile.cp-kafka-connect -t cdc-kafka-connect:latest   .; }

case "$TARGET" in
    kafka)    build_kafka    ;;
    postgres) build_postgres ;;
    registry) build_registry ;;
    connect)  build_connect  ;;
    all)
        build_kafka
        build_postgres
        build_registry
        build_connect
        log "All images built"
        ;;
    *)
        echo "Usage: $0 [all|kafka|postgres|registry|connect]"
        exit 1
        ;;
esac
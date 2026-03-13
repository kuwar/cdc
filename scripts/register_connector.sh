#!/usr/bin/env bash
# scripts/register_connector.sh
#
# Orchestrator — registers all connectors or a named subset.
# Called by start.sh during stack startup.
# Each connector also has its own standalone script in register-connectors/.
#
# Usage:
#   bash scripts/register_connector.sh               register all
#   bash scripts/register_connector.sh --force       force re-register all
#   bash scripts/register_connector.sh source        source connectors only
#   bash scripts/register_connector.sh sink          sink connectors only
#   bash scripts/register_connector.sh source --force
#
# Individual scripts (can be called directly without going through this file):
#   bash scripts/register-connectors/source_postgres.sh [--force]
#   bash scripts/register-connectors/sink_minio.sh      [--force]
#   bash scripts/register-connectors/sink_aws_s3.sh     [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

REG_DIR="$SCRIPT_DIR/register-connectors"

# ── Parse arguments ───────────────────────────────────────────────────────────
TARGET="all"
FORCE=""
for arg in "$@"; do
    case "$arg" in
        --force)        FORCE="--force" ;;
        source|sink|all) TARGET="$arg" ;;
    esac
done

# ── Source helper for print_status ───────────────────────────────────────────
source "$REG_DIR/_lib.sh"

# ── Dispatch ──────────────────────────────────────────────────────────────────
run_source() { bash "$REG_DIR/source_postgres.sh" $FORCE; }
run_sink()   {
    # Default sink: MinIO. Switch to sink_aws_s3.sh for production.
    bash "$REG_DIR/sink_minio.sh" $FORCE;
}

case "$TARGET" in
    source) run_source ;;
    sink)   run_sink   ;;
    all)
        run_source
        run_sink
        ;;
esac
#!/usr/bin/env bash
# scripts/register-connectors/sink_aws_s3.sh
#
# Registers the S3 sink connector pointed at real AWS S3.
#
# What this connector does:
#   Reads Avro CDC events from all four ecommerce Kafka topics and writes
#   them as Avro container files into the configured AWS S3 bucket.
#
#   Object layout in S3:
#     s3://<bucket>/raw/cdc/
#       ecommerce.public.orders/
#         year=2026/month=03/day=10/hour=14/
#           ecommerce.public.orders+0+000000000.avro
#
# Prerequisites:
#   1. config/kafka-connect/aws-credentials.properties exists and contains:
#        s3.bucket.name=your-bucket
#        s3.region=eu-west-1
#
#   2. env.aws exists and contains:
#        AWS_ACCESS_KEY_ID=AKIA...
#        AWS_SECRET_ACCESS_KEY=...
#
#   3. The cdc-kafka-connect container was started with --env-file aws.env.
#      If it was started with env.minio (the default), recreate it:
#        docker stop cdc-kafka-connect && docker rm cdc-kafka-connect
#        docker run -d ... --env-file env.aws cdc-kafka-connect:latest
#
#   4. The S3 bucket exists in the configured region.
#
#   5. The IAM user has s3:PutObject, s3:GetObject, s3:ListBucket,
#      s3:AbortMultipartUpload, s3:ListMultipartUploadParts on the bucket.
#
# Usage:
#   bash scripts/register-connectors/sink_aws_s3.sh
#   bash scripts/register-connectors/sink_aws_s3.sh --force

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$SCRIPT_DIR/_lib.sh"

FORCE="${1:-}"

# ── Prerequisites check ───────────────────────────────────────────────────────
[[ -f "config/kafka-connect/aws-credentials.properties" ]] \
    || err "config/kafka-connect/aws-credentials.properties not found.\n  Copy the template: cp config/kafka-connect/aws-credentials.properties.template config/kafka-connect/aws-credentials.properties"

[[ -f "env.aws" ]] \
    || err "env.aws not found.\n  Copy the template: cp env.aws.template env.aws"

# Warn if the cdc-kafka-connect container appears to be running with minio.env
# (heuristic: check if AWS_ACCESS_KEY_ID inside the container is the MinIO default)
CURRENT_KEY=$(docker exec cdc-kafka-connect env 2>/dev/null \
    | grep '^AWS_ACCESS_KEY_ID=' | cut -d= -f2 || echo "")
if [[ "$CURRENT_KEY" == "minioadmin" ]]; then
    warn "cdc-kafka-connect appears to be running with MinIO credentials."
    warn "The S3 connector will fail to authenticate against AWS."
    warn "Recreate the container with aws.env:"
    warn "  docker stop cdc-kafka-connect && docker rm cdc-kafka-connect"
    warn "  Then re-run ./scripts/start.sh after updating it to use --env-file aws.env"
    echo ""
    read -r -p "Continue anyway? (yes/no): " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { log "Aborted."; exit 0; }
fi

CONNECTOR_NAME="ecommerce-s3-sink"
CONNECTOR_CONFIG="config/kafka-connect/sink/s3-sink-connector.json"

register_connector "$CONNECTOR_NAME" "$CONNECTOR_CONFIG" "$FORCE"
print_status
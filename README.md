# CDC E-Commerce Pipeline

A production-grade **Change Data Capture (CDC)** pipeline that streams real-time database changes from PostgreSQL into Apache Kafka and AWS S3, using Debezium, Confluent Schema Registry, and Avro serialisation.

Built as a portfolio project demonstrating senior data engineering patterns: event-driven architecture, schema evolution, exactly-once semantics, and cloud sink integration — all running locally via Docker.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Configuration](#configuration)
- [Running the Pipeline](#running-the-pipeline)
- [Operational Reference](#operational-reference)
- [Development Guide](#development-guide)
- [Contributing](#contributing)
- [Troubleshooting](#troubleshooting)

---

## Overview

This pipeline captures every `INSERT`, `UPDATE`, and `DELETE` from a simulated e-commerce PostgreSQL database and publishes them as structured Avro events to Kafka topics — in real time, without any changes to the application.

**What it demonstrates:**

- CDC via PostgreSQL logical replication (WAL) using Debezium
- Schema-on-write with Confluent Schema Registry and Avro
- Kafka in KRaft mode (no ZooKeeper) with multi-listener networking
- Sink connector streaming Avro CDC events to AWS S3 as partitioned files
- Least-privilege database design (dedicated replication user, scoped publication)
- Heartbeat-driven WAL slot management to prevent disk bloat
- Dead-letter queue handling for sink connector failures

**Data flow:**

```
PostgreSQL WAL
    │  logical replication slot (pgoutput)
    ▼
Debezium Source Connector
    │  Avro + Schema Registry
    ▼
Kafka Topics (one per table)
    │
    ├──▶  Python Consumer    (real-time terminal output)
    │
    └──▶  S3 Sink Connector  (partitioned Avro files on AWS S3)
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          cdc-network (Docker bridge)                │
│                                                                     │
│  ┌──────────────┐    WAL stream     ┌───────────────────────────┐  │
│  │              │ ←──────────────── │  cdc-kafka-connect       │  │
│  │  cdc-postgres│                   │   cp-kafka-connect:8.2.0  │  │
│  │  postgres:18 │                   │                           │  │
│  │  port 5432   │                   │  ┌─────────────────────┐  │  │
│  │              │                   │  │ Debezium PG Source  │  │  │
│  │  Tables:     │                   │  │ connector           │  │  │
│  │  • users     │                   │  └──────────┬──────────┘  │  │
│  │  • products  │                   │             │ Avro         │  │
│  │  • orders    │                   │  ┌──────────▼──────────┐  │  │
│  │  • order_    │                   │  │ S3 Sink connector   │  │  │
│  │    items     │                   │  └──────────┬──────────┘  │  │
│  └──────────────┘                   └─────────────┼─────────────┘  │
│                                                   │                 │
│  ┌──────────────────────┐           ┌─────────────▼─────────────┐  │
│  │  cdc-schema-registry │           │   cdc-kafka               │  │
│  │  cp-schema-registry  │◀─────────▶│   apache/kafka:4.2.0      │  │
│  │  :8081               │  schemas  │   KRaft mode (no ZK)      │  │
│  │                      │           │                           │  │
│  │  Schema store:       │           │   Topics:                 │  │
│  │  _schemas (compacted)│           │   ecommerce.public.users  │  │
│  └──────────────────────┘           │   ecommerce.public.orders │  │
│                                     │   ecommerce.public.       │  │
│                                     │     products              │  │
│                                     │   ecommerce.public.       │  │
│                                     │     order_items           │  │
│                                     └───────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

  Host machine:
    Python consumer  →  localhost:9093 (Kafka EXTERNAL listener)
    Python simulator →  localhost:5432 (PostgreSQL)
    Scripts          →  localhost:8083 (Kafka Connect REST API)

  AWS S3:
    s3://your-bucket/raw/cdc/
      ecommerce.public.orders/year=2026/month=03/day=10/hour=14/
        ecommerce.public.orders+0+000000000.avro
```

### Kafka Listener Architecture

Kafka exposes three listeners on separate ports — each for a different network context:

| Listener   | Port | Protocol  | Used by                              |
|------------|------|-----------|--------------------------------------|
| INTERNAL   | 9092 | PLAINTEXT | Debezium, Schema Registry, Connect   |
| EXTERNAL   | 9093 | PLAINTEXT | Host machine (Python scripts, CLI)   |
| CONTROLLER | 9094 | PLAINTEXT | KRaft controller-broker coordination |

Only port `9093` is published via `-p 9093:9093`. Ports `9092` and `9094` stay inside `cdc-network`.

### CDC Event Structure

Every Kafka message produced by Debezium follows this Avro envelope:

```json
{
  "op":     "c | u | d | r",
  "before": { ... } ,
  "after":  { ... },
  "source": {
    "table": "orders",
    "db":    "ecommerce",
    "lsn":   12345678,
    "txId":  42,
    "ts_ms": 1741622400000
  },
  "ts_ms":  1741622400123
}
```

`op` values: `c` = INSERT, `u` = UPDATE, `d` = DELETE, `r` = snapshot read.

---

## Tech Stack

| Component            | Technology                          | Version |
|----------------------|-------------------------------------|---------|
| Message broker       | Apache Kafka (KRaft mode)           | 4.2.0   |
| CDC connector        | Debezium PostgreSQL Source          | 3.1.2   |
| Connect runtime      | Confluent cp-kafka-connect          | 8.2.0   |
| Schema registry      | Confluent cp-schema-registry        | 8.2.0   |
| Serialisation        | Apache Avro                         | —       |
| Source database      | PostgreSQL                          | 18      |
| Cloud sink           | Confluent S3 Sink Connector         | 12.1.2 |
| Cloud storage        | AWS S3                              | —       |
| Python Kafka client  | confluent-kafka                     | 2.13.2   |
| Container runtime    | Docker                              | 29.1.3     |

---

## Project Structure

```
cdc-ecommerce/
│
├── docker/                          # Dockerfile per service
│   ├── Dockerfile.kafka             # apache/kafka:4.2.0 with KRaft config
│   ├── Dockerfile.postgres          # postgres:18 with CDC config + schema
│   ├── Dockerfile.cp-schema-registry   # cp-schema-registry:8.2.0
│   └── Dockerfile.cp-kafka-connect    # cp-kafka-connect:8.2.0
│                                    #   + Debezium(Maven Central)
│                                    #   + S3 Sink(Confluent Hub)
│
├── config/
│   ├── postgres/
│   │   ├── init.sql                 # Schema, users, publication, seed data
│   │   ├── custom.conf              # PostgreSQL CDC tuning (wal_level=logical)
│   │   └── pg_hba.conf              # Host-based auth rules
│   ├── debezium/
│   │   ├── postgres-connector.json  # Debezium source connector config
│   │   └── s3-sink-connector.json   # S3 sink connector config
│   └── kafka-connect/
│   |    |── source/
│   |    |   └── postgres-connector.json
│   |    |── sink/
│   |    |   └── s3-sink-connector.json
│   |    |── aws-credentials.properties.template   # S3 bucket + region
│
├── scripts/
│   ├── build.sh                     # Build all (or one) Docker image(s)
│   ├── start.sh                     # Start stack, idempotent
│   ├── stop.sh                      # Stop stack, preserve volumes
│   ├── create_topics.sh             # Pre-create Kafka topics with compact policy
│   └── register_connector.sh        # Register source and/or sink connectors
│
├── python/
│   ├── config.py                    # Bootstrap, Schema Registry, DB connection
│   ├── simulate.py                  # E-commerce workload generator
│   ├── consumer.py                  # Real-time CDC event terminal viewer
│   └── requirements.txt
│
└── README.md
|── env.aws                     # AWS credentials (never commit)
```

---

## Prerequisites

| Requirement     | Minimum version | Check                      |
|-----------------|-----------------|----------------------------|
| Docker Desktop  | 29.1.3          | `docker --version`         |
| Python          | 3.14.2          | `python --version`         |
| AWS CLI         | 2.34.6          | `aws --version`            |
| `nc` (netcat)   | any             | `nc -h`                    |
| `curl`          | any             | `curl --version`           |

Docker Desktop must be **running** before executing any script. The pipeline uses ~3 GB RAM across all containers. Recommended: 6 GB allocated to Docker.

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/your-username/cdc-ecommerce.git
cd cdc-ecommerce
```

### 2. Set up Python environment

```bash
python -m venv venv
source venv/bin/activate           # Windows: venv\Scripts\activate
pip install -r python/requirements.txt
```

### 3. Configure AWS credentials

This step is only required for the S3 sink connector. Skip if running Kafka + PostgreSQL only.

```bash
# Copy templates
cp config/kafka-connect/aws-credentials.properties.template \
   config/kafka-connect/aws-credentials.properties

cp env.aws.template \
   env.aws

# Add real values — see Configuration section below
```

Then add both files to `.gitignore`:

```bash
echo "config/kafka-connect/aws-credentials.properties" >> .gitignore
echo "env.aws"                    >> .gitignore
```

### 4. Build Docker images

```bash
chmod +x scripts/*.sh
./scripts/build.sh
```

Build time is ~3–5 minutes on first run (downloads Debezium plugin ZIP and S3 connector from the internet). Subsequent builds use the Docker layer cache and complete in seconds.

### 5. Start the stack

```bash
./scripts/start.sh
```

This script is **idempotent** — running it multiple times is safe. It checks whether each container already exists before creating it, and skips connector registration if the connector is already `RUNNING`.

### 6. Verify all services are up

```bash
# Kafka — list topics
docker exec cdc-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Schema Registry
curl -s http://localhost:8081/subjects

# Kafka Connect — list loaded plugins
curl -s http://localhost:8083/connector-plugins | python3 -m json.tool

# Connector status
curl -s http://localhost:8083/connectors/ecommerce-postgres-cdc/status \
  | python3 -m json.tool
```

---

## Configuration

### AWS Credentials

Credentials are split across two files to prevent secrets from appearing in connector logs (Kafka Connect logs every config property at startup).

**`config/kafka-connect/aws-credentials.properties`** — not secret, safe to appear in logs:

```properties
s3.bucket.name=your-ecommerce-cdc-bucket
s3.region=eu-west-1
```

**`env.aws`** — secret, never commit, never logs:

```properties
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

Get the key ID and secret from: **AWS Console → IAM → Users → your user → Security credentials → Create access key**. The secret is shown only once at creation time.

The `env.aws` file is passed to the Kafka Connect container via `--env-file` in `start.sh`. The AWS SDK inside the S3 connector reads `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` automatically from the environment via the Default Credential Provider Chain — credentials never appear in connector config or logs.

### IAM Policy for S3 Sink

Attach this policy to your IAM user or role:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ],
    "Resource": [
      "arn:aws:s3:::your-ecommerce-cdc-bucket",
      "arn:aws:s3:::your-ecommerce-cdc-bucket/*"
    ]
  }]
}
```

### Connector Configuration

Both connector configs live in `config/debezium/` and are registered via the Kafka Connect REST API — they are not baked into the image.

Key settings in `postgres-connector.json`:

| Setting | Value | Why |
|---------|-------|-----|
| `publication.autocreate.mode` | `disabled` | Publication is pre-created by `init.sql`; Debezium must not ALTER it |
| `snapshot.mode` | `initial` | Snapshot all existing rows on first run, then stream WAL |
| `tombstones.on.delete` | `true` | Emit null-value tombstone after DELETE for log compaction |
| `heartbeat.interval.ms` | `10000` | Prevent WAL slot from falling behind when tables are idle |
| `decimal.handling.mode` | `double` | Consistent numeric type in Avro across all consumers |

Key settings in `s3-sink-connector.json`:

| Setting | Value | Why |
|---------|-------|-----|
| `format.class` | `AvroFormat` | Avro container files readable by Spark, Athena, Glue |
| `flush.size` | `1000` | Close and upload file after 1000 records |
| `rotate.interval.ms` | `60000` | Also flush if 60 seconds pass (handles low-volume periods) |
| `timestamp.extractor` | `RecordField` | Partition by event time (`ts_ms`), not processing time |
| `path.format` | `year=YYYY/month=MM/day=dd/hour=HH` | Hive-compatible partitioning for Athena/Glue |
| `errors.deadletterqueue.topic.name` | `ecommerce-s3-sink-dlq` | Failed messages routed here instead of blocking the connector |

---

## Running the Pipeline

### Normal daily workflow

```bash
# Start everything (resumes from last offset — no data loss, no re-snapshot)
./scripts/start.sh

# In terminal 1: produce e-commerce events
source venv/bin/activate
python python/simulate.py

# In terminal 2: consume and display CDC events in real time
source venv/bin/activate
python python/consumer.py
```

### Simulator options

```bash
python python/simulate.py                  # run continuously
python python/simulate.py --loops 5        # run 5 cycles then exit
```

The simulator generates realistic order lifecycle events:
`register user → browse products → place order → pay → ship → deliver`
with a configurable cancellation rate.

### Consumer options

```bash
python python/consumer.py                               # all tables, latest offset
python python/consumer.py --topic ecommerce.public.orders   # single topic
python python/consumer.py --from-beginning              # replay full history
```

### Connector management

```bash
# Register all connectors (skips any that are already RUNNING)
bash scripts/register_connector.sh

# Register source connector only
bash scripts/register_connector.sh source

# Register sink connector only
bash scripts/register_connector.sh sink

# Force delete and re-register (use after changing connector config)
bash scripts/register_connector.sh --force
```

### Stopping the stack

```bash
# Stop containers, preserve Kafka and PostgreSQL data volumes
./scripts/stop.sh

# Full teardown — wipe all volumes and network (fresh start next time)
./scripts/stop.sh --clean
```

> **Note:** `stop.sh` without `--clean` preserves both Docker volumes (`cdc-kafka-data`, `cdc-postgres-data`). On next `start.sh`, Debezium resumes from the last committed WAL LSN — no re-snapshot, no duplicate events.

---

## Operational Reference

### Service endpoints

| Service         | URL / Address          | Purpose                     |
|-----------------|------------------------|-----------------------------|
| Kafka (external)| `localhost:9093`       | Host machine clients (Python, CLI) |
| Schema Registry | `http://localhost:8081`| Schema CRUD, compatibility  |
| PostgreSQL      | `localhost:5432`       | DB: `ecommerce`, user: `ecommerce_user` |
| Kafka Connect   | `http://localhost:8083`| Connector REST API          |

### Kafka Connect REST API quick reference

```bash
# Check connector status (most useful first command when debugging)
curl -s http://localhost:8083/connectors/ecommerce-postgres-cdc/status \
  | python3 -m json.tool

# Restart a failed task
curl -X POST http://localhost:8083/connectors/ecommerce-postgres-cdc/tasks/0/restart

# Pause connector (stops consuming WAL without losing position)
curl -X PUT http://localhost:8083/connectors/ecommerce-postgres-cdc/pause

# Resume connector
curl -X PUT http://localhost:8083/connectors/ecommerce-postgres-cdc/resume

# List all registered plugins (verify Debezium and S3 connector loaded)
curl -s http://localhost:8083/connector-plugins | python3 -m json.tool

# Dynamically change log level (no restart needed)
curl -X PUT http://localhost:8083/admin/loggers/io.debezium \
  -H "Content-Type: application/json" -d '{"level": "DEBUG"}'
```

### Kafka CLI reference

> The `kafka-*` scripts are not on `$PATH` inside `apache/kafka:4.x`. Always use the full path.

```bash
# List topics
docker exec cdc-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Describe a topic (check partition count, retention policy)
docker exec cdc-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe --topic ecommerce.public.orders

# Tail messages in raw JSON (bypasses Avro — useful for debugging)
docker exec cdc-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic ecommerce.public.orders \
  --from-beginning
```

### S3 output layout

```
s3://your-bucket/
└── raw/cdc/
    ├── ecommerce.public.users/
    │   └── year=2026/month=03/day=10/hour=14/
    │       └── ecommerce.public.users+0+000000000.avro
    ├── ecommerce.public.products/
    ├── ecommerce.public.orders/
    └── ecommerce.public.order_items/
```

Files are Hive-compatible Avro containers. Query directly with AWS Athena after creating a Glue crawler over the `raw/cdc/` prefix.

---

## Development Guide

### Adding a new table to CDC

1. Add `CREATE TABLE` and `ALTER TABLE ... REPLICA IDENTITY FULL` to `config/postgres/init.sql`
2. Add the table to `CREATE PUBLICATION debezium_pub FOR TABLE ...` in `init.sql`
3. Add the table name to `table.include.list` in `config/debezium/postgres-connector.json`
4. Add the Kafka topic name to `topics` in `config/debezium/s3-sink-connector.json`
5. Run `./scripts/stop.sh --clean && ./scripts/build.sh postgres && ./scripts/start.sh`

### Adding a new Kafka connector

1. Add the `confluent-hub install` or `curl`+`unzip` step to `docker/Dockerfile.cpkafkaconnect`
2. Add the connector JSON config to `config/debezium/`
3. Register the new connector name and config path in the `SINK_CONNECTORS` or `SOURCE_CONNECTORS` array in `scripts/register_connector.sh`
4. Run `./scripts/build.sh connect`, recreate the container, then `bash scripts/register_connector.sh`

### Rebuilding a single image

```bash
./scripts/build.sh kafka       # rebuild only Kafka image
./scripts/build.sh postgres    # rebuild only PostgreSQL image
./scripts/build.sh registry    # rebuild only Schema Registry image
./scripts/build.sh connect     # rebuild only Kafka Connect image (most common)
./scripts/build.sh             # rebuild all
```

After rebuilding an image, recreate only the affected container:

```bash
docker stop cdc-debezium && docker rm cdc-debezium
./scripts/start.sh   # detects missing container, creates fresh one
```

Connector registrations survive container recreation — they are stored in the `debezium_connect_configs` Kafka topic, not in the container.

### Python development

```bash
cd python

# Edit config.py to point at local services
# KAFKA_BOOTSTRAP = "localhost:9093"
# SCHEMA_REGISTRY = "http://localhost:8081"

# Run type checks (optional)
pip install mypy
mypy consumer.py simulate.py

# Format
pip install black
black .
```

---

## Contributing

Contributions are welcome. Please follow the workflow below to keep the project consistent.

### Branching strategy

```
main          stable, tested, matches README
feat/<name>   new features
fix/<name>    bug fixes
docs/<name>   documentation only
```

### Before submitting a pull request

```bash
# 1. Run a full clean start to verify your changes work end-to-end
./scripts/stop.sh --clean
./scripts/build.sh
./scripts/start.sh

# 2. Confirm both connectors reach RUNNING
curl -s http://localhost:8083/connectors?expand=status | python3 -m json.tool

# 3. Run the simulator and confirm events appear in the consumer
# Terminal 1:
python python/simulate.py --loops 2
# Terminal 2:
python python/consumer.py --from-beginning

# 4. Verify no secrets are staged for commit
git diff --staged | grep -iE "AWS_|secret|password|key"
```

### What to check before modifying connector configs

- After changing `postgres-connector.json`, re-register with `--force`:
  ```bash
  bash scripts/register_connector.sh source --force
  ```
- After changing `s3-sink-connector.json`, re-register with `--force`:
  ```bash
  bash scripts/register_connector.sh sink --force
  ```
- After changing `Dockerfile.cpkafkaconnect`, rebuild and recreate the Connect container.

### Commit message format

```
type(scope): short description

type:  feat | fix | docs | refactor | chore
scope: kafka | postgres | connect | s3 | python | scripts | docker

Examples:
  feat(connect): add S3 sink connector with Avro format
  fix(postgres): set publication.autocreate.mode to disabled
  docs(readme): add operational reference section
  chore(scripts): make register_connector.sh idempotent
```

### What not to commit

```gitignore
# Credentials — never commit these
config/connect/aws-credentials.properties
config/connect/aws.env

# Python
venv/
__pycache__/
*.pyc
.mypy_cache/

# Docker build artifacts
*.log
```

---

## Troubleshooting

### Connector fails with `must be owner of publication`

The `debezium` database user does not own the `debezium_pub` publication.

**Fix:** ensure `publication.autocreate.mode` is `disabled` in `postgres-connector.json`. The publication is created by `init.sql` under `ecommerce_user` — Debezium should use it as-is without attempting to ALTER it.

### `ModuleNotFoundError: No module named 'certifi'`

```bash
pip install certifi
# or reinstall everything
pip install -r python/requirements.txt
```

### Consumer receives no events after stack restart

The consumer likely has a committed offset from a previous run. Run with `--from-beginning` to replay, or delete the consumer group offset:

```bash
python python/consumer.py --from-beginning
```

### S3 connector in FAILED state

```bash
# Check the task error message
curl -s http://localhost:8083/connectors/ecommerce-s3-sink/status | python3 -m json.tool

# Common causes:
# 1. AWS credentials not set — verify env vars reached the container
docker exec cdc-debezium env | grep AWS_

# 2. S3 bucket does not exist or wrong region
# 3. IAM user lacks s3:PutObject permission on the bucket
```

### Kafka topic not found when registering connector

Run topic creation before registering connectors:

```bash
bash scripts/create_topics.sh
bash scripts/register_connector.sh
```

### Container exits with code 137

The JVM process was OOM-killed by Docker. Increase memory in Docker Desktop settings or add heap tuning to the relevant Dockerfile:

```dockerfile
ENV KAFKA_HEAP_OPTS="-Xms512m -Xmx1g"
```

### Full reset

When in doubt, wipe everything and start clean:

```bash
./scripts/stop.sh --clean
./scripts/build.sh
./scripts/start.sh
```
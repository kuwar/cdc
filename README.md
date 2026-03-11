## Change Data Capture (CDC)

```
cdc-ecommerce/
├── docker/
│   ├── Dockerfile.kafka
│   ├── Dockerfile.postgres
│   ├── Dockerfile.schema-registry
│   └── Dockerfile.debezium
├── config/
│   ├── postgres/  → custom.conf  pg_hba.conf  init.sql
│   └── debezium/  → postgres-connector.json
├── scripts/       → start.sh  stop.sh  create_topics.sh  register_connector.sh
└── python/        → config.py  simulate.py  consumer.py  requirements.txt

```

## Schema
```
{
  "before": {
    "id": 1,
    "status": "PENDING",
    "total_cents": 4999
  },
  "after": {
    "id": 1,
    "status": "PAID",
    "total_cents": 4999
  },
  "source": {
    "db": "ecommerce",
    "table": "orders",
    "lsn": 23068700,
    "txId": 742,
    "ts_ms": 1704067200000
  },
  "op": "u",
  "ts_ms": 1704067200150
}
```
**op values: c = INSERT, u = UPDATE, d = DELETE, r = READ (snapshot)**





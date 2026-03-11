-- config/postgres/init.sql
--
-- E-commerce schema: intentionally minimal.
-- 4 tables, enough to demonstrate the full CDC lifecycle:
--   users → registers
--   products → stock changes on order
--   orders → status transitions (PENDING→PAID→SHIPPED→DELIVERED / CANCELLED)
--   order_items → line items per order

-- ── Debezium replication user ─────────────────────────────────────────────────
-- REPLICATION: allows the user to connect via replication protocol (WAL)
-- LOGIN: needed for psql-style connections
-- Not a superuser — least-privilege principle.
CREATE USER debezium WITH
    REPLICATION
    LOGIN
    PASSWORD 'debezium_pass';

-- Grant SELECT on all current and future tables in public schema.
-- Debezium needs SELECT for the initial snapshot (reads all existing rows).
GRANT CONNECT ON DATABASE ecommerce TO debezium;
GRANT USAGE ON SCHEMA public TO debezium;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium;

-- ── Tables ────────────────────────────────────────────────────────────────────

CREATE TABLE users (
    id          BIGSERIAL       PRIMARY KEY,
    email       VARCHAR(255)    NOT NULL UNIQUE,
    name        VARCHAR(255)    NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TABLE products (
    id          BIGSERIAL       PRIMARY KEY,
    name        VARCHAR(255)    NOT NULL,
    price_cents INTEGER         NOT NULL CHECK (price_cents > 0),
    stock       INTEGER         NOT NULL DEFAULT 0 CHECK (stock >= 0),
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TABLE orders (
    id          BIGSERIAL       PRIMARY KEY,
    user_id     BIGINT          NOT NULL REFERENCES users(id),
    -- Status lifecycle: PENDING → PAID → SHIPPED → DELIVERED
    --                   PENDING → CANCELLED  (before payment)
    --                   PAID    → CANCELLED  (after payment — triggers refund event)
    status      VARCHAR(50)     NOT NULL DEFAULT 'PENDING'
                                CHECK (status IN ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED')),
    total_cents INTEGER         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TABLE order_items (
    id          BIGSERIAL       PRIMARY KEY,
    order_id    BIGINT          NOT NULL REFERENCES orders(id),
    product_id  BIGINT          NOT NULL REFERENCES products(id),
    quantity    INTEGER         NOT NULL CHECK (quantity > 0),
    -- price_cents at time of order (snapshot — product price may change later)
    price_cents INTEGER         NOT NULL
);

-- ── Indexes ───────────────────────────────────────────────────────────────────
CREATE INDEX idx_orders_user_id      ON orders(user_id);
CREATE INDEX idx_orders_status       ON orders(status);
CREATE INDEX idx_order_items_order   ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);

-- ── REPLICA IDENTITY FULL ─────────────────────────────────────────────────────
-- PostgreSQL default REPLICA IDENTITY is DEFAULT: only primary key columns
-- are included in the WAL before-image for UPDATE and DELETE events.
--
-- With DEFAULT, Debezium's UPDATE event looks like:
--   before: {id: 1}                                 ← only PK!
--   after:  {id: 1, status: "PAID", ...}            ← full row
--
-- With FULL, Debezium's UPDATE event looks like:
--   before: {id: 1, status: "PENDING", ...}         ← full row
--   after:  {id: 1, status: "PAID", ...}            ← full row
--
-- FULL is required if consumers need to know what changed (old vs new value).
-- Cost: WAL entries are larger (full row written twice for every UPDATE).
-- For CDC/audit use cases, FULL is almost always the right choice.
ALTER TABLE users        REPLICA IDENTITY FULL;
ALTER TABLE products     REPLICA IDENTITY FULL;
ALTER TABLE orders       REPLICA IDENTITY FULL;
ALTER TABLE order_items  REPLICA IDENTITY FULL;

-- ── Publication ───────────────────────────────────────────────────────────────
-- Publication defines which tables are included in the logical replication stream.
-- Debezium can create this automatically, but explicit creation gives us control.
-- FOR ALL TABLES: captures all current and future tables.
-- Alternative: FOR TABLE users, products, orders, order_items (explicit list).
CREATE PUBLICATION debezium_pub FOR TABLE users, products, orders, order_items;

-- ── Seed products ─────────────────────────────────────────────────────────────
-- Pre-populate product catalogue so simulate.py can place orders immediately.
INSERT INTO products (name, price_cents, stock) VALUES
    ('Wireless Headphones',     9999,  50),
    ('Mechanical Keyboard',    14999,  30),
    ('USB-C Hub',               4999, 100),
    ('Laptop Stand',            3999,  75),
    ('Webcam HD',               7999,  40),
    ('Mouse Pad XL',            1999, 200),
    ('Cable Management Kit',    2499,  60),
    ('Monitor Light Bar',       3499,  45);

-- ── Heartbeat table ───────────────────────────────────────────────────────────
-- Debezium heartbeats: when business tables are idle, the replication slot LSN
-- doesn't advance — PostgreSQL cannot reclaim WAL segments.
-- The heartbeat action query writes to this table periodically, advancing the slot.
CREATE TABLE debezium_heartbeat (
    id  INT         PRIMARY KEY DEFAULT 1,
    ts  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO debezium_heartbeat VALUES (1, NOW());
GRANT INSERT, UPDATE, SELECT ON debezium_heartbeat TO debezium;
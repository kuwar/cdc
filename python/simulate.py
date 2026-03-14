#!/usr/bin/env python3
# python/simulate.py
#
# Simulates realistic e-commerce user behaviour:
#   register → browse → place_order → pay → ship → deliver
#                                  ↘ cancel (some % of orders)
#
# Every write triggers Debezium to read the WAL and publish a CDC event to Kafka.
# Run consumer.py in a separate terminal to see events in real-time.
#
# Usage:
#   pip install -r requirements.txt
#   python python/simulate.py
#   python python/simulate.py --loops 5  (run 5 full cycles then exit)

import time
import random
import logging
import argparse
import uuid
from datetime import datetime
import psycopg2
import psycopg2.extras
from faker import Faker

from config import DB

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("simulate")
fake = Faker()


# ── Database helpers ───────────────────────────────────────────────────────────

def get_connection():
    return psycopg2.connect(**DB, cursor_factory=psycopg2.extras.RealDictCursor)


def fetch_one(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def fetch_all(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def execute(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        result = cur.fetchone() if cur.description else None
    conn.commit()
    return result


# ── User actions ───────────────────────────────────────────────────────────────

def register_user(conn) -> dict:
    """
    INSERT into users.
    Debezium emits: op=c  topic=ecommerce.public.users
    """
    name  = fake.name()
    email = f"{fake.user_name()}+{uuid.uuid4().hex[:8]}@{fake.free_email_domain()}"

    user = execute(conn, """
        INSERT INTO users (name, email)
        VALUES (%s, %s)
        RETURNING id, name, email, created_at
    """, (name, email))

    log.info(f"👤 REGISTER   user_id={user['id']}  email={user['email']}")
    return dict(user)


def browse_products(conn) -> list:
    """
    Pure SELECT — no WAL write, no CDC event.
    Represents a user browsing the product catalogue.
    """
    products = fetch_all(conn, "SELECT * FROM products WHERE stock > 0 ORDER BY RANDOM() LIMIT 4")
    names = [p['name'] for p in products]
    log.info(f"🔍 BROWSE     saw: {', '.join(names)}")
    return [dict(p) for p in products]


def place_order(conn, user_id: int, products: list) -> dict | None:
    """
    Three writes in one transaction:
      1. INSERT orders (status=PENDING)
      2. INSERT order_items (one per product)
      3. UPDATE products (reduce stock)

    Debezium emits 3+ CDC events:
      op=c  ecommerce.public.orders
      op=c  ecommerce.public.order_items  (one per item)
      op=u  ecommerce.public.products     (one per item, stock change)

    All three happen atomically — Debezium preserves transaction boundaries
    (all events share the same source.txId in the CDC envelope).
    """
    # Pick 1-3 random products with available stock
    chosen = random.sample(products, k=min(random.randint(1, 3), len(products)))

    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            # Verify stock and lock chosen products
            placeholders = ','.join(['%s'] * len(chosen))
            cur.execute(f"""
                SELECT id, name, price_cents, stock
                FROM products
                WHERE id = ANY(ARRAY[{placeholders}])
                FOR UPDATE
            """, [p['id'] for p in chosen])
            locked = {row['id']: row for row in cur.fetchall()}

            # Build line items
            items = []
            for p in chosen:
                row = locked[p['id']]
                if row['stock'] < 1:
                    continue
                qty = random.randint(1, min(3, row['stock']))
                items.append({
                    'product_id': row['id'],
                    'name':       row['name'],
                    'price_cents': row['price_cents'],
                    'qty':        qty,
                })

            if not items:
                conn.rollback()
                log.warning("  No items in stock — skipping order")
                return None

            total = sum(i['price_cents'] * i['qty'] for i in items)

            # 1. Create order
            cur.execute("""
                INSERT INTO orders (user_id, status, total_cents)
                VALUES (%s, 'PENDING', %s)
                RETURNING id
            """, (user_id, total))
            order_id = cur.fetchone()['id']

            # 2. Insert order items
            for item in items:
                cur.execute("""
                    INSERT INTO order_items (order_id, product_id, quantity, price_cents)
                    VALUES (%s, %s, %s, %s)
                """, (order_id, item['product_id'], item['qty'], item['price_cents']))

            # 3. Reduce stock
            for item in items:
                cur.execute("""
                    UPDATE products
                    SET stock = stock - %s
                    WHERE id = %s
                """, (item['qty'], item['product_id']))

        conn.commit()
        summary = ', '.join(f"{i['qty']}x {i['name']}" for i in items)
        log.info(f"🛒 ORDER      order_id={order_id}  total=€{total/100:.2f}  items=[{summary}]")
        return {"id": order_id, "user_id": user_id, "total_cents": total, "items": items}

    except Exception as e:
        conn.rollback()
        log.error(f"  place_order failed: {e}")
        return None
    finally:
        conn.autocommit = True


def pay_order(conn, order_id: int):
    """
    UPDATE orders: PENDING → PAID

    Debezium emits: op=u  ecommerce.public.orders
      before: {status: "PENDING"}
      after:  {status: "PAID"}
    """
    execute(conn, """
        UPDATE orders
        SET status = 'PAID', updated_at = NOW()
        WHERE id = %s AND status = 'PENDING'
    """, (order_id,))
    log.info(f"💳 PAY        order_id={order_id}  PENDING → PAID")


def cancel_order(conn, order_id: int):
    """
    UPDATE orders: PENDING/PAID → CANCELLED
    Also restores product stock (compensating write).

    Debezium emits:
      op=u  ecommerce.public.orders     (status → CANCELLED)
      op=u  ecommerce.public.products   (stock restored, one per item)
    """
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            # Check current status
            cur.execute("SELECT status FROM orders WHERE id = %s FOR UPDATE", (order_id,))
            row = cur.fetchone()
            if not row or row['status'] not in ('PENDING', 'PAID'):
                conn.rollback()
                log.warning(f"  Cannot cancel order_id={order_id} in status={row['status'] if row else 'NOT FOUND'}")
                return

            # Cancel order
            cur.execute("""
                UPDATE orders
                SET status = 'CANCELLED', updated_at = NOW()
                WHERE id = %s
            """, (order_id,))

            # Restore stock for each line item
            cur.execute("""
                SELECT product_id, quantity FROM order_items WHERE order_id = %s
            """, (order_id,))
            for item in cur.fetchall():
                cur.execute("""
                    UPDATE products SET stock = stock + %s WHERE id = %s
                """, (item['quantity'], item['product_id']))

        conn.commit()
        log.info(f"❌ CANCEL     order_id={order_id}  → CANCELLED (stock restored)")

    except Exception as e:
        conn.rollback()
        log.error(f"  cancel_order failed: {e}")
    finally:
        conn.autocommit = True


def ship_order(conn, order_id: int):
    """
    UPDATE orders: PAID → SHIPPED

    Debezium emits: op=u  ecommerce.public.orders
      before: {status: "PAID"}
      after:  {status: "SHIPPED"}
    """
    execute(conn, """
        UPDATE orders SET status = 'SHIPPED', updated_at = NOW()
        WHERE id = %s AND status = 'PAID'
    """, (order_id,))
    log.info(f"📦 SHIP       order_id={order_id}  PAID → SHIPPED")


def deliver_order(conn, order_id: int):
    """
    UPDATE orders: SHIPPED → DELIVERED

    Debezium emits: op=u  ecommerce.public.orders
      before: {status: "SHIPPED"}
      after:  {status: "DELIVERED"}
    """
    execute(conn, """
        UPDATE orders SET status = 'DELIVERED', updated_at = NOW()
        WHERE id = %s AND status = 'SHIPPED'
    """, (order_id,))
    log.info(f"✅ DELIVER    order_id={order_id}  SHIPPED → DELIVERED")


def track_order(conn, order_id: int):
    """
    SELECT only — no CDC event. Represents a user checking their order status.
    """
    row = fetch_one(conn, """
        SELECT o.id, o.status, o.total_cents, o.updated_at,
               COUNT(oi.id) AS item_count
        FROM orders o
        JOIN order_items oi ON oi.order_id = o.id
        WHERE o.id = %s
        GROUP BY o.id
    """, (order_id,))
    if row:
        log.info(f"🔎 TRACK      order_id={order_id}  status={row['status']}  "
                 f"items={row['item_count']}  total=€{row['total_cents']/100:.2f}")


# ── Simulation loop ────────────────────────────────────────────────────────────

def run_simulation_cycle(conn):
    """
    One full user journey cycle.
    Includes realistic timing delays between actions.
    """
    pause = lambda: time.sleep(random.uniform(0.3, 1.0))

    # 1. Register a new user
    user = register_user(conn)
    pause()

    # 2. Browse products
    products = browse_products(conn)
    if not products:
        log.warning("No products in stock — skipping cycle")
        return
    pause()

    # 3. Place an order
    order = place_order(conn, user['id'], products)
    if not order:
        return
    pause()

    # 4. Track immediately after placing
    track_order(conn, order['id'])
    pause()

    # 5. Randomly cancel ~20% of orders before payment
    if random.random() < 0.20:
        cancel_order(conn, order['id'])
        return

    # 6. Pay the order
    pay_order(conn, order['id'])
    pause()

    # 7. Randomly cancel ~10% after payment (refund scenario)
    if random.random() < 0.10:
        cancel_order(conn, order['id'])
        return

    # 8. Track again
    track_order(conn, order['id'])
    pause()

    # 9. Ship
    ship_order(conn, order['id'])
    pause()

    # 10. Deliver
    deliver_order(conn, order['id'])

    log.info(f"─── Cycle complete for user_id={user['id']} order_id={order['id']} ───")


def main():
    parser = argparse.ArgumentParser(description="E-commerce CDC simulator")
    parser.add_argument("--loops", type=int, default=0,
                        help="Number of cycles to run (0 = infinite)")
    parser.add_argument("--delay", type=float, default=1.5,
                        help="Seconds between cycles")
    args = parser.parse_args()

    log.info("E-commerce simulator starting...")
    log.info(f"  loops={args.loops or '∞'}  delay={args.delay}s between cycles")
    log.info("  Run consumer.py in another terminal to see CDC events")
    log.info("─" * 60)

    conn = get_connection()
    conn.autocommit = True

    cycle = 0
    try:
        while True:
            cycle += 1
            log.info(f"═══ Cycle {cycle} ═══")
            run_simulation_cycle(conn)
            if args.loops and cycle >= args.loops:
                break
            time.sleep(args.delay)
    except KeyboardInterrupt:
        log.info("Stopped by user")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
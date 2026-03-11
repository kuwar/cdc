# test_host.py — run this on your host machine, NOT inside Docker
from confluent_kafka import Producer, Consumer
from confluent_kafka.admin import AdminClient, NewTopic

# ── Connect from host using EXTERNAL listener port 9093 ───────────────────────
BOOTSTRAP = "localhost:9093"

# List existing topics
admin = AdminClient({"bootstrap.servers": BOOTSTRAP})
meta = admin.list_topics(timeout=10)
print("Topics:", list(meta.topics.keys()))

# Produce a message
p = Producer({"bootstrap.servers": BOOTSTRAP})

def on_delivery(err, msg):
    if err:
        print(f"Delivery failed: {err}")
    else:
        print(f"Delivered → topic={msg.topic()} partition={msg.partition()} offset={msg.offset()}")

p.produce("test-cdc", key="k1", value="hello from host", on_delivery=on_delivery)
p.flush()

# Consume it back
c = Consumer({
    "bootstrap.servers": BOOTSTRAP,
    "group.id": "host-test-group",
    "auto.offset.reset": "earliest",
})
c.subscribe(["test-cdc"])
msg = c.poll(timeout=5.0)
if msg:
    print(f"Received: {msg.value().decode()}")
c.close()
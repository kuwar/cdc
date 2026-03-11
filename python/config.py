# python/config.py
#
# Central configuration for all Python scripts.
# In production these come from environment variables / secrets manager.

DB = {
    "host":     "localhost",
    "port":     5432,
    "dbname":   "ecommerce",
    "user":     "ecommerce_user",
    "password": "ecommerce_pass",
}

KAFKA_BOOTSTRAP    = "localhost:9093"  # EXTERNAL listener — Python runs on host
SCHEMA_REGISTRY    = "http://localhost:8081"
CONSUMER_GROUP     = "ecommerce-cdc-consumer"

TOPICS = [
    "ecommerce.public.users",
    "ecommerce.public.products",
    "ecommerce.public.orders",
    "ecommerce.public.order_items",
]
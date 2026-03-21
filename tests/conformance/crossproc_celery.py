# §22.2 Celery task validation — PROC004

from celery import Celery

app = Celery("tasks")

class Order:
    user = None
    query = None

@app.task
def process_order(order_id):
    order = Order.query.get(order_id)
    user = order.user  # E: lazy-loaded attribute in Celery task
    return user

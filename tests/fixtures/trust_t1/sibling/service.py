"""Order service — builds and prices orders. (Planted bugs 1-4.)"""
from __future__ import annotations
from models import Product, LineItem, Order


def make_product(sku: str, name: str, price: float) -> Product:
    return Product(sku, name, price)


def build_order(order_id: int, products: list[Product]) -> Order:
    order = Order(order_id)
    for p in products:
        # BUG 1: LineItem.quantity is int; passing str "1"
        item = LineItem(p, "1")
        order.add(item)
    return order


def apply_bulk_discount(order: Order, pct: float) -> Order:
    order.discount = pct
    return order


def cheapest(products: list[Product]) -> Product:
    best = None
    for p in products:
        if best is None or p.price < best.price:
            best = p
    # BUG 2: returns Product | None but declared -> Product (None on empty list)
    return best


def label(order: Order) -> str:
    # BUG 3: attribute typo — Order has order_id, not id
    return f"Order #{order.id}"


def total_price_cents(order: Order) -> int:
    # BUG 4: declared -> int but order.total() is float
    return order.total()

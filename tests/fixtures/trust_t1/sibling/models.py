"""Domain models for a small order-processing system. (No planted bugs.)"""
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class Product:
    sku: str
    name: str
    price: float
    tags: list[str] = field(default_factory=list)


@dataclass
class LineItem:
    product: Product
    quantity: int

    def subtotal(self) -> float:
        return self.product.price * self.quantity


@dataclass
class Order:
    order_id: int
    items: list[LineItem] = field(default_factory=list)
    discount: float = 0.0

    def total(self) -> float:
        raw = sum(item.subtotal() for item in self.items)
        return raw * (1.0 - self.discount)

    def add(self, item: LineItem) -> None:
        self.items.append(item)

"""Attribute narrowing: obj.attr guards narrow attribute types in if-branches."""
from typing import Optional

class Node:
    def __init__(self, value: int, next: Optional["Node"] = None) -> None:
        self.value = value
        self.next = next

# is not None narrowing on attribute
def attr_none_narrow(node: Node) -> int:
    if node.next is not None:
        return node.next.value
    return -1

# Truthiness narrowing on attribute
def attr_truthy(node: Node) -> int:
    if node.next:
        return node.next.value
    return -1

class Container:
    def __init__(self, data: Optional[str] = None) -> None:
        self.data = data

# is None + else branch narrowing
def attr_is_none(c: Container) -> str:
    if c.data is None:
        return "empty"
    return c.data

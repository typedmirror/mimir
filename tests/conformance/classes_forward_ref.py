from typing import Optional

class Node:
    value: int
    next: "Node"
    parent: Optional["Node"]

n = Node()
x: int = n.next  # E

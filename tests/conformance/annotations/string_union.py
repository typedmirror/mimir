# String annotation with union syntax: "X | Y"

class Node:
    left: "Node | None" = None
    right: "Node | None" = None
    value: int = 0

n = Node()
x: str = n.left  # E[T001]: Incompatible types

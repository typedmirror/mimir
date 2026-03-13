from typing import assert_type, Optional

# Forward reference with Optional for self-referential type
class Node:
    def __init__(self, val: int, next: Optional["Node"]) -> None:
        self.val = val
        self.next = next

# Can pass None for terminal node
leaf = Node(3, None)
assert_type(leaf.val, int)

# Can chain nodes
chain = Node(1, Node(2, Node(3, None)))
assert_type(chain.val, int)
